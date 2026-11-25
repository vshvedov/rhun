# Claude Code's Manage Plugins dialog (claude-chat-p7b; ext-webview-ui.md 6.4, 6.5, 6.6, 4.19), a module of
# claude_dlg2.s. Everything goes through `claude plugin ...` runs (README findings 86 to 88), one at a time:
# `plugin list --json` (installed), `plugin marketplace list --json`, `plugin list --json --available`; the
# changes `plugin install|update|uninstall --scope S --json -- ID`, `plugin enable|disable --json -- ID`,
# `plugin configure --json [--values-stdin] -- ID`, `plugin marketplace add|remove|update --json -- X`. After a
# change a running session reloads its plugins (reload_plugins); when it cannot, "Restart Claude to apply
# plugin changes" with Restart (the process ends; the next message starts it again).
# A link's plugin (4.19): `plugin marketplace add --from-link --resolve-only -- SRC` finds its marketplace; a
# new one asks first ("Trust marketplace and continue"), then `plugin marketplace add --from-link -- SRC`.
# Text from a marketplace (names, descriptions, options) is cleaned and cut (c2_clean); a source's page opens
# only through links_ask_open; a sensitive option is typed as bullets.
.include "rhun.inc"

.equ PG_LIST, 0                 # pages
.equ PG_PLUGIN, 1
.equ PG_INSTALL, 2
.equ PG_UNINSTALL, 3
.equ PG_OPTIONS, 4
.equ PG_MKT, 5
.equ PG_MKTREMOVE, 6
.equ PG_TRUST, 7
.equ GA_TAB, 1                  # acts (arg: the tab)
.equ GA_PLUGIN, 2               # (arg: the installed one's index)
.equ GA_AVAIL, 3                # (arg: the available one's index)
.equ GA_BACK, 4
.equ GA_TOGGLE, 5
.equ GA_OPTIONS, 6
.equ GA_UPDATE, 7
.equ GA_UNINSTALL, 8
.equ GA_KEEP, 9
.equ GA_DELETE, 10
.equ GA_SCOPE, 11               # (arg: 0 user, 1 project, 2 local)
.equ GA_SAVEOPTS, 12
.equ GA_CHOICE, 13              # (arg: option index << 8 | choice index)
.equ GA_MKTADD, 14
.equ GA_MKT, 15                 # (arg: the marketplace's index)
.equ GA_REFRESH, 16
.equ GA_MKTREMOVE, 17
.equ GA_MKTCONFIRM, 18
.equ GA_RESTART, 19
.equ GA_TRUST, 20
.equ GA_SOURCE, 21              # a source's page (arg: the marketplace's index)
.equ GA_RETRY, 22
.equ GA_RELOAD, 23               # Try again after the session could not reload its plugins
.equ GW_LIST, 1                 # runs
.equ GW_MKTS, 2
.equ GW_AVAIL, 3
.equ GW_CHANGE, 4
.equ GW_OPTS, 5
.equ GW_SAVEOPTS, 6
.equ GW_RESOLVE, 7
.equ GW_LINKADD, 8
.equ GR_RELOAD, 1               # control requests
.equ OPTS_MAX, 16
.equ CHOICES_MAX, 16
.equ NAME_MAX, 200
.equ ORDER_MAX, 16384           # available plugins listed at most (the official directory has thousands)

.bss
.p2align 3
g_tab: .quad 0                  # 0 Plugins, 1 Marketplaces
g_restart: .quad 0              # the restart notice shows
g_reload_failed: .quad 0        # the session could not reload its plugins (the extension's Reload plugins); 2
                                #   asked again (Try again): the notice goes when it can
g_avail: .quad 0                # the available list: 0 not read yet, 1 read, 2 failed
g_after: .quad 0                # what follows the lists: 1 the link's install page
g_id: .quad 0                   # owned cstr: the plugin (or marketplace) a page or a change is about
g_scope: .quad 0                # owned cstr: its scope
g_label: .quad 0                # owned cstr: its name as shown
g_link_plugin: .quad 0          # owned cstrs: a link's plugin and marketplace source (4.19)
g_link_source: .quad 0
g_link_mkt: .quad 0             # owned cstr: the marketplace it resolved to
g_tf_mkt: .zero TF_SIZE         # the marketplace to add
o_n: .quad 0                    # the options form: the keys shown
o_keys: .zero 8 * OPTS_MAX      #   owned cstrs
o_req: .zero 8 * OPTS_MAX       #   required (and not stored already)
o_choice: .zero 8 * OPTS_MAX    #   a choice's index chosen, -1 none (a text option)
o_nchoice: .zero 8 * OPTS_MAX
o_tfs: .zero TF_SIZE * OPTS_MAX
o_init: .zero SB_SIZE * OPTS_MAX    # their first text
o_err: .zero 8 * OPTS_MAX       #   owned cstr: an option's error, 0 none
o_doc: .zero SB_SIZE            # configure --json's answer, as JSON text

.text

.globl plg_open, plg_act, plg_answer, plg_ran, plg_send, plg_free, plg_tick

# plg_open(-, -): the installed plugins first, then the marketplaces, then what can be installed
plg_open:
    PROLOGUE
    mov qword ptr [rip + g_defer], 0
    mov qword ptr [rip + g_tab], 0
    mov qword ptr [rip + g_restart], 0
    mov qword ptr [rip + g_reload_failed], 0
    mov qword ptr [rip + g_avail], 0
    mov qword ptr [rip + g_after], 0
    lea rdi, [rip + .Lg_loading]
    call agentdlg_loading
    mov edi, GW_LIST
    call run_list
    EPILOGUE

plg_free:
    PROLOGUE
    mov qword ptr [rip + g_defer], 0
    call opts_clear
    lea rdi, [rip + g_tf_mkt]
    call c2_wipe_tf
    lea rax, [rip + g_id]
    call free_q
    lea rax, [rip + g_scope]
    call free_q
    lea rax, [rip + g_label]
    call free_q
    lea rax, [rip + g_link_plugin]
    call free_q
    lea rax, [rip + g_link_source]
    call free_q
    lea rax, [rip + g_link_mkt]
    call free_q
    EPILOGUE

plg_tick:
    ret

# free_q(rax: an owned cstr's slot)
free_q:
    push rbx
    mov rbx, rax
    mov rdi, [rbx]
    call mem_free
    mov qword ptr [rbx], 0
    pop rbx
    ret

# set_q(rax: slot, ptr, len): an owned copy in the slot
set_q:
    PROLOGUE
    mov rbx, rax
    mov r12, rdi
    mov r13, rsi
    mov rdi, [rbx]
    call mem_free
    mov rdi, r12
    mov rsi, r13
    call mem_dup
    mov [rbx], rax
    EPILOGUE

# plg_send(rq, AL*): reload_plugins
plg_send:
    mov rdi, rsi
    lea rsi, [rip + .Lv_reload]
    jmp claude_dlg2_begin

# plg_answer(rq, envelope): reload_plugins answered: when it could not (an error, or errors counted), the
#   restart notice and "This session couldn't reload its plugins." with Try again and Restart
plg_answer:
    PROLOGUE
    mov rbx, rsi
    mov rdi, rbx
    call c2_ok
    test eax, eax
    jz 1f
    mov rdi, rbx
    call c2_resp
    mov rdi, rax
    lea rsi, [rip + .Lk_error_count]
    call json_get
    mov rdi, rax
    call json_int
    test rax, rax
    jle 2f
1:  mov qword ptr [rip + g_restart], 1
    mov qword ptr [rip + g_reload_failed], 1
    jmp 3f
2:  cmp qword ptr [rip + g_reload_failed], 2
    jne 3f
    mov qword ptr [rip + g_reload_failed], 0    # reloaded after Try again: nothing to restart for
    mov qword ptr [rip + g_restart], 0
3:  call plg_build
    EPILOGUE

# reload(): a session running reloads its plugins; none running: the next start reads them
reload:
    PROLOGUE
    call c2_up
    test eax, eax
    jz 9f
    mov edi, GR_RELOAD
    call c2_ask
9:  EPILOGUE

# run_list(what): `plugin list --json` (GW_LIST), `plugin marketplace list --json` (GW_MKTS), `plugin list
#   --json --available` (GW_AVAIL)
run_list:
    PROLOGUE
    mov rbx, rdi
    call c2_args
    lea rdi, [rip + .La_plugin]
    call c2_arg_c
    cmp rbx, GW_MKTS
    jne 1f
    lea rdi, [rip + .La_marketplace]
    call c2_arg_c
1:  lea rdi, [rip + .La_list]
    call c2_arg_c
    lea rdi, [rip + .La_json]
    call c2_arg_c
    cmp rbx, GW_AVAIL
    jne 2f
    lea rdi, [rip + .La_available]
    call c2_arg_c
2:  lea rdi, [rip + c2_in]
    call sb_clear
    mov rdi, rbx
    call c2_run
    test eax, eax
    jnz 9f
    lea rdi, [rip + .Lno_run]
    call strlen
    mov rsi, rax
    lea rdi, [rip + .Lno_run]
    call agentdlg_fail
9:  EPILOGUE

# change(verb cstr, scope cstr or 0, extra flag cstr or 0, id cstr): `plugin VERB [--scope S] [FLAG] --json --
#   ID` (a marketplace's: verb "marketplace X" as two words, through mkt_change)
change:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    call c2_args
    lea rdi, [rip + .La_plugin]
    call c2_arg_c
    mov rdi, rbx
    call c2_arg_c
    test r12, r12
    jz 1f
    lea rdi, [rip + .La_scope]
    call c2_arg_c
    mov rdi, r12
    call c2_arg_c
1:  test r13, r13
    jz 2f
    mov rdi, r13
    call c2_arg_c
2:  lea rdi, [rip + .La_json]
    call c2_arg_c
    lea rdi, [rip + .La_dashes]
    call c2_arg_c
    mov rdi, r14
    call c2_arg_c
    call go_change
    EPILOGUE

# go_change(): the run made (c2_args ...) goes (GW_CHANGE), the page busy
go_change:
    PROLOGUE
    call c2_notes_clear
    lea rdi, [rip + c2_in]
    call sb_clear
    mov edi, GW_CHANGE
    call c2_run
    test eax, eax
    jz 8f
    mov qword ptr [rip + c2_busy], 1
    EPILOGUE
8:  lea rdi, [rip + .Lno_run]
    call c2_err_cset
    EPILOGUE

# mkt_change(verb cstr, name cstr): `plugin marketplace VERB --json -- NAME`
mkt_change:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call c2_args
    lea rdi, [rip + .La_plugin]
    call c2_arg_c
    lea rdi, [rip + .La_marketplace]
    call c2_arg_c
    mov rdi, rbx
    call c2_arg_c
    lea rdi, [rip + .La_json]
    call c2_arg_c
    lea rdi, [rip + .La_dashes]
    call c2_arg_c
    mov rdi, r12
    call c2_arg_c
    call go_change
    EPILOGUE

# plg_ran(what, code): its end (plg_ran1), then an act that waited for it
plg_ran:
    PROLOGUE
    call plg_ran1
    call c2_running
    test eax, eax
    jnz 9f
    mov rdi, [rip + g_defer]
    test rdi, rdi
    jz 9f
    mov qword ptr [rip + g_defer], 0
    mov rsi, [rip + g_defer_arg]
    xor edx, edx
    call plg_act
9:  EPILOGUE

plg_ran1:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    cmp rbx, GW_LIST
    je .Lpr_list
    cmp rbx, GW_MKTS
    je .Lpr_mkts
    cmp rbx, GW_AVAIL
    je .Lpr_avail
    cmp rbx, GW_CHANGE
    je .Lpr_change
    cmp rbx, GW_OPTS
    je .Lpr_opts
    cmp rbx, GW_SAVEOPTS
    je .Lpr_saveopts
    cmp rbx, GW_RESOLVE
    je .Lpr_resolve
    cmp rbx, GW_LINKADD
    je .Lpr_linkadd
    EPILOGUE
.Lpr_list:
    test r12, r12               # installed: kept, then the marketplaces
    jnz .Lpr_loadfail
    lea rdi, [rip + c2_out]
    lea rsi, [rip + c2_doc]
    call keep_out
    test eax, eax
    jz .Lpr_loadfail
    mov edi, GW_MKTS
    call run_list
    EPILOGUE
.Lpr_mkts:
    test r12, r12
    jnz .Lpr_loadfail
    lea rdi, [rip + c2_out]
    lea rsi, [rip + c2_doc2]
    call keep_out
    test eax, eax
    jz .Lpr_loadfail
    call plg_build              # shown now; what can be installed follows
    mov edi, GW_AVAIL
    call run_list
    EPILOGUE
.Lpr_avail:
    test r12, r12               # {"installed": [...], "available": [...]}: what is not installed
    jnz 2f
    lea rdi, [rip + c2_out]
    call c2_last_json
    test rax, rax
    jz 2f
    mov r13, rax
    mov rdi, rax
    lea rsi, [rip + .Lk_available]
    call json_get
    mov rdi, rax
    call json_type
    cmp eax, JT_ARR
    jne 2f
    mov rdi, r13
    lea rsi, [rip + .Lk_installed]
    call json_get
    test rax, rax
    jz 1f
    mov rsi, rax
    lea rdi, [rip + c2_doc]
    call c2_keep
    lea rdi, [rip + c2_out]
    call c2_last_json
    mov r13, rax
1:  mov rdi, r13
    lea rsi, [rip + .Lk_available]
    call json_get
    mov rsi, rax
    lea rdi, [rip + c2_doc3]
    call c2_keep
    mov qword ptr [rip + g_avail], 1
    jmp 3f
2:  mov qword ptr [rip + g_avail], 2
3:  cmp qword ptr [rip + g_after], 1 # a link's plugin: its install page
    jne 31f
    mov qword ptr [rip + g_after], 0
    call link_install
    jmp 4f
31: cmp qword ptr [rip + g_after], 2 # a link's: its marketplace looked up once the lists are read
    jne 4f
    mov qword ptr [rip + g_after], 0
    call resolve_link
    EPILOGUE
4:  call plg_build
    EPILOGUE
.Lpr_loadfail:
    call agentdlg_begin         # "Your plugins and marketplaces couldn't be loaded." and Try again
    lea rdi, [rip + .Lg_load_failed]
    mov esi, DGF_ERROR
    call c2_text
    mov rdi, r12
    call c2_errout
    mov edi, DGF_MUTED | DGF_SMALL
    call c2_ftext
    lea rdi, [rip + .Lg_try_again]
    mov esi, GA_RETRY
    mov edx, DBF_PRIMARY
    call agentdlg_button
    EPILOGUE
.Lpr_change:
    test r12, r12
    jnz 5f
    call done_f                 # done: its notice; plugins reloaded; the lists again
    call c2_msg_fsb
    cmp qword ptr [rip + c2_busy_act], GA_MKTADD
    jne 40f
    lea rdi, [rip + g_tf_mkt]   # (the marketplace added: its field emptied)
    call tf_clear
40: mov rax, [rip + c2_page]
    cmp rax, PG_MKT
    je 41f
    cmp rax, PG_MKTREMOVE
    je 41f
    cmp rax, PG_INSTALL
    je 42f
    jmp 43f
41: lea rdi, [rip + g_tf_mkt]
    call tf_clear
    mov qword ptr [rip + c2_page], PG_LIST
    jmp 44f
42: mov qword ptr [rip + c2_page], PG_LIST
    jmp 44f
43: cmp rax, PG_UNINSTALL
    jne 44f
    mov qword ptr [rip + c2_page], PG_LIST
44: call reload
    mov qword ptr [rip + c2_busy], 1
    call plg_build
    mov edi, GW_LIST
    call run_list
    EPILOGUE
5:  call fail_f                 # failed: the extension's words, then the CLI's
    call c2_err_fsb
    call plg_build
    EPILOGUE
.Lpr_opts:
    test r12, r12               # configure --json: the form, or why not
    jnz 61f
    lea rdi, [rip + c2_out]
    call c2_last_json
    test rax, rax
    jz 61f
    mov rsi, rax
    lea rdi, [rip + o_doc]
    call c2_keep
    call opts_fill
    mov qword ptr [rip + c2_page], PG_OPTIONS
    xor edi, edi
    call agentdlg_focus
    call plg_build
    EPILOGUE
61: call f_clr
    lea rdi, [rip + .Lg_opts_unloaded]
    call f_c
    lea rdi, [rip + .Lspace]
    call f_c
    mov rdi, r12
    call errout_append
    call c2_err_fsb
    call plg_build
    EPILOGUE
.Lpr_saveopts:
    lea rdi, [rip + c2_out]     # {"saved": [...]} or {"refused": {"option"?, "message"}}
    call c2_last_json
    mov r13, rax
    test rax, rax
    jz 7f
    mov rdi, rax
    lea rsi, [rip + .Lk_refused]
    call json_get
    test rax, rax
    jz 7f
    mov r14, rax
    mov rdi, rax
    lea rsi, [rip + .Lk_option]
    call c2_jstr
    test rdx, rdx
    jz 65f
    mov rdi, rax                # an option's: under it
    mov rsi, rdx
    call opt_index
    cmp rax, -1
    je 65f
    mov r15, rax
    mov rdi, r14
    lea rsi, [rip + .Lk_message]
    mov edx, 800
    call c2_jcl
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    lea rcx, [rip + o_err]
    mov rdi, [rcx + r15*8]
    mov [rcx + r15*8], rax
    call mem_free
    call plg_build
    EPILOGUE
65: lea rdi, [rip + .Lg_opts_changed]
    call c2_err_cset
    call plg_build
    EPILOGUE
7:  test r12, r12
    jnz 71f
    mov rdi, r13                # saved: the restart notice when anything was
    lea rsi, [rip + .Lk_saved]
    call json_get
    mov rdi, rax
    call json_len
    test eax, eax
    jz 72f
    mov qword ptr [rip + g_restart], 1
    call reload
72: call opts_clear
    mov qword ptr [rip + c2_page], PG_LIST
    call plg_build
    EPILOGUE
71: call f_clr
    lea rdi, [rip + .Lg_opts_unsaved]
    call f_c
    lea rdi, [rip + .Lspace]
    call f_c
    mov rdi, r12
    call errout_append
    call c2_err_fsb
    call plg_build
    EPILOGUE
.Lpr_resolve:
    lea rdi, [rip + c2_out]     # {"existing": NAME | null}: added already, or the trust question
    call c2_last_json
    test rax, rax
    jz 81f
    mov rdi, rax
    lea rsi, [rip + .Lk_existing]
    call c2_jstr
    test rdx, rdx
    jz 81f
    mov rdi, rax
    mov rsi, rdx
    lea rax, [rip + g_link_mkt]
    call set_q
    mov qword ptr [rip + g_after], 1
    lea rdi, [rip + .Lg_loading_avail]
    call agentdlg_loading
    mov edi, GW_LIST
    call run_list
    EPILOGUE
81: mov qword ptr [rip + c2_page], PG_TRUST
    call plg_build
    EPILOGUE
.Lpr_linkadd:
    test r12, r12               # added: its name ({"name", "added"}), the lists, its install page
    jnz 91f
    lea rdi, [rip + c2_out]
    call c2_last_json
    test rax, rax
    jz 92f
    mov r13, rax
    mov rdi, rax
    lea rsi, [rip + .Lk_refused]
    call json_get
    test rax, rax
    jnz 93f
    mov rdi, r13
    lea rsi, [rip + .Lk_name]
    call c2_jstr
    test rdx, rdx
    jz 92f
    mov rdi, rax
    mov rsi, rdx
    lea rax, [rip + g_link_mkt]
    call set_q
92: mov qword ptr [rip + g_after], 1
    mov qword ptr [rip + c2_page], PG_LIST
    lea rdi, [rip + .Lg_loading_avail]
    call agentdlg_loading
    mov edi, GW_LIST
    call run_list
    EPILOGUE
93: lea rdi, [rip + .Lg_link_refused]   # refused (a name or address it has already): nothing changed
    call c2_err_cset
    mov qword ptr [rip + c2_page], PG_LIST
    call plg_build
    EPILOGUE
91: call f_clr
    lea rdi, [rip + .Lg_mkt_failed]
    call f_c
    lea rdi, [rip + .Lspace]
    call f_c
    mov rdi, r12
    call errout_append
    call c2_err_fsb
    mov qword ptr [rip + c2_page], PG_LIST
    call plg_build
    EPILOGUE

# errout_append(code): fsb += the run's error (c2_errout's words)
errout_append:
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rip + c2_msg]     # (fsb is c2_errout's: the start goes through c2_msg's spare room)
    call sb_clear
    lea rdi, [rip + c2_msg]
    mov rsi, [rip + fsb + SB_ptr]
    mov rdx, [rip + fsb + SB_len]
    call sb_push
    mov rdi, rbx
    call c2_errout
    mov rdi, [rip + fsb + SB_ptr]
    mov rsi, [rip + fsb + SB_len]
    lea r12, [rip + c2_msg]
    mov rdi, r12
    mov rsi, [rip + fsb + SB_ptr]
    mov rdx, [rip + fsb + SB_len]
    call sb_push
    call f_clr
    mov rdi, [r12 + SB_ptr]
    mov rsi, [r12 + SB_len]
    call f_n
    mov rdi, r12
    call sb_clear
    EPILOGUE

# keep_out(sb out, sb keep) -> eax 1 when the output's last JSON line is an array: kept
keep_out:
    PROLOGUE
    mov rbx, rsi
    call c2_last_json
    test rax, rax
    jz 8f
    mov r12, rax
    mov rdi, rax
    call json_type
    cmp eax, JT_ARR
    jne 8f
    mov rdi, rbx
    mov rsi, r12
    call c2_keep
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# done_f(): fsb = a change's notice (the page says what was done)
done_f:
    PROLOGUE
    call f_clr
    mov rax, [rip + c2_busy_act]
    lea rcx, [rip + done_words]
    mov rdi, [rcx + rax*8]
    cmp rax, GA_TOGGLE
    jne 1f
    cmp qword ptr [rip + g_turn_on], 0
    je 1f
    lea rdi, [rip + .Lg_d_enabled]
1:  call f_c
    mov rdi, [rip + g_label]
    test rdi, rdi
    jz 9f
    lea rdi, [rip + .Lspace]
    call f_c
    mov rdi, [rip + g_label]
    call f_c
9:  EPILOGUE

# fail_f(): fsb = a change's failure: the extension's words for its failureCode (uBt), else "Something went
#   wrong while ...", then the CLI's message
fail_f:
    PROLOGUE
    call f_clr
    lea rdi, [rip + c2_out]
    call c2_last_json
    mov rbx, rax
    test rax, rax
    jz 5f
    mov rdi, rax
    lea rsi, [rip + .Lk_failureCode]
    call c2_jstr
    test rdx, rdx
    jz 5f
    mov r12, rax
    mov r13, rdx
    lea r14, [rip + fail_codes]
1:  mov rdx, [r14]
    test rdx, rdx
    jz 5f
    mov rdi, r12
    mov rsi, r13
    call str_eq_cstr
    test eax, eax
    jnz 2f
    add r14, 24
    jmp 1b
2:  mov rdi, [r14 + 8]
    call f_c
    lea rdi, [rip + .Lspace]
    call f_c
    mov rdi, [r14 + 16]
    call f_c
    jmp 6f
5:  lea rdi, [rip + .Lg_wrong]  # "Something went wrong while installing this plugin."
    call f_c
    mov rax, [rip + c2_busy_act]
    lea rcx, [rip + doing_words]
    mov rdi, [rcx + rax*8]
    cmp rax, GA_TOGGLE
    jne 51f
    cmp qword ptr [rip + g_turn_on], 0
    je 51f
    lea rdi, [rip + .Lg_x_toggle_on]
51: call f_c
    lea rdi, [rip + .Ldot]
    call f_c
6:  test rbx, rbx               # the CLI's message
    jz 7f
    lea rdi, [rip + c2_out]     # (parsed again: the codes above did not parse)
    call c2_last_json
    mov rdi, rax
    lea rsi, [rip + .Lk_message]
    mov edx, 800
    call c2_jcl
    test rdx, rdx
    jz 7f
    push rax
    push rdx
    lea rdi, [rip + .Lspace]
    call f_c
    pop rsi
    pop rdi
    call f_n
    EPILOGUE
7:  mov rdi, [rip + c2_eout + SB_ptr]
    mov rsi, [rip + c2_eout + SB_len]
    call c2_trim
    test rdx, rdx
    jz 9f
    push rax
    push rdx
    lea rdi, [rip + .Lspace]
    call f_c
    pop rsi
    pop rdi
    mov edx, 800
    call f_cl
9:  EPILOGUE

# name_f(id ptr, len): fsb += the plugin's name: the id without "@marketplace", cleaned
name_f:
    mov rdx, rsi
1:  test rdx, rdx
    jz 2f
    cmp byte ptr [rdi + rdx - 1], '@'
    je 3f
    dec rdx
    jmp 1b
3:  dec rdx
    mov rsi, rdx
2:  mov edx, NAME_MAX
    jmp f_cl

# status_of(plugin) -> rax its words: Not loaded (it needs another Claude Code), Failed to load, Enabled,
#   Disabled
status_of:
    PROLOGUE
    mov rbx, rdi
    call kept
    lea rcx, [rip + .Lg_kept]
    test eax, eax
    jnz 9f
    mov rdi, rbx
    lea rsi, [rip + .Lk_errors]
    call json_get
    mov rdi, rax
    call json_len
    lea rcx, [rip + .Lg_failed]
    test eax, eax
    jnz 9f
    mov rdi, rbx
    lea rsi, [rip + .Lk_enabled]
    call json_get
    mov rdi, rax
    call json_type
    lea rcx, [rip + .Lg_disabled]
    cmp eax, JT_FALSE
    je 9f
    lea rcx, [rip + .Lg_enabled]
9:  mov rax, rcx
    EPILOGUE

# kept(plugin) -> eax 1 when every error says it needs another version of Claude Code (TAe)
kept:
    PROLOGUE
    lea rsi, [rip + .Lk_errorDetails]
    call json_get
    mov rbx, rax
    mov rdi, rax
    call json_len
    test eax, eax
    jz 8f
    xor r12d, r12d
1:  mov rdi, rbx
    call json_len
    cmp r12d, eax
    jae 7f
    mov rdi, rbx
    mov esi, r12d
    call json_at
    inc r12d
    mov r13, rax
    mov rdi, rax
    lea rsi, [rip + .Lk_type]
    call c2_jstr
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + .Lv_engine]
    call str_eq_cstr
    test eax, eax
    jnz 1b
    mov rdi, r13
    lea rsi, [rip + .Lk_needsOther]
    call c2_jbool
    test eax, eax
    jnz 1b
8:  xor eax, eax
    EPILOGUE
7:  mov eax, 1
    EPILOGUE

# uninstallable(plugin) -> eax 1 when it can be uninstalled here (IBt): a user, project or local scope,
#   and an id NAME@MARKETPLACE of a real marketplace (not inline, synced, skills-dir, builtin)
uninstallable:
    PROLOGUE
    mov rbx, rdi
    lea rsi, [rip + .Lk_scope]
    call c2_jstr
    mov r12, rax
    mov r13, rdx
    xor r14d, r14d
1:  cmp r14d, 3
    jae 8f
    lea rax, [rip + scope_ids]
    mov rdx, [rax + r14*8]
    mov rdi, r12
    mov rsi, r13
    call str_eq_cstr
    test eax, eax
    jnz 2f
    inc r14d
    jmp 1b
2:  mov rdi, rbx
    lea rsi, [rip + .Lk_id]
    call c2_jstr
    mov r12, rax
    mov rcx, rdx
3:  test rcx, rcx               # its marketplace: after the last @
    jz 8f
    cmp byte ptr [r12 + rcx - 1], '@'
    je 4f
    dec rcx
    jmp 3b
4:  lea r13, [r12 + rcx]
    sub rdx, rcx
    mov r14, rdx
    lea r15, [rip + local_mkts]
5:  mov rdx, [r15]
    test rdx, rdx
    jz 7f
    mov rdi, r13
    mov rsi, r14
    call str_eq_cstr
    test eax, eax
    jnz 8f
    add r15, 8
    jmp 5b
7:  mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# plg_build(): the page shown
plg_build:
    PROLOGUE 48
    call agentdlg_begin
    cmp qword ptr [rip + c2_page], PG_LIST
    jne 1f
    cmp qword ptr [rip + g_tab], 0
    je 2f
1:  xor edi, edi                # the filter is the Plugins tab's alone
    call agentdlg_x_filter
2:  mov rax, [rip + c2_page]
    cmp rax, PG_LIST
    je .Lpb_list
    cmp rax, PG_PLUGIN
    je .Lpb_plugin
    cmp rax, PG_INSTALL
    je .Lpb_install
    cmp rax, PG_UNINSTALL
    je .Lpb_uninstall
    cmp rax, PG_OPTIONS
    je .Lpb_options
    cmp rax, PG_MKT
    je .Lpb_mkt
    cmp rax, PG_MKTREMOVE
    je .Lpb_mktremove
    cmp rax, PG_TRUST
    je .Lpb_trust
    EPILOGUE
.Lpb_list:
    xor edi, edi
    call agentdlg_back
    call restart_rows
    mov edi, DGK_TABS           # the tabs: Plugins (N), Marketplaces (N)
    xor esi, esi
    mov edx, GA_TAB
    call agentdlg_row
    mov [rsp], rax
    mov rcx, [rip + g_tab]
    mov [rax + DGR_val], rcx
    xor ecx, 1                  # (the row's own act, as a pick: the other tab)
    mov [rax + DGR_arg], rcx
    call f_clr
    lea rdi, [rip + .Lg_tab_plugins]
    call f_c
    lea rdi, [rip + c2_doc]
    call c2_parse
    mov rdi, rax
    call json_len
    test eax, eax
    jz 1f
    push rax
    push rax
    lea rdi, [rip + .Lspace]
    call f_c
    pop rdi
    pop rdi
    call f_u
1:  lea rdi, [rip + .Lg_tab_sep]
    call f_c
    lea rdi, [rip + c2_doc2]
    call c2_parse
    mov rdi, rax
    call json_len
    test eax, eax
    jz 2f
    push rax
    push rax
    lea rdi, [rip + .Lspace]
    call f_c
    pop rdi
    pop rdi
    call f_u
2:  mov rdi, [rsp]
    xor esi, esi
    call c2_fset
    call c2_msgs
    cmp qword ptr [rip + g_tab], 1
    je .Lpb_mkts
    lea rdi, [rip + c2_doc]     # the Plugins tab: Installed, Available
    call c2_parse
    mov rbx, rax
    mov rdi, rax
    call json_len
    mov r12d, eax
    lea rdi, [rip + c2_doc3]
    call c2_parse
    mov rdi, rax
    call json_len
    mov r13d, eax
    mov eax, r12d
    or eax, r13d
    jnz 3f
    cmp qword ptr [rip + g_avail], 0
    je 31f
    lea rdi, [rip + .Lg_none]
    xor esi, esi
    call c2_text
    EPILOGUE
31: lea rdi, [rip + .Lg_loading_avail]
    mov esi, DGF_MUTED
    call c2_text
    EPILOGUE
3:  lea rdi, [rip + .Lg_search]
    call agentdlg_x_filter
    test r12d, r12d
    jz 5f
    lea rdi, [rip + .Lg_installed]
    call c2_head
    lea rdi, [rip + c2_doc]
    call c2_parse
    mov rbx, rax
    xor r14d, r14d
4:  cmp r14d, r12d
    jae 5f
    mov rdi, rbx
    mov esi, r14d
    call json_at
    mov r15, rax
    inc r14d
    mov edi, DGK_ITEM
    mov esi, DGF_FILTER
    mov edx, GA_PLUGIN
    call agentdlg_row
    mov [rsp + 8], rax
    lea ecx, [r14 - 1]
    mov [rax + DGR_arg], rcx
    call f_clr
    mov rdi, r15
    lea rsi, [rip + .Lk_id]
    call c2_jstr
    mov rdi, rax
    mov rsi, rdx
    call name_f
    mov rdi, [rsp + 8]
    xor esi, esi
    call c2_fset
    call f_clr                  # "Scope: S", its first error
    lea rdi, [rip + .Lg_scope_c]
    call f_c
    mov rdi, r15
    lea rsi, [rip + .Lk_scope]
    mov edx, 100
    call c2_jcl
    mov rdi, rax
    mov rsi, rdx
    call f_n
    mov rdi, [rsp + 8]
    mov esi, 1
    call c2_fset
    mov rdi, r15
    call status_of
    mov rdx, rax
    mov rdi, [rsp + 8]
    mov esi, 2
    call agentdlg_ctext
    jmp 4b
5:  cmp qword ptr [rip + g_avail], 0
    jne 51f
    lea rdi, [rip + .Lg_loading_avail]
    mov esi, DGF_MUTED
    call c2_text
    EPILOGUE
51: test r13d, r13d
    jz 9f
    lea rdi, [rip + .Lg_available]
    call c2_head
    call installed_ids          # the installed ids copied, so the available list is parsed once
    lea rdi, [rip + c2_doc3]
    call c2_parse
    mov rbx, rax
    call avail_order            # by install count, the most first
    mov r13d, eax               #   (ORDER_MAX at most)
    xor r14d, r14d
6:  cmp r14d, r13d
    jae 9f
    lea rax, [rip + order]
    mov esi, [rax + r14*4]
    inc r14d
    mov [rsp + 16], esi
    mov rdi, rbx
    call json_at
    mov r15, rax
    mov rdi, rax                # installed already (the extension leaves those out)
    call is_installed
    test eax, eax
    jnz 6b
    mov edi, DGK_ITEM
    mov esi, DGF_FILTER
    mov edx, GA_AVAIL
    call agentdlg_row
    mov [rsp + 8], rax
    mov ecx, [rsp + 16]
    mov [rax + DGR_arg], rcx
    mov rdi, r15
    lea rsi, [rip + .Lk_name]
    mov edx, NAME_MAX
    call c2_jcl
    mov rdi, [rsp + 8]
    xor esi, esi
    mov rcx, rdx
    mov rdx, rax
    call agentdlg_text
    call f_clr                  # "from MKT · description"
    lea rdi, [rip + .Lg_from]
    call f_c
    mov rdi, r15
    lea rsi, [rip + .Lk_marketplaceName]
    mov edx, NAME_MAX
    call c2_jcl
    mov rdi, rax
    mov rsi, rdx
    call f_n
    mov rdi, r15
    lea rsi, [rip + .Lk_description]
    call c2_jstr
    test rdx, rdx
    jz 61f
    push rax
    push rdx
    lea rdi, [rip + .Lg_dot_sep]
    call f_c
    pop rsi
    pop rdi
    mov edx, 400
    call f_cl
61: mov rdi, [rsp + 8]
    mov esi, 1
    call c2_fset
    mov rdi, r15
    lea rsi, [rip + .Lk_installCount]
    call json_get
    mov rdi, rax
    call json_int
    test rax, rax
    jle 6b
    push rax
    push rax
    call f_clr
    pop rdi
    pop rdi
    call f_u
    lea rdi, [rip + .Lg_installs]
    call f_c
    mov rdi, [rsp + 8]
    mov esi, 2
    call c2_fset
    jmp 6b
9:  EPILOGUE
.Lpb_mkts:
    mov edi, DGK_FIELD          # the Marketplaces tab: the field and Add, the list
    xor esi, esi
    mov edx, GA_MKTADD
    xor ecx, ecx
    lea r8, [rip + .Lg_mkt_ph]
    xor r9d, r9d
    call c2_crow
    lea rcx, [rip + g_tf_mkt]
    mov [rax + DGR_val], rcx
    lea rdi, [rip + c2_doc2]
    call c2_parse
    mov rbx, rax
    mov rdi, rax
    call json_len
    mov r12d, eax
    test eax, eax
    jnz 1f
    lea rdi, [rip + .Lg_no_mkts]
    mov esi, DGF_MUTED
    call c2_text
    jmp 3f
1:  xor r13d, r13d
2:  cmp r13d, r12d
    jae 3f
    mov rdi, rbx
    mov esi, r13d
    call json_at
    mov r14, rax
    inc r13d
    mov edi, DGK_ITEM
    xor esi, esi
    mov edx, GA_MKT
    call agentdlg_row
    mov r15, rax
    lea ecx, [r13 - 1]
    mov [rax + DGR_arg], rcx
    mov rdi, r14
    lea rsi, [rip + .Lk_name]
    mov edx, NAME_MAX
    call c2_jcl
    mov rdi, r15
    xor esi, esi
    mov rcx, rdx
    mov rdx, rax
    call agentdlg_text
    mov rdi, r14
    call source_f
    mov rdi, r15
    mov esi, 1
    call c2_fset
    mov rdi, r14
    call official
    test eax, eax
    jz 2b
    mov rdi, r15
    mov esi, 2
    lea rdx, [rip + .Lg_official]
    call agentdlg_ctext
    jmp 2b
3:  lea rdi, [rip + .Lg_add]
    cmp qword ptr [rip + c2_busy], 0
    je 4f
    lea rdi, [rip + .Lg_adding]
4:  mov esi, GA_MKTADD
    mov edx, DBF_PRIMARY
    call agentdlg_button
    EPILOGUE
.Lpb_plugin:
    mov edi, GA_BACK            # an installed plugin: its state, scope, description, errors; its actions
    call agentdlg_back
    call c2_msgs
    lea rdi, [rip + c2_doc]
    call c2_parse
    mov rdi, rax
    call find_installed
    test rax, rax
    jz .Lpb_gone
    mov rbx, rax
    call f_clr
    mov rdi, rbx
    lea rsi, [rip + .Lk_id]
    call c2_jstr
    mov rdi, rax
    mov rsi, rdx
    call name_f
    mov edi, DGK_HEAD
    xor esi, esi
    xor edx, edx
    call c2_frow
    mov r12, rax
    mov rdi, rbx
    call status_of
    mov rdi, r12
    mov esi, 2
    mov rdx, rax
    call agentdlg_ctext
    mov rdi, rbx
    lea rsi, [rip + .Lk_description]
    call c2_jstr
    test rdx, rdx
    jz 1f
    call f_clr
    mov rdi, rbx
    lea rsi, [rip + .Lk_description]
    mov edx, 1000
    call c2_jcl
    mov rdi, rax
    mov rsi, rdx
    call f_n
    mov edi, DGF_MUTED
    call c2_ftext
1:  call f_clr
    lea rdi, [rip + .Lg_scope_c]
    call f_c
    mov rdi, rbx
    lea rsi, [rip + .Lk_scope]
    mov edx, 100
    call c2_jcl
    mov rdi, rax
    mov rsi, rdx
    call f_n
    mov edi, DGF_MUTED | DGF_SMALL
    call c2_ftext
    mov rdi, rbx                # its load errors, in plain words (IAe), then its notes (sBt)
    call errors_rows
    mov rdi, rbx
    lea rsi, [rip + .Lk_enabled]
    call json_get
    mov rdi, rax
    call json_type
    mov r13d, eax
    lea rdi, [rip + .Lg_disable]
    cmp r13d, JT_FALSE
    jne 2f
    lea rdi, [rip + .Lg_enable]
2:  mov esi, GA_TOGGLE
    mov edx, DBF_PRIMARY
    call busy_btn
    mov rdi, rbx
    lea rsi, [rip + .Lk_hasUserConfig]
    call c2_jbool
    test eax, eax
    jz 3f
    lea rdi, [rip + .Lg_configure]
    mov esi, GA_OPTIONS
    xor edx, edx
    call busy_btn
3:  mov rdi, rbx
    lea rsi, [rip + .Lk_scope]
    call c2_jstr
    test rdx, rdx
    jz 4f
    lea rdi, [rip + .Lg_update]
    mov esi, GA_UPDATE
    xor edx, edx
    call busy_btn
4:  mov rdi, rbx
    call uninstallable
    test eax, eax
    jz 5f
    lea rdi, [rip + .Lg_uninstall]
    mov esi, GA_UNINSTALL
    xor edx, edx
    call busy_btn
    EPILOGUE
5:  lea rdi, [rip + .Lg_cannot_uninstall]
    mov esi, DGF_MUTED | DGF_SMALL
    call c2_text
    EPILOGUE
.Lpb_gone:
    mov qword ptr [rip + c2_page], PG_LIST
    xor edi, edi
    call agentdlg_back
    EPILOGUE
.Lpb_install:
    mov edi, GA_BACK            # where to install it: the warning, three places, Cancel
    call agentdlg_back
    call c2_msgs
    call f_clr
    lea rdi, [rip + .Lg_install_q]
    call f_c
    mov rdi, [rip + g_label]
    call f_c
    mov edi, DGK_HEAD
    xor esi, esi
    xor edx, edx
    call c2_frow
    lea rdi, [rip + .Lg_warning]
    mov esi, DGF_MUTED | DGF_SMALL
    call c2_text
    xor ebx, ebx
1:  cmp ebx, 3
    jae 2f
    xor esi, esi
    cmp qword ptr [rip + c2_busy], 0
    je 11f
    mov esi, DGF_OFF
11: mov edi, DGK_OPTION
    mov edx, GA_SCOPE
    lea rax, [rip + install_places]
    imul rcx, rbx, 16
    mov r8, [rax + rcx + 8]
    mov rcx, [rax + rcx]
    xor r9d, r9d
    call c2_crow
    mov [rax + DGR_arg], rbx
    inc ebx
    jmp 1b
2:  cmp qword ptr [rip + c2_busy], 0
    je 3f
    lea rdi, [rip + .Lg_installing]
    mov esi, DGF_MUTED
    call c2_text
3:  lea rdi, [rip + .Lcancel]
    mov esi, GA_BACK
    xor edx, edx
    call agentdlg_button
    EPILOGUE
.Lpb_uninstall:
    mov edi, GA_BACK            # uninstall: keep its data or delete it
    call agentdlg_back
    call c2_msgs
    call f_clr
    lea rdi, [rip + .Lg_uninstall_q]
    call f_c
    mov rdi, [rip + g_label]
    call f_c
    lea rdi, [rip + .Lopen_paren]
    call f_c
    mov rdi, [rip + g_scope]
    call f_c
    lea rdi, [rip + .Lg_scope_q]
    call f_c
    mov edi, DGK_HEAD
    xor esi, esi
    xor edx, edx
    call c2_frow
    lea rdi, [rip + .Lg_saved_data]
    mov esi, DGF_MUTED
    call c2_text
    lea rdi, [rip + .Lg_keep]
    mov esi, GA_KEEP
    mov edx, DBF_PRIMARY
    call busy_btn
    lea rdi, [rip + .Lg_delete]
    mov esi, GA_DELETE
    xor edx, edx
    call busy_btn
    lea rdi, [rip + .Lcancel]
    mov esi, GA_BACK
    xor edx, edx
    call agentdlg_button
    EPILOGUE
.Lpb_options:
    call opts_rows
    EPILOGUE
.Lpb_mkt:
    mov edi, GA_BACK            # a marketplace: its source (a link to its page), Refresh, Remove
    call agentdlg_back
    call c2_msgs
    lea rdi, [rip + c2_doc2]
    call c2_parse
    mov rdi, rax
    mov rsi, [rip + c2_arg]
    call json_at
    test rax, rax
    jz .Lpb_gone
    mov rbx, rax
    mov rdi, rax
    lea rsi, [rip + .Lk_name]
    mov edx, NAME_MAX
    call c2_jcl
    mov rdi, rax
    mov rsi, rdx
    call f_clr
    mov rdi, rbx
    lea rsi, [rip + .Lk_name]
    mov edx, NAME_MAX
    call c2_jcl
    mov rdi, rax
    mov rsi, rdx
    call f_n
    mov edi, DGK_HEAD
    xor esi, esi
    xor edx, edx
    call c2_frow
    mov r12, rax
    mov rdi, rbx
    call official
    test eax, eax
    jz 1f
    mov rdi, r12
    mov esi, 2
    lea rdx, [rip + .Lg_official_long]
    call agentdlg_ctext
1:  mov rdi, rbx
    call source_url
    test eax, eax
    jz 2f
    mov edi, DGK_LINK
    xor esi, esi
    mov edx, GA_SOURCE
    call c2_frow
    mov rcx, [rip + c2_arg]
    mov [rax + DGR_arg], rcx
    jmp 3f
2:  mov rdi, rbx
    call source_f
    mov edi, DGF_MUTED
    call c2_ftext
3:  lea rdi, [rip + .Lg_refresh]
    mov esi, GA_REFRESH
    xor edx, edx
    call busy_btn
    lea rdi, [rip + .Lg_remove_mkt]
    mov esi, GA_MKTREMOVE
    xor edx, edx
    call agentdlg_button
    EPILOGUE
.Lpb_mktremove:
    mov edi, GA_BACK
    call agentdlg_back
    call c2_msgs
    call f_clr
    lea rdi, [rip + .Lg_remove_mkt_q]
    call f_c
    mov rdi, [rip + g_label]
    call f_c
    lea rdi, [rip + .Lg_q]
    call f_c
    xor edi, edi
    call c2_ftext
    lea rdi, [rip + .Lg_remove_mkt_note]
    mov esi, DGF_MUTED | DGF_SMALL
    call c2_text
    lea rdi, [rip + .Lg_remove_mkt]
    mov esi, GA_MKTCONFIRM
    mov edx, DBF_PRIMARY
    call busy_btn
    lea rdi, [rip + .Lcancel]
    mov esi, GA_BACK
    xor edx, edx
    call agentdlg_button
    EPILOGUE
.Lpb_trust:
    xor edi, edi                # 4.19: a link's plugin from a marketplace not added yet
    call agentdlg_back
    call c2_msgs
    lea rdi, [rip + .Lg_trust1]
    xor esi, esi
    call c2_text
    call f_clr
    mov rdi, [rip + g_link_plugin]
    call strlen
    mov rsi, rax
    mov rdi, [rip + g_link_plugin]
    mov edx, 100
    call f_cl
    xor edi, edi
    call c2_ftext
    lea rdi, [rip + .Lg_trust2]
    xor esi, esi
    call c2_text
    call f_clr
    mov rdi, [rip + g_link_source]
    call strlen
    mov rsi, rax
    mov rdi, [rip + g_link_source]
    mov edx, 256
    call f_cl
    xor edi, edi
    call c2_ftext
    lea rdi, [rip + .Lg_trust3]
    mov esi, DGF_MUTED
    call c2_text
    lea rdi, [rip + .Lg_trust_btn]
    cmp qword ptr [rip + c2_busy], 0
    je 1f
    lea rdi, [rip + .Lg_adding_mkt]
1:  mov esi, GA_TRUST
    mov edx, DBF_PRIMARY
    call agentdlg_button
    lea rdi, [rip + .Lcancel]
    mov esi, DA_CLOSE
    xor edx, edx
    call agentdlg_button
    EPILOGUE

# restart_rows(): "Restart Claude to apply plugin changes" with Restart, when a change needs it
restart_rows:
    PROLOGUE
    cmp qword ptr [rip + g_restart], 0
    je 9f
    lea rdi, [rip + .Lg_restart_note]
    mov esi, DGF_MUTED
    call c2_text
    cmp qword ptr [rip + g_reload_failed], 0
    je 1f
    lea rdi, [rip + .Lg_reload_failed]  # the extension's Reload plugins: Try again, Restart
    mov esi, DGF_ERROR
    call c2_text
    lea rdi, [rip + .Lg_try_again]
    mov esi, GA_RELOAD
    call c2_link
1:  lea rdi, [rip + .Lg_restart]
    mov esi, GA_RESTART
    call c2_link
9:  EPILOGUE

# busy_btn(label, act, flags): a button whose label is "Working…" while a change runs from this page
busy_btn:
    cmp qword ptr [rip + c2_busy], 0
    je 1f
    cmp esi, [rip + c2_busy_act]
    jne 1f
    lea rdi, [rip + .Lg_working]
1:  jmp agentdlg_button

# errors_rows(plugin): a row for each load error in plain words (IAe), each note (sBt)
errors_rows:
    PROLOGUE 16
    mov rbx, rdi
    lea rsi, [rip + .Lk_errors]
    call json_get
    mov r12, rax
    mov rdi, rbx
    lea rsi, [rip + .Lk_errorDetails]
    call json_get
    mov r13, rax
    xor r14d, r14d
1:  mov rdi, r12
    call json_len
    cmp r14d, eax
    jae 2f
    mov rdi, r13
    mov esi, r14d
    call json_at
    mov rdi, rax
    lea rsi, [rip + error_words]
    lea rdx, [rip + .Lg_err_default]
    call detail_words
    inc r14d
    mov edi, DGF_ERROR
    call c2_ftext
    jmp 1b
2:  mov rdi, rbx
    lea rsi, [rip + .Lk_notes]
    call json_get
    mov r12, rax
    mov rdi, rbx
    lea rsi, [rip + .Lk_noteDetails]
    call json_get
    mov r13, rax
    xor r14d, r14d
3:  mov rdi, r12
    call json_len
    cmp r14d, eax
    jae 9f
    mov rdi, r13
    mov esi, r14d
    call json_at
    mov rdi, rax
    lea rsi, [rip + note_words]
    lea rdx, [rip + .Lg_note_default]
    call detail_words
    inc r14d
    mov edi, DGF_MUTED | DGF_SMALL
    call c2_ftext
    jmp 3b
9:  EPILOGUE

# detail_words(detail or 0, table {type, words}, default): fsb = the words for its type, else the default
detail_words:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    call f_clr
    test rbx, rbx
    jz 8f
    mov rdi, rbx
    lea rsi, [rip + .Lk_type]
    call c2_jstr
    mov r14, rax
    mov r15, rdx
1:  mov rdx, [r12]
    test rdx, rdx
    jz 8f
    mov rdi, r14
    mov rsi, r15
    call str_eq_cstr
    test eax, eax
    jnz 2f
    add r12, 16
    jmp 1b
2:  mov rdi, [r12 + 8]
    call f_c
    EPILOGUE
8:  mov rdi, r13
    call f_c
    EPILOGUE

# source_f(marketplace): fsb = its source as text: the GitHub repo, the URL, the path
source_f:
    PROLOGUE
    mov rbx, rdi
    call f_clr
    lea r12, [rip + source_keys]
1:  mov rsi, [r12]
    test rsi, rsi
    jz 9f
    mov rdi, rbx
    call c2_jstr
    add r12, 8
    test rdx, rdx
    jz 1b
    mov rdi, rax
    mov rsi, rdx
    mov edx, 400
    call f_cl
9:  EPILOGUE

# source_url(marketplace) -> eax 1 with fsb = the web page of its source (a GitHub repo's, an https URL)
source_url:
    PROLOGUE
    mov rbx, rdi
    lea rsi, [rip + .Lk_repo]
    call c2_jstr
    test rdx, rdx
    jz 1f
    mov r12, rax
    mov r13, rdx
    call f_clr
    lea rdi, [rip + .Lg_github]
    call f_c
    mov rdi, r12
    mov rsi, r13
    mov edx, 300
    call f_cl
    mov eax, 1
    EPILOGUE
1:  mov rdi, rbx
    lea rsi, [rip + .Lk_url]
    call c2_jstr
    cmp rdx, 8
    jb 8f
    mov r12, rax
    mov r13, rdx
    mov rdi, rax
    mov esi, 8
    lea rdx, [rip + .Lg_https]
    call str_eq_cstr
    test eax, eax
    jz 8f
    call f_clr
    mov rdi, r12
    mov rsi, r13
    mov edx, 400
    call f_cl
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# official(marketplace) -> eax 1 for the official Claude Code marketplace (its GitHub repo)
official:
    push rbx
    lea rsi, [rip + .Lk_repo]
    call c2_jstr
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + .Lv_official_repo]
    call str_eq_cstr
    pop rbx
    ret

# find_installed(list) -> rax the installed plugin g_id and g_scope name, 0 none
find_installed:
    PROLOGUE
    mov rbx, rdi
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
    lea rsi, [rip + .Lk_id]
    call c2_jstr
    mov rdi, rax
    mov rsi, rdx
    mov rdx, [rip + g_id]
    test rdx, rdx
    jz 8f
    call str_eq_cstr
    test eax, eax
    jz 1b
    mov rdx, [rip + g_scope]
    test rdx, rdx
    jz 7f
    mov rdi, r13
    lea rsi, [rip + .Lk_scope]
    call c2_jstr
    mov rdi, rax
    mov rsi, rdx
    mov rdx, [rip + g_scope]
    call str_eq_cstr
    test eax, eax
    jz 1b
7:  mov rax, r13
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# avail_order(rbx: c2_doc3 parsed) -> eax how many: order = the indexes by installCount, the most first (a
#   stable insertion sort; ORDER_MAX at most)
avail_order:
    PROLOGUE 16
    mov rdi, rbx
    call json_len
    mov r12d, eax
    cmp r12d, ORDER_MAX
    jbe 1f
    mov r12d, ORDER_MAX
1:  xor r13d, r13d
2:  cmp r13d, r12d
    jae 9f
    mov rdi, rbx                # its count
    mov esi, r13d
    call json_at
    mov rdi, rax
    lea rsi, [rip + .Lk_installCount]
    call json_get
    mov rdi, rax
    call json_int
    mov r14, rax
    lea rcx, [rip + counts]
    mov [rcx + r13*8], rax
    mov r15d, r13d              # into place among the ones before
3:  test r15d, r15d
    jz 4f
    lea rax, [rip + order]
    mov ecx, [rax + r15*4 - 4]
    lea rdx, [rip + counts]
    cmp [rdx + rcx*8], r14
    jge 4f
    mov [rax + r15*4], ecx
    dec r15d
    jmp 3b
4:  lea rax, [rip + order]
    mov [rax + r15*4], r13d
    inc r13d
    jmp 2b
9:  mov eax, r12d
    EPILOGUE

# installed_ids(): inst_ids = the installed plugins' ids, each with a NUL after it (c2_doc parsed for it)
installed_ids:
    PROLOGUE
    lea rdi, [rip + inst_ids]
    call sb_clear
    lea rdi, [rip + c2_doc]
    call c2_parse
    mov rbx, rax
    xor r12d, r12d
1:  mov rdi, rbx
    call json_len
    cmp r12d, eax
    jae 9f
    mov rdi, rbx
    mov esi, r12d
    call json_at
    inc r12d
    mov rdi, rax
    lea rsi, [rip + .Lk_id]
    call c2_jstr
    test rdx, rdx
    jz 1b
    lea rdi, [rip + inst_ids]
    mov rsi, rax
    call sb_push
    lea rdi, [rip + inst_ids]
    xor esi, esi
    call sb_push_byte
    jmp 1b
9:  EPILOGUE

# is_installed(available entry) -> eax 1 when its pluginId is one of inst_ids (installed_ids; nothing parsed)
is_installed:
    PROLOGUE
    lea rsi, [rip + .Lk_pluginId]
    call c2_jstr
    test rdx, rdx
    jz 8f
    mov r12, rax                # its id
    mov r13, rdx
    mov rbx, [rip + inst_ids + SB_ptr]
    mov r14, [rip + inst_ids + SB_len]
    add r14, rbx                # the end
1:  cmp rbx, r14
    jae 8f
    mov rdi, rbx
    call strlen
    mov r15, rax
    cmp rax, r13
    jne 2f
    mov rdi, r12
    mov rsi, r13
    mov rdx, rbx
    call str_eq_cstr
    test eax, eax
    jnz 9f
2:  lea rbx, [rbx + r15 + 1]
    jmp 1b
8:  xor eax, eax
9:  EPILOGUE

# link_install(): a link's plugin, its marketplace added: its install page (found among the available), else
#   why not
link_install:
    PROLOGUE
    lea rdi, [rip + c2_doc3]
    call c2_parse
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
    lea rsi, [rip + .Lk_name]
    call c2_jstr
    mov rdi, rax
    mov rsi, rdx
    mov rdx, [rip + g_link_plugin]
    test rdx, rdx
    jz 8f
    call str_eq_cstr
    test eax, eax
    jz 1b
    mov rdx, [rip + g_link_mkt]
    test rdx, rdx
    jz 2f
    mov rdi, r13
    lea rsi, [rip + .Lk_marketplaceName]
    call c2_jstr
    mov rdi, rax
    mov rsi, rdx
    mov rdx, [rip + g_link_mkt]
    call str_eq_cstr
    test eax, eax
    jz 1b
2:  lea edi, [r12 - 1]          # found: its install page
    call open_install
    EPILOGUE
8:  lea rdi, [rip + .Lg_link_none]
    call c2_err_cset
    mov qword ptr [rip + c2_page], PG_LIST
    EPILOGUE

# open_install(index): the available plugin's install page
open_install:
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rip + c2_doc3]
    call c2_parse
    mov rdi, rax
    mov esi, ebx
    call json_at
    test rax, rax
    jz 9f
    mov r12, rax
    mov rdi, rax
    lea rsi, [rip + .Lk_pluginId]
    call c2_jstr
    test rdx, rdx
    jz 9f
    mov rdi, rax
    mov rsi, rdx
    lea rax, [rip + g_id]
    call set_q
    call f_clr
    mov rdi, r12
    lea rsi, [rip + .Lk_name]
    mov edx, NAME_MAX
    call c2_jcl
    mov rdi, rax
    mov rsi, rdx
    call f_n
    call f_get
    mov rdi, rax
    mov rsi, rdx
    lea rax, [rip + g_label]
    call set_q
    call c2_notes_clear
    mov qword ptr [rip + c2_page], PG_INSTALL
    xor edi, edi
    call agentdlg_x_filter
    xor edi, edi
    call agentdlg_focus
9:  EPILOGUE

# plg_act(act, arg, DGR*)
plg_act:
    PROLOGUE
    mov r12d, edi
    mov r13, rsi
    cmp r12d, GA_SOURCE
    je .Lga_source
    cmp r12d, GA_RESTART
    je .Lga_restart
    cmp r12d, GA_RELOAD
    je .Lga_reload
    cmp qword ptr [rip + c2_busy], 0
    jne 9f
    cmp r12d, GA_TAB
    je .Lga_tab
    cmp r12d, GA_PLUGIN
    je .Lga_plugin
    cmp r12d, GA_AVAIL
    je .Lga_avail
    cmp r12d, GA_BACK
    je .Lga_back
    cmp r12d, GA_RETRY
    je .Lga_retry
    cmp r12d, GA_CHOICE         # (a choice starts no run)
    je .Lga_choice
    call c2_running             # a list still being read: the act waits for it (g_defer)
    test eax, eax
    jz 10f
    mov [rip + g_defer], r12
    mov [rip + g_defer_arg], r13
    jmp 9f
10: mov [rip + c2_busy_act], r12
    cmp r12d, GA_TOGGLE
    je .Lga_toggle
    cmp r12d, GA_OPTIONS
    je .Lga_options
    cmp r12d, GA_UPDATE
    je .Lga_update
    cmp r12d, GA_UNINSTALL
    je .Lga_uninstall
    cmp r12d, GA_KEEP
    je .Lga_keep
    cmp r12d, GA_DELETE
    je .Lga_delete
    cmp r12d, GA_SCOPE
    je .Lga_scope
    cmp r12d, GA_SAVEOPTS
    je .Lga_saveopts
    cmp r12d, GA_CHOICE
    je .Lga_choice
    cmp r12d, GA_MKTADD
    je .Lga_mktadd
    cmp r12d, GA_MKT
    je .Lga_mkt
    cmp r12d, GA_REFRESH
    je .Lga_refresh
    cmp r12d, GA_MKTREMOVE
    je .Lga_mktremove
    cmp r12d, GA_MKTCONFIRM
    je .Lga_mktconfirm
    cmp r12d, GA_TRUST
    je .Lga_trust
    jmp 9f
.Lga_source:
    lea rdi, [rip + c2_doc2]
    call c2_parse
    mov rdi, rax
    mov rsi, r13
    call json_at
    test rax, rax
    jz 9f
    mov rdi, rax
    call source_url
    test eax, eax
    jz 9f
    lea rdi, [rip + fsb]        # (a NUL after it for links_ask_open)
    xor esi, esi
    call sb_push_byte
    lea rdi, [rip + .Lwho]
    mov rsi, [rip + fsb + SB_ptr]
    call links_ask_open
    jmp 9f
.Lga_reload:
    mov qword ptr [rip + g_reload_failed], 2
    call reload
    jmp 8f
.Lga_restart:
    mov qword ptr [rip + g_restart], 0  # the process ends; the next message starts it with the plugins
    mov qword ptr [rip + g_reload_failed], 0
    mov rdi, [rip + c2_as]
    test rdi, rdi
    jz 8f
    call agent_release
    jmp 8f
.Lga_tab:
    mov qword ptr [rip + g_defer], 0    # another page: an act that waited for a list is not for it
    mov [rip + g_tab], r13
    call c2_notes_clear
    xor edi, edi
    call agentdlg_x_filter
    xor edi, edi
    call agentdlg_focus
    jmp 8f
.Lga_plugin:
    mov qword ptr [rip + g_defer], 0
    lea rdi, [rip + c2_doc]     # its id and scope kept: the list may change under the page
    call c2_parse
    mov rdi, rax
    mov rsi, r13
    call json_at
    test rax, rax
    jz 9f
    mov rbx, rax
    call keep_plugin
    call c2_notes_clear
    mov qword ptr [rip + c2_page], PG_PLUGIN
    xor edi, edi
    call agentdlg_x_filter
    xor edi, edi
    call agentdlg_focus
    jmp 8f
.Lga_avail:
    mov qword ptr [rip + g_defer], 0
    mov rdi, r13
    call open_install
    jmp 8f
.Lga_back:
    mov qword ptr [rip + g_defer], 0
    call c2_notes_clear
    mov rax, [rip + c2_page]
    cmp rax, PG_UNINSTALL
    je 1f
    cmp rax, PG_MKTREMOVE
    je 2f
    cmp rax, PG_OPTIONS
    jne 3f
    call opts_clear
    jmp 3f
1:  mov qword ptr [rip + c2_page], PG_PLUGIN
    jmp 8f
2:  mov qword ptr [rip + c2_page], PG_MKT
    jmp 8f
3:  mov qword ptr [rip + c2_page], PG_LIST
    jmp 8f
.Lga_retry:
    mov qword ptr [rip + g_defer], 0
    lea rdi, [rip + .Lg_loading]
    call agentdlg_loading
    mov edi, GW_LIST
    call run_list
    jmp 9f
.Lga_toggle:
    lea rdi, [rip + c2_doc]     # enable or disable (no scope: the CLI picks the installation)
    call c2_parse
    mov rdi, rax
    call find_installed
    test rax, rax
    jz 9f
    mov rdi, rax
    lea rsi, [rip + .Lk_enabled]
    call json_get
    mov rdi, rax
    call json_type
    mov qword ptr [rip + g_turn_on], 0
    lea rdi, [rip + .La_disable]
    cmp eax, JT_FALSE
    jne 1f
    lea rdi, [rip + .La_enable]
    mov qword ptr [rip + g_turn_on], 1
1:  xor esi, esi
    xor edx, edx
    mov rcx, [rip + g_id]
    call change
    jmp 8f
.Lga_options:
    call c2_args                # configure --json: its options
    lea rdi, [rip + .La_plugin]
    call c2_arg_c
    lea rdi, [rip + .La_configure]
    call c2_arg_c
    lea rdi, [rip + .La_json]
    call c2_arg_c
    lea rdi, [rip + .La_dashes]
    call c2_arg_c
    mov rdi, [rip + g_id]
    call c2_arg_c
    lea rdi, [rip + c2_in]
    call sb_clear
    call c2_notes_clear
    mov edi, GW_OPTS
    call c2_run
    test eax, eax
    jz 9f
    mov qword ptr [rip + c2_busy], 1
    jmp 8f
.Lga_update:
    lea rdi, [rip + .La_update]
    mov rsi, [rip + g_scope]
    xor edx, edx
    mov rcx, [rip + g_id]
    call change
    jmp 8f
.Lga_uninstall:
    call c2_notes_clear
    mov qword ptr [rip + c2_page], PG_UNINSTALL
    mov edi, 1000               # the focus on Cancel
    call agentdlg_focus
    jmp 8f
.Lga_keep:
    lea rdi, [rip + .La_uninstall]
    mov rsi, [rip + g_scope]
    lea rdx, [rip + .La_keep_data]
    mov rcx, [rip + g_id]
    call change
    jmp 8f
.Lga_delete:
    lea rdi, [rip + .La_uninstall]
    mov rsi, [rip + g_scope]
    xor edx, edx
    mov rcx, [rip + g_id]
    call change
    jmp 8f
.Lga_scope:
    cmp r13, 3
    jae 9f
    lea rax, [rip + install_ids]
    mov rsi, [rax + r13*8]
    mov rax, [rip + c2_busy_act]
    lea rdi, [rip + .La_install]
    xor edx, edx
    mov rcx, [rip + g_id]
    call change
    jmp 8f
.Lga_saveopts:
    call opts_save
    jmp 8f
.Lga_choice:
    mov rax, r13
    shr rax, 8
    cmp rax, OPTS_MAX
    jae 9f
    mov rcx, r13
    and ecx, 0xff
    lea rdx, [rip + o_choice]
    mov [rdx + rax*8], rcx
    jmp 8f
.Lga_mktadd:
    lea rdi, [rip + g_tf_mkt]   # `plugin marketplace add --json -- SOURCE` (typed by the user)
    call c2_tf_text
    test rdx, rdx
    jz 9f
    cmp rdx, 2000
    ja 9f
    mov rbx, rax
    mov r14, rdx
    call c2_args
    lea rdi, [rip + .La_plugin]
    call c2_arg_c
    lea rdi, [rip + .La_marketplace]
    call c2_arg_c
    lea rdi, [rip + .La_add]
    call c2_arg_c
    lea rdi, [rip + .La_json]
    call c2_arg_c
    lea rdi, [rip + .La_dashes]
    call c2_arg_c
    mov rdi, rbx
    mov rsi, r14
    call c2_arg_n
    mov rdi, rbx
    mov rsi, r14
    lea rax, [rip + g_label]
    call set_q
    call go_change
    jmp 8f
.Lga_mkt:
    mov [rip + c2_arg], r13
    lea rdi, [rip + c2_doc2]
    call c2_parse
    mov rdi, rax
    mov rsi, r13
    call json_at
    test rax, rax
    jz 9f
    mov rdi, rax
    lea rsi, [rip + .Lk_name]
    call c2_jstr
    mov rdi, rax
    mov rsi, rdx
    lea rax, [rip + g_id]
    call set_q
    call f_clr
    mov rdi, [rip + g_id]
    call strlen
    mov rsi, rax
    mov rdi, [rip + g_id]
    mov edx, NAME_MAX
    call f_cl
    call f_get
    mov rdi, rax
    mov rsi, rdx
    lea rax, [rip + g_label]
    call set_q
    call c2_notes_clear
    mov qword ptr [rip + c2_page], PG_MKT
    xor edi, edi
    call agentdlg_focus
    jmp 8f
.Lga_refresh:
    lea rdi, [rip + .La_update]
    mov rsi, [rip + g_id]
    call mkt_change
    jmp 8f
.Lga_mktremove:
    call c2_notes_clear
    mov qword ptr [rip + c2_page], PG_MKTREMOVE
    mov edi, 1000
    call agentdlg_focus
    jmp 8f
.Lga_mktconfirm:
    lea rdi, [rip + .La_remove]
    mov rsi, [rip + g_id]
    call mkt_change
    jmp 8f
.Lga_trust:
    call c2_args                # 4.19: `plugin marketplace add --from-link -- SOURCE`
    lea rdi, [rip + .La_plugin]
    call c2_arg_c
    lea rdi, [rip + .La_marketplace]
    call c2_arg_c
    lea rdi, [rip + .La_add]
    call c2_arg_c
    lea rdi, [rip + .La_from_link]
    call c2_arg_c
    lea rdi, [rip + .La_dashes]
    call c2_arg_c
    mov rdi, [rip + g_link_source]
    call c2_arg_c
    lea rdi, [rip + c2_in]
    call sb_clear
    call c2_notes_clear
    mov edi, GW_LINKADD
    call c2_run
    test eax, eax
    jz 9f
    mov qword ptr [rip + c2_busy], 1
8:  call plg_build
9:  EPILOGUE

# keep_plugin(rbx: an installed plugin): g_id, g_scope, g_label its
keep_plugin:
    PROLOGUE
    mov rdi, rbx
    lea rsi, [rip + .Lk_id]
    call c2_jstr
    mov rdi, rax
    mov rsi, rdx
    lea rax, [rip + g_id]
    call set_q
    mov rdi, rbx
    lea rsi, [rip + .Lk_scope]
    call c2_jstr
    test rdx, rdx
    jz 1f
    mov rdi, rax
    mov rsi, rdx
    lea rax, [rip + g_scope]
    call set_q
    jmp 2f
1:  lea rax, [rip + g_scope]
    call free_q
2:  call f_clr
    mov rdi, [rip + g_id]
    call strlen
    mov rsi, rax
    mov rdi, [rip + g_id]
    call name_f
    call f_get
    mov rdi, rax
    mov rsi, rdx
    lea rax, [rip + g_label]
    call set_q
    EPILOGUE

# ---- the options form (6.6) ----

# opts_clear(): the form emptied (its fields wiped: an option may be a secret)
opts_clear:
    PROLOGUE
    xor ebx, ebx
1:  cmp ebx, OPTS_MAX
    jae 2f
    imul rdi, rbx, TF_SIZE
    lea rax, [rip + o_tfs]
    add rdi, rax
    call c2_wipe_tf
    imul rdi, rbx, SB_SIZE
    lea rax, [rip + o_init]
    add rdi, rax
    call sb_clear
    lea rax, [rip + o_keys]
    lea rax, [rax + rbx*8]
    call free_q
    lea rax, [rip + o_err]
    lea rax, [rax + rbx*8]
    call free_q
    inc ebx
    jmp 1b
2:  mov qword ptr [rip + o_n], 0
    lea rdi, [rip + o_doc]
    call sb_clear
    EPILOGUE

# opts_fill(): the form from configure --json's answer (o_doc): every key of its schema (the extension's
#   "all"), its value, whether it must be given, its choices
opts_fill:
    PROLOGUE 16
    call opts_clear_keep
    lea rdi, [rip + o_doc]
    call c2_parse
    mov rbx, rax
    mov rdi, rax
    lea rsi, [rip + .Lk_schema]
    call json_get
    mov r12, rax
    xor r13d, r13d
1:  mov rdi, r12
    call json_npairs
    cmp r13d, eax
    jae 9f
    cmp r13d, OPTS_MAX
    jae 9f
    mov rdi, r12
    mov esi, r13d
    call json_pair
    mov r14, rdx                # its schema
    mov rdi, rax
    call json_str
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    lea rcx, [rip + o_keys]
    mov [rcx + r13*8], rax
    mov r15, rax                # the key
    mov rdi, rbx                # its value (inputs)
    lea rsi, [rip + .Lk_inputs]
    call json_get
    mov rdi, rax
    mov rsi, r15
    call json_get
    mov rdi, rax
    call json_str
    mov [rsp], rax
    mov [rsp + 8], rdx
    imul rdi, r13, TF_SIZE
    lea rcx, [rip + o_tfs]
    add rdi, rcx
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    call tf_set
    imul rdi, r13, SB_SIZE
    lea rcx, [rip + o_init]
    add rdi, rcx
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    call sb_push
    mov rdi, r14                # required, unless stored already (configured, no choices, empty)
    lea rsi, [rip + .Lk_required]
    call c2_jbool
    mov ecx, eax
    lea rdx, [rip + o_req]
    mov [rdx + r13*8], rcx
    mov qword ptr [rip + tmp_n], -1     # its choices: the value's index
    mov rdi, rbx
    lea rsi, [rip + .Lk_choices]
    call json_get
    mov rdi, rax
    mov rsi, r15
    call json_get
    test rax, rax
    jz 3f
    mov r14, rax
    mov rdi, rax
    call json_len
    lea rcx, [rip + o_nchoice]
    mov [rcx + r13*8], rax
    xor ecx, ecx
    mov [rip + tmp_n], rcx
2:  mov rax, [rip + tmp_n]
    mov rdi, r14
    push rax
    push rax
    call json_len
    pop rcx
    pop rcx
    cmp ecx, eax
    jae 21f
    mov rdi, r14
    mov esi, ecx
    call json_at
    mov rdi, rax
    call json_str
    cmp rdx, [rsp + 8]
    jne 22f
    mov rdi, rax
    mov rsi, [rsp]
    mov rcx, rdx
    xor edx, edx
23: cmp rdx, rcx
    jae 24f
    movzx r8d, byte ptr [rdi + rdx]
    cmp r8b, [rsi + rdx]
    jne 22f
    inc rdx
    jmp 23b
24: mov rax, [rip + tmp_n]
    lea rcx, [rip + o_choice]
    mov [rcx + r13*8], rax
    jmp 25f
22: inc qword ptr [rip + tmp_n]
    jmp 2b
21: lea rcx, [rip + o_choice]
    mov qword ptr [rcx + r13*8], 0
25: jmp 4f
3:  lea rcx, [rip + o_choice]
    mov qword ptr [rcx + r13*8], -1
    lea rcx, [rip + o_nchoice]
    mov qword ptr [rcx + r13*8], 0
    mov rdi, rbx                # stored and empty: not required ("(unchanged)")
    mov rsi, r15
    call stored_empty
    test eax, eax
    jz 4f
    lea rcx, [rip + o_req]
    mov qword ptr [rcx + r13*8], 0
4:  inc r13d
    mov [rip + o_n], r13
    jmp 1b
9:  EPILOGUE

# opts_clear_keep(): the form's fields emptied, its answer (o_doc) kept
opts_clear_keep:
    PROLOGUE
    lea rdi, [rip + tmp_doc]
    call sb_clear
    lea rdi, [rip + tmp_doc]
    mov rsi, [rip + o_doc + SB_ptr]
    mov rdx, [rip + o_doc + SB_len]
    call sb_push
    call opts_clear
    lea rdi, [rip + o_doc]
    mov rsi, [rip + tmp_doc + SB_ptr]
    mov rdx, [rip + tmp_doc + SB_len]
    call sb_push
    lea rdi, [rip + tmp_doc]
    call sb_clear
    EPILOGUE

# stored_empty(answer, key cstr) -> eax 1 when the key is configured, has no choices and no value shown (E)
stored_empty:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea rsi, [rip + .Lk_inputs]
    call json_get
    mov rdi, rax
    mov rsi, r12
    call json_get
    mov rdi, rax
    call json_str
    test rdx, rdx
    jnz 8f
    mov rdi, rbx
    lea rsi, [rip + .Lk_configured]
    call json_get
    mov r13, rax
    xor r14d, r14d
1:  mov rdi, r13
    call json_len
    cmp r14d, eax
    jae 8f
    mov rdi, r13
    mov esi, r14d
    call json_at
    inc r14d
    mov rdi, rax
    mov rsi, r12
    call json_is
    test eax, eax
    jz 1b
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# opt_index(ptr, len) -> rax the option of that key, -1 none
opt_index:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    xor r13d, r13d
1:  cmp r13, [rip + o_n]
    jae 8f
    lea rax, [rip + o_keys]
    mov rdx, [rax + r13*8]
    mov rdi, rbx
    mov rsi, r12
    call str_eq_cstr
    test eax, eax
    jnz 2f
    inc r13
    jmp 1b
2:  mov rax, r13
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

# opts_rows(): "Configure NAME", a field (or a choice) an option: its title (* when required), its
#   description or its error; "Save configuration"
opts_rows:
    PROLOGUE 32
    mov edi, GA_BACK
    call agentdlg_back
    call f_clr
    lea rdi, [rip + .Lg_configure_t]
    call f_c
    mov rdi, [rip + g_label]
    call f_c
    mov edi, DGK_HEAD
    xor esi, esi
    xor edx, edx
    call c2_frow
    call c2_msgs
    lea rdi, [rip + o_doc]
    call c2_parse
    mov rbx, rax
    mov rdi, rax
    lea rsi, [rip + .Lk_schema]
    call json_get
    mov r12, rax
    xor r13d, r13d
1:  cmp r13, [rip + o_n]
    jae 8f
    lea rax, [rip + o_keys]     # its schema
    mov rsi, [rax + r13*8]
    mov rdi, r12
    call json_get
    mov r14, rax
    call f_clr                  # its title (* required)
    mov rdi, r14
    lea rsi, [rip + .Lk_title]
    call c2_jstr
    test rdx, rdx
    jnz 2f
    lea rax, [rip + o_keys]
    mov rdi, [rax + r13*8]
    push rdi
    push rdi
    call strlen
    mov rdx, rax
    pop rax
    pop rax
2:  mov rdi, rax
    mov rsi, rdx
    mov edx, NAME_MAX
    call f_cl
    lea rax, [rip + o_req]
    cmp qword ptr [rax + r13*8], 0
    je 3f
    lea rdi, [rip + .Lg_star]
    call f_c
3:  lea rax, [rip + o_choice]
    cmp qword ptr [rax + r13*8], -1
    je 5f
    xor edi, edi                # a choice: its title, its values as options
    call c2_ftext
    mov rdi, rbx
    lea rsi, [rip + .Lk_choices]
    call json_get
    lea rcx, [rip + o_keys]
    mov rsi, [rcx + r13*8]
    mov rdi, rax
    call json_get
    mov r15, rax
    xor ecx, ecx
    mov [rsp], ecx
4:  mov ecx, [rsp]
    cmp ecx, CHOICES_MAX
    jae 7f
    mov rdi, r15
    call json_len
    cmp [rsp], eax
    jae 7f
    mov rdi, r15
    mov esi, [rsp]
    call json_at
    mov rdi, rax
    call json_str
    mov rdi, rax
    mov rsi, rdx
    mov edx, NAME_MAX
    call c2_clean
    mov [rsp + 8], rax
    mov [rsp + 16], rdx
    xor esi, esi
    lea rax, [rip + o_choice]
    mov ecx, [rsp]
    cmp [rax + r13*8], rcx
    jne 41f
    mov esi, DGF_ON
41: mov edi, DGK_OPTION
    mov edx, GA_CHOICE
    call agentdlg_row
    mov rcx, r13
    shl rcx, 8
    or ecx, [rsp]
    mov [rax + DGR_arg], rcx
    mov rdi, rax
    xor esi, esi
    mov rdx, [rsp + 8]
    mov rcx, [rsp + 16]
    call agentdlg_text
    inc dword ptr [rsp]
    jmp 4b
5:  mov edi, DGK_FIELD          # a field: secret when the schema says sensitive
    xor esi, esi
    mov rdi, r14
    lea rsi, [rip + .Lk_sensitive]
    call c2_jbool
    xor esi, esi
    test eax, eax
    jz 51f
    mov esi, DGF_SECRET
51: lea rax, [rip + o_err]
    cmp qword ptr [rax + r13*8], 0
    je 52f
    or esi, DGF_ERROR
52: mov edi, DGK_FIELD
    mov edx, GA_SAVEOPTS
    call agentdlg_row
    mov [rsp + 8], rax
    imul rcx, r13, TF_SIZE
    lea rdx, [rip + o_tfs]
    add rcx, rdx
    mov [rax + DGR_val], rcx
    mov rdi, rax
    xor esi, esi
    call c2_fset
    mov rdi, rbx                # "(unchanged)" when stored and empty
    lea rcx, [rip + o_keys]
    mov rsi, [rcx + r13*8]
    call stored_empty
    test eax, eax
    jz 53f
    mov rdi, [rsp + 8]
    mov esi, 1
    lea rdx, [rip + .Lg_unchanged]
    call agentdlg_ctext
53: lea rax, [rip + o_err]      # its error, else its description
    mov rdx, [rax + r13*8]
    test rdx, rdx
    jz 54f
    mov rdi, [rsp + 8]
    mov esi, 2
    call agentdlg_ctext
    jmp 7f
54: mov rdi, r14
    lea rsi, [rip + .Lk_description]
    mov edx, 800
    call c2_jcl
    test rdx, rdx
    jz 7f
    mov rdi, [rsp + 8]
    mov esi, 2
    mov rcx, rdx
    mov rdx, rax
    call agentdlg_text
7:  inc r13
    jmp 1b
8:  lea rdi, [rip + .Lg_save_config]
    cmp qword ptr [rip + c2_busy], 0
    je 81f
    lea rdi, [rip + .Lg_saving]
81: mov esi, GA_SAVEOPTS
    mov edx, DBF_PRIMARY
    call agentdlg_button
    EPILOGUE

# opts_save(): the options changed (and the choices of the ones not set yet) as JSON on stdin of `plugin
#   configure --json --values-stdin -- ID`; a required one empty: its error, nothing written
opts_save:
    PROLOGUE 16
    call c2_notes_clear
    xor ebx, ebx                # the required ones first
1:  cmp rbx, [rip + o_n]
    jae 3f
    lea rax, [rip + o_err]
    lea rax, [rax + rbx*8]
    call free_q
    lea rax, [rip + o_choice]
    cmp qword ptr [rax + rbx*8], -1
    jne 2f
    lea rax, [rip + o_req]
    cmp qword ptr [rax + rbx*8], 0
    je 2f
    imul rdi, rbx, TF_SIZE
    lea rax, [rip + o_tfs]
    add rdi, rax
    call c2_tf_text
    test rdx, rdx
    jnz 2f
    lea rdi, [rip + .Lg_required_opt]
    call c2_err_cset
    EPILOGUE
2:  inc rbx
    jmp 1b
3:  lea rdi, [rip + o_doc]      # (the choices' values read from the answer as it was)
    call c2_parse
    mov r14, rax
    lea rdi, [rip + c2_in]
    call jw_begin
    lea rdi, [rip + c2_in]
    call jw_obj
    xor ebx, ebx
4:  cmp rbx, [rip + o_n]
    jae 8f
    lea rax, [rip + o_choice]
    mov rcx, [rax + rbx*8]
    cmp rcx, -1
    je 6f
    mov rdi, r14                # a choice: its value
    lea rsi, [rip + .Lk_choices]
    call json_get
    lea rcx, [rip + o_keys]
    mov rsi, [rcx + rbx*8]
    mov rdi, rax
    call json_get
    lea rcx, [rip + o_choice]
    mov rsi, [rcx + rbx*8]
    mov rdi, rax
    call json_at
    mov rdi, rax
    call json_str
    mov [rsp], rax
    mov [rsp + 8], rdx
    imul rcx, rbx, SB_SIZE      # (none set before: written)
    lea rax, [rip + o_init]
    cmp qword ptr [rax + rcx + SB_len], 0
    je 61f
    jmp 60f
6:  imul rdi, rbx, TF_SIZE      # a field: only when it changed
    lea rax, [rip + o_tfs]
    add rdi, rax
    call tf_text
    mov [rsp], rax
    mov [rsp + 8], rdx
60: imul rcx, rbx, SB_SIZE      # only when it changed
    lea rax, [rip + o_init]
    add rcx, rax
    mov rdx, [rsp + 8]
    cmp rdx, [rcx + SB_len]
    jne 61f
    mov rdi, [rsp]
    mov rsi, [rcx + SB_ptr]
    xor eax, eax
62: cmp rax, rdx
    jae 7f                      # the same: left out
    movzx r8d, byte ptr [rdi + rax]
    cmp r8b, [rsi + rax]
    jne 61f
    inc rax
    jmp 62b
61: lea rcx, [rip + o_keys]
    mov rsi, [rcx + rbx*8]
    lea rdi, [rip + c2_in]
    call jw_key
    lea rdi, [rip + c2_in]
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    call jw_str
7:  inc rbx
    jmp 4b
8:  lea rdi, [rip + c2_in]
    call jw_end_obj
    call c2_args
    lea rdi, [rip + .La_plugin]
    call c2_arg_c
    lea rdi, [rip + .La_configure]
    call c2_arg_c
    lea rdi, [rip + .La_json]
    call c2_arg_c
    lea rdi, [rip + .La_values_stdin]
    call c2_arg_c
    lea rdi, [rip + .La_dashes]
    call c2_arg_c
    mov rdi, [rip + g_id]
    call c2_arg_c
    mov edi, GW_SAVEOPTS
    call c2_run
    test eax, eax
    jz 9f
    mov qword ptr [rip + c2_busy], 1
9:  EPILOGUE

# FN claude_dlg2_install_link(AS*, plugin cstr, source cstr) -> eax 1: Manage Plugins on a link's plugin
#   (4.19): the plugin's name must be plain (letters, digits, ".", "_", "-", 100 at most) and the source
#   short and without control characters or "%"; its marketplace is looked up first
FN claude_dlg2_install_link
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    xor eax, eax
    test rbx, rbx
    jz 9f
    mov rdi, r12
    call plain_name
    test eax, eax
    jz 9f
    mov rdi, r13
    call plain_source
    test eax, eax
    jz 9f
    mov rdi, rbx
    call agent_live
    test rax, rax
    jz 8f
    mov rdi, rax
    mov esi, ACT_PLUGINS
    xor edx, edx
    xor ecx, ecx
    call claude_dlg2_open
    test eax, eax
    jz 8f
    mov rdi, r12
    call strlen
    mov rsi, rax
    mov rdi, r12
    lea rax, [rip + g_link_plugin]
    call set_q
    mov rdi, r13
    call strlen
    mov rsi, rax
    mov rdi, r13
    lea rax, [rip + g_link_source]
    call set_q
    call c2_running             # (the list's run that opening started is let go: its answer is the
    test eax, eax               #   dialog's still; the resolve goes once it ends)
    jz 1f
    mov qword ptr [rip + g_after], 2
    mov eax, 1
    EPILOGUE
1:  call resolve_link
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
9:  EPILOGUE

# FN c2_c_link(out, rest, len) -> rax 0 or -1: agent-plugin-link PLUGIN SOURCE: Manage Plugins on a link's
#   plugin for the box's conversation (a draft becomes one), as the rhun://claude/install-plugin link will
FN c2_c_link
    PROLOGUE 16
    mov rbx, rsi
    mov r12, rdx
    xor ecx, ecx
1:  cmp rcx, r12
    jae 8f
    cmp byte ptr [rbx + rcx], ' '
    je 2f
    inc rcx
    jmp 1b
2:  mov [rsp], rcx
    mov rdi, rbx
    mov rsi, rcx
    call mem_dup
    mov r13, rax                # PLUGIN
    mov rcx, [rsp]
    lea rdi, [rbx + rcx + 1]
    mov rsi, r12
    sub rsi, rcx
    dec rsi
    call c2_trim
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov r14, rax                # SOURCE
    call agentext_box_owner
    test rax, rax
    jnz 3f
    call agentext_draft_own
3:  mov rdi, rax
    mov rsi, r13
    mov rdx, r14
    call claude_dlg2_install_link
    mov r15d, eax
    mov rdi, r13
    call mem_free
    mov rdi, r14
    call mem_free
    xor eax, eax
    test r15d, r15d
    jnz 9f
8:  mov rax, -1
9:  EPILOGUE

# FN claude_plugin_link(AL* or 0, act, "PLUGIN\0SOURCE\0" or "PLUGIN\0", len) -> eax 1: DRV_action's
#   ACT_PLUGIN_LINK (row 4.19, a rhun://claude/install-plugin link, agenttab.s): no SOURCE is the official
#   marketplace (the extension's default); the extension's checks (Mrt @3525150) with its words as a toast, then
#   Manage Plugins on the plugin for the box's conversation (a draft becomes one), as agent-plugin-link
FN claude_plugin_link
    PROLOGUE
    mov rbx, rdx
    mov r12, rcx
    mov rdi, rbx                # PLUGIN, SOURCE: NUL-ended strings filling the bytes
    call strlen
    lea r13, [rbx + rax + 1]    # SOURCE
    lea rcx, [rax + 1]
    cmp rcx, r12
    ja 7f
    jb 0f
    lea r13, [rip + .Lpl_official]  # the link named no marketplace
    jmp 1f
0:  mov rdi, r13
    call strlen
    lea rcx, [r13 + rax + 1]
    sub rcx, rbx
    cmp rcx, r12
    jne 7f
1:  mov rdi, rbx
    call plain_name
    test eax, eax
    jz 7f
    mov rdi, r13
    call plain_source
    test eax, eax
    jz 8f
    call agentext_box_owner
    test rax, rax
    jnz 2f
    call agentext_draft_own
2:  mov rdi, rax
    mov rsi, rbx
    mov rdx, r13
    call claude_dlg2_install_link
    mov eax, 1
    EPILOGUE
7:  lea rdi, [rip + .Lpl_bad_plugin]
    call app_toast
    mov eax, 1
    EPILOGUE
8:  lea rdi, [rip + .Lpl_bad_market]
    call app_toast
    mov eax, 1
    EPILOGUE

# resolve_link(): `plugin marketplace add --from-link --resolve-only -- SOURCE`
resolve_link:
    PROLOGUE
    lea rdi, [rip + .Lg_loading_avail]
    call agentdlg_loading
    call c2_args
    lea rdi, [rip + .La_plugin]
    call c2_arg_c
    lea rdi, [rip + .La_marketplace]
    call c2_arg_c
    lea rdi, [rip + .La_add]
    call c2_arg_c
    lea rdi, [rip + .La_from_link]
    call c2_arg_c
    lea rdi, [rip + .La_resolve]
    call c2_arg_c
    lea rdi, [rip + .La_dashes]
    call c2_arg_c
    mov rdi, [rip + g_link_source]
    call c2_arg_c
    lea rdi, [rip + c2_in]
    call sb_clear
    mov edi, GW_RESOLVE
    call c2_run
    EPILOGUE

# plain_name(cstr) -> eax 1 for [A-Za-z0-9][A-Za-z0-9._-]{0,99}
plain_name:
    xor ecx, ecx
1:  movzx eax, byte ptr [rdi + rcx]
    test eax, eax
    jz 3f
    cmp ecx, 100
    jae 8f
    lea edx, [rax - '0']
    cmp edx, 9
    jbe 2f
    mov edx, eax
    or edx, 0x20
    sub edx, 'a'
    cmp edx, 25
    jbe 2f
    test ecx, ecx
    jz 8f
    cmp eax, '.'
    je 2f
    cmp eax, '_'
    je 2f
    cmp eax, '-'
    jne 8f
2:  inc ecx
    jmp 1b
3:  xor eax, eax
    test ecx, ecx
    setnz al
    ret
8:  xor eax, eax
    ret

# plain_source(cstr) -> eax 1 for 1 to 256 bytes with no control character and no "%"
plain_source:
    xor ecx, ecx
1:  movzx eax, byte ptr [rdi + rcx]
    test eax, eax
    jz 3f
    cmp ecx, 256
    jae 8f
    cmp eax, ' '
    jbe 8f
    cmp eax, 0x7f
    je 8f
    cmp eax, '%'
    je 8f
    inc ecx
    jmp 1b
3:  xor eax, eax
    test ecx, ecx
    setnz al
    ret
8:  xor eax, eax
    ret

.data
.p2align 3
c2_busy_act: .quad 0            # the act a change runs for (its button's words, its notice)
g_turn_on: .quad 0              # the toggle turns it on
g_defer: .quad 0                # an act that waits for the run going on (0 none), its arg
g_defer_arg: .quad 0
tmp_n: .quad 0

.bss
.p2align 3
order: .zero 4 * ORDER_MAX
inst_ids: .zero SB_SIZE         # the installed ids (installed_ids)
counts: .zero 8 * ORDER_MAX
tmp_doc: .zero SB_SIZE

.section .rodata
.globl c2_n_link
c2_n_link: .asciz "agent-plugin-link"
.Lpl_official: .asciz "anthropics/claude-plugins-official"
.Lpl_bad_plugin: .asciz "Invalid plugin installation URL. The plugin name can't be used in a link, so nothing was installed."
.Lpl_bad_market: .asciz "Invalid plugin installation URL. The marketplace can't be used in a link, so nothing was installed."
.p2align 3
scope_ids: .quad .Lv_user, .Lv_project, .Lv_local
install_ids: .quad .Lv_user, .Lv_project, .Lv_local
install_places: .quad .Lg_for_you, .Lg_for_you_d, .Lg_for_project, .Lg_for_project_d, .Lg_locally
    .quad .Lg_locally_d
local_mkts: .quad .Lv_inline, .Lv_synced, .Lv_skillsdir, .Lv_builtin, 0
source_keys: .quad .Lk_repo, .Lk_url, .Lk_path, .Lk_package, 0
done_words:                     # by act (GA_*): what the notice says was done
    .quad 0, 0, 0, 0, 0, .Lg_d_disabled, 0, .Lg_d_updated, 0, .Lg_d_uninstalled, .Lg_d_uninstalled
    .quad .Lg_d_installed, 0, 0, .Lg_d_added_mkt, 0, .Lg_d_refreshed, 0, .Lg_d_removed_mkt
doing_words:
    .quad .Lg_x_load, .Lg_x_load, .Lg_x_load, .Lg_x_load, .Lg_x_load, .Lg_x_toggle, .Lg_x_load
    .quad .Lg_x_update, .Lg_x_load, .Lg_x_uninstall, .Lg_x_uninstall, .Lg_x_install, .Lg_x_load
    .quad .Lg_x_load, .Lg_x_add_mkt, .Lg_x_load, .Lg_x_refresh, .Lg_x_load, .Lg_x_remove_mkt
fail_codes:                     # failureCode, title, message (uBt and $A's)
    .quad .Lv_dep_res, .Lg_f_deps, .Lg_f_deps_m, .Lv_dep_conflict, .Lg_f_deps, .Lg_f_deps_m
    .quad .Lv_dep_pinned, .Lg_f_deps, .Lg_f_deps_m, .Lv_plugin_policy, .Lg_f_policy, .Lg_f_admin
    .quad .Lv_mkt_policy, .Lg_f_mkt_policy, .Lg_f_admin, .Lv_dep_policy, .Lg_f_dep_policy, .Lg_f_admin
    .quad .Lv_other_mkt, .Lg_f_other_mkt, .Lg_f_other_mkt_m, .Lv_engine_range, .Lg_f_engine, .Lg_f_engine_m
    .quad .Lv_folder_held, .Lg_f_folder, .Lg_f_folder_m, .Lv_net, .Lg_f_net, .Lg_f_net_m
    .quad .Lv_dir_unavail, .Lg_f_dir, .Lg_f_dir_m, 0, 0, 0
error_words:                    # IAe (CBn): a load error's plain words
    .quad .Lv_manifest_parse, .Lg_e_json, .Lv_manifest_valid, .Lg_e_invalid, 0, 0
note_words:                     # sBt (SBn)
    .quad .Lv_agent_dep, .Lg_n_agent, .Lv_status_dep, .Lg_n_status, .Lv_synced_shadow, .Lg_n_synced
    .quad .Lv_managed_hooks, .Lg_n_managed_hooks, .Lv_managed_disabled, .Lg_n_managed_disabled
    .quad .Lv_ineffective, .Lg_n_ineffective, .Lv_version_list, .Lg_n_version_list
    .quad .Lv_engine_invalid, .Lg_n_engine_invalid, .Lv_engine_exempt, .Lg_n_engine_exempt
    .quad .Lv_wikilink, .Lg_n_wikilink, .Lv_deps_refused, .Lg_n_deps_refused
    .quad .Lv_deps_missing, .Lg_n_deps_missing, 0, 0
.Lspace: .asciz " "
.Ldot: .asciz "."
.Lopen_paren: .asciz " ("
.Lcancel: .asciz "Cancel"
.Lwho: .asciz "Claude Code"
.Lno_run: .asciz "Claude Code could not be started."
.Lk_id: .asciz "id"
.Lk_name: .asciz "name"
.Lk_scope: .asciz "scope"
.Lk_enabled: .asciz "enabled"
.Lk_errors: .asciz "errors"
.Lk_errorDetails: .asciz "errorDetails"
.Lk_notes: .asciz "notes"
.Lk_noteDetails: .asciz "noteDetails"
.Lk_type: .asciz "type"
.Lk_needsOther: .asciz "needsOtherClaudeCodeVersion"
.Lk_hasUserConfig: .asciz "hasUserConfig"
.Lk_description: .asciz "description"
.Lk_installed: .asciz "installed"
.Lk_available: .asciz "available"
.Lk_pluginId: .asciz "pluginId"
.Lk_marketplaceName: .asciz "marketplaceName"
.Lk_installCount: .asciz "installCount"
.Lk_repo: .asciz "repo"
.Lk_url: .asciz "url"
.Lk_path: .asciz "path"
.Lk_package: .asciz "package"
.Lk_failureCode: .asciz "failureCode"
.Lk_message: .asciz "message"
.Lk_refused: .asciz "refused"
.Lk_option: .asciz "option"
.Lk_saved: .asciz "saved"
.Lk_existing: .asciz "existing"
.Lk_schema: .asciz "schema"
.Lk_inputs: .asciz "inputs"
.Lk_choices: .asciz "choices"
.Lk_configured: .asciz "configured"
.Lk_required: .asciz "required"
.Lk_sensitive: .asciz "sensitive"
.Lk_title: .asciz "title"
.Lk_error_count: .asciz "error_count"
.Lv_reload: .asciz "reload_plugins"
.Lv_user: .asciz "user"
.Lv_project: .asciz "project"
.Lv_local: .asciz "local"
.Lv_inline: .asciz "inline"
.Lv_synced: .asciz "synced"
.Lv_skillsdir: .asciz "skills-dir"
.Lv_builtin: .asciz "builtin"
.Lv_engine: .asciz "engine-range-unsatisfied"
.Lv_official_repo: .asciz "anthropics/claude-plugins-official"
.Lv_dep_res: .asciz "dependency_resolution_failed"
.Lv_dep_conflict: .asciz "dependency_version_conflict"
.Lv_dep_pinned: .asciz "dependency_pinned_version_unsatisfied"
.Lv_plugin_policy: .asciz "plugin_policy_blocked"
.Lv_mkt_policy: .asciz "marketplace_policy_blocked"
.Lv_dep_policy: .asciz "dependency_policy_blocked"
.Lv_other_mkt: .asciz "installed_from_other_marketplace"
.Lv_engine_range: .asciz "engine_range"
.Lv_folder_held: .asciz "plugin_folder_held"
.Lv_net: .asciz "error_network"
.Lv_dir_unavail: .asciz "directory_unavailable"
.Lv_manifest_parse: .asciz "manifest-parse-error"
.Lv_manifest_valid: .asciz "manifest-validation-error"
.Lv_agent_dep: .asciz "plugin-agent-setting-deprecated"
.Lv_status_dep: .asciz "plugin-subagent-status-line-deprecated"
.Lv_synced_shadow: .asciz "synced-plugin-shadowed"
.Lv_managed_hooks: .asciz "managed-hooks-restricted"
.Lv_managed_disabled: .asciz "managed-plugin-disabled-by-settings"
.Lv_ineffective: .asciz "ineffective-disable"
.Lv_version_list: .asciz "version-list-not-enabled"
.Lv_engine_invalid: .asciz "engine-range-invalid"
.Lv_engine_exempt: .asciz "engine-range-exempt"
.Lv_wikilink: .asciz "broken-wikilink"
.Lv_deps_refused: .asciz "dependencies-refused"
.Lv_deps_missing: .asciz "dependencies-not-installed"
.La_plugin: .asciz "plugin"
.La_marketplace: .asciz "marketplace"
.La_list: .asciz "list"
.La_json: .asciz "--json"
.La_available: .asciz "--available"
.La_scope: .asciz "--scope"
.La_dashes: .asciz "--"
.La_enable: .asciz "enable"
.La_disable: .asciz "disable"
.La_update: .asciz "update"
.La_uninstall: .asciz "uninstall"
.La_install: .asciz "install"
.La_keep_data: .asciz "--keep-data"
.La_configure: .asciz "configure"
.La_values_stdin: .asciz "--values-stdin"
.La_add: .asciz "add"
.La_remove: .asciz "remove"
.La_from_link: .asciz "--from-link"
.La_resolve: .asciz "--resolve-only"
.Lg_loading: .asciz "Loading plugins\342\200\246"
.Lg_loading_avail: .asciz "Loading available plugins\342\200\246"
.Lg_load_failed: .asciz "Your plugins and marketplaces couldn't be loaded."
.Lg_try_again: .asciz "Try again"
.Lg_tab_plugins: .asciz "Plugins"
.Lg_tab_sep: .asciz "\037Marketplaces"
.Lg_none: .asciz "No plugins available. Add a marketplace to discover plugins."
.Lg_search: .asciz "Search plugins\342\200\246"
.Lg_installed: .asciz "Installed"
.Lg_available: .asciz "Available"
.Lg_scope_c: .asciz "Scope: "
.Lg_from: .asciz "from "
.Lg_dot_sep: .asciz " \302\267 "
.Lg_installs: .asciz " installs"
.Lg_kept: .asciz "Not loaded"
.Lg_failed: .asciz "Failed to load"
.Lg_enabled: .asciz "Enabled"
.Lg_disabled: .asciz "Disabled"
.Lg_disable: .asciz "Disable"
.Lg_enable: .asciz "Enable"
.Lg_configure: .asciz "Configure options"
.Lg_update: .asciz "Update"
.Lg_uninstall: .asciz "Uninstall"
.Lg_cannot_uninstall: .asciz "This plugin can't be uninstalled here."
.Lg_working: .asciz "Working\342\200\246"
.Lg_install_q: .asciz "Install "
.Lg_warning: .asciz "Plugins can run code on your computer, with access to your files and shell. Make sure you trust a plugin before installing, updating, or using it. Anthropic does not control what MCP servers, files, or other software are included in plugins and cannot verify that they will work as intended or that they won't change."
.Lg_for_you: .asciz "Install for you"
.Lg_for_you_d: .asciz "Available in all your projects"
.Lg_for_project: .asciz "Install for this project"
.Lg_for_project_d: .asciz "Shared with all collaborators"
.Lg_locally: .asciz "Install locally"
.Lg_locally_d: .asciz "Only for you, only in this repo"
.Lg_installing: .asciz "Installing\342\200\246"
.Lg_uninstall_q: .asciz "Uninstall "
.Lg_scope_q: .asciz " scope)?"
.Lg_saved_data: .asciz "Uninstalling it deletes any saved data unless you keep it."
.Lg_keep: .asciz "Keep"
.Lg_delete: .asciz "Delete"
.Lg_mkt_ph: .asciz "GitHub repo, URL, or path\342\200\246"
.Lg_no_mkts: .asciz "No marketplaces configured. Add one above to discover plugins."
.Lg_official: .asciz "Official"
.Lg_official_long: .asciz "Official Claude Code marketplace"
.Lg_add: .asciz "Add"
.Lg_adding: .asciz "Adding\342\200\246"
.Lg_refresh: .asciz "Refresh marketplace"
.Lg_remove_mkt: .asciz "Remove marketplace"
.Lg_remove_mkt_q: .asciz "Remove marketplace "
.Lg_q: .asciz "?"
.Lg_remove_mkt_note: .asciz "Its plugins can no longer be installed or updated from it."
.Lg_github: .asciz "https://github.com/"
.Lg_https: .asciz "https://"
.Lg_restart_note: .asciz "Restart Claude to apply plugin changes"
.Lg_restart: .asciz "Restart"
.Lg_reload_failed: .asciz "This session couldn't reload its plugins."
.Lg_trust1: .asciz "Installing plugin"
.Lg_trust2: .asciz "requires adding a new marketplace source:"
.Lg_trust3: .asciz "Plugins from this source can run code on your computer, with access to your files and shell. Only continue if you trust it."
.Lg_trust_btn: .asciz "Trust marketplace and continue"
.Lg_adding_mkt: .asciz "Adding marketplace\342\200\246"
.Lg_link_none: .asciz "The link's plugin isn't in that marketplace."
.Lg_link_refused: .asciz "This link's marketplace wasn't added: you already have a marketplace with that name or address. Nothing changed and the plugin wasn't installed."
.Lg_mkt_failed: .asciz "Something went wrong while adding this marketplace."
.Lg_configure_t: .asciz "Configure "
.Lg_star: .asciz " *"
.Lg_unchanged: .asciz "(unchanged)"
.Lg_save_config: .asciz "Save configuration"
.Lg_saving: .asciz "Saving\342\200\246"
.Lg_required_opt: .asciz "Fill in the options marked * first."
.Lg_opts_unloaded: .asciz "This plugin's options couldn't be loaded."
.Lg_opts_unsaved: .asciz "This plugin's options weren't saved."
.Lg_opts_changed: .asciz "The plugin's options changed while this form was open. Go back and open them again."
.Lg_err_default: .asciz "It couldn't be loaded."
.Lg_e_json: .asciz "Its plugin.json isn't valid JSON."
.Lg_e_invalid: .asciz "Its plugin.json has settings that aren't valid."
.Lg_note_default: .asciz "Part of it may not be running."
.Lg_n_agent: .asciz "It sets this session's agent, which still works but will stop in a future release."
.Lg_n_status: .asciz "It sets subagentStatusLine, which still works in the terminal but will stop in a future release."
.Lg_n_synced: .asciz "Its copy from claude.ai isn't loaded; a plugin on this machine with the same name takes its place."
.Lg_n_managed_hooks: .asciz "Its hooks aren't running, because your organization only allows hooks from plugins it manages."
.Lg_n_managed_disabled: .asciz "It is turned off by your settings, so it is not running."
.Lg_n_ineffective: .asciz "It is turned off in your user settings, but another settings file turns it on, so it still runs."
.Lg_n_version_list: .asciz "It is off because its enabledPlugins entry is a version list, and only true turns it on."
.Lg_n_engine_invalid: .asciz "Its Claude Code version range isn't valid, so it's ignored."
.Lg_n_engine_exempt: .asciz "It needs another version of Claude Code, but loads anyway because it's read from a local folder."
.Lg_n_wikilink: .asciz "One of its links points to a skill that does not exist."
.Lg_n_deps_refused: .asciz "The packages it lists couldn't be installed automatically. If it needs them, parts of it may not work."
.Lg_n_deps_missing: .asciz "The packages it lists weren't installed. If it needs them, parts of it may not work. Updating the plugin tries again."
.Lg_wrong: .asciz "Something went wrong while "
.Lg_x_load: .asciz "loading your plugins and marketplaces"
.Lg_x_toggle: .asciz "turning this plugin off"
.Lg_x_update: .asciz "updating this plugin"
.Lg_x_uninstall: .asciz "uninstalling this plugin"
.Lg_x_install: .asciz "installing this plugin"
.Lg_x_add_mkt: .asciz "adding this marketplace"
.Lg_x_refresh: .asciz "refreshing this marketplace"
.Lg_x_remove_mkt: .asciz "removing this marketplace"
.Lg_d_disabled: .asciz "Turned off"
.Lg_d_enabled: .asciz "Turned on"
.Lg_x_toggle_on: .asciz "turning this plugin on"
.Lg_d_updated: .asciz "Updated"
.Lg_d_uninstalled: .asciz "Uninstalled"
.Lg_d_installed: .asciz "Installed"
.Lg_d_added_mkt: .asciz "Added marketplace"
.Lg_d_refreshed: .asciz "Refreshed marketplace"
.Lg_d_removed_mkt: .asciz "Removed marketplace"
.Lg_f_deps: .asciz "This plugin's dependencies can't be installed."
.Lg_f_deps_m: .asciz "A plugin it needs is missing, or the versions don't fit together."
.Lg_f_policy: .asciz "Your organization doesn't allow this plugin."
.Lg_f_mkt_policy: .asciz "Your organization doesn't allow plugins from this plugin's marketplace."
.Lg_f_dep_policy: .asciz "This plugin needs a plugin your organization doesn't allow."
.Lg_f_admin: .asciz "Ask an admin if you need it."
.Lg_f_other_mkt: .asciz "This plugin is already installed from another marketplace."
.Lg_f_other_mkt_m: .asciz "Uninstall the copy in your Installed list first."
.Lg_f_engine: .asciz "This plugin needs another version of Claude Code."
.Lg_f_engine_m: .asciz "This plugin, or a plugin it needs, says it works only with other versions of Claude Code."
.Lg_f_folder: .asciz "A plugin couldn't be installed alongside another one."
.Lg_f_folder_m: .asciz "This plugin, or a plugin it needs, would use the same folder as another plugin."
.Lg_f_net: .asciz "This plugin's source couldn't be reached."
.Lg_f_net_m: .asciz "Check your connection, then try again."
.Lg_f_dir: .asciz "This plugin's marketplace couldn't be read."
.Lg_f_dir_m: .asciz "Try again, or copy the error to see why."
