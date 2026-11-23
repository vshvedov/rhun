# The agents panel's popup list (generic): the command menu, the mode picker and the model picker, drawn
# above the prompt box over the conversation's bottom, in the panel's faces and metrics, and kept by the
# keyboard.
#
# The model picker: "Select a model", a row per model (a check on the one in use, the unavailable greyed and
# never picked), "Loading models…" / "No models available", then the effort row (a track: click or drag;
# Enter or a click on its label goes to the next level round; Left and Right step) and the Ultracode switch.
# The modes picker ends with the effort row too. Picks go to the driver (DRV_set_model, DRV_set_effort
# through DRV_action ACT_EFFORT, DRV_set_ultra, DRV_set_thinking); nothing here starts a process.
#
# The command menu has two modes. Typed: the box's caret is in a token matching (?:^|\s)/[^\s/]* (the token
# is the filter; the menu closes when the caret leaves it); it takes Enter, Tab and the arrows only while it
# shows a row, every other key goes on to the box. Button (agent-menu; the footer's "/"): its filter field
# "Filter actions…" takes the keys. Sections in order: Context, Model, Customize, Settings, Support (the
# driver's actions, DRV_menu: APM entries, each shown by its own rule), then Slash Commands (every command
# the program advertises, and the driver's /copy and /plan; in button mode only once the filter starts with
# "/"). Filtered: an exact match on a label, a name or an alias first, then a prefix, then the best of 3 x
# the label's, 2 x the name's or an alias's, 0.5 x the description's fuzzy score (palette.s); each section
# follows its best row. Enter on a row: an action runs (its token leaves the box); a slash command typed
# whole is sent as text (Enter goes on to the box), another is completed as Tab completes it ("/name ").
# Nothing here starts a process or reads a file but the driver's record (agentcfg_need: opening a popup is a
# writer's action).
#
#   agentpop_open(kind APP_*, AS*, typed) -> eax 1 open (the box's owner's; typed 1: the box's "/token")
#   agentpop_close(), agentpop_kind() -> eax APP_* or 0, agentpop_owner() -> rax AS* or 0
#   agentpop_typed(ptr, len, caret)     the box changed: the typed menu opens, follows or closes
#   agentpop_key(keysym, cp, mods) -> eax taken (never in typed mode while it shows no row)
#   agentpop_h(w) -> eax, agentpop_draw(x, bottom, w, max_h)   above the box, over the thread
#   agentpop_shield(), agentpop_unshield()   around what is drawn under it: the pointer there is the popup's
#   agentpop_gone(ptr)                  an AS or AQ is freed: the popup opened for it closes
#   agentpop_changed()                  the driver's lists changed (ev_config)
#   agentpop_field() -> rax the button menu's filter field, or 0
#   agentpop_slash(AS*, ptr, len) -> eax 1 when the text is a command the driver's own table runs (it ran)
#   agentpop_run(AS* or 0, kind, act, ptr, len)     a command's action
#   agentpop_pick(n) -> eax 1           row n (from 1) as Enter would (headless)
#   agentpop_dump(sb)                   print-agent-menu; agentpop_fit_dump(sb) its layout at every size
.include "rhun.inc"

.equ R_INFO, 6                  # agents.s's info row
.equ ROWS_IDS, 0x3fd            # rows with a button id of their own (later ones share the last)
.equ ID_TRACK, 0x3fe            # ID_AGPOP + : the effort row's track
.equ AT_MAX, 64                 # rows whose drawn place print-agent-menu names
.equ QB_MAX, 63
.equ DROPPED, 9                 # a row the filter leaves out (PR_tier)

# a row: APR's fields (rhun.inc), then what the filter and the keys need
STRUCT
F PR_kind, 4
F PR_flags, 4
F PR_label, 8
F PR_desc, 8
F PR_trail, 8
F PR_act, 4
F PR_sec, 4
F PR_arg, 8
F PR_name, 8            # a slash command's name, or 0
F PR_alias, 8           # its aliases, space-separated, or 0
F PR_extra, 8           # a levels row's level id, or 0
F PR_model, 8           # a levels row's model (AMO*: its levels), or 0
F PR_tier, 4            # 0 exact, 1 prefix, 2 fuzzy, DROPPED
F PR_score, 4
ENDSTRUCT PR_SIZE

.bss
.p2align 3
pop_tf: .zero TF_SIZE           # the button menu's filter field
pop_q: .zero SB_SIZE            # the filter as typed (the typed menu: the token, its "/" too)
psb: .zero SB_SIZE
cands: .zero VEC_SIZE           # PR: every row that may show, before the filter
rows: .zero VEC_SIZE            # PR: what shows, sections among them
keys: .zero VEC_SIZE            # qwords: the order (a candidate's index in the low 16 bits)
owned: .zero VEC_SIZE           # strings made for the rows, freed at the next build
tmpl: .zero PR_SIZE             # the row being made
pop_owner: .quad 0              # the box's owner it was opened for (0: a new conversation's draft)
pop_aq: .quad 0                 # the request it was opened for, or 0
pop_usel_arg: .quad 0           # the row the user chose: its arg and act
pop_ts: .quad 0                 # typed: the token in the box
pop_te: .quad 0
dis_hash: .quad 0               # the typed menu was closed with Escape over this text (its hash), 0 none
q_ptr: .quad 0                  # the filter without its "/"
q_len: .quad 0
pop_kind: .long 0               # APP_*, 0 closed
pop_typed: .long 0
pop_dkind: .long 0              # the driver kind
pop_slash: .long 0              # the slash commands show
pop_sel: .long 0                # the selected row (index in rows), -1 none
pop_user: .long 0               # the user chose it (keys, the pointer)
pop_usel_act: .long 0
pop_scroll: .long 0
pop_reveal: .long 0
pop_shielded: .long 0
pop_mx: .long 0
pop_my: .long 0
pop_rect: .zero 16              # x, y, w, h as drawn last (h 0: not drawn)
qbuf: .zero QB_MAX + 1          # the filter, lower case, without separators (: _ - and blanks)
qblen: .long 0
g_px: .long 0                   # geom's results
g_py: .long 0
g_pw: .long 0
g_ph: .long 0
g_ry: .long 0
g_rh: .long 0
g_fh: .long 0
lay_lx: .long 0                 # row_geom's results: the label, the description, the trail
lay_lw: .long 0
lay_dx: .long 0
lay_dw: .long 0
lay_tx: .long 0
lay_tw: .long 0
secrank: .zero 8
row_ay: .zero 4 * AT_MAX        # as drawn last: each row's centre (y; 0 not drawn), the track's rect
trk_rect: .zero 16

.text

# ---- state ----

# FN agentpop_kind() -> eax APP_* or 0
FN agentpop_kind
    mov eax, [rip + pop_kind]
    ret

# FN agentpop_owner() -> rax the AS* it belongs to (0: a draft's, or closed)
FN agentpop_owner
    mov rax, [rip + pop_owner]
    ret

# FN agentpop_close()
FN agentpop_close
    cmp dword ptr [rip + pop_kind], 0
    je 1f
    mov dword ptr [rip + g_dirty], 1
1:  mov dword ptr [rip + pop_kind], 0
    mov dword ptr [rip + pop_typed], 0
    mov dword ptr [rip + pop_rect + 12], 0
    mov qword ptr [rip + pop_owner], 0
    mov qword ptr [rip + pop_aq], 0
    ret

# FN agentpop_gone(ptr): an AS or an AQ is freed: the popup opened for it closes
FN agentpop_gone
    test rdi, rdi
    jz 9f
    cmp dword ptr [rip + pop_kind], 0
    je 9f
    cmp rdi, [rip + pop_owner]
    je agentpop_close
    cmp rdi, [rip + pop_aq]
    je agentpop_close
9:  ret

# FN agentpop_changed(): the driver's lists changed: the rows are made again when it draws
FN agentpop_changed
    cmp dword ptr [rip + pop_kind], 0
    je 1f
    mov dword ptr [rip + g_dirty], 1
1:  ret

# FN agentpop_field() -> rax the button menu's filter field, or 0
FN agentpop_field
    xor eax, eax
    cmp dword ptr [rip + pop_kind], APP_MENU
    jne 1f
    cmp dword ptr [rip + pop_typed], 0
    jne 1f
    lea rax, [rip + pop_tf]
1:  ret

# FN agentpop_shield(): before what is drawn under the popup: the pointer over last frame's popup is its
#   own (g_block), until agentpop_unshield
FN agentpop_shield
    mov dword ptr [rip + pop_shielded], 0
    cmp dword ptr [rip + pop_kind], 0
    je 9f
    cmp dword ptr [rip + pop_rect + 12], 0
    je 9f
    cmp dword ptr [rip + g_block], 0
    jne 9f
    mov eax, [rip + g_mx]
    mov ecx, [rip + pop_rect]
    cmp eax, ecx
    jl 9f
    add ecx, [rip + pop_rect + 8]
    cmp eax, ecx
    jge 9f
    mov eax, [rip + g_my]
    mov ecx, [rip + pop_rect + 4]
    cmp eax, ecx
    jl 9f
    add ecx, [rip + pop_rect + 12]
    cmp eax, ecx
    jge 9f
    mov dword ptr [rip + g_block], 1
    mov dword ptr [rip + pop_shielded], 1
9:  ret

# FN agentpop_unshield()
FN agentpop_unshield
    cmp dword ptr [rip + pop_shielded], 0
    je 1f
    mov dword ptr [rip + g_block], 0
    mov dword ptr [rip + pop_shielded], 0
1:  ret

# need_cfg(): the driver's record is read (opening a popup is a writer's action)
need_cfg:
    PROLOGUE
    mov edi, [rip + pop_dkind]
    call agentcfg_get
    mov rdi, rax
    call agentcfg_need
    EPILOGUE

# FN agentpop_open(kind APP_*, AS* (the box's owner), typed) -> eax 1 when it is open: typed 1 follows the box's
#   "/token" (none: it stays closed); a picker with nothing to show does not open
FN agentpop_open
    PROLOGUE
    mov r12d, edi
    mov r14d, edx
    test r14d, r14d
    jz 1f
    call agentpop_close
    mov qword ptr [rip + dis_hash], 0
    call agentext_box
    mov rbx, rax
    mov rdi, rax
    call tf_text
    mov rdi, rax
    mov rsi, rdx
    mov rdx, [rbx + TF_cur]
    call agentpop_typed
    jmp 7f
1:  call agentext_box_owner
    test edx, edx
    jz 8f
    mov [rip + pop_owner], rax
    mov [rip + pop_dkind], edx
    mov [rip + pop_kind], r12d
    mov dword ptr [rip + pop_typed], 0
    mov qword ptr [rip + pop_aq], 0
    mov dword ptr [rip + pop_user], 0
    mov dword ptr [rip + pop_scroll], 0
    lea rdi, [rip + pop_tf]
    call tf_clear
    mov dword ptr [rip + pop_tf + TF_id], ID_AGPOP + 0x3ff
    lea rdi, [rip + pop_q]
    call sb_clear
    mov byte ptr [rip + pop_q_marker], 1    # differs from any query: the first build starts fresh
    call need_cfg
    call sync
    call build
    cmp r12d, APP_MENU
    je 6f
    cmp qword ptr [rip + rows + VEC_len], 0
    jne 6f
    call agentpop_close
    jmp 8f
6:  mov dword ptr [rip + g_focus], FOCUS_AGENT_INPUT
7:  mov dword ptr [rip + g_dirty], 1
    xor eax, eax
    cmp dword ptr [rip + pop_kind], 0
    setne al
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN agentpop_typed(ptr, len, caret): the box's text or caret changed. Open, the typed menu follows its
#   token or closes; closed, it opens when the caret is in a token (not while the text is the one Escape
#   closed it over). A picker or the button menu stays as it is
FN agentpop_typed
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    cmp dword ptr [rip + pop_kind], 0
    je 1f
    cmp dword ptr [rip + pop_typed], 0
    je 9f
    call sync
    jmp 9f
1:  cmp dword ptr [rip + g_focus], FOCUS_AGENT_INPUT
    jne 9f
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    call find_token
    test rax, rax
    js 8f
    mov rdi, r12
    mov rsi, r13
    call hash_text
    cmp rax, [rip + dis_hash]
    je 9f
    call agentext_box_owner
    test edx, edx
    jz 9f
    mov [rip + pop_owner], rax
    mov [rip + pop_dkind], edx
    mov dword ptr [rip + pop_kind], APP_MENU
    mov dword ptr [rip + pop_typed], 1
    mov qword ptr [rip + pop_aq], 0
    mov dword ptr [rip + pop_user], 0
    mov dword ptr [rip + pop_scroll], 0
    lea rdi, [rip + pop_q]
    call sb_clear
    mov byte ptr [rip + pop_q_marker], 1
    call need_cfg
    call sync
    mov dword ptr [rip + g_dirty], 1
    jmp 9f
8:  mov qword ptr [rip + dis_hash], 0   # out of a token: Escape's mark goes
9:  EPILOGUE

# sync() -> eax 1 when the popup is open and still the box's: the owner and its kind are the box's, the typed
#   menu's caret is in its token (its filter follows it), the button menu's filter is its field; else it
#   closes
sync:
    PROLOGUE
    xor r15d, r15d
    cmp dword ptr [rip + pop_kind], 0
    je 9f
    call agentext_box_owner
    cmp rax, [rip + pop_owner]
    jne 8f
    cmp edx, [rip + pop_dkind]
    jne 8f
    cmp dword ptr [rip + pop_typed], 0
    je 2f
    cmp dword ptr [rip + g_focus], FOCUS_AGENT_INPUT
    jne 8f                      # the typed menu lives while the box has the keys
    call agentext_box
    mov rbx, rax
    mov rdi, rax
    call tf_text
    mov r12, rax
    mov r13, rdx
    mov rdi, r12
    mov rsi, r13
    mov rdx, [rbx + TF_cur]
    call find_token
    test rax, rax
    js 8f
    mov [rip + pop_ts], rax
    mov [rip + pop_te], rdx
    lea rdi, [r12 + rax]
    mov rsi, rdx
    sub rsi, rax
    call set_query
    jmp 7f
2:  xor esi, esi
    lea rdi, [rip + empty]
    cmp dword ptr [rip + pop_kind], APP_MENU
    jne 3f
    lea rdi, [rip + pop_tf]
    call tf_text
    mov rdi, rax
    mov rsi, rdx
3:  call set_query
7:  mov r15d, 1
    jmp 9f
8:  call agentpop_close
9:  mov eax, r15d
    EPILOGUE

# set_query(ptr, len): the filter; another one than before: the user's choice and the scroll go. q_ptr/q_len
#   without its "/", qbuf, and whether the slash commands show
set_query:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    cmp byte ptr [rip + pop_q_marker], 0
    jne 1f
    cmp r13, [rip + pop_q + SB_len]
    jne 1f
    mov rdi, r12
    mov rsi, [rip + pop_q + SB_ptr]
    mov rdx, r13
    test rdx, rdx
    jz 2f
    call memeq
    test eax, eax
    jnz 2f
1:  mov byte ptr [rip + pop_q_marker], 0
    lea rdi, [rip + psb]        # (ptr may be in pop_q itself)
    call sb_clear
    lea rdi, [rip + psb]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    lea rdi, [rip + pop_q]
    call sb_clear
    lea rdi, [rip + pop_q]
    mov rsi, [rip + psb + SB_ptr]
    mov rdx, [rip + psb + SB_len]
    call sb_push
    mov dword ptr [rip + pop_user], 0
    mov dword ptr [rip + pop_scroll], 0
2:  mov rax, [rip + pop_q + SB_ptr]
    mov rcx, [rip + pop_q + SB_len]
    test rax, rax
    jnz 3f
    lea rax, [rip + empty]
3:  mov edx, [rip + pop_typed]
    test rcx, rcx
    jz 4f
    cmp byte ptr [rax], '/'
    jne 4f
    inc rax
    dec rcx
    mov edx, 1
4:  mov [rip + q_ptr], rax
    mov [rip + q_len], rcx
    mov [rip + pop_slash], edx
    mov r12, rax                # qbuf: lower case, no separators
    mov r13, rcx
    xor ebx, ebx
    xor r14d, r14d
5:  cmp rbx, r13
    jae 6f
    movzx edi, byte ptr [r12 + rbx]
    inc rbx
    call is_sep
    test eax, eax
    jnz 5b
    cmp r14d, QB_MAX
    jae 6f
    lea eax, [rdi - 'A']
    cmp eax, 25
    ja 52f
    or edi, 0x20
52: lea rax, [rip + qbuf]
    mov [rax + r14], dil
    inc r14d
    jmp 5b
6:  mov [rip + qblen], r14d
    EPILOGUE

# is_sep(c) -> eax 1 for the separators of a typed name: : _ - and blanks (keeps every other register)
is_sep:
    xor eax, eax
    cmp edi, ':'
    je 1f
    cmp edi, '_'
    je 1f
    cmp edi, '-'
    je 1f
    cmp edi, ' '
    ja 2f
1:  mov eax, 1
2:  ret

# find_token(ptr, len, caret) -> rax where the "/token" holding the caret starts (its "/"), -1 none; rdx its
#   end: (?:^|\s)/[^\s/]*, the caret after its "/" and not past its end
find_token:
    cmp rdx, rsi
    jbe 0f
    mov rdx, rsi
0:  mov rcx, rdx
1:  test rcx, rcx
    jz 8f
    movzx eax, byte ptr [rdi + rcx - 1]
    cmp eax, '/'
    je 2f
    cmp eax, ' '
    jbe 8f
    dec rcx
    jmp 1b
2:  lea r8, [rcx - 1]
    test r8, r8
    jz 3f
    movzx eax, byte ptr [rdi + r8 - 1]
    cmp eax, ' '
    ja 8f
3:  mov rcx, rdx
4:  cmp rcx, rsi
    jae 5f
    movzx eax, byte ptr [rdi + rcx]
    cmp eax, ' '
    jbe 5f
    cmp eax, '/'
    je 5f
    inc rcx
    jmp 4b
5:  mov rax, r8
    mov rdx, rcx
    ret
8:  mov rax, -1
    ret

# hash_text(ptr, len) -> rax its FNV-1a hash (never 0)
hash_text:
    mov rax, 0xcbf29ce484222325
    mov r8, 0x100000001b3
    xor ecx, ecx
1:  cmp rcx, rsi
    jae 2f
    movzx edx, byte ptr [rdi + rcx]
    xor rax, rdx
    imul rax, r8
    inc rcx
    jmp 1b
2:  test rax, rax
    jnz 3f
    inc rax
3:  ret

# ---- the rows ----

# build(): the rows for the open popup and its filter, and its selection
build:
    PROLOGUE
    call free_owned
    mov qword ptr [rip + cands + VEC_len], 0
    mov qword ptr [rip + rows + VEC_len], 0
    mov qword ptr [rip + keys + VEC_len], 0
    call clear_tmpl
    mov eax, [rip + pop_kind]
    cmp eax, APP_MENU
    jne 1f
    call build_menu
    jmp 5f
1:  cmp eax, APP_MODES
    jne 2f
    call build_modes
    jmp 5f
2:  cmp eax, APP_MODELS
    jne 5f
    call build_models
5:  call select
    EPILOGUE

# free_owned(): the strings the last build made
free_owned:
    PROLOGUE
    xor ebx, ebx
1:  cmp rbx, [rip + owned + VEC_len]
    jae 2f
    mov rax, [rip + owned + VEC_ptr]
    mov rdi, [rax + rbx*8]
    call mem_free
    inc rbx
    jmp 1b
2:  mov qword ptr [rip + owned + VEC_len], 0
    EPILOGUE

# own_concat(a, b, c, d cstrs or 0) -> rax a new string of them, freed at the next build
own_concat:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    lea rdi, [rip + psb]
    call sb_clear
    mov rbx, r12
    call 1f
    mov rbx, r13
    call 1f
    mov rbx, r14
    call 1f
    mov rbx, r15
    call 1f
    mov rdi, [rip + psb + SB_ptr]
    mov rsi, [rip + psb + SB_len]
    call mem_dup
    mov rbx, rax
    lea rdi, [rip + owned]
    mov esi, 8
    call vec_push
    mov [rax], rbx
    mov rax, rbx
    EPILOGUE
1:  test rbx, rbx               # (a part, when there is one)
    jz 2f
    sub rsp, 8
    lea rdi, [rip + psb]
    mov rsi, rbx
    call sb_push_cstr
    add rsp, 8
2:  ret

# clear_tmpl(): the row being made is empty
clear_tmpl:
    lea rdi, [rip + tmpl]
    xor eax, eax
    mov ecx, PR_SIZE / 8
1:  mov [rdi], rax
    add rdi, 8
    dec ecx
    jnz 1b
    ret

# copy_pr(dst, src)
copy_pr:
    mov ecx, PR_SIZE / 8
1:  mov rax, [rsi]
    mov [rdi], rax
    add rsi, 8
    add rdi, 8
    dec ecx
    jnz 1b
    ret

# cand_push(): the row being made joins the candidates; row_push(): the rows; both empty it
cand_push:
    lea rdi, [rip + cands]
    jmp 1f
row_push:
    lea rdi, [rip + rows]
1:  PROLOGUE
    mov esi, PR_SIZE
    call vec_push
    mov rdi, rax
    lea rsi, [rip + tmpl]
    call copy_pr
    call clear_tmpl
    EPILOGUE

# row_push_from(PR*): a copy of a candidate joins the rows
row_push_from:
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rip + rows]
    mov esi, PR_SIZE
    call vec_push
    mov rdi, rax
    mov rsi, rbx
    call copy_pr
    EPILOGUE

# build_menu(): the driver's actions shown now, the slash commands (when they show), filtered and ordered,
#   with their sections; "No matching commands" when none; the version without a filter
build_menu:
    PROLOGUE 16
    mov edi, [rip + pop_dkind]
    call agent_drv_for_kind
    test rax, rax
    jz .Lbm_slash
    mov qword ptr [rsp], 0
    mov rdi, [rip + pop_owner]
    lea rsi, [rsp]
    call [rax + DRV_menu]
    mov r12d, eax
    mov r13, [rsp]
    test r13, r13
    jz .Lbm_slash
    xor r14d, r14d
.Lbm_act:
    cmp r14d, r12d
    jae .Lbm_slash
    imul r15, r14, APM_SIZE
    add r15, r13
    inc r14d
    test dword ptr [r15 + APM_flags], APRF_FILTERONLY
    jz 1f
    cmp qword ptr [rip + q_len], 0
    je .Lbm_act
1:  mov rdi, r15
    call apm_tmpl
    test eax, eax
    jz .Lbm_act
    call cand_push
    jmp .Lbm_act
.Lbm_slash:
    cmp dword ptr [rip + pop_slash], 0
    je .Lbm_rank
    mov edi, [rip + pop_dkind]
    call agentcfg_get
    mov rbx, rax
    xor r12d, r12d
.Lbm_cmd:
    cmp r12, [rbx + AGC_cmds + VEC_len]
    jae .Lbm_rank
    mov rax, [rbx + AGC_cmds + VEC_ptr]
    mov r13, [rax + r12*8]
    inc r12
    test dword ptr [r13 + ACM_flags], ACMF_CLI
    jnz 1f
    cmp dword ptr [r13 + ACM_act], ACT_COPY     # the driver's own that have no other target: listed
    je 1f
    cmp dword ptr [r13 + ACM_act], ACT_PLAN
    jne .Lbm_cmd
1:  lea rdi, [rip + .Lslash]
    mov rsi, [r13 + ACM_name]
    xor edx, edx
    xor ecx, ecx
    call own_concat
    mov [rip + tmpl + PR_label], rax
    mov rax, [r13 + ACM_desc]
    mov [rip + tmpl + PR_desc], rax
    mov rdx, [r13 + ACM_origin]         # a plugin's: "DESC (ORIGIN)"
    test rdx, rdx
    jz 2f
    cmp byte ptr [rdx], 0
    je 2f
    mov rdi, rax
    lea rsi, [rip + .Lparen]
    lea rcx, [rip + .Lparen_end]
    call own_concat
    mov [rip + tmpl + PR_desc], rax
2:  mov rax, [r13 + ACM_hint]
    test rax, rax
    jz 3f
    cmp byte ptr [rax], 0
    jne 3f
    xor eax, eax
3:  mov [rip + tmpl + PR_trail], rax
    mov dword ptr [rip + tmpl + PR_kind], APK_ROW
    mov dword ptr [rip + tmpl + PR_flags], APRF_SLASH
    mov eax, [r13 + ACM_act]
    mov [rip + tmpl + PR_act], eax
    mov dword ptr [rip + tmpl + PR_sec], APS_SLASH
    mov [rip + tmpl + PR_arg], r13
    mov rax, [r13 + ACM_name]
    mov [rip + tmpl + PR_name], rax
    mov rax, [r13 + ACM_aliases]
    mov [rip + tmpl + PR_alias], rax
    call cand_push
    jmp .Lbm_cmd
.Lbm_rank:
    call rank
    call emit
    EPILOGUE

# apm_tmpl(APM*) -> eax 1 when the action shows now (its rule, APM_shows): the row being made is its row (a
#   levels row's label "Effort (Level)", its level and its model's levels)
apm_tmpl:
    PROLOGUE
    mov r15, rdi
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    xor r9d, r9d
    mov rax, [r15 + APM_shows]
    test rax, rax
    jz 2f
    mov rdi, [rip + pop_owner]
    mov esi, [rip + pop_dkind]
    call rax
    test eax, eax
    jz 9f
2:  mov [rip + tmpl + PR_trail], rdx
    mov [rip + tmpl + PR_extra], r8
    mov [rip + tmpl + PR_model], r9
    or ecx, [r15 + APM_flags]
    mov [rip + tmpl + PR_flags], ecx
    mov eax, [r15 + APM_kind]
    mov [rip + tmpl + PR_kind], eax
    mov eax, [r15 + APM_act]
    mov [rip + tmpl + PR_act], eax
    mov eax, [r15 + APM_sec]
    mov [rip + tmpl + PR_sec], eax
    mov [rip + tmpl + PR_arg], r15
    mov rax, [r15 + APM_desc]
    mov [rip + tmpl + PR_desc], rax
    mov rax, [r15 + APM_label]
    mov [rip + tmpl + PR_label], rax
    cmp dword ptr [r15 + APM_kind], APK_LEVELS
    jne 3f
    mov rdx, [rip + tmpl + PR_trail]    # a levels row: "Effort (High)"
    test rdx, rdx
    jz 3f
    mov rdi, rax
    lea rsi, [rip + .Lsp]
    xor ecx, ecx
    call own_concat
    mov [rip + tmpl + PR_label], rax
    mov qword ptr [rip + tmpl + PR_trail], 0
3:  mov eax, 1
9:  EPILOGUE

# act_row(act ACT_*): a picker's row for the driver's command-menu action of that act (the effort row, the
#   Ultracode switch), when it shows now
act_row:
    PROLOGUE 16
    mov r12d, edi
    mov edi, [rip + pop_dkind]
    call agent_drv_for_kind
    test rax, rax
    jz 9f
    mov qword ptr [rsp], 0
    mov rdi, [rip + pop_owner]
    lea rsi, [rsp]
    call [rax + DRV_menu]
    mov r13d, eax
    mov r14, [rsp]
    test r14, r14
    jz 9f
    xor ebx, ebx
1:  cmp ebx, r13d
    jae 9f
    imul rdi, rbx, APM_SIZE
    add rdi, r14
    inc ebx
    cmp [rdi + APM_act], r12d
    jne 1b
    call apm_tmpl
    test eax, eax
    jz 9f
    call row_push
9:  EPILOGUE

# rank(): keys = the candidates that pass the filter, in their order: without a filter by section, then as
#   listed; with one by tier, score and listing, then the sections in the order of their best rows
rank:
    PROLOGUE
    xor r12d, r12d
1:  cmp r12, [rip + cands + VEC_len]
    jae 5f
    imul rbx, r12, PR_SIZE
    add rbx, [rip + cands + VEC_ptr]
    cmp qword ptr [rip + q_len], 0
    je 2f
    mov rdi, rbx
    call score_cand
    cmp dword ptr [rbx + PR_tier], DROPPED
    je 4f
    mov eax, [rbx + PR_tier]
    shl rax, 40
    mov ecx, 0xffffff
    sub ecx, [rbx + PR_score]
    shl rcx, 16
    or rax, rcx
    jmp 3f
2:  mov eax, [rbx + PR_sec]
    shl rax, 48
3:  or rax, r12
    mov r13, rax
    lea rdi, [rip + keys]
    mov esi, 8
    call vec_push
    mov [rax], r13
4:  inc r12
    jmp 1b
5:  call sort_keys
    cmp qword ptr [rip + q_len], 0
    je 9f
    mov qword ptr [rip + secrank], -1   # each section's rank: where its first row is
    xor r13d, r13d
    xor r12d, r12d
6:  cmp r12, [rip + keys + VEC_len]
    jae 7f
    call key_sec
    lea rcx, [rip + secrank]
    cmp byte ptr [rcx + rax], 0xff
    jne 61f
    mov [rcx + rax], r13b
    inc r13d
61: inc r12
    jmp 6b
7:  xor r12d, r12d
8:  cmp r12, [rip + keys + VEC_len]
    jae 81f
    call key_sec
    lea rcx, [rip + secrank]
    movzx eax, byte ptr [rcx + rax]
    shl rax, 48
    mov rcx, [rip + keys + VEC_ptr]
    or [rcx + r12*8], rax
    inc r12
    jmp 8b
81: call sort_keys
9:  EPILOGUE

# key_sec() using r12 = a key's index -> rax its candidate's section (0..7)
key_sec:
    mov rax, [rip + keys + VEC_ptr]
    movzx eax, word ptr [rax + r12*8]
    imul rax, rax, PR_SIZE
    add rax, [rip + cands + VEC_ptr]
    mov eax, [rax + PR_sec]
    and eax, 7
    ret

# sort_keys(): keys in ascending order (insertion sort: a few hundred at most)
sort_keys:
    mov r8, [rip + keys + VEC_ptr]
    mov r9, [rip + keys + VEC_len]
    mov ecx, 1
1:  cmp rcx, r9
    jae 9f
    mov rax, [r8 + rcx*8]
    mov rdx, rcx
2:  test rdx, rdx
    jz 3f
    mov r10, [r8 + rdx*8 - 8]
    cmp r10, rax
    jbe 3f
    mov [r8 + rdx*8], r10
    dec rdx
    jmp 2b
3:  mov [r8 + rdx*8], rax
    inc rcx
    jmp 1b
9:  ret

# emit(): the rows in the keys' order, a section row before each section's first; the empty row; the foot
emit:
    PROLOGUE
    mov r13d, -1
    xor r12d, r12d
1:  cmp r12, [rip + keys + VEC_len]
    jae 5f
    mov rax, [rip + keys + VEC_ptr]
    movzx eax, word ptr [rax + r12*8]
    imul rbx, rax, PR_SIZE
    add rbx, [rip + cands + VEC_ptr]
    inc r12
    mov eax, [rbx + PR_sec]
    cmp eax, r13d
    je 2f
    mov r13d, eax
    and eax, 7
    lea rcx, [rip + sec_names]
    mov rcx, [rcx + rax*8]
    mov [rip + tmpl + PR_label], rcx
    mov dword ptr [rip + tmpl + PR_kind], APK_SECTION
    mov [rip + tmpl + PR_sec], r13d
    call row_push
2:  mov rdi, rbx
    call row_push_from
    jmp 1b
5:  cmp qword ptr [rip + rows + VEC_len], 0
    jne 6f
    lea rax, [rip + .Lnone]
    mov [rip + tmpl + PR_label], rax
    mov dword ptr [rip + tmpl + PR_kind], APK_EMPTY
    call row_push
6:  cmp qword ptr [rip + q_len], 0
    jne 9f
    mov edi, [rip + pop_dkind]
    call agentcfg_get
    cmp byte ptr [rax + AGC_version], 0
    je 9f
    lea rsi, [rax + AGC_version]
    lea rdi, [rip + .Lv]
    xor edx, edx
    xor ecx, ecx
    call own_concat
    mov [rip + tmpl + PR_label], rax
    mov dword ptr [rip + tmpl + PR_kind], APK_FOOT
    call row_push
9:  EPILOGUE

# build_modes(): the header "Modes" with its hint "⇧ + tab to switch" (ext-webview-ui.md 2.3), then the
#   modes the driver offers now, the current one checked
build_modes:
    PROLOGUE 16
    mov edi, [rip + pop_dkind]
    call agent_drv_for_kind
    test rax, rax
    jz 9f
    mov qword ptr [rsp], 0
    mov rdi, [rip + pop_owner]
    lea rsi, [rsp]
    call [rax + DRV_modes]
    mov r12d, eax
    mov r13, [rsp]
    test r13, r13
    jz 9f
    test r12d, r12d
    jz 9f
    lea rax, [rip + .Lm_modes]
    mov [rip + tmpl + PR_label], rax
    lea rax, [rip + .Lm_modes_hint]
    mov [rip + tmpl + PR_trail], rax
    mov dword ptr [rip + tmpl + PR_kind], APK_SECTION
    call row_push
    xor r14d, r14d
1:  cmp r14d, r12d
    jae 7f
    imul rbx, r14, AMD_SIZE
    add rbx, r13
    inc r14d
    mov dword ptr [rip + tmpl + PR_kind], APK_ROW
    xor eax, eax
    test dword ptr [rbx + AMD_flags], AMDF_CURRENT
    jz 2f
    mov eax, APRF_CHECK
2:  mov [rip + tmpl + PR_flags], eax
    mov rax, [rbx + AMD_label]
    mov [rip + tmpl + PR_label], rax
    mov rax, [rbx + AMD_desc]
    mov [rip + tmpl + PR_desc], rax
    mov dword ptr [rip + tmpl + PR_act], ACT_MODES
    mov [rip + tmpl + PR_arg], rbx
    call row_push
    jmp 1b
7:  mov edi, ACT_EFFORT         # then the effort row (ext-webview-ui.md 2.11)
    call act_row
9:  EPILOGUE

# build_models(): the header "Select a model" and a row per model the driver lists (agentcfg: its name and
#   description, a check on the one the conversation uses, the unavailable ones greyed), "Loading models…"
#   while the program starts and nothing is listed yet, else "No models available"; then the effort row and
#   the Ultracode switch when they show (ext-webview-ui.md 2.9)
build_models:
    PROLOGUE
    mov edi, [rip + pop_dkind]
    call agentcfg_get
    mov rbx, rax
    mov rdi, [rip + pop_owner]
    mov rsi, rax
    call agentcfg_current
    mov r14, rax                # the model checked, or 0
    cmp qword ptr [rbx + AGC_models + VEC_len], 0
    jne 1f
    lea rax, [rip + .Lm_none]
    mov rcx, [rip + pop_owner]
    test rcx, rcx
    jz 11f
    mov rcx, [rcx + AS_live]
    test rcx, rcx
    jz 11f
    cmp dword ptr [rcx + AL_state], ALS_STARTING
    jne 11f
    lea rax, [rip + .Lm_loading]
11: mov [rip + tmpl + PR_label], rax
    mov dword ptr [rip + tmpl + PR_kind], APK_EMPTY
    call row_push
    jmp 9f
1:  lea rax, [rip + .Lm_select]
    mov [rip + tmpl + PR_label], rax
    mov dword ptr [rip + tmpl + PR_kind], APK_SECTION
    call row_push
    xor r12d, r12d
2:  cmp r12, [rbx + AGC_models + VEC_len]
    jae 8f
    mov rax, [rbx + AGC_models + VEC_ptr]
    mov r13, [rax + r12*8]
    inc r12
    mov dword ptr [rip + tmpl + PR_kind], APK_ROW
    xor r15d, r15d
    test dword ptr [r13 + AMO_flags], AMOF_OFF
    jz 3f
    mov r15d, APRF_OFF
3:  cmp r13, r14
    jne 4f
    or r15d, APRF_CHECK
4:  mov [rip + tmpl + PR_flags], r15d
    mov rax, [r13 + AMO_label]
    mov [rip + tmpl + PR_label], rax
    mov rax, [r13 + AMO_desc]
    mov [rip + tmpl + PR_desc], rax
    mov dword ptr [rip + tmpl + PR_act], ACT_MODEL
    mov [rip + tmpl + PR_arg], r13
    call row_push
    jmp 2b
8:  mov edi, ACT_EFFORT         # below the models: the effort row, the Ultracode switch
    call act_row
    mov edi, ACT_ULTRA
    call act_row
9:  EPILOGUE

# score_cand(PR*): its tier (0 its label or an alias is the filter, 1 starts with it, 2 else) and score (the
#   best of 3 x the label's fuzzy score, 2 x the name's or an alias's, the description's / 2); DROPPED when
#   nothing matches
score_cand:
    PROLOGUE
    mov rbx, rdi
    mov r12, [rbx + PR_label]
    cmp byte ptr [r12], '/'
    jne 1f
    inc r12
1:  mov rdi, r12
    call strlen
    mov r13, rax
    mov r14d, 2
    mov rdi, r12
    mov rsi, r13
    mov rdx, [rip + q_ptr]
    mov rcx, [rip + q_len]
    call str_ieq
    test eax, eax
    jz 2f
    xor r14d, r14d
    jmp 3f
2:  cmp r13, [rip + q_len]
    jb 21f
    mov rdi, r12
    mov rsi, [rip + q_len]
    mov rdx, [rip + q_ptr]
    mov rcx, [rip + q_len]
    call str_ieq
    test eax, eax
    jz 21f
    mov r14d, 1
21: mov rdi, [rbx + PR_alias]
    call alias_tier
    cmp eax, r14d
    cmovb r14d, eax
3:  mov r15d, -1
    mov rdi, r12
    mov rsi, r13
    call fz
    test eax, eax
    js 4f
    imul eax, eax, 3
    cmp eax, r15d
    cmovg r15d, eax
4:  mov rdi, [rbx + PR_name]
    test rdi, rdi
    jz 5f
    call strlen
    mov rsi, rax
    mov rdi, [rbx + PR_name]
    call fz
    test eax, eax
    js 5f
    add eax, eax
    cmp eax, r15d
    cmovg r15d, eax
5:  mov rdi, [rbx + PR_alias]
    call alias_score
    test eax, eax
    js 6f
    add eax, eax
    cmp eax, r15d
    cmovg r15d, eax
6:  mov rdi, [rbx + PR_desc]
    test rdi, rdi
    jz 7f
    call strlen
    mov rsi, rax
    mov rdi, [rbx + PR_desc]
    call fz
    test eax, eax
    js 7f
    shr eax, 1
    cmp eax, r15d
    cmovg r15d, eax
7:  test r15d, r15d
    jns 8f
    cmp r14d, 2
    jne 71f
    mov dword ptr [rbx + PR_tier], DROPPED
    EPILOGUE
71: xor r15d, r15d
8:  mov [rbx + PR_tier], r14d
    mov [rbx + PR_score], r15d
    EPILOGUE

# fz(ptr, len) -> eax fuzzy's score of the filter in it, -1 when it is not there
fz:
    mov rdx, [rip + q_ptr]
    mov rcx, [rip + q_len]
    jmp fuzzy

# next_alias(cstr) -> rax a word's start, rdx its length (0: none left), rcx where the next one is looked for
next_alias:
    mov rax, rdi
1:  cmp byte ptr [rax], ' '
    jne 2f
    inc rax
    jmp 1b
2:  xor edx, edx
3:  movzx ecx, byte ptr [rax + rdx]
    test ecx, ecx
    jz 4f
    cmp ecx, ' '
    je 4f
    inc rdx
    jmp 3b
4:  lea rcx, [rax + rdx]
    ret

# alias_tier(aliases or 0) -> eax 0 when one is the filter, 1 when one starts with it, else 2
alias_tier:
    PROLOGUE
    mov r15d, 2
    mov rbx, rdi
    test rbx, rbx
    jz 9f
1:  mov rdi, rbx
    call next_alias
    test rdx, rdx
    jz 9f
    mov rbx, rcx
    mov r12, rax
    mov r13, rdx
    mov rdi, r12
    mov rsi, r13
    mov rdx, [rip + q_ptr]
    mov rcx, [rip + q_len]
    call str_ieq
    test eax, eax
    jz 2f
    xor r15d, r15d
    jmp 9f
2:  cmp r13, [rip + q_len]
    jb 1b
    mov rdi, r12
    mov rsi, [rip + q_len]
    mov rdx, [rip + q_ptr]
    mov rcx, [rip + q_len]
    call str_ieq
    test eax, eax
    jz 1b
    mov r15d, 1
    jmp 1b
9:  mov eax, r15d
    EPILOGUE

# alias_score(aliases or 0) -> eax the best fuzzy score among them, -1 none
alias_score:
    PROLOGUE
    mov r15d, -1
    mov rbx, rdi
    test rbx, rbx
    jz 9f
1:  mov rdi, rbx
    call next_alias
    test rdx, rdx
    jz 9f
    mov rbx, rcx
    mov rdi, rax
    mov rsi, rdx
    call fz
    cmp eax, r15d
    cmovg r15d, eax
    jmp 1b
9:  mov eax, r15d
    EPILOGUE

# sep_prefix(cstr) -> eax 1 when the filter (qbuf: no separators) starts one of its words, the separators
#   after that word's start left out ("conv" in "Clear conversation", "co" in "compact")
sep_prefix:
    PROLOGUE
    mov rbx, rdi
    xor eax, eax
    cmp dword ptr [rip + qblen], 0
    je 9f
    xor r12d, r12d              # a word's start
1:  movzx edi, byte ptr [rbx + r12]
    test edi, edi
    jz 8f
    call is_sep
    test eax, eax
    jnz 7f
    test r12, r12
    jz 2f
    movzx edi, byte ptr [rbx + r12 - 1]
    call is_sep
    test eax, eax
    jz 7f
2:  mov r13, r12                # compare from it
    xor r14d, r14d
3:  cmp r14d, [rip + qblen]
    jae 6f
    movzx edi, byte ptr [rbx + r13]
    test edi, edi
    jz 7f
    inc r13
    call is_sep
    test eax, eax
    jnz 3b
    lea eax, [rdi - 'A']
    cmp eax, 25
    ja 4f
    or edi, 0x20
4:  lea rax, [rip + qbuf]
    cmp dil, [rax + r14]
    jne 7f
    inc r14d
    jmp 3b
6:  mov eax, 1
    EPILOGUE
7:  inc r12
    jmp 1b
8:  xor eax, eax
9:  EPILOGUE

# selectable(PR*) -> eax 1 for a row the keys stop on
selectable:
    xor eax, eax
    mov ecx, [rdi + PR_kind]
    cmp ecx, APK_ROW
    je 1f
    cmp ecx, APK_SWITCH
    je 1f
    cmp ecx, APK_LEVELS
    jne 2f
1:  mov eax, 1
2:  ret

# row_at(i) -> rax the row i (from 0)
row_at:
    imul rax, rdi, PR_SIZE
    add rax, [rip + rows + VEC_ptr]
    ret

# first_sel() -> eax the first row the keys stop on, -1 none
first_sel:
    PROLOGUE
    xor ebx, ebx
1:  cmp rbx, [rip + rows + VEC_len]
    jae 8f
    mov rdi, rbx
    call row_at
    mov rdi, rax
    call selectable
    test eax, eax
    jnz 9f
    inc rbx
    jmp 1b
8:  mov ebx, -1
9:  mov eax, ebx
    EPILOGUE

# sel_count() -> eax the rows the keys stop on
sel_count:
    PROLOGUE
    xor ebx, ebx
    xor r12d, r12d
1:  cmp rbx, [rip + rows + VEC_len]
    jae 9f
    mov rdi, rbx
    call row_at
    mov rdi, rax
    call selectable
    add r12d, eax
    inc rbx
    jmp 1b
9:  mov eax, r12d
    EPILOGUE

# select(): the selection after a build: the user's row while it is there; else, the menu with a filter:
#   the first row (typed: when the filter starts one of its words), a picker: its checked row or its first
select:
    PROLOGUE
    mov dword ptr [rip + pop_sel], -1
    cmp dword ptr [rip + pop_user], 0
    je 3f
    xor r12d, r12d
1:  cmp r12, [rip + rows + VEC_len]
    jae 2f
    mov rdi, r12
    call row_at
    mov rbx, rax
    mov rdi, rax
    call selectable
    test eax, eax
    jz 11f
    mov rax, [rbx + PR_arg]
    cmp rax, [rip + pop_usel_arg]
    jne 11f
    mov eax, [rbx + PR_act]
    cmp eax, [rip + pop_usel_act]
    jne 11f
    mov [rip + pop_sel], r12d
    EPILOGUE
11: inc r12
    jmp 1b
2:  mov dword ptr [rip + pop_user], 0
3:  call first_sel
    mov r12d, eax
    test eax, eax
    js 9f
    cmp dword ptr [rip + pop_kind], APP_MENU
    jne 6f
    cmp qword ptr [rip + q_len], 0
    je 9f
    cmp dword ptr [rip + pop_typed], 0
    je 5f
    movsxd rdi, r12d
    call row_at
    mov rbx, rax
    mov rdi, [rbx + PR_label]
    cmp byte ptr [rdi], '/'
    jne 4f
    inc rdi
4:  call sep_prefix
    test eax, eax
    jnz 5f
    mov rbx, [rbx + PR_alias]
41: test rbx, rbx
    jz 9f
    mov rdi, rbx
    call next_alias
    test rdx, rdx
    jz 9f
    mov rbx, rcx
    mov r14, rax
    mov r15, rdx
    mov r13b, [r14 + r15]       # the word alone
    mov byte ptr [r14 + r15], 0
    mov rdi, r14
    call sep_prefix
    mov [r14 + r15], r13b
    test eax, eax
    jz 41b
5:  mov [rip + pop_sel], r12d
    jmp 9f
6:  xor ebx, ebx                # a picker: its checked row, else its first
7:  cmp rbx, [rip + rows + VEC_len]
    jae 5b
    mov rdi, rbx
    call row_at
    test dword ptr [rax + PR_flags], APRF_CHECK
    jz 71f
    mov [rip + pop_sel], ebx
    jmp 9f
71: inc rbx
    jmp 7b
9:  EPILOGUE

# choose(i): row i is the user's choice (its identity stays through builds), shown
choose:
    mov [rip + pop_sel], edi
    mov dword ptr [rip + pop_user], 1
    mov dword ptr [rip + pop_reveal], 1
    movsxd rdi, edi
    imul rax, rdi, PR_SIZE
    add rax, [rip + rows + VEC_ptr]
    mov rcx, [rax + PR_arg]
    mov [rip + pop_usel_arg], rcx
    mov ecx, [rax + PR_act]
    mov [rip + pop_usel_act], ecx
    mov dword ptr [rip + g_dirty], 1
    ret

# move(dir): the selection goes to the next (1) or previous (-1) row the keys stop on, wrapping around
move:
    PROLOGUE
    mov r12d, edi
    mov r13, [rip + rows + VEC_len]
    test r13, r13
    jz 9f
    mov r14d, r13d              # tries
    mov ebx, [rip + pop_sel]
    test ebx, ebx
    jns 1f
    mov ebx, -1                 # none yet: down to the first, up to the last
    test r12d, r12d
    jns 1f
    mov ebx, r13d
1:  add ebx, r12d
    test ebx, ebx
    jns 2f
    lea ebx, [r13 - 1]
2:  cmp ebx, r13d
    jl 3f
    xor ebx, ebx
3:  mov edi, ebx
    call row_at
    mov rdi, rax
    call selectable
    test eax, eax
    jnz 4f
    dec r14d
    jnz 1b
    jmp 9f
4:  mov edi, ebx
    call choose
9:  EPILOGUE

# ---- the keys ----

# FN agentpop_key(keysym, cp, mods) -> eax 1 when the popup took the key. Escape closes it (the typed menu
#   stays closed over this text). Typed: only while it shows a row, only Enter, Tab and the arrows, only
#   while the box has the keys. Button and pickers: the arrows, Enter, Tab, Space (the model picker), Left
#   and Right on a levels row; the button menu's field the rest; a plain key never reaches the box
FN agentpop_key
    PROLOGUE
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    call sync
    test eax, eax
    jz .Lk_no
    cmp dword ptr [rip + pop_typed], 0
    je 1f
    cmp dword ptr [rip + g_focus], FOCUS_AGENT_INPUT
    jne .Lk_no
1:  call build
    cmp r12d, KEY_ESCAPE
    jne 2f
    cmp dword ptr [rip + pop_typed], 0
    je 11f
    call agentext_box
    mov rdi, rax
    call tf_text
    mov rdi, rax
    mov rsi, rdx
    call hash_text
    mov [rip + dis_hash], rax
11: call agentpop_close
    jmp .Lk_yes
2:  cmp dword ptr [rip + pop_typed], 0
    je .Lk_button
    call sel_count
    test eax, eax
    jz .Lk_no                   # "No matching commands": every key is the box's
    test r14d, MOD_CTRL | MOD_ALT | MOD_SUPER
    jnz .Lk_no
    cmp r12d, KEY_UP
    jne 3f
    mov edi, -1
    call move
    jmp .Lk_yes
3:  cmp r12d, KEY_DOWN
    jne 4f
    mov edi, 1
    call move
    jmp .Lk_yes
4:  test r14d, MOD_SHIFT
    jnz .Lk_no
    xor edi, edi
    cmp r12d, KEY_RETURN
    je 5f
    cmp r12d, KEY_KP_ENTER
    je 5f
    mov edi, 1
    cmp r12d, KEY_TAB
    jne .Lk_no
5:  call enter
    test eax, eax
    jz .Lk_no
.Lk_yes:
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE
.Lk_no:
    xor eax, eax
    EPILOGUE
.Lk_button:
    test r14d, MOD_CTRL | MOD_ALT | MOD_SUPER
    jnz .Lk_field
    cmp r12d, KEY_UP
    jne 1f
    mov edi, -1
    call move
    jmp .Lk_yes
1:  cmp r12d, KEY_DOWN
    jne 2f
    mov edi, 1
    call move
    jmp .Lk_yes
2:  xor edi, edi
    cmp r12d, KEY_RETURN
    je 3f
    cmp r12d, KEY_KP_ENTER
    je 3f
    mov edi, 1
    cmp r12d, KEY_TAB
    jne 4f
3:  test r14d, MOD_SHIFT
    jnz .Lk_yes
    call enter
    jmp .Lk_yes
4:  cmp r13d, ' '
    jne 5f
    cmp dword ptr [rip + pop_kind], APP_MODELS
    jne 5f
    xor edi, edi
    call enter
    jmp .Lk_yes
5:  mov edi, -1
    cmp r12d, KEY_LEFT
    je 6f
    mov edi, 1
    cmp r12d, KEY_RIGHT
    jne .Lk_field
6:  mov ebx, edi
    movsxd rdi, dword ptr [rip + pop_sel]
    test rdi, rdi
    js .Lk_field
    call row_at
    cmp dword ptr [rax + PR_kind], APK_LEVELS
    jne .Lk_field
    lea rdi, [rip + .Lplus]
    test ebx, ebx
    jns 7f
    lea rdi, [rip + .Lminus]
7:  call level
    jmp .Lk_yes
.Lk_field:
    cmp dword ptr [rip + pop_kind], APP_MENU
    jne 8f
    lea rdi, [rip + pop_tf]
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    call ta_key
    test eax, eax
    jnz .Lk_yes
8:  test r14d, MOD_CTRL | MOD_ALT | MOD_SUPER
    jnz .Lk_no                  # a shortcut the field did not take goes on
    jmp .Lk_yes

# enter(tab) -> eax 1 taken, 0 the key goes on to the box (a slash command typed whole: it is sent). The
#   selected row (typed, none selected: Enter sends, Tab completes the first row when it is a command)
enter:
    PROLOGUE 16
    mov r15d, edi
    movsxd rax, dword ptr [rip + pop_sel]
    test rax, rax
    js .Le_none
    mov rdi, rax
    call row_at
    mov rbx, rax
    jmp .Le_row
.Le_none:
    cmp dword ptr [rip + pop_typed], 0
    je .Le_taken
    cmp qword ptr [rip + q_len], 0
    je .Le_taken
    test r15d, r15d
    jz .Le_decline
    call first_sel
    test eax, eax
    js .Le_taken
    movsxd rdi, eax
    call row_at
    mov rbx, rax
    test dword ptr [rbx + PR_flags], APRF_SLASH
    jz .Le_taken
.Le_row:
    test dword ptr [rbx + PR_flags], APRF_OFF
    jnz .Le_taken
    cmp dword ptr [rbx + PR_kind], APK_LEVELS   # the effort row (any popup): the next level round
    jne 11f
    lea rdi, [rip + .Lcycle]
    call level
    jmp .Le_taken
11: cmp dword ptr [rbx + PR_kind], APK_SWITCH   # a switch (any popup): flipped, the popup stays
    je 1f
    mov eax, [rip + pop_kind]
    cmp eax, APP_MODES
    je .Le_mode
    cmp eax, APP_MODELS
    je .Le_model
    test dword ptr [rbx + PR_flags], APRF_SLASH
    jnz .Le_slash
1:  mov r12d, [rbx + PR_act]    # an action: its token leaves the box
    mov r13d, [rbx + PR_kind]
    lea r15, [rip + .Lw_on]     # a switch's new state: the one it does not show
    test dword ptr [rbx + PR_flags], APRF_ON
    jz 12f
    lea r15, [rip + .Lw_off]
12: cmp dword ptr [rip + pop_typed], 0
    je 2f
    call cut_token
2:  mov r14, [rip + pop_owner]
    mov eax, [rip + pop_dkind]
    mov [rsp], eax
    xor ecx, ecx
    xor r8d, r8d
    cmp r13d, APK_SWITCH        # a switch: the popup stays
    jne 21f
    mov rdi, r15
    call strlen
    mov r8, rax
    mov rcx, r15
    jmp 3f
21: push rcx
    push r8
    call agentpop_close
    pop r8
    pop rcx
3:  mov rdi, r14
    mov esi, [rsp]
    mov edx, r12d
    call agentpop_run
    jmp .Le_taken
.Le_slash:
    mov r12, [rbx + PR_arg]     # ACM*
    cmp dword ptr [rip + pop_typed], 0
    je 6f
    test r15d, r15d
    jnz 5f
    mov rdi, r12                # Enter on a command typed whole: the box sends it
    call typed_whole
    test eax, eax
    jz 5f
    call agentpop_close
    jmp .Le_decline
5:  mov rdi, r12
    call complete
    call agentpop_close
    jmp .Le_taken
6:  mov rdi, r12                # the button menu: "/name " into the box
    call insert_cmd
    call agentpop_close
    jmp .Le_taken
.Le_mode:
    mov r12, [rbx + PR_arg]     # (its id is the driver's static text: it outlives the list)
    mov r13, [rip + pop_owner]
    call agentpop_close
    mov rdi, r13
    mov rsi, [r12 + AMD_id]
    call foot_mode_set
    jmp .Le_taken
.Le_model:
    mov r12, [rbx + PR_arg]
    call live_of_owner
    mov r13, rax
    call agentpop_close
    test r13, r13
    jz .Le_taken
    mov rax, [r13 + AL_drv]
    mov rdi, r13
    mov rsi, [r12 + AMO_value]
    call [rax + DRV_set_model]
.Le_taken:
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE
.Le_decline:
    xor eax, eax
    EPILOGUE

# level(how cstr): the effort level one step up ("+"), down ("-"), round ("~"), or the level of that id: the
#   driver's part (DRV_action ACT_EFFORT)
level:
    PROLOGUE
    mov r12, rdi
    call live_of_owner
    test rax, rax
    jz 9f
    mov r13, rax
    mov rdi, r12
    call strlen
    mov rcx, rax
    mov rdi, r13
    mov rax, [r13 + AL_drv]
    mov esi, ACT_EFFORT
    mov rdx, r12
    call [rax + DRV_action]
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# live_of_owner() -> rax the owner's live record (made; a draft becomes its conversation first), or 0
live_of_owner:
    PROLOGUE
    mov rdi, [rip + pop_owner]
    test rdi, rdi
    jnz 1f
    call agentext_draft_own
    test rax, rax
    jz 9f
    mov rdi, rax
1:  call agent_live
9:  EPILOGUE

# box_text() -> rax ptr, rdx len, rbx the box (TF*)
box_text:
    call agentext_box
    mov rbx, rax
    mov rdi, rax
    jmp tf_text

# typed_whole(ACM*) -> eax 1 when the typed token is the command's name or one of its aliases
typed_whole:
    PROLOGUE
    mov r12, rdi
    call box_text
    mov r13, [rip + pop_ts]
    lea r13, [rax + r13 + 1]
    mov r14, [rip + pop_te]
    sub r14, [rip + pop_ts]
    dec r14                     # the token without its "/"
    mov rdi, [r12 + ACM_name]
    call strlen
    mov rcx, rax
    mov rdi, r13
    mov rsi, r14
    mov rdx, [r12 + ACM_name]
    call str_ieq
    test eax, eax
    jnz 9f
    mov rbx, [r12 + ACM_aliases]
1:  test rbx, rbx
    jz 8f
    mov rdi, rbx
    call next_alias
    test rdx, rdx
    jz 8f
    mov rbx, rcx
    mov rcx, rdx
    mov rdx, rax
    mov rdi, r13
    mov rsi, r14
    call str_ieq
    test eax, eax
    jnz 9f
    jmp 1b
8:  xor eax, eax
9:  EPILOGUE

# set_box(caret): the box's text is psb's, the caret there; the box heard of it (agentext_box_changed)
set_box:
    PROLOGUE
    mov r12, rdi
    call agentext_box
    mov rbx, rax
    mov rdi, rax
    mov rsi, [rip + psb + SB_ptr]
    mov rdx, [rip + psb + SB_len]
    test rsi, rsi
    jnz 1f
    lea rsi, [rip + empty]
1:  call tf_set
    mov [rbx + TF_cur], r12
    mov [rbx + TF_anchor], r12
    call agentext_box_changed
    EPILOGUE

# complete(ACM*): the token becomes "/name " (a space after it unless one follows), the caret after it
complete:
    PROLOGUE
    mov r12, rdi
    call box_text
    mov r13, rax
    mov r14, rdx
    lea rdi, [rip + psb]
    call sb_clear
    lea rdi, [rip + psb]
    mov rsi, r13
    mov rdx, [rip + pop_ts]
    call sb_push
    lea rdi, [rip + psb]
    mov esi, '/'
    call sb_push_byte
    lea rdi, [rip + psb]
    mov rsi, [r12 + ACM_name]
    call sb_push_cstr
    mov r15, [rip + psb + SB_len]
    mov rax, [rip + pop_te]
    cmp rax, r14
    jae 1f
    cmp byte ptr [r13 + rax], ' '
    je 2f
1:  lea rdi, [rip + psb]
    mov esi, ' '
    call sb_push_byte
2:  inc r15                     # the caret after the space
    lea rdi, [rip + psb]
    mov rsi, [rip + pop_te]
    lea rsi, [r13 + rsi]
    mov rdx, r14
    sub rdx, [rip + pop_te]
    call sb_push
    mov rdi, r15
    call set_box
    EPILOGUE

# cut_token(): the typed token leaves the box, the caret where it was
cut_token:
    PROLOGUE
    call box_text
    mov r13, rax
    mov r14, rdx
    lea rdi, [rip + psb]
    call sb_clear
    lea rdi, [rip + psb]
    mov rsi, r13
    mov rdx, [rip + pop_ts]
    call sb_push
    lea rdi, [rip + psb]
    mov rsi, [rip + pop_te]
    lea rsi, [r13 + rsi]
    mov rdx, r14
    sub rdx, [rip + pop_te]
    call sb_push
    mov rdi, [rip + pop_ts]
    call set_box
    EPILOGUE

# insert_cmd(ACM*): "/name " at the box's caret, the caret after it
insert_cmd:
    PROLOGUE
    mov r12, rdi
    call box_text
    mov r13, rax
    mov r14, rdx
    mov r15, [rbx + TF_cur]
    cmp r15, r14
    jbe 1f
    mov r15, r14
1:  lea rdi, [rip + psb]
    call sb_clear
    lea rdi, [rip + psb]
    mov rsi, r13
    mov rdx, r15
    call sb_push
    lea rdi, [rip + psb]
    mov esi, '/'
    call sb_push_byte
    lea rdi, [rip + psb]
    mov rsi, [r12 + ACM_name]
    call sb_push_cstr
    lea rdi, [rip + psb]
    mov esi, ' '
    call sb_push_byte
    mov rbx, [rip + psb + SB_len]
    lea rdi, [rip + psb]
    lea rsi, [r13 + r15]
    mov rdx, r14
    sub rdx, r15
    call sb_push
    mov rdi, rbx
    call set_box
    EPILOGUE

# FN agentpop_pick(n) -> eax 1 when row n (from 1, among the rows the keys stop on) was taken as Enter takes
#   it (a command typed whole: the box sends it)
FN agentpop_pick
    PROLOGUE
    mov r12, rdi
    call sync
    test eax, eax
    jz 8f
    call build
    xor ebx, ebx
1:  cmp rbx, [rip + rows + VEC_len]
    jae 8f
    mov rdi, rbx
    call row_at
    mov rdi, rax
    call selectable
    test eax, eax
    jz 2f
    dec r12
    jz 3f
2:  inc rbx
    jmp 1b
3:  mov edi, ebx
    call choose
    xor edi, edi
    call enter
    test eax, eax
    jnz 9f
    call agentext_send
9:  mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# ---- a command's action ----

# FN agentpop_slash(AS*, ptr, len) -> eax 1 when the text's first word "/NAME" is one of the driver's own
#   commands (ACMF_LOCAL) with a target: it ran with the rest of the text (else 0: the text goes as it is)
FN agentpop_slash
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    xor eax, eax
    test rbx, rbx
    jz 9f
    cmp dword ptr [rbx + AS_kind], AS_KIND_EXT
    je 8f
    cmp r13, 2
    jb 8f
    cmp byte ptr [r12], '/'
    jne 8f
    mov r14d, 1                 # the name's end
1:  cmp r14, r13
    jae 2f
    cmp byte ptr [r12 + r14], ' '
    jbe 2f
    inc r14
    jmp 1b
2:  cmp r14, 1
    je 8f
    mov edi, [rbx + AS_kind]
    call agentcfg_get
    mov r15, rax
    mov rdi, rax
    call agentcfg_need
    mov rdi, r15
    lea rsi, [r12 + 1]
    lea rdx, [r14 - 1]
    call agentcfg_find_cmd
    test rax, rax
    jz 8f
    test dword ptr [rax + ACM_flags], ACMF_LOCAL
    jz 8f
    mov r15d, [rax + ACM_act]
    cmp r15d, ACT_SEND
    je 8f
    cmp r15d, ACT_UNAVAILABLE
    je 8f
3:  cmp r14, r13                # the rest, without the blanks around it
    jae 4f
    cmp byte ptr [r12 + r14], ' '
    ja 4f
    inc r14
    jmp 3b
4:  cmp r13, r14
    jbe 5f
    cmp byte ptr [r12 + r13 - 1], ' '
    ja 5f
    dec r13
    jmp 4b
5:  mov rdi, rbx
    mov esi, [rbx + AS_kind]
    mov edx, r15d
    lea rcx, [r12 + r14]
    mov r8, r13
    sub r8, r14
    call agentpop_run
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
9:  EPILOGUE

# FN agentpop_run(AS* or 0 for a draft, kind, act ACT_*, arg ptr, len): a command's action. Clear and New
#   open a new draft of the kind; Model and Modes their pickers; Copy a reply into the clipboard; Help and
#   Settings are the driver's (DRV_action, without a conversation); the rest act on the conversation (a
#   draft becomes one): Thinking, Ultracode (DRV_set_*: the arg "on" or "off", else the live record's
#   state flipped), sign-in, sign-out, Terminal (DRV_terminal 1, 2, 0), anything else the driver's
#   (DRV_action)
FN agentpop_run
    PROLOGUE 16
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    mov r14, rcx
    mov r15, r8
    cmp r13d, ACT_CLEAR
    je .Lr_new
    cmp r13d, ACT_NEW
    je .Lr_new
    cmp r13d, ACT_MODEL
    je .Lr_models
    cmp r13d, ACT_MODES
    je .Lr_modes
    cmp r13d, ACT_COPY
    je .Lr_copy
    cmp r13d, ACT_HELP
    je .Lr_noconv
    cmp r13d, ACT_SETTINGS
    je .Lr_noconv
    test rbx, rbx
    jnz 1f
    call agentext_draft_own
    mov rbx, rax
    test rax, rax
    jz 9f
1:  mov rdi, rbx
    call agent_live
    test rax, rax
    jz 9f
    mov [rsp], rax
    mov rcx, [rax + AL_drv]
    mov [rsp + 8], rcx
    mov rdi, rax
    cmp r13d, ACT_THINKING
    jne 2f
    xor esi, esi
    cmp dword ptr [rdi + AL_think], 0
    sete sil
    call switch_arg
    call [rcx + DRV_set_thinking]
    jmp 9f
2:  cmp r13d, ACT_ULTRA
    jne 3f
    xor esi, esi
    cmp dword ptr [rdi + AL_ultra], 1
    setne sil
    call switch_arg
    call [rcx + DRV_set_ultra]
    jmp 9f
3:  mov esi, 1
    cmp r13d, ACT_SIGNIN
    je 4f
    mov esi, 2
    cmp r13d, ACT_SIGNOUT
    je 4f
    xor esi, esi
    cmp r13d, ACT_TERMINAL
    jne 5f
4:  call [rcx + DRV_terminal]
    jmp 9f
5:  mov esi, r13d
    mov rdx, r14
    mov rcx, r15
    mov rax, [rsp + 8]
    call [rax + DRV_action]
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE
.Lr_new:
    mov edi, r12d
    call agentext_new_kind
    EPILOGUE
.Lr_models:
    mov edi, APP_MODELS
    jmp 6f
.Lr_modes:
    mov edi, APP_MODES
6:  mov rsi, rbx
    xor edx, edx
    call agentpop_open
    EPILOGUE
.Lr_copy:
    mov rdi, rbx
    mov rsi, r14
    mov rdx, r15
    call copy_reply
    EPILOGUE
.Lr_noconv:
    mov edi, r12d
    call agent_drv_for_kind
    test rax, rax
    jz 9b
    xor edi, edi
    test rbx, rbx
    jz 7f
    mov rdi, [rbx + AS_live]
7:  mov esi, r13d
    mov rdx, r14
    mov rcx, r15
    call [rax + DRV_action]
    jmp 9b

# switch_arg() using agentpop_run's r14/r15 (the arg) and esi (the flip of the live record's state): esi 1
#   for "on", 0 for "off", else as it was; rdi and rcx stay
switch_arg:
    cmp r15, 2
    jne 1f
    cmp word ptr [r14], 0x6e6f  # "on"
    jne 9f
    mov esi, 1
    ret
1:  cmp r15, 3
    jne 9f
    cmp word ptr [r14], 0x666f  # "of(f)"
    jne 9f
    cmp byte ptr [r14 + 2], 'f'
    jne 9f
    xor esi, esi
9:  ret

# copy_reply(AS* or 0, arg ptr, len): /copy [N]: the N-th last reply (1 the latest) into the clipboard, with the
#   extension's messages as a toast
copy_reply:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    xor r14d, r14d              # replies
    test rbx, rbx
    jz 1f
    mov rdi, rbx
    xor esi, esi
    call agents_reply_nth
    mov r14d, ecx
1:  lea rdi, [rip + .Lc_none]
    test r14d, r14d
    jz .Lc_toast
    mov r15d, 1
    test r13, r13
    jz 4f
    xor ecx, ecx                # N: digits only, 1 at least
2:  cmp rcx, r13
    jae 3f
    movzx eax, byte ptr [r12 + rcx]
    sub eax, '0'
    cmp eax, 9
    ja .Lc_usage
    inc rcx
    jmp 2b
3:  cmp r13, 9
    ja .Lc_only
    mov rdi, r12
    mov rsi, r13
    call parse_u64
    test rax, rax
    jz .Lc_usage
    cmp rax, r14
    ja .Lc_only
    mov r15, rax
4:  mov rdi, rbx
    mov rsi, r15
    call agents_reply_nth
    lea rdi, [rip + .Lc_none]
    test rax, rax
    jz .Lc_toast
    mov r12, rax
    mov r13, rdx
    mov rdi, rax
    mov rsi, rdx
    xor edx, edx
    call ed_clip_set
    lea rdi, [rip + .Lc_failed]
    test eax, eax
    jz .Lc_toast
    xor ecx, ecx                # characters (UTF-16 units) and lines
    xor r14d, r14d
    mov r15d, 1
5:  cmp rcx, r13
    jae 6f
    movzx eax, byte ptr [r12 + rcx]
    inc rcx
    cmp eax, 10
    jne 51f
    inc r15d
51: mov edx, eax
    and edx, 0xc0
    cmp edx, 0x80
    je 5b
    inc r14d
    cmp eax, 0xf0
    jb 5b
    inc r14d
    jmp 5b
6:  lea rdi, [rip + psb]
    call sb_clear
    lea rdi, [rip + psb]
    lea rsi, [rip + .Lc_copied]
    call sb_push_cstr
    lea rdi, [rip + psb]
    mov esi, r14d
    call sb_push_u64
    lea rdi, [rip + psb]
    lea rsi, [rip + .Lc_chars]
    call sb_push_cstr
    lea rdi, [rip + psb]
    mov esi, r15d
    call sb_push_u64
    lea rsi, [rip + .Lc_line]
    cmp r15d, 1
    je 7f
    lea rsi, [rip + .Lc_lines]
7:  lea rdi, [rip + psb]
    call sb_push_cstr
    jmp .Lc_psb
.Lc_usage:
    lea rdi, [rip + psb]
    call sb_clear
    lea rdi, [rip + psb]
    lea rsi, [rip + .Lc_usage_text]
    call sb_push_cstr
    lea rdi, [rip + psb]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    jmp .Lc_psb
.Lc_only:
    lea rdi, [rip + psb]
    call sb_clear
    lea rdi, [rip + psb]
    lea rsi, [rip + .Lc_only1]
    call sb_push_cstr
    lea rdi, [rip + psb]
    mov esi, r14d
    call sb_push_u64
    lea rsi, [rip + .Lc_only2]
    cmp r14d, 1
    je 8f
    lea rsi, [rip + .Lc_only3]
8:  lea rdi, [rip + psb]
    call sb_push_cstr
.Lc_psb:
    lea rdi, [rip + psb]
    xor esi, esi
    call sb_push_byte
    mov rdi, [rip + psb + SB_ptr]
.Lc_toast:
    call app_toast
    EPILOGUE

# ---- drawing ----

# row_h(kind) -> eax a row's height: a section's, the foot's in the small face, the others in the panel's
row_h:
    mov rax, [rip + ag_fui]
    mov ecx, [rip + g_pmt + 4*MI_10]
    cmp edi, APK_SECTION
    je 1f
    cmp edi, APK_FOOT
    jne 2f
1:  mov rax, [rip + ag_fsmall]
    mov ecx, [rip + g_pmt + 4*MI_8]
2:  mov eax, [rax + FACE_lineh]
    add eax, ecx
    ret

# content_h() -> eax the rows' height
content_h:
    PROLOGUE
    xor ebx, ebx
    xor r12d, r12d
1:  cmp rbx, [rip + rows + VEC_len]
    jae 9f
    mov rdi, rbx
    call row_at
    mov edi, [rax + PR_kind]
    call row_h
    add r12d, eax
    inc rbx
    jmp 1b
9:  mov eax, r12d
    EPILOGUE

# field_h() -> eax the button menu's filter field (a line of the panel's face and the text area's padding;
#   0 for the others)
field_h:
    xor eax, eax
    cmp dword ptr [rip + pop_kind], APP_MENU
    jne 9f
    cmp dword ptr [rip + pop_typed], 0
    jne 9f
    push rbx
    mov rax, [rip + ag_fui]
    mov [rip + pop_tf + TF_face], rax
    lea rdi, [rip + pop_tf]
    call ta_line_h_of
    PM ecx, MI_12
    cmp ecx, [rip + g_mt + 4*MI_12]
    jge 1f
    mov ecx, [rip + g_mt + 4*MI_12]
1:  add eax, ecx
    pop rbx
9:  ret

# FN agentpop_h(w) -> eax the popup's whole height (before it is cut to its room)
FN agentpop_h
    PROLOGUE
    call field_h
    mov ebx, eax
    test eax, eax
    jz 1f
    add ebx, [rip + g_pmt + 4*MI_4]
1:  call content_h
    add eax, ebx
    add eax, [rip + g_pmt + 4*MI_4]
    add eax, [rip + g_pmt + 4*MI_4]
    EPILOGUE

# geom(x, bottom, w, max_h): g_px, g_py, g_pw, g_ph (the popup), g_ry, g_rh (its rows), g_fh (its field)
geom:
    PROLOGUE
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov r15d, ecx
    mov eax, r12d
    add eax, [rip + g_pmt + 4*MI_8]
    mov [rip + g_px], eax
    mov eax, r14d
    sub eax, [rip + g_pmt + 4*MI_8]
    sub eax, [rip + g_pmt + 4*MI_8]
    cmp eax, 1
    jge 1f
    mov eax, 1
1:  mov [rip + g_pw], eax
    call field_h
    mov [rip + g_fh], eax
    mov edi, r14d
    call agentpop_h
    cmp eax, r15d
    jle 2f
    mov eax, r15d
2:  test eax, eax
    jg 3f
    mov eax, 1
3:  mov [rip + g_ph], eax
    mov ecx, r13d
    sub ecx, eax
    sub ecx, [rip + g_pmt + 4*MI_4]
    mov [rip + g_py], ecx
    add ecx, [rip + g_pmt + 4*MI_4]
    mov edx, [rip + g_fh]
    test edx, edx
    jz 4f
    add edx, [rip + g_pmt + 4*MI_4]
4:  add ecx, edx
    mov [rip + g_ry], ecx
    sub eax, edx
    sub eax, [rip + g_pmt + 4*MI_4]
    sub eax, [rip + g_pmt + 4*MI_4]
    jns 5f
    xor eax, eax
5:  mov [rip + g_rh], eax
    EPILOGUE

# row_geom(PR*): where its parts go in the popup (g_px, g_pw): lay_lx/lw the label, lay_dx/dw the
#   description (dw 0: none), lay_tx/tw the trail or the switch (tw 0: none). The trail takes at most a third,
#   the label what is left, the description the rest; every part inside the popup
row_geom:
    PROLOGUE
    mov rbx, rdi
    mov r12d, [rip + g_px]
    add r12d, [rip + g_pmt + 4*MI_10]   # lx
    mov r13d, [rip + g_px]
    add r13d, [rip + g_pw]
    sub r13d, [rip + g_pmt + 4*MI_10]   # rx
    cmp dword ptr [rip + pop_kind], APP_MENU
    je 1f
    add r12d, [rip + g_pmt + 4*MI_16]   # a picker: the check's column
    add r12d, [rip + g_pmt + 4*MI_4]
1:  cmp r13d, r12d
    jge 2f
    mov r13d, r12d
2:  mov [rip + lay_lx], r12d
    mov dword ptr [rip + lay_dw], 0
    mov dword ptr [rip + lay_tw], 0
    mov [rip + lay_tx], r13d
    mov eax, [rbx + PR_kind]
    cmp eax, APK_SECTION
    je .Lrg_small
    cmp eax, APK_EMPTY
    je .Lrg_small
    cmp eax, APK_FOOT
    je .Lrg_small
    xor r14d, r14d              # the trail's width
    cmp eax, APK_LEVELS
    jne 31f
    PM r14d, MI_64              # the effort row's track (a third of the row at most)
    add r14d, [rip + g_pmt + 4*MI_16]
    jmp 32f
31: cmp eax, APK_SWITCH
    jne 3f
    PM r14d, MI_28
    jmp 4f
3:  mov rsi, [rbx + PR_trail]
    test rsi, rsi
    jz 5f
    mov rdi, rsi
    call strlen
    mov rdx, rax
    mov rdi, [rip + ag_fsmall]
    mov rsi, [rbx + PR_trail]
    call text_width
    mov r14d, eax
32: mov eax, r13d               # a third of the row at most
    sub eax, r12d
    xor edx, edx
    mov ecx, 3
    div ecx
    cmp r14d, eax
    jle 4f
    mov r14d, eax
4:  mov eax, r13d
    sub eax, r14d
    mov [rip + lay_tx], eax
    mov [rip + lay_tw], r14d
    sub eax, [rip + g_pmt + 4*MI_8]
    mov r13d, eax               # the label and description end here
    cmp r13d, r12d
    jge 5f
    mov r13d, r12d
5:  mov rdi, [rbx + PR_label]
    call strlen
    mov rdx, rax
    mov rdi, [rip + ag_fui]
    mov rsi, [rbx + PR_label]
    call text_width
    mov ecx, r13d
    sub ecx, r12d
    cmp eax, ecx
    jle 6f
    mov eax, ecx
6:  mov [rip + lay_lw], eax
    mov rsi, [rbx + PR_desc]
    test rsi, rsi
    jz 9f
    cmp byte ptr [rsi], 0
    je 9f
    lea ecx, [r12 + rax]
    add ecx, [rip + g_pmt + 4*MI_8]
    mov [rip + lay_dx], ecx
    mov eax, r13d
    sub eax, ecx
    cmp eax, [rip + g_pmt + 4*MI_16]
    jl 9f
    mov [rip + lay_dw], eax
9:  EPILOGUE
.Lrg_small:
    mov rdi, [rbx + PR_label]
    call strlen
    mov rdx, rax
    mov rdi, [rip + ag_fsmall]
    mov rsi, [rbx + PR_label]
    call text_width
    mov ecx, r13d
    sub ecx, r12d
    cmp eax, ecx
    jle 1f
    mov eax, ecx
1:  mov [rip + lay_lw], eax
    mov rsi, [rbx + PR_trail]   # a header's hint at the right, in what the label leaves (MI_16 at least)
    test rsi, rsi
    jz 9f
    lea r14d, [r12 + rax]
    add r14d, [rip + g_pmt + 4*MI_8]
    mov rdi, rsi
    call strlen
    mov rdx, rax
    mov rdi, [rip + ag_fsmall]
    mov rsi, [rbx + PR_trail]
    call text_width
    mov ecx, r13d
    sub ecx, r14d
    cmp ecx, [rip + g_pmt + 4*MI_16]
    jl 9f
    cmp eax, ecx
    cmovg eax, ecx
    mov [rip + lay_tw], eax
    mov ecx, r13d
    sub ecx, eax
    mov [rip + lay_tx], ecx
9:  EPILOGUE

# fix_scroll(): pop_scroll within the rows, the selected row shown when the keys moved to it
fix_scroll:
    PROLOGUE
    cmp dword ptr [rip + pop_reveal], 0
    je 3f
    mov dword ptr [rip + pop_reveal], 0
    movsxd r12, dword ptr [rip + pop_sel]
    test r12, r12
    js 3f
    xor ebx, ebx                # its top
    xor r13d, r13d
1:  cmp rbx, r12
    jae 2f
    mov rdi, rbx
    call row_at
    mov edi, [rax + PR_kind]
    call row_h
    add r13d, eax
    inc rbx
    jmp 1b
2:  mov rdi, r12
    call row_at
    mov edi, [rax + PR_kind]
    call row_h
    cmp r13d, [rip + pop_scroll]
    jge 21f
    mov [rip + pop_scroll], r13d
21: add eax, r13d
    sub eax, [rip + g_rh]
    cmp eax, [rip + pop_scroll]
    jle 3f
    mov [rip + pop_scroll], eax
3:  call content_h
    sub eax, [rip + g_rh]
    jns 4f
    xor eax, eax
4:  cmp [rip + pop_scroll], eax
    jle 5f
    mov [rip + pop_scroll], eax
5:  cmp dword ptr [rip + pop_scroll], 0
    jge 9f
    mov dword ptr [rip + pop_scroll], 0
9:  EPILOGUE

# FN agentpop_draw(x, bottom, w, area_h): the popup of the panel x..x+w, its bottom MI_4 above bottom, over
#   the area_h above it: at most half of it, more (up to all of it) only when half cannot hold its field and
#   three rows (a large font in a short panel); its rows scroll. A press outside it and the box below
#   closes it
FN agentpop_draw
    PROLOGUE 16
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    call agentpop_unshield
    mov dword ptr [rip + pop_rect + 12], 0
    lea rdi, [rip + row_ay]     # where the rows are, as this frame draws them
    xor eax, eax
    mov ecx, AT_MAX + 4
1:  mov [rdi], eax
    add rdi, 4
    dec ecx
    jnz 1b
    call sync
    test eax, eax
    jz 9f
    call build
    call field_h                # its room: half the area, or what three rows need
    test eax, eax
    jz 11f
    add eax, [rip + g_pmt + 4*MI_4]
11: mov ebx, eax
    mov edi, APK_ROW
    call row_h
    imul eax, eax, 3
    add ebx, eax
    add ebx, [rip + g_pmt + 4*MI_8]
    mov eax, [rsp + 12]
    sub eax, [rip + g_pmt + 4*MI_4]
    mov ecx, [rsp + 12]
    sar ecx, 1
    cmp ecx, ebx
    jge 12f
    mov ecx, ebx
12: cmp ecx, eax
    jle 13f
    mov ecx, eax
13: mov [rsp + 12], ecx
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    call geom
    mov edi, [rip + g_px]
    mov esi, [rip + g_py]
    mov edx, [rip + g_pw]
    mov ecx, [rip + g_ph]
    call ui_in
    mov r12d, eax
    test dword ptr [rip + g_pressed], 1 << BTN_LEFT
    jz 1f
    test r12d, r12d
    jnz 1f
    mov eax, [rip + g_my]       # the box below keeps it (the typed menu follows its caret)
    cmp eax, [rsp + 4]
    jl 11f
    mov eax, [rip + g_mx]
    cmp eax, [rsp]
    jl 11f
    mov ecx, [rsp]
    add ecx, [rsp + 8]
    cmp eax, ecx
    jl 1f
11: call agentpop_close
    jmp 9f
1:  test r12d, r12d
    jz 2f
    mov eax, [rip + g_scroll_y]
    test eax, eax
    jz 2f
    add [rip + pop_scroll], eax
    mov dword ptr [rip + g_scroll_y], 0
2:  call fix_scroll
    mov edi, [rip + g_px]       # the surface
    mov esi, [rip + g_py]
    mov edx, [rip + g_pw]
    mov ecx, [rip + g_ph]
    PM r8d, MI_12
    PM r9d, MI_4
    PM eax, MI_RADIUS
    add eax, [rip + g_pmt + 4*MI_2]
    push rax
    push rax
    call ui_card_shadow
    add rsp, 16
    cmp dword ptr [rip + g_fh], 0
    je 3f
    lea rdi, [rip + pop_tf]     # the filter field
    mov esi, [rip + g_px]
    add esi, [rip + g_pmt + 4*MI_6]
    mov edx, [rip + g_py]
    add edx, [rip + g_pmt + 4*MI_4]
    mov ecx, [rip + g_pw]
    sub ecx, [rip + g_pmt + 4*MI_6]
    sub ecx, [rip + g_pmt + 4*MI_6]
    mov r8d, [rip + g_fh]
    mov r9d, 1
    lea rax, [rip + .Lph_filter]
    push rax
    push rax
    call ui_textarea
    add rsp, 16
3:  mov edi, [rip + g_px]       # the rows
    mov esi, [rip + g_ry]
    mov edx, [rip + g_pw]
    mov ecx, [rip + g_rh]
    call gfx_clip_push
    mov r13d, [rip + g_ry]
    sub r13d, [rip + pop_scroll]
    xor r12d, r12d
4:  cmp r12, [rip + rows + VEC_len]
    jae 5f
    mov rdi, r12
    call row_at
    mov rbx, rax
    mov edi, [rbx + PR_kind]
    call row_h
    mov r14d, eax
    lea eax, [r13 + r14]
    cmp eax, [rip + g_ry]
    jle 41f
    mov eax, [rip + g_ry]
    add eax, [rip + g_rh]
    cmp r13d, eax
    jge 5f
    mov rdi, rbx
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    call draw_row
    test eax, eax
    jnz 5f                      # it acted: the rows may be others now
41: add r13d, r14d
    inc r12
    jmp 4b
5:  call gfx_clip_pop
    cmp dword ptr [rip + pop_kind], 0
    je 6f
    mov eax, [rip + g_px]
    mov [rip + pop_rect], eax
    mov eax, [rip + g_py]
    mov [rip + pop_rect + 4], eax
    mov eax, [rip + g_pw]
    mov [rip + pop_rect + 8], eax
    mov eax, [rip + g_ph]
    mov [rip + pop_rect + 12], eax
6:  mov eax, [rip + g_mx]
    mov [rip + pop_mx], eax
    mov eax, [rip + g_my]
    mov [rip + pop_my], eax
9:  EPILOGUE

# draw_row(PR*, i, y, h) -> eax 1 when a click took it
draw_row:
    PROLOGUE 32
    mov rbx, rdi
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    mov rdi, rbx
    call row_geom
    mov eax, [rbx + PR_kind]
    cmp eax, APK_SECTION
    je .Ldr_small
    cmp eax, APK_EMPTY
    je .Ldr_small
    cmp eax, APK_FOOT
    je .Ldr_small
    mov edi, [rsp]              # a row: hover, press
    cmp edi, ROWS_IDS
    jbe 1f
    mov edi, ROWS_IDS
1:  add edi, ID_AGPOP
    mov esi, [rip + g_px]
    add esi, [rip + g_pmt + 4*MI_4]
    mov edx, [rsp + 4]
    mov ecx, [rip + g_pw]
    sub ecx, [rip + g_pmt + 4*MI_4]
    sub ecx, [rip + g_pmt + 4*MI_4]
    mov r8d, [rsp + 8]
    call ui_btn
    mov [rsp + 12], eax
    mov eax, [rsp]              # its centre, for print-agent-menu
    cmp eax, AT_MAX
    jae 10f
    mov ecx, [rsp + 8]
    shr ecx, 1
    add ecx, [rsp + 4]
    lea rdx, [rip + row_ay]
    mov [rdx + rax*4], ecx
10: mov eax, [rsp + 12]
    test eax, UB_HOVER
    jz 2f
    mov eax, [rip + g_mx]       # the pointer moved onto it: it is the selection
    cmp eax, [rip + pop_mx]
    jne 11f
    mov eax, [rip + g_my]
    cmp eax, [rip + pop_my]
    je 2f
11: mov eax, [rsp]
    cmp eax, [rip + pop_sel]
    je 2f
    mov edi, eax
    call choose
    mov dword ptr [rip + pop_reveal], 0
2:  mov eax, [rsp]
    cmp eax, [rip + pop_sel]
    jne 3f
    COLOR edi, T_POPUP          # the selection: the accent over the surface
    COLOR esi, T_ACCENT
    mov edx, 56
    call color_mix
    mov r9d, eax
    mov edi, [rip + g_px]
    add edi, [rip + g_pmt + 4*MI_4]
    mov esi, [rsp + 4]
    mov edx, [rip + g_pw]
    sub edx, [rip + g_pmt + 4*MI_4]
    sub edx, [rip + g_pmt + 4*MI_4]
    mov ecx, [rsp + 8]
    PM r8d, MI_RADIUS
    call gfx_round_rect
3:  test dword ptr [rbx + PR_flags], APRF_CHECK
    jz 4f
    PM ecx, MI_16               # the check, in its column
    mov esi, [rsp + 8]
    sub esi, ecx
    sar esi, 1
    add esi, [rsp + 4]
    mov edx, esi
    mov esi, [rip + g_px]
    add esi, [rip + g_pmt + 4*MI_10]
    mov edi, IC_CHECK
    COLOR r8d, T_ACCENT
    call icon_draw
4:  COLOR r10d, T_FG            # the label
    test dword ptr [rbx + PR_flags], APRF_OFF
    jz 41f
    COLOR r10d, T_MUTED
41: mov rdi, [rbx + PR_label]
    mov rax, [rip + ag_fui]
    call text_at
    cmp dword ptr [rip + lay_dw], 0 # the description
    je 5f
    mov rsi, [rbx + PR_desc]
    mov rdi, rsi
    mov eax, [rip + lay_dx]
    mov [rip + lay_lx], eax
    mov eax, [rip + lay_dw]
    mov [rip + lay_lw], eax
    COLOR r10d, T_MUTED
    mov rax, [rip + ag_fsmall]
    call text_at
5:  cmp dword ptr [rip + lay_tw], 0
    je 7f
    cmp dword ptr [rbx + PR_kind], APK_LEVELS
    jne 51f
    mov rdi, rbx                # the effort row: its track, and the row's title
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 12]
    call levels_tip
    mov rdi, rbx
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    call draw_track
    test eax, eax
    jz 7f
    EPILOGUE                    # a level was set: the rows are made again
51: cmp dword ptr [rbx + PR_kind], APK_SWITCH
    je 6f
    mov eax, [rip + lay_tx]     # the trail
    mov [rip + lay_lx], eax
    mov eax, [rip + lay_tw]
    mov [rip + lay_lw], eax
    mov rdi, [rbx + PR_trail]
    COLOR r10d, T_MUTED
    mov rax, [rip + ag_fsmall]
    call text_at
    jmp 7f
6:  mov rdi, rbx
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    call draw_switch
7:  test dword ptr [rsp + 12], UB_CLICK
    jz 8f
    mov edi, [rsp]
    call choose
    mov edi, 1
    call enter
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE
.Ldr_small:
    COLOR r10d, T_MUTED
    mov rdi, [rbx + PR_label]
    mov rax, [rip + ag_fsmall]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    call text_at_y
    cmp dword ptr [rip + lay_tw], 0 # a header's hint
    je 1f
    mov eax, [rip + lay_tx]
    mov [rip + lay_lx], eax
    mov eax, [rip + lay_tw]
    mov [rip + lay_lw], eax
    COLOR r10d, T_MUTED
    mov rdi, [rbx + PR_trail]
    mov rax, [rip + ag_fsmall]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    call text_at_y
1:  xor eax, eax
    EPILOGUE

# text_at(cstr, face rax, colour r10d) using [rsp + 4 + 8] y and [rsp + 8 + 8] h of draw_row's frame: the
#   text at lay_lx, at most lay_lw wide (cut with "…")
text_at:
    mov edx, [rsp + 8 + 4]
    mov ecx, [rsp + 8 + 8]
# text_at_y(cstr, face rax, y, h, colour r10d): the same at y, h
text_at_y:
    PROLOGUE 16
    mov r12, rdi
    mov r13, rax
    mov [rsp], edx
    mov [rsp + 4], ecx
    mov r14d, r10d
    test r12, r12
    jz 9f
    mov rdi, r12
    call strlen
    mov r9, rax
    mov rdi, r13
    mov esi, [rip + lay_lx]
    mov edx, [rsp]
    mov ecx, [rsp + 4]
    mov r8, r12
    mov r11d, [rip + lay_lw]
    inc r11d
    push r11
    push r14
    call ui_text_v_fit
    add rsp, 16
9:  EPILOGUE

# levels_tip(PR*, i, y, h, ub): the effort row's title "Click to cycle effort level" (its button's)
levels_tip:
    PROLOGUE
    mov edi, esi
    cmp edi, ROWS_IDS
    jbe 1f
    mov edi, ROWS_IDS
1:  add edi, ID_AGPOP
    mov esi, [rip + g_px]
    add esi, [rip + g_pmt + 4*MI_4]
    add edx, ecx                # below it
    mov ecx, [rip + g_pw]
    sub ecx, [rip + g_pmt + 4*MI_4]
    sub ecx, [rip + g_pmt + 4*MI_4]
    lea r9, [rip + .Lt_cycle]
    call tip_note_text
    EPILOGUE

# draw_track(PR*, y, h) -> eax 1 when it set a level: the effort row's track at lay_tx, lay_tw wide (2.11):
#   a bar, its part up to the level in effect filled, a notch per level, the thumb on the level in effect;
#   a press on it or a drag (the button held) sets the nearest level (once per level reached); title
#   "Click or drag to set effort level"
draw_track:
    PROLOGUE 48
    mov rbx, rdi
    mov [rsp], esi
    mov [rsp + 4], edx
    mov r12, [rbx + PR_model]
    test r12, r12
    jz .Ltr_none
    mov r13, [r12 + AMO_levels + VEC_len]
    test r13, r13
    jz .Ltr_none
    mov r14d, -1                # the level in effect, -1 none
    mov rsi, [rbx + PR_extra]
    test rsi, rsi
    jz 2f
    xor ecx, ecx
1:  cmp rcx, r13
    jae 2f
    imul rax, rcx, AEL_SIZE
    add rax, [r12 + AMO_levels + VEC_ptr]
    push rcx
    push rsi
    mov rdi, [rax + AEL_id]
    call strcmp_eq
    pop rsi
    pop rcx
    test eax, eax
    jnz 11f
    inc rcx
    jmp 1b
11: mov r14d, ecx
2:  PM eax, MI_12               # the thumb's size, the bar's height, the inset
    mov [rsp + 8], eax
    PM eax, MI_6
    mov [rsp + 12], eax
    PM eax, MI_2
    mov [rsp + 16], eax
    mov eax, [rip + lay_tw]     # the thumb's travel
    sub eax, [rsp + 8]
    sub eax, [rsp + 16]
    sub eax, [rsp + 16]
    cmp eax, 1
    jge 3f
    mov eax, 1
3:  mov [rsp + 20], eax
    mov eax, [rsp + 4]          # the middle
    shr eax, 1
    add eax, [rsp]
    mov [rsp + 24], eax
    mov eax, [rip + lay_tx]     # the rect print-agent-menu names
    mov [rip + trk_rect], eax
    mov eax, [rsp]
    mov [rip + trk_rect + 4], eax
    mov eax, [rip + lay_tw]
    mov [rip + trk_rect + 8], eax
    mov eax, [rsp + 4]
    mov [rip + trk_rect + 12], eax
    mov edi, ID_AGPOP + ID_TRACK
    mov esi, [rip + lay_tx]
    mov edx, [rsp]
    mov ecx, [rip + lay_tw]
    mov r8d, [rsp + 4]
    call ui_btn
    mov [rsp + 28], eax
    xor r15d, r15d              # acted
    test eax, UB_PRESS | UB_HELD
    jz .Ltr_draw
    test eax, UB_PRESS
    jz 4f
    mov dword ptr [rip + trk_last], -1
4:  mov eax, [rip + g_mx]       # the nearest level: (x - left) * (n - 1) / travel, rounded
    sub eax, [rip + lay_tx]
    sub eax, [rsp + 16]
    mov ecx, [rsp + 8]
    shr ecx, 1
    sub eax, ecx
    jns 41f
    xor eax, eax
41: lea ecx, [r13 - 1]
    imul eax, ecx
    mov ecx, [rsp + 20]
    mov edx, ecx
    shr edx, 1
    add eax, edx
    xor edx, edx
    div ecx
    lea ecx, [r13 - 1]
    cmp eax, ecx
    cmova eax, ecx
    cmp eax, [rip + trk_last]
    je .Ltr_draw
    mov [rip + trk_last], eax
    cmp eax, r14d
    je .Ltr_draw
    imul rax, rax, AEL_SIZE
    add rax, [r12 + AMO_levels + VEC_ptr]
    mov rdi, [rax + AEL_id]
    call level
    mov r15d, 1
.Ltr_draw:
    mov edi, [rip + lay_tx]     # the bar
    mov esi, [rsp + 24]
    mov ecx, [rsp + 12]
    shr ecx, 1
    sub esi, ecx
    mov edx, [rip + lay_tw]
    mov ecx, [rsp + 12]
    mov r8d, ecx
    shr r8d, 1
    COLOR r9d, T_BORDER
    call gfx_round_rect
    test r14d, r14d             # its part up to the thumb
    js 6f
    mov edi, r14d
    call track_x
    add eax, [rsp + 8]
    add eax, [rsp + 16]
    sub eax, [rip + lay_tx]
    mov [rsp + 32], eax
    COLOR edi, T_POPUP
    COLOR esi, T_ACCENT
    mov edx, 60
    call color_mix
    mov r9d, eax
    mov edi, [rip + lay_tx]
    mov esi, [rsp + 24]
    mov ecx, [rsp + 12]
    shr ecx, 1
    sub esi, ecx
    mov edx, [rsp + 32]
    mov ecx, [rsp + 12]
    mov r8d, ecx
    shr r8d, 1
    call gfx_round_rect
6:  xor ebx, ebx                # a notch per level
7:  cmp rbx, r13
    jae 8f
    mov edi, ebx
    call track_x
    mov edi, eax
    mov ecx, [rsp + 8]
    shr ecx, 1
    add edi, ecx
    mov edx, [rsp + 16]         # (MI_2 square, centred)
    shr edx, 1
    sub edi, edx
    mov esi, [rsp + 24]
    sub esi, edx
    mov edx, [rsp + 16]
    mov ecx, edx
    mov r8d, edx
    shr r8d, 1
    COLOR r9d, T_MUTED
    call gfx_round_rect
    inc rbx
    jmp 7b
8:  test r14d, r14d             # the thumb
    js 9f
    mov edi, r14d
    call track_x
    mov edi, eax
    mov esi, [rsp + 24]
    mov ecx, [rsp + 8]
    shr ecx, 1
    sub esi, ecx
    mov edx, [rsp + 8]
    mov ecx, edx
    mov r8d, edx
    shr r8d, 1
    COLOR r9d, T_ACCENT
    call gfx_round_rect
9:  mov edi, ID_AGPOP + ID_TRACK
    mov esi, [rip + lay_tx]
    mov edx, [rsp]
    add edx, [rsp + 4]
    mov ecx, [rip + lay_tw]
    mov r8d, [rsp + 28]
    lea r9, [rip + .Lt_track]
    call tip_note_text
    mov eax, r15d
    EPILOGUE
.Ltr_none:
    xor eax, eax
    EPILOGUE

# track_x(i) using draw_track's r13 (levels) and frame -> eax the thumb's left at level i
track_x:
    mov eax, [rsp + 8 + 20]     # the travel (draw_track's [rsp + 20], under this call's return address)
    imul eax, edi
    lea ecx, [r13 - 1]
    test ecx, ecx
    jz 1f
    xor edx, edx
    div ecx
    jmp 2f
1:  xor eax, eax
2:  add eax, [rip + lay_tx]
    add eax, [rsp + 8 + 16]
    ret

# draw_switch(PR*, y, h): a switch at lay_tx, on with APRF_ON
draw_switch:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    PM r14d, MI_16              # its height
    mov eax, r13d
    sub eax, r14d
    sar eax, 1
    add r12d, eax               # its top
    COLOR r9d, T_BORDER
    test dword ptr [rbx + PR_flags], APRF_ON
    jz 1f
    COLOR r9d, T_ACCENT
1:  mov edi, [rip + lay_tx]
    mov esi, r12d
    mov edx, [rip + lay_tw]
    mov ecx, r14d
    mov r8d, r14d
    shr r8d, 1
    call gfx_round_rect
    mov r15d, r14d              # the knob
    sub r15d, [rip + g_pmt + 4*MI_2]
    sub r15d, [rip + g_pmt + 4*MI_2]
    jg 2f
    mov r15d, 1
2:  mov edi, [rip + lay_tx]
    add edi, [rip + g_pmt + 4*MI_2]
    COLOR r9d, T_POPUP
    test dword ptr [rbx + PR_flags], APRF_ON
    jz 3f
    mov edi, [rip + lay_tx]
    add edi, [rip + lay_tw]
    sub edi, [rip + g_pmt + 4*MI_2]
    sub edi, r15d
    COLOR r9d, T_ACCENT_FG
3:  mov esi, r12d
    add esi, [rip + g_pmt + 4*MI_2]
    mov edx, r15d
    mov ecx, r15d
    mov r8d, r15d
    shr r8d, 1
    call gfx_round_rect
    EPILOGUE

# ---- tests ----

# FN agentpop_dump(sb): "popup=menu|modes|models filter=T sel=N owner=SID" (sel 0 none, owner - a draft's), then
#   "section NAME" (a header's hint after a tab), "row N LABEL\tDESC\tTRAIL\tFLAGS" (N from 1 among the rows the keys stop on; - for none;
#   FLAGS of check, off, on, switch, levels=ID; a levels row is followed by "levels ID:LABEL,…"), "empty T",
#   "foot T"; "popup=none" when closed. Then where the last frame drew them ("at N X,Y" a row, "track
#   X,Y,W,H" the effort track: at_dump), then the box's argument hint (composer_hint_dump)
FN agentpop_dump
    PROLOGUE
    mov rbx, rdi
    call sync
    test eax, eax
    jnz 1f
    mov rdi, rbx
    lea rsi, [rip + .Ld_none]
    call sb_push_cstr
    jmp .Ldp_hint
1:  call build
    mov rdi, rbx
    lea rsi, [rip + .Ld_popup]
    call sb_push_cstr
    mov eax, [rip + pop_kind]
    lea rcx, [rip + kind_names]
    mov rsi, [rcx + rax*8]
    mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Ld_filter]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rip + pop_q + SB_ptr]
    mov rdx, [rip + pop_q + SB_len]
    test rsi, rsi
    jz 2f
    call sb_push
2:  mov rdi, rbx
    lea rsi, [rip + .Ld_sel]
    call sb_push_cstr
    xor r12d, r12d              # sel: its number among the rows the keys stop on
    movsxd r13, dword ptr [rip + pop_sel]
    test r13, r13
    js 4f
    xor r14d, r14d
3:  cmp r14, r13
    ja 4f
    mov rdi, r14
    call row_at
    mov rdi, rax
    call selectable
    add r12d, eax
    inc r14
    jmp 3b
4:  mov rdi, rbx
    mov esi, r12d
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_owner]
    call sb_push_cstr
    mov rax, [rip + pop_owner]
    test rax, rax
    jz 5f
    mov rax, [rax + AS_live]
    test rax, rax
    jz 5f
    cmp byte ptr [rax + AL_sid], 0
    je 5f
    lea rsi, [rax + AL_sid]
    mov rdi, rbx
    call sb_push_cstr
    jmp 6f
5:  mov rdi, rbx
    mov esi, '-'
    call sb_push_byte
6:  mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    xor r12d, r12d              # the rows
    xor r13d, r13d              # numbered
.Ldp_row:
    cmp r12, [rip + rows + VEC_len]
    jae .Ldp_hint
    mov rdi, r12
    call row_at
    mov r14, rax
    inc r12
    mov eax, [r14 + PR_kind]
    lea rsi, [rip + .Ld_section]
    cmp eax, APK_SECTION
    je 1f
    lea rsi, [rip + .Ld_empty]
    cmp eax, APK_EMPTY
    je 1f
    lea rsi, [rip + .Ld_foot]
    cmp eax, APK_FOOT
    jne 2f
1:  mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [r14 + PR_label]
    call sb_push_cstr
    mov rsi, [r14 + PR_trail]   # a header's hint after a tab
    test rsi, rsi
    jz 9f
    cmp dword ptr [r14 + PR_kind], APK_SECTION
    jne 9f
    mov rdi, rbx
    mov esi, 9
    call sb_push_byte
    mov rdi, rbx
    mov rsi, [r14 + PR_trail]
    call sb_push_cstr
    jmp 9f
2:  inc r13d
    mov rdi, rbx
    lea rsi, [rip + .Ld_row]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, r13d
    call sb_push_u64
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rdi, rbx
    mov rsi, [r14 + PR_label]
    call push_or_dash
    mov rdi, rbx
    mov esi, 9
    call sb_push_byte
    mov rdi, rbx
    mov rsi, [r14 + PR_desc]
    call push_or_dash
    mov rdi, rbx
    mov esi, 9
    call sb_push_byte
    mov rdi, rbx
    mov rsi, [r14 + PR_trail]
    call push_or_dash
    mov rdi, rbx
    mov esi, 9
    call sb_push_byte
    mov r15, [rbx + SB_len]     # the flags
    test dword ptr [r14 + PR_flags], APRF_CHECK
    jz 3f
    lea rsi, [rip + .Lf_check]
    call flag_word
3:  test dword ptr [r14 + PR_flags], APRF_OFF
    jz 4f
    lea rsi, [rip + .Lf_off]
    call flag_word
4:  test dword ptr [r14 + PR_flags], APRF_ON
    jz 5f
    lea rsi, [rip + .Lf_on]
    call flag_word
5:  cmp dword ptr [r14 + PR_kind], APK_SWITCH
    jne 6f
    lea rsi, [rip + .Lf_switch]
    call flag_word
6:  cmp dword ptr [r14 + PR_kind], APK_LEVELS
    jne 7f
    lea rsi, [rip + .Lf_levels]
    call flag_word
    mov rdi, rbx
    mov rsi, [r14 + PR_extra]
    call push_or_dash
7:  cmp [rbx + SB_len], r15
    jne 9f
    mov rdi, rbx
    mov esi, '-'
    call sb_push_byte
9:  mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    cmp dword ptr [r14 + PR_kind], APK_LEVELS
    jne .Ldp_row
    mov rdi, rbx                # its levels: "levels ID:LABEL,ID:LABEL"
    mov rsi, [r14 + PR_model]
    call levels_dump
    jmp .Ldp_row
.Ldp_hint:
    mov rdi, rbx
    call at_dump
    mov rdi, rbx
    call composer_hint_dump
    EPILOGUE

# levels_dump(sb, AMO* or 0): "levels ID:LABEL,ID:LABEL" (nothing without a model)
levels_dump:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    test r12, r12
    jz 9f
    lea rsi, [rip + .Ld_levels]
    call sb_push_cstr
    xor r13d, r13d
1:  cmp r13, [r12 + AMO_levels + VEC_len]
    jae 8f
    imul r14, r13, AEL_SIZE
    add r14, [r12 + AMO_levels + VEC_ptr]
    test r13, r13
    jz 2f
    mov rdi, rbx
    mov esi, ','
    call sb_push_byte
2:  mov rdi, rbx
    mov rsi, [r14 + AEL_id]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, ':'
    call sb_push_byte
    mov rdi, rbx
    mov rsi, [r14 + AEL_label]
    call sb_push_cstr
    inc r13
    jmp 1b
8:  mov rdi, rbx
    mov esi, 10
    call sb_push_byte
9:  EPILOGUE

# at_dump(sb): "at N X,Y" for each row the keys stop on that the last frame drew (N as the rows' numbers; X
#   MI_40 in from the popup's left, Y its middle), then "track X,Y,W,H" when an effort track was drawn
at_dump:
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rip + pop_rect + 12], 0
    je 9f
    xor r12d, r12d              # the row
    xor r13d, r13d              # its number
1:  cmp r12, [rip + rows + VEC_len]
    jae 5f
    cmp r12, AT_MAX
    jae 5f
    mov rdi, r12
    call row_at
    mov rdi, rax
    call selectable
    inc r12
    test eax, eax
    jz 1b
    inc r13d
    lea rax, [rip + row_ay]
    mov r14d, [rax + r12*4 - 4]
    test r14d, r14d
    jz 1b
    mov rdi, rbx
    lea rsi, [rip + .Ld_at]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, r13d
    call sb_push_u64
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov esi, [rip + pop_rect]   # (on its label's side, left of a track or a switch)
    add esi, [rip + g_pmt + 4*MI_40]
    mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    mov esi, ','
    call sb_push_byte
    mov rdi, rbx
    mov esi, r14d
    call sb_push_u64
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    jmp 1b
5:  cmp dword ptr [rip + trk_rect + 8], 0
    je 9f
    mov rdi, rbx
    lea rsi, [rip + .Ld_track]
    call sb_push_cstr
    xor r12d, r12d
6:  lea rax, [rip + trk_rect]
    mov esi, [rax + r12*4]
    mov rdi, rbx
    call sb_push_u64
    inc r12d
    cmp r12d, 4
    jae 7f
    mov rdi, rbx
    mov esi, ','
    call sb_push_byte
    jmp 6b
7:  mov rdi, rbx
    mov esi, 10
    call sb_push_byte
9:  EPILOGUE

# flag_word(word cstr) using rbx = sb, r15 = where the flags start: ",WORD" (the first without the comma)
flag_word:
    push rsi
    cmp [rbx + SB_len], r15
    je 1f
    mov rdi, rbx
    mov esi, ','
    call sb_push_byte
1:  pop rsi
    mov rdi, rbx
    jmp sb_push_cstr

# push_or_dash(sb, cstr or 0): the text, "-" when it is none or empty
push_or_dash:
    test rsi, rsi
    jz 1f
    cmp byte ptr [rsi], 0
    je 1f
    jmp sb_push_cstr
1:  mov esi, '-'
    jmp sb_push_byte

# FN agentpop_fit_dump(sb): the open popup's layout at every panel size 8 to 32 and width 240 to 900 (step
#   20), a line each: "size=S w=W x=X pw=PW h=H left=L right=R label=LW" (x and the parts from the panel's
#   left; L and R the leftmost and rightmost a row's parts reach, LW the narrowest label of a row); the
#   setting is the user's again after it
FN agentpop_fit_dump
    PROLOGUE 16
    mov rbx, rdi
    call sync
    test eax, eax
    jnz 1f
    mov rdi, rbx
    lea rsi, [rip + .Ld_none]
    call sb_push_cstr
    EPILOGUE
1:  mov eax, [rip + cfg_agents_font_size]
    mov [rsp], eax
    mov r12d, 8
.Lfd_size:
    cmp r12d, 32
    ja .Lfd_done
    mov [rip + cfg_agents_font_size], r12d
    call agents_metrics
    call build
    mov r13d, 240
.Lfd_w:
    cmp r13d, 900
    ja .Lfd_next
    xor edi, edi
    mov esi, 2000
    mov edx, r13d
    mov ecx, 1000
    call geom
    mov dword ptr [rsp + 4], 0x7fffffff     # left
    mov dword ptr [rsp + 8], 0              # right
    mov dword ptr [rsp + 12], 0x7fffffff    # narrowest label
    xor r14d, r14d
2:  cmp r14, [rip + rows + VEC_len]
    jae 5f
    mov rdi, r14
    call row_at
    mov r15, rax
    mov rdi, rax
    call row_geom
    inc r14
    mov eax, [rip + lay_lx]
    cmp eax, [rsp + 4]
    jge 3f
    mov [rsp + 4], eax
3:  add eax, [rip + lay_lw]
    mov ecx, [rip + lay_dw]
    test ecx, ecx
    jz 31f
    add ecx, [rip + lay_dx]
    cmp ecx, eax
    cmovg eax, ecx
31: mov ecx, [rip + lay_tw]
    test ecx, ecx
    jz 32f
    add ecx, [rip + lay_tx]
    cmp ecx, eax
    cmovg eax, ecx
32: cmp eax, [rsp + 8]
    jle 33f
    mov [rsp + 8], eax
33: mov rdi, r15
    call selectable
    test eax, eax
    jz 2b
    mov eax, [rip + lay_lw]
    cmp eax, [rsp + 12]
    jge 2b
    mov [rsp + 12], eax
    jmp 2b
5:  mov rdi, rbx
    lea rsi, [rip + .Lfd_s]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, r12d
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lfd_wd]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, r13d
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lfd_x]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + g_px]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lfd_pw]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + g_pw]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lfd_h]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + g_ph]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lfd_left]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rsp + 4]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lfd_right]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rsp + 8]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lfd_label]
    call sb_push_cstr
    mov esi, [rsp + 12]
    cmp esi, 0x7fffffff
    jne 6f
    xor esi, esi
6:  mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    add r13d, 20
    jmp .Lfd_w
.Lfd_next:
    inc r12d
    jmp .Lfd_size
.Lfd_done:
    mov eax, [rsp]
    mov [rip + cfg_agents_font_size], eax
    call agents_metrics
    EPILOGUE

.data
.p2align 2
trk_last: .long -1              # the level a drag of the track gave last
pop_q_marker: .byte 0           # 1: the next query differs from the last, whatever it is

.section .rodata
.p2align 3
sec_names: .quad .Lempty_s, .Ls_context, .Ls_model, .Ls_customize, .Ls_settings, .Ls_support, .Ls_slash
    .quad .Lempty_s
kind_names: .quad .Ld_dash, .Lk_menu, .Lk_modes, .Lk_models
empty: .byte 0
.Lempty_s: .asciz ""
.Ls_context: .asciz "Context"
.Ls_model: .asciz "Model"
.Ls_customize: .asciz "Customize"
.Ls_settings: .asciz "Settings"
.Ls_support: .asciz "Support"
.Ls_slash: .asciz "Slash Commands"
.Lnone: .asciz "No matching commands"
.Lm_modes: .asciz "Modes"
.Lm_select: .asciz "Select a model"
.Lm_loading: .asciz "Loading models\342\200\246"
.Lm_none: .asciz "No models available"
.Lt_track: .asciz "Click or drag to set effort level"
.Lt_cycle: .asciz "Click to cycle effort level"
.Lcycle: .asciz "~"
.Lw_on: .asciz "on"
.Lw_off: .asciz "off"
.Ld_levels: .asciz "levels "
.Ld_at: .asciz "at "
.Ld_track: .asciz "track "
.Lm_modes_hint: .asciz "\342\207\247 + tab to switch"
.Lph_filter: .asciz "Filter actions\342\200\246"
.Lv: .asciz "v"
.Lsp: .asciz " "
.Lslash: .asciz "/"
.Lparen: .asciz " ("
.Lparen_end: .asciz ")"
.Lplus: .asciz "+"
.Lminus: .asciz "-"
.Lc_none: .asciz "No assistant message to copy"
.Lc_failed: .asciz "Could not copy to clipboard"
.Lc_copied: .asciz "Copied to clipboard ("
.Lc_chars: .asciz " characters, "
.Lc_line: .asciz " line)"
.Lc_lines: .asciz " lines)"
.Lc_usage_text: .asciz "Usage: /copy [N] where N is 1 (latest), 2, 3, \342\200\246 Got: "
.Lc_only1: .asciz "Only "
.Lc_only2: .asciz " assistant message available to copy"
.Lc_only3: .asciz " assistant messages available to copy"
.Ld_none: .asciz "popup=none\n"
.Ld_popup: .asciz "popup="
.Ld_filter: .asciz " filter="
.Ld_sel: .asciz " sel="
.Ld_owner: .asciz " owner="
.Ld_dash: .asciz "-"
.Ld_section: .asciz "section "
.Ld_empty: .asciz "empty "
.Ld_foot: .asciz "foot "
.Ld_row: .asciz "row "
.Lk_menu: .asciz "menu"
.Lk_modes: .asciz "modes"
.Lk_models: .asciz "models"
.Lf_check: .asciz "check"
.Lf_off: .asciz "off"
.Lf_on: .asciz "on"
.Lf_switch: .asciz "switch"
.Lf_levels: .asciz "levels="
.Lfd_s: .asciz "size="
.Lfd_wd: .asciz " w="
.Lfd_x: .asciz " x="
.Lfd_pw: .asciz " pw="
.Lfd_h: .asciz " h="
.Lfd_left: .asciz " left="
.Lfd_right: .asciz " right="
.Lfd_label: .asciz " label="
