# subscription-only sign-in (spec 5.3): the environment scrub, the lock arguments, the classifiers
# of what each CLI reports, and the preflight runner. rhun reads no credential files.
.include "rhun.inc"

.section .rodata
# scrub rules per agent: (kind, name, len) where kind 1 = exact name, 2 = prefix, 3 = suffix
.p2align 3
scrub_claude:
    .quad 2, .Ls_anthropic, 10
    .quad 2, .Ls_claude_code, 12
    .quad 1, .Ls_claudecode, 10
    .quad 0, 0, 0
scrub_codex:
    .quad 2, .Ls_openai, 7
    .quad 1, .Ls_codex_key, 13
    .quad 0, 0, 0
scrub_grok:
    .quad 1, .Ls_xai_key, 11
    .quad 1, .Ls_grok_key, 21
    .quad 0, 0, 0
scrub_opencode:
    .quad 3, .Ls_api_key, 8
    .quad 3, .Ls_api_token, 10
    .quad 3, .Ls_auth_token, 11
    .quad 0, 0, 0
scrub_table: .quad 0, scrub_claude, scrub_codex, scrub_grok, scrub_opencode
.Ls_anthropic: .ascii "ANTHROPIC_"
.Ls_claude_code: .ascii "CLAUDE_CODE_"
.Ls_claudecode: .ascii "CLAUDECODE"
.Ls_openai: .ascii "OPENAI_"
.Ls_codex_key: .ascii "CODEX_API_KEY"
.Ls_xai_key: .ascii "XAI_API_KEY"
.Ls_grok_key: .ascii "GROK_CODE_XAI_API_KEY"
.Ls_api_key: .ascii "_API_KEY"
.Ls_api_token: .ascii "_API_TOKEN"
.Ls_auth_token: .ascii "_AUTH_TOKEN"
# lock arguments (spec 5.3), spliced after the program name
.p2align 3
lock_claude: .quad .Ll_settings, .Ll_settings_json, 0
lock_codex: .quad .Ll_c, .Ll_forced, .Ll_c, .Ll_provider, 0
lock_table: .quad 0, lock_claude, lock_codex, 0, 0
.Ll_settings: .asciz "--settings"
.Ll_settings_json: .asciz "{\"forceLoginMethod\":\"claudeai\"}"
.Ll_c: .asciz "-c"
.Ll_forced: .asciz "forced_login_method=\"chatgpt\""
.Ll_provider: .asciz "model_provider=\"openai\""

.text

# scrubbed(entry, rules) -> 1 if the entry's name matches a rule
scrubbed:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    # the name ends at '='
    xor ecx, ecx
1:  mov al, [rbx + rcx]
    test al, al
    jz 2f
    cmp al, '='
    je 2f
    inc rcx
    jmp 1b
2:  mov r13, rcx                # name length
3:  mov rax, [r12]
    test rax, rax
    jz 8f
    mov rdi, rbx
    mov rsi, r13
    mov rdx, [r12 + 8]
    mov rcx, [r12 + 16]
    cmp rax, 1
    je 4f
    cmp rax, 2
    je 5f
    call str_ends
    jmp 6f
4:  call str_eq
    jmp 6f
5:  call str_starts
6:  test eax, eax
    jnz 9f
    add r12, 24
    jmp 3b
8:  xor eax, eax
    EPILOGUE
9:  mov eax, 1
    EPILOGUE

# auth_envp_from(envp, agent, extras) -> a new envp: envp minus the agent's scrubbed names, then extras
# (extras 0 is an empty list). Extras are appended after the survivors, so an extra meant to override
# a surviving name must be one the agent's rules scrub as well.
FN auth_envp_from
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    # count both lists
    xor ecx, ecx
1:  cmp qword ptr [rbx + rcx*8], 0
    je 2f
    inc rcx
    jmp 1b
2:  xor edx, edx
    test r13, r13
    jz 4f
3:  cmp qword ptr [r13 + rdx*8], 0
    je 4f
    inc rdx
    jmp 3b
4:  lea rdi, [rcx + rdx + 1]
    shl rdi, 3
    call mem_alloc
    mov r14, rax
    xor r15d, r15d              # out index
    xor eax, eax                # no rules for a kind outside the table
    cmp r12, AG_OPENCODE
    ja 41f
    lea rax, [rip + scrub_table]
    mov rax, [rax + r12*8]
41: push rax                    # rules
    push rax
    xor ecx, ecx
5:  mov rdi, [rbx + rcx*8]
    test rdi, rdi
    jz 7f
    push rcx
    push rcx
    mov rsi, [rsp + 16]
    test rsi, rsi
    jz 51f
    call scrubbed
    jmp 52f
51: xor eax, eax
52: pop rcx
    pop rcx
    test eax, eax
    jnz 6f
    mov rax, [rbx + rcx*8]
    mov [r14 + r15*8], rax
    inc r15
6:  inc rcx
    jmp 5b
7:  pop rax
    pop rax
    test r13, r13
    jz 9f
    xor ecx, ecx
8:  mov rax, [r13 + rcx*8]
    test rax, rax
    jz 9f
    mov [r14 + r15*8], rax
    inc r15
    inc rcx
    jmp 8b
9:  mov qword ptr [r14 + r15*8], 0
    mov rax, r14
    EPILOGUE

# auth_envp(agent, extras) -> rhun's own environment, scrubbed, plus extras
FN auth_envp
    mov rdx, rsi
    mov rsi, rdi
    mov rdi, [rip + g_envp]
    jmp auth_envp_from

# auth_lock_args(agent) -> a NUL-terminated list of cstr arguments, or 0
FN auth_lock_args
    cmp rdi, AG_OPENCODE
    ja 1f
    lea rax, [rip + lock_table]
    mov rax, [rax + rdi*8]
    ret
1:  xor eax, eax
    ret

# ---------- classifiers of the preflight reports: each fails closed (AUTH_UNKNOWN) ----------
.section .rodata
.Lk_loggedIn: .asciz "loggedIn"
.Lk_authMethod: .asciz "authMethod"
.Lk_apiProvider: .asciz "apiProvider"
.Lv_claudeai: .asciz "claude.ai"
.Lv_firstParty: .asciz "firstParty"
.Lcx_ok: .ascii "Logged in using ChatGPT"
.Lcx_out: .ascii "Not logged in"
.Lcx_key1: .ascii "API key"
.Lcx_key2: .ascii "api key"
.Lk_id: .asciz "id"
.Lk_connections: .asciz "connections"
.Lk_type: .asciz "type"
.Lk_label: .asciz "label"
.Lv_credential: .asciz "credential"
.Loauth1: .ascii "OAuth"
.Loauth2: .ascii "oauth"
.p2align 3
opencode_allowed: .quad .Lid_openai, .Lid_xai, .Lid_copilot, 0
.Lid_openai: .asciz "openai"
.Lid_xai: .asciz "xai"
.Lid_copilot: .asciz "github-copilot"
.text

# auth_claude_status(ptr, len) -> AUTH_*: `claude auth status` as JSON. OK takes loggedIn true,
# authMethod "claude.ai" and apiProvider "firstParty"; signed in any other way is KEY.
FN auth_claude_status
    PROLOGUE
    call json_parse
    test rax, rax
    jz .Lacs_unknown
    mov rbx, rax
    mov rdi, rbx
    lea rsi, [rip + .Lk_loggedIn]
    call json_get
    mov rdi, rax
    call json_type
    cmp eax, JT_FALSE
    je .Lacs_out
    cmp eax, JT_TRUE
    jne .Lacs_unknown
    mov rdi, rbx
    lea rsi, [rip + .Lk_authMethod]
    call json_get
    mov r12, rax
    mov rdi, rax
    call json_type
    cmp eax, JT_STR
    jne .Lacs_unknown
    mov rdi, r12
    lea rsi, [rip + .Lv_claudeai]
    call json_is
    test eax, eax
    jz .Lacs_key
    mov rdi, rbx
    lea rsi, [rip + .Lk_apiProvider]
    call json_get
    mov r12, rax
    mov rdi, rax
    call json_type
    cmp eax, JT_STR
    jne .Lacs_unknown
    mov rdi, r12
    lea rsi, [rip + .Lv_firstParty]
    call json_is
    test eax, eax
    jz .Lacs_key
    mov eax, AUTH_OK
    EPILOGUE
.Lacs_out:
    mov eax, AUTH_OUT
    EPILOGUE
.Lacs_key:
    mov eax, AUTH_KEY
    EPILOGUE
.Lacs_unknown:
    mov eax, AUTH_UNKNOWN
    EPILOGUE

# has(ptr, len, needle, nlen) -> 1 if found
has:
    call str_find
    test rax, rax
    setns al
    movzx eax, al
    ret

# auth_codex_login(ptr, len) -> AUTH_*: `codex login status` text. Signed out and API key are tested
# before ChatGPT, so a report that mentions ChatGPT and either of them fails toward the stricter class.
FN auth_codex_login
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea rdx, [rip + .Lcx_out]
    mov ecx, 13
    call has
    test eax, eax
    jnz 2f
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lcx_key1]
    mov ecx, 7
    call has
    test eax, eax
    jnz 3f
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lcx_key2]
    mov ecx, 7
    call has
    test eax, eax
    jnz 3f
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lcx_ok]
    mov ecx, 23
    call has
    test eax, eax
    jnz 1f
    mov eax, AUTH_UNKNOWN
    EPILOGUE
1:  mov eax, AUTH_OK
    EPILOGUE
2:  mov eax, AUTH_OUT
    EPILOGUE
3:  mov eax, AUTH_KEY
    EPILOGUE

# oauth_label(jv) -> 1 if the connection is a stored credential whose label names OAuth
oauth_label:
    PROLOGUE
    mov rbx, rdi
    lea rsi, [rip + .Lk_type]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lv_credential]
    call json_is
    test eax, eax
    jz 8f
    mov rdi, rbx
    lea rsi, [rip + .Lk_label]
    call json_get
    mov rdi, rax
    call json_str
    test rax, rax
    jz 8f
    mov rbx, rax
    mov r12, rdx
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + .Loauth1]
    mov ecx, 5
    call has
    test eax, eax
    jnz 9f
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Loauth2]
    mov ecx, 5
    call has
    jmp 9f
8:  xor eax, eax
9:  EPILOGUE

# allowed_id(ptr, len) -> 1 if the provider id is one rhun may use through a subscription
allowed_id:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea r13, [rip + opencode_allowed]
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

# auth_opencode_creds(ptr, len, sb) -> AUTH_*; the allowed OAuth-backed ids are appended to sb,
# space-separated. OK with at least one, OUT with none, UNKNOWN when the listing is not what
# `opencode auth list --format json` prints.
# Locals: [rsp] the id, [rsp + 8] its length, [rsp + 16] the connection index.
FN auth_opencode_creds
    PROLOGUE 32
    mov r15, rdx
    call json_parse
    test rax, rax
    jz .Laoc_unknown
    mov rbx, rax                # the listing
    mov rdi, rax
    call json_type
    cmp eax, JT_ARR
    jne .Laoc_unknown
    xor r12d, r12d              # integration index
    xor r14d, r14d              # ids found
.Laoc_next:
    mov rdi, rbx
    call json_len
    cmp r12, rax
    jae .Laoc_done
    mov rdi, rbx
    mov rsi, r12
    call json_at
    mov r13, rax                # the integration
    inc r12
    mov rdi, r13
    lea rsi, [rip + .Lk_id]
    call json_get
    mov rdi, rax
    call json_str
    test rax, rax
    jz .Laoc_next
    mov [rsp], rax
    mov [rsp + 8], rdx
    mov rdi, rax
    mov rsi, rdx
    call allowed_id
    test eax, eax
    jz .Laoc_next
    mov rdi, r13
    lea rsi, [rip + .Lk_connections]
    call json_get
    mov r13, rax                # its connections (json_len 0 when missing)
    mov qword ptr [rsp + 16], 0
.Laoc_conn:
    mov rdi, r13
    call json_len
    cmp [rsp + 16], rax
    jae .Laoc_next              # no OAuth connection
    mov rdi, r13
    mov rsi, [rsp + 16]
    call json_at
    inc qword ptr [rsp + 16]
    mov rdi, rax
    call oauth_label
    test eax, eax
    jz .Laoc_conn
    test r14d, r14d
    jz 1f
    mov rdi, r15
    mov esi, ' '
    call sb_push_byte
1:  mov rdi, r15
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    call sb_push
    inc r14d
    jmp .Laoc_next
.Laoc_done:
    test r14d, r14d
    jz .Laoc_out
    mov eax, AUTH_OK
    EPILOGUE
.Laoc_out:
    mov eax, AUTH_OUT
    EPILOGUE
.Laoc_unknown:
    mov eax, AUTH_UNKNOWN
    EPILOGUE

# ---------- the preflight runner: one sign-in report command at a time ----------
.bss
.p2align 3
pf_conn: .zero CN_SIZE
pf_out: .zero SB_SIZE
.globl g_auth_ids
g_auth_ids: .zero SB_SIZE       # OpenCode: the allowed provider ids of the last preflight
pf_cb: .quad 0
pf_ctx: .quad 0
pf_deadline: .quad 0
pf_argv: .zero 8 * 8
pf_agent: .long 0
pf_busy: .long 0
pf_timed: .long 0
.data
.globl g_auth_preflight_ms
g_auth_preflight_ms: .long 10000
.section .rodata
.p2align 3
cli_names: .quad 0, .Lcli_claude, .Lcli_codex, .Lcli_grok, .Lcli_opencode
.Lcli_claude: .asciz "claude"
.Lcli_codex: .asciz "codex"
.Lcli_grok: .asciz "grok"
.Lcli_opencode: .asciz "opencode"
.Lcodex_bundled: .asciz "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"
.p2align 3
pf_args_claude: .quad .Lpa_auth, .Lpa_status, 0
pf_args_codex: .quad .Lpa_login, .Lpa_status, 0
pf_args_opencode: .quad .Lpa_auth, .Lpa_list, .Lpa_format, .Lpa_json, 0
# OpenCode: `--format json` is what 1.17 accepted; 1.19 prints usage and the preflight fails closed
pf_args: .quad 0, pf_args_claude, pf_args_codex, 0, pf_args_opencode
no_extras: .quad 0
.Lpa_auth: .asciz "auth"
.Lpa_status: .asciz "status"
.Lpa_login: .asciz "login"
.Lpa_list: .asciz "list"
.Lpa_format: .asciz "--format"
.Lpa_json: .asciz "json"
.text

# auth_find_cli(agent) -> path to run (mem_free it) or 0; Codex falls back to the ChatGPT app's copy on macOS
FN auth_find_cli
    PROLOGUE
    mov ebx, edi
    cmp ebx, AG_OPENCODE
    ja 8f
    lea rax, [rip + cli_names]
    mov rdi, [rax + rbx*8]
    test rdi, rdi
    jz 8f
    call proc_which
    test rax, rax
    jnz 9f
.ifdef MACOS
    cmp ebx, AG_CODEX
    jne 8f
    lea rdi, [rip + .Lcodex_bundled]
    mov esi, 1                  # X_OK
    SYS SYS_access
    test rax, rax
    jnz 8f
    lea rdi, [rip + .Lcodex_bundled]
    call strlen
    lea rdi, [rip + .Lcodex_bundled]
    mov rsi, rax
    call mem_dup
    jmp 9f
.endif
8:  xor eax, eax
9:  EPILOGUE

# pf_line(conn, ptr, len): collect the report
pf_line:
    PROLOGUE
    mov r12, rsi
    mov r13, rdx
    lea rdi, [rip + pf_out]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    lea rdi, [rip + pf_out]
    mov esi, 10
    call sb_push_byte
    EPILOGUE

# pf_close(conn, err): classify the report of a child that exited in time, release, report. Stdout's
# lines and then stderr are classified: the CLIs do not agree on which stream carries the report
# (codex login status writes it to stderr).
pf_close:
    PROLOGUE
    mov rdx, [rip + pf_conn + CN_ebuf + SB_len]
    test rdx, rdx
    jz 3f
    mov ebx, esi
    lea rdi, [rip + pf_out]
    mov rsi, [rip + pf_conn + CN_ebuf + SB_ptr]
    call sb_push
    mov esi, ebx
3:  mov eax, AUTH_UNKNOWN
    cmp dword ptr [rip + pf_timed], 0
    jne 5f
    cmp esi, CN_E_EXIT
    jne 5f
    mov eax, [rip + pf_agent]
    mov rdi, [rip + pf_out + SB_ptr]
    mov rsi, [rip + pf_out + SB_len]
    cmp eax, AG_CLAUDE
    je 1f
    cmp eax, AG_CODEX
    je 2f
    lea rdx, [rip + g_auth_ids]
    call auth_opencode_creds
    jmp 5f
1:  call auth_claude_status
    jmp 5f
2:  call auth_codex_login
5:  mov ebx, eax
    lea rdi, [rip + pf_conn]
    call conn_close
    mov dword ptr [rip + pf_busy], 0
    mov rdi, [rip + pf_ctx]
    mov esi, ebx
    mov rdx, [rip + pf_out + SB_ptr]
    mov rcx, [rip + pf_out + SB_len]
    test rcx, rcx
    jnz 6f
    xor edx, edx                # no output
6:  call [rip + pf_cb]
    EPILOGUE

# auth_preflight(agent, cwd, cb, ctx): runs the agent's sign-in report command in cwd with the scrubbed
# environment; cb(ctx, result, ptr, len) once, from here or from a later tick, with the AUTH_* result and
# the output (ptr 0 when there was none). Grok has none: AUTH_OK at once. A call while one runs, an
# unknown agent, a missing CLI or a failed start: AUTH_UNKNOWN at once. The ptr handed to cb lives in
# pf_out until the next auth_preflight starts. g_auth_ids is cleared on every call.
# Locals: [rsp] the environment.
FN auth_preflight
    PROLOGUE 16
    mov ebx, edi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    lea rdi, [rip + g_auth_ids]
    call sb_clear
    cmp ebx, AG_GROK            # its check is the initialize response; it runs nothing here
    je .Lpf_ok_now
    cmp dword ptr [rip + pf_busy], 0
    jne .Lpf_unknown_now
    cmp ebx, AG_OPENCODE
    ja .Lpf_unknown_now
    lea rax, [rip + pf_args]
    cmp qword ptr [rax + rbx*8], 0
    je .Lpf_unknown_now
    mov edi, ebx
    call auth_find_cli
    test rax, rax
    jz .Lpf_unknown_now
    mov r15, rax                # the path
    lea rdi, [rip + pf_argv]
    mov [rdi], rax
    lea rax, [rip + pf_args]
    mov rsi, [rax + rbx*8]
    lea rdi, [rdi + 8]
1:  mov rax, [rsi]
    mov [rdi], rax
    test rax, rax
    jz 2f
    add rsi, 8
    add rdi, 8
    jmp 1b
2:  mov edi, ebx
    lea rsi, [rip + no_extras]
    call auth_envp
    mov [rsp], rax
    lea rdi, [rip + pf_out]
    call sb_clear
    mov [rip + pf_agent], ebx
    mov [rip + pf_cb], r13
    mov [rip + pf_ctx], r14
    mov dword ptr [rip + pf_timed], 0
    lea rdi, [rip + pf_conn]
    lea rax, [rip + pf_line]
    mov [rdi + CN_on_line], rax
    lea rax, [rip + pf_close]
    mov [rdi + CN_on_close], rax
    lea rsi, [rip + pf_argv]
    mov rdx, [rsp]
    mov rcx, r12
    call conn_open
    mov ebx, eax
    mov rdi, [rsp]              # the child has its own copy now
    call mem_free
    mov rdi, r15
    call mem_free
    test ebx, ebx
    jz .Lpf_unknown_now
    lea rdi, [rip + pf_conn]
    call conn_end_input         # the report commands read nothing
    mov dword ptr [rip + pf_busy], 1
    call time_ms
    mov ecx, [rip + g_auth_preflight_ms]
    add rax, rcx
    mov [rip + pf_deadline], rax
    EPILOGUE
.Lpf_ok_now:
    mov rdi, r14
    mov esi, AUTH_OK
    xor edx, edx
    xor ecx, ecx
    call r13
    EPILOGUE
.Lpf_unknown_now:
    mov rdi, r14
    mov esi, AUTH_UNKNOWN
    xor edx, edx
    xor ecx, ecx
    call r13
    EPILOGUE

# agent_auth_tick(now_ms): a report command that overran its deadline is stopped and counts as unknown
# (pf_close reports it once the child is reaped)
FN agent_auth_tick
    cmp dword ptr [rip + pf_busy], 0
    je 9f
    cmp dword ptr [rip + pf_timed], 0
    jne 9f
    cmp rdi, [rip + pf_deadline]
    jb 9f
    mov dword ptr [rip + pf_timed], 1
    lea rdi, [rip + pf_conn]
    jmp conn_stop
9:  ret

# agent_auth_timeout() -> ms until the tick has work, or -1
FN agent_auth_timeout
    mov eax, -1
    cmp dword ptr [rip + pf_busy], 0
    je 9f
    mov eax, 100
9:  ret

# ---------- after-start checks: pure, on what each driver reads after its start handshake ----------
.section .rodata
.Lk_apiKeySource: .asciz "apiKeySource"
.Lv_none: .asciz "none"
.Lk_account: .asciz "account"
.Lv_chatgpt: .asciz "chatgpt"
.Lv_apiKey: .asciz "apiKey"
.Lk_authMethods: .asciz "authMethods"
.Lk_meta: .asciz "_meta"
.Lk_default: .asciz "defaultAuthMethodId"
.Lv_xai_key: .asciz "xai.api_key"
.p2align 3
grok_oauth_ids: .quad .Lv_cached, .Lv_grokcom, .Lv_oidc, 0
.Lv_cached: .asciz "cached_token"
.Lv_grokcom: .asciz "grok.com"
.Lv_oidc: .asciz "oidc"
.Lk_enabled: .asciz "enabled_providers"
.Lk_small: .asciz "small_model"
.Lk_model: .asciz "model"
.Lk_agent: .asciz "agent"
.Lk_provider: .asciz "provider"
.Lk_models: .asciz "models"
.Lk_name: .asciz "name"
.Lp_agent_dot: .asciz "agent."
.Lp_dot_model: .asciz ".model"
.Lp_provider_dot: .asciz "provider."
.Lp_dot: .asciz "."
.Lt_api_key: .asciz "api_key"
.Lt_env_key: .asciz "env_key"
.Lslash: .byte '/'
.text

# auth_claude_init(jv) -> AUTH_*: system/init's apiKeySource
FN auth_claude_init
    push rbx
    lea rsi, [rip + .Lk_apiKeySource]
    call json_get
    mov rbx, rax
    mov rdi, rax
    call json_type
    cmp eax, JT_STR
    jne 3f
    mov rdi, rbx
    lea rsi, [rip + .Lv_none]
    call json_is
    test eax, eax
    jz 2f
    mov eax, AUTH_OK
    pop rbx
    ret
2:  mov eax, AUTH_KEY
    pop rbx
    ret
3:  mov eax, AUTH_UNKNOWN
    pop rbx
    ret

# auth_codex_account(jv) -> AUTH_*: account/read's account.type
FN auth_codex_account
    push rbx
    lea rsi, [rip + .Lk_account]
    call json_get
    mov rbx, rax
    mov rdi, rax
    call json_type
    cmp eax, JT_NULL
    je 1f
    cmp eax, JT_OBJ
    jne 3f
    mov rdi, rbx
    lea rsi, [rip + .Lk_type]
    call json_get
    mov rbx, rax
    mov rdi, rax
    lea rsi, [rip + .Lv_chatgpt]
    call json_is
    test eax, eax
    jnz 0f
    mov rdi, rbx
    lea rsi, [rip + .Lv_apiKey]
    call json_is
    test eax, eax
    jnz 2f
    jmp 3f
0:  mov eax, AUTH_OK
    pop rbx
    ret
1:  mov eax, AUTH_OUT
    pop rbx
    ret
2:  mov eax, AUTH_KEY
    pop rbx
    ret
3:  mov eax, AUTH_UNKNOWN
    pop rbx
    ret

# auth_grok_init(jv) -> AUTH_*: the initialize result's authMethods order and default
FN auth_grok_init
    PROLOGUE
    mov rbx, rdi
    lea rsi, [rip + .Lk_authMethods]
    call json_get
    mov r12, rax
    mov rdi, rax
    call json_type
    cmp eax, JT_ARR
    jne .Lagi_unknown
    mov rdi, r12
    xor esi, esi
    call json_at
    test rax, rax
    jz .Lagi_unknown
    mov rdi, rax
    lea rsi, [rip + .Lk_id]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lv_xai_key]
    call json_is
    test eax, eax
    jnz .Lagi_key
    mov rdi, rbx
    lea rsi, [rip + .Lk_meta]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lk_default]
    call json_get
    mov r13, rax
    mov rdi, rax
    call json_type
    cmp eax, JT_NULL
    je .Lagi_out
    cmp eax, JT_STR
    jne .Lagi_unknown
    lea r14, [rip + grok_oauth_ids]
1:  mov rsi, [r14]
    test rsi, rsi
    jz .Lagi_unknown
    mov rdi, r13
    call json_is
    test eax, eax
    jnz .Lagi_ok
    add r14, 8
    jmp 1b
.Lagi_ok:
    mov eax, AUTH_OK
    EPILOGUE
.Lagi_out:
    mov eax, AUTH_OUT
    EPILOGUE
.Lagi_key:
    mov eax, AUTH_KEY
    EPILOGUE
.Lagi_unknown:
    mov eax, AUTH_UNKNOWN
    EPILOGUE

# auth_opencode_lock(sb, ids, small): the OPENCODE_CONFIG_CONTENT value for the space-separated ids
# (jw_begin empties sb first)
FN auth_opencode_lock
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, rbx
    call jw_begin
    mov rdi, rbx
    call jw_obj
    mov rdi, rbx
    lea rsi, [rip + .Lk_enabled]
    call jw_key
    mov rdi, rbx
    call jw_arr
    mov rdi, r12
    call strlen
    mov r14, r12
    mov r15, rax
1:  mov rdi, r14
    mov rsi, r15
    call next_word
    test rdx, rdx
    jz 2f
    add r14, rcx
    sub r15, rcx
    mov rdi, rbx
    mov rsi, rax
    call jw_str
    jmp 1b
2:  mov rdi, rbx
    call jw_end_arr
    mov rdi, rbx
    lea rsi, [rip + .Lk_small]
    call jw_key
    mov rdi, rbx
    mov rsi, r13
    call jw_cstr
    mov rdi, rbx
    call jw_end_obj
    EPILOGUE

# in_ids(ptr, len, ids) -> 1 if the word is one of the space-separated ids
in_ids:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, rdx
    call strlen
    mov r14, rax
1:  mov rdi, r13
    mov rsi, r14
    call next_word
    test rdx, rdx
    jz 8f
    add r13, rcx
    sub r14, rcx
    mov rcx, rdx
    mov rdx, rax
    mov rdi, rbx
    mov rsi, r12
    call str_eq
    test eax, eax
    jz 1b
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# count_ids(ids) -> the number of words
count_ids:
    PROLOGUE
    mov rbx, rdi
    call strlen
    mov r12, rax
    xor r13d, r13d
1:  mov rdi, rbx
    mov rsi, r12
    call next_word
    test rdx, rdx
    jz 2f
    add rbx, rcx
    sub r12, rcx
    inc r13d
    jmp 1b
2:  mov eax, r13d
    EPILOGUE

# model_ok(jv, ids) -> 1 if jv is absent, or a string "provider/model" whose provider is in ids;
# a value of any other type fails
model_ok:
    PROLOGUE
    test rdi, rdi
    jz 9f
    mov r12, rsi
    call json_str
    test rax, rax
    jz 8f
    mov rbx, rax
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + .Lslash]
    mov ecx, 1
    call str_find
    test rax, rax
    js 8f
    mov rdi, rbx
    mov rsi, rax
    mov rdx, r12
    call in_ids
    EPILOGUE
8:  xor eax, eax
    EPILOGUE
9:  mov eax, 1
    EPILOGUE

# refuse(sb, prefix cstr, ptr, len, suffix cstr): note the offending key path
refuse:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov r15, r8
    mov rdi, rbx
    mov rsi, r12
    call sb_push_cstr
    test r14, r14
    jz 1f
    mov rdi, rbx
    mov rsi, r13
    mov rdx, r14
    call sb_push
1:  test r15, r15
    jz 2f
    mov rdi, rbx
    mov rsi, r15
    call sb_push_cstr
2:  EPILOGUE

# auth_opencode_config(jv, ids, small, sb) -> AUTH_OK or AUTH_UNKNOWN (the key path in sb):
# the resolved configuration from `opencode debug config`, checked against the lock. enabled_providers
# must be exactly the ids; model, small_model and every agent.<name>.model, where present, must name
# one of them (small_model is checked like model, so small is not read); an allowed provider's
# provider.<id> entry may hold nothing but models, each with only id and name.
# Locals: [rsp] the id count, then the ids left; [rsp + 8] the index, then their length;
# [rsp + 16] the id's length; [rsp + 24] the offending key.
FN auth_opencode_config
    PROLOGUE 32
    mov rbx, rdi
    mov r12, rsi
    mov r14, rcx
    # enabled_providers: exactly the ids
    mov rdi, rbx
    lea rsi, [rip + .Lk_enabled]
    call json_get
    mov r15, rax
    mov rdi, rax
    call json_type
    cmp eax, JT_ARR
    jne .Laoc2_enabled
    mov rdi, r12
    call count_ids
    mov [rsp], rax
    mov rdi, r15
    call json_len
    cmp rax, [rsp]
    jne .Laoc2_enabled
    mov qword ptr [rsp + 8], 0
1:  mov rax, [rsp + 8]
    cmp rax, [rsp]
    jae 2f
    mov rdi, r15
    mov rsi, rax
    call json_at
    mov rdi, rax
    call json_str
    mov rdi, rax
    mov rsi, rdx
    mov rdx, r12
    call in_ids
    test eax, eax
    jz .Laoc2_enabled
    inc qword ptr [rsp + 8]
    jmp 1b
2:  # model and small_model
    mov rdi, rbx
    lea rsi, [rip + .Lk_model]
    call json_get
    mov rdi, rax
    mov rsi, r12
    call model_ok
    test eax, eax
    jz .Laoc2_model
    mov rdi, rbx
    lea rsi, [rip + .Lk_small]
    call json_get
    mov rdi, rax
    mov rsi, r12
    call model_ok
    test eax, eax
    jz .Laoc2_small
    # agent.<name>.model for every agent
    mov rdi, rbx
    lea rsi, [rip + .Lk_agent]
    call json_get
    mov r15, rax
    mov rdi, rax
    call json_type
    cmp eax, JT_OBJ
    jne 5f
    xor r13d, r13d              # the agent index
3:  cmp r13d, [r15 + JV_n]
    jae 5f
    mov rax, [r15 + JV_ptr]
    mov rcx, r13
    shl rcx, 4
    mov rdi, [rax + rcx + 8]    # the agent
    lea rsi, [rip + .Lk_model]
    call json_get
    mov rdi, rax
    mov rsi, r12
    call model_ok
    test eax, eax
    jz .Laoc2_agent
    inc r13d
    jmp 3b
5:  # provider.<id> for each allowed id: only "models", each with only id and name
    mov rdi, rbx
    lea rsi, [rip + .Lk_provider]
    call json_get
    mov r15, rax
    test rax, rax
    jz .Laoc2_ok
    mov rdi, r12
    call strlen
    mov [rsp], r12
    mov [rsp + 8], rax
6:  mov rdi, [rsp]
    mov rsi, [rsp + 8]
    call next_word
    test rdx, rdx
    jz .Laoc2_ok
    add [rsp], rcx
    sub [rsp + 8], rcx
    mov [rsp + 16], rdx
    mov rdi, rax
    mov rsi, rdx
    call mem_dup                # a cstr id for json_get
    mov r13, rax
    mov rdi, r15
    mov rsi, rax
    call json_get
    mov rdi, rax
    call provider_entry_ok
    test rax, rax
    jz 7f
    mov [rsp + 24], rax
    xor r8d, r8d                # not an object: the key path is the entry itself
    cmp rax, -2
    je 60f
    lea r8, [rip + .Lp_dot]
60: mov rdi, r14
    lea rsi, [rip + .Lp_provider_dot]
    mov rdx, r13
    mov rcx, [rsp + 16]
    call refuse
    mov rax, [rsp + 24]
    cmp rax, -2
    je 62f
    cmp rax, -1
    je 61f
    mov rdi, r14
    mov rsi, [rax + JV_ptr]
    mov edx, [rax + JV_n]
    call sb_push
    jmp 62f
61: mov rdi, r14
    lea rsi, [rip + .Lk_models]
    call sb_push_cstr
62: mov rdi, r13
    call mem_free
    mov eax, AUTH_UNKNOWN
    EPILOGUE
7:  mov rdi, r13
    call mem_free
    jmp 6b
.Laoc2_ok:
    mov eax, AUTH_OK
    EPILOGUE
.Laoc2_enabled:
    mov rdi, r14
    lea rsi, [rip + .Lk_enabled]
    call sb_push_cstr
    mov eax, AUTH_UNKNOWN
    EPILOGUE
.Laoc2_model:
    mov rdi, r14
    lea rsi, [rip + .Lk_model]
    call sb_push_cstr
    mov eax, AUTH_UNKNOWN
    EPILOGUE
.Laoc2_small:
    mov rdi, r14
    lea rsi, [rip + .Lk_small]
    call sb_push_cstr
    mov eax, AUTH_UNKNOWN
    EPILOGUE
.Laoc2_agent:
    mov rax, [r15 + JV_ptr]
    mov rcx, r13
    shl rcx, 4
    mov rax, [rax + rcx]        # the agent's name
    mov rdi, r14
    lea rsi, [rip + .Lp_agent_dot]
    mov rdx, [rax + JV_ptr]
    mov ecx, [rax + JV_n]
    lea r8, [rip + .Lp_dot_model]
    call refuse
    mov eax, AUTH_UNKNOWN
    EPILOGUE

# provider_entry_ok(jv) -> 0 when absent or an object with nothing but "models" of {id, name}
# entries; else the JV* of the offending key, -1 for a bad models value or model entry, or -2 when
# present but not an object
provider_entry_ok:
    PROLOGUE
    mov rbx, rdi
    call json_type
    cmp eax, -1
    je .Lpe_ok                  # absent: nothing to configure with
    cmp eax, JT_OBJ
    jne .Lpe_not_obj
    xor r12d, r12d              # the key index
1:  cmp r12d, [rbx + JV_n]
    jae .Lpe_ok
    mov rax, [rbx + JV_ptr]
    mov rcx, r12
    shl rcx, 4
    mov r13, [rax + rcx]        # key
    mov r14, [rax + rcx + 8]    # value
    mov rdi, [r13 + JV_ptr]
    mov esi, [r13 + JV_n]
    lea rdx, [rip + .Lk_models]
    call str_eq_cstr
    test eax, eax
    jz .Lpe_key
    mov rdi, r14
    call json_type
    cmp eax, JT_OBJ
    jne .Lpe_bad_model
    xor r15d, r15d              # the model index
2:  cmp r15d, [r14 + JV_n]
    jae 4f
    mov rax, [r14 + JV_ptr]
    mov rcx, r15
    shl rcx, 4
    mov rdi, [rax + rcx + 8]    # the model entry
    call model_entry_ok
    test eax, eax
    jz .Lpe_bad_model
    inc r15d
    jmp 2b
4:  inc r12d
    jmp 1b
.Lpe_ok:
    xor eax, eax
    EPILOGUE
.Lpe_key:
    mov rax, r13
    EPILOGUE
.Lpe_bad_model:
    mov rax, -1
    EPILOGUE
.Lpe_not_obj:
    mov rax, -2
    EPILOGUE

# model_entry_ok(jv) -> 1 if an object whose keys are only "id" and "name"
model_entry_ok:
    PROLOGUE
    mov rbx, rdi
    call json_type
    cmp eax, JT_OBJ
    jne 8f
    xor r12d, r12d              # the key index
1:  cmp r12d, [rbx + JV_n]
    jae 9f
    mov rax, [rbx + JV_ptr]
    mov rcx, r12
    shl rcx, 4
    mov r13, [rax + rcx]        # key
    mov rdi, [r13 + JV_ptr]
    mov esi, [r13 + JV_n]
    lea rdx, [rip + .Lk_id]
    call str_eq_cstr
    test eax, eax
    jnz 2f
    mov rdi, [r13 + JV_ptr]
    mov esi, [r13 + JV_n]
    lea rdx, [rip + .Lk_name]
    call str_eq_cstr
    test eax, eax
    jz 8f
2:  inc r12d
    jmp 1b
8:  xor eax, eax
    EPILOGUE
9:  mov eax, 1
    EPILOGUE

# toml_seg(ptr, len) -> rax the segment, rdx its length, rcx the bytes taken with the blanks around it and
#   a following dot; rcx -1 when no key segment starts there. Quotes are stripped; a "..." holding a
#   backslash is refused rather than decoded.
toml_seg:
    xor ecx, ecx
1:  cmp rcx, rsi                # blanks before
    jae 8f
    movzx r8d, byte ptr [rdi + rcx]
    cmp r8d, ' '
    je 2f
    cmp r8d, 9
    jne 3f
2:  inc rcx
    jmp 1b
3:  cmp r8d, 34
    je 4f
    cmp r8d, 39
    je 4f
    lea rax, [rdi + rcx]        # bare: A-Z a-z 0-9 _ -
    mov r9, rcx
31: cmp rcx, rsi
    jae 32f
    movzx r10d, byte ptr [rdi + rcx]
    cmp r10d, '-'
    je 33f
    cmp r10d, '_'
    je 33f
    lea r11d, [r10 - 48]
    cmp r11d, 10
    jb 33f
    or r10d, 0x20
    sub r10d, 'a'
    cmp r10d, 26
    jae 32f
33: inc rcx
    jmp 31b
32: mov rdx, rcx
    sub rdx, r9
    jz 8f
    jmp 5f
4:  inc rcx                     # quoted: r8 the quote
    lea rax, [rdi + rcx]
    mov r9, rcx
41: cmp rcx, rsi
    jae 8f
    movzx r10d, byte ptr [rdi + rcx]
    cmp r10d, r8d
    je 42f
    cmp r10d, 92
    jne 43f
    cmp r8d, 34
    je 8f
43: inc rcx
    jmp 41b
42: mov rdx, rcx
    sub rdx, r9
    inc rcx
5:  cmp rcx, rsi                # blanks after, then the end or a dot with more to come
    jae 9f
    movzx r10d, byte ptr [rdi + rcx]
    cmp r10d, ' '
    je 51f
    cmp r10d, 9
    jne 52f
51: inc rcx
    jmp 5b
52: cmp r10d, '.'
    jne 8f
    inc rcx
    cmp rcx, rsi
    jae 8f
9:  ret
8:  mov rcx, -1
    ret

# toml_path(ptr, len, out, max) -> the segments of a TOML dotted key, the first max of them stored at out
#   as (ptr, len) pairs, or -1 when it is not a key
toml_path:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    xor r15d, r15d
1:  test r12, r12
    jz 9f
    mov rdi, rbx
    mov rsi, r12
    call toml_seg
    test rcx, rcx
    js 8f
    add rbx, rcx
    sub r12, rcx
    cmp r15, r14
    jae 2f
    mov r8, r15
    shl r8, 4
    mov [r13 + r8], rax
    mov [r13 + r8 + 8], rdx
2:  inc r15
    jmp 1b
8:  mov rax, -1
    EPILOGUE
9:  mov rax, r15
    EPILOGUE

# value_end(it) -> 1, or 0 when the current key's value runs unclosed to the end of the text. INI_p moves
#   past the line the value ends on: a multi-line string or array spans lines, and a bracket, a # or a
#   [section] line inside a string does not count.
value_end:
    mov rax, [rdi + INI_val]
    mov rsi, [rdi + INI_end]
    xor edx, edx                # [ { depth
1:  cmp rax, rsi
    jae 7f
    movzx ecx, byte ptr [rax]
    cmp ecx, 10
    je 5f
    cmp ecx, '#'
    je 6f
    cmp ecx, 34
    je 3f
    cmp ecx, 39
    je 3f
    cmp ecx, '['
    je 21f
    cmp ecx, '{'
    je 21f
    cmp ecx, ']'
    je 22f
    cmp ecx, '}'
    je 22f
2:  inc rax
    jmp 1b
21: inc edx
    jmp 2b
22: test edx, edx
    jz 2b
    dec edx
    jmp 2b
5:  test edx, edx               # a newline ends the value outside brackets
    jnz 2b
    inc rax
    cmp rax, [rdi + INI_p]
    jbe 51f
    mov [rdi + INI_p], rax
51: mov eax, 1
    ret
6:  inc rax                     # a comment: to the end of its line
    cmp rax, rsi
    jae 7f
    cmp byte ptr [rax], 10
    jne 6b
    jmp 1b
3:  lea r8, [rax + 2]           # a string, ecx its quote; three quotes open a multi-line one
    cmp r8, rsi
    jae 4f
    cmp byte ptr [rax + 1], cl
    jne 4f
    cmp byte ptr [rax + 2], cl
    jne 4f
    add rax, 3
31: cmp rax, rsi
    jae 9f
    movzx r8d, byte ptr [rax]
    cmp r8d, 92
    jne 32f
    cmp ecx, 34
    jne 32f
    add rax, 2                  # an escape in """..."""
    jmp 31b
32: cmp r8d, ecx
    jne 33f
    lea r9, [rax + 2]
    cmp r9, rsi
    jae 9f
    cmp byte ptr [rax + 1], cl
    jne 33f
    cmp byte ptr [rax + 2], cl
    jne 33f
    add rax, 3
34: cmp rax, rsi                # quotes right after the closing three belong to the string
    jae 7f
    cmp byte ptr [rax], cl
    jne 1b
    inc rax
    jmp 34b
33: inc rax
    jmp 31b
4:  inc rax                     # one line: to the closing quote or the line's end
41: cmp rax, rsi
    jae 7f
    movzx r8d, byte ptr [rax]
    cmp r8d, 10
    je 1b
    inc rax
    cmp r8d, ecx
    je 1b
    cmp r8d, 92
    jne 41b
    cmp ecx, 34
    jne 41b
    cmp rax, rsi                # "\x": skip x, but never the line's end
    jae 7f
    cmp byte ptr [rax], 10
    je 1b
    inc rax
    jmp 41b
7:  mov [rdi + INI_p], rsi      # the end of the text
    xor eax, eax
    test edx, edx
    setz al
    ret
9:  mov [rdi + INI_p], rsi      # an unclosed multi-line string
    xor eax, eax
    ret

# auth_grok_models(ptr, len, sb) -> 1, or 0 when the file says something about model tables this scan
#   cannot follow (spec 5.3, fail closed: the caller refuses Grok). sb gets the names of the
#   [model.<name>] tables with an api_key or env_key key, space-separated; values are never read. A table
#   with both keys is named once. Keys and names are compared with their quotes stripped. Not followed:
#   a dotted key that reaches into a model table (model.x.api_key at the top, x.api_key under [model]),
#   an inline table for the model tables or one model ([model] x = { ... }), an array of tables under
#   model, a key or a table name that is not one, a name with a blank, and a value left unclosed.
.equ GM_PATH, INI_SIZE          # the key's full path, its first three segments as (ptr, len)
.equ GM_N, INI_SIZE + 48        # its segment count
.equ GM_OK, INI_SIZE + 56       # the result
FN auth_grok_models
    PROLOGUE INI_SIZE + 64
    mov r12, rdx                # sb
    mov rbx, rsp                # the iterator
    mov rdx, rsi
    mov rsi, rdi
    mov rdi, rbx
    call ini_init
    xor r13d, r13d              # names written
    xor r14d, r14d              # the section last named
    mov qword ptr [rsp + GM_OK], 1
1:  mov rdi, rbx
    call ini_next
    test eax, eax
    jz 9f
    mov rdi, rbx
    call value_end
    test eax, eax
    jz 8f
    mov rdi, [rbx + INI_sec]
    mov rsi, [rbx + INI_seclen]
    test rsi, rsi
    jz 2f
    cmp byte ptr [rdi], '['     # [[an array of tables]]: unclassifiable under model, ignored elsewhere
    jne 2f
    cmp rsi, 2
    jb 8f
    cmp byte ptr [rdi + rsi - 1], ']'
    jne 8f
    inc rdi
    sub rsi, 2
    lea rdx, [rsp + GM_PATH]
    mov ecx, 1
    call toml_path
    test rax, rax
    jle 8f
    mov rdi, [rsp + GM_PATH]
    mov rsi, [rsp + GM_PATH + 8]
    lea rdx, [rip + .Lk_model]
    call str_eq_cstr
    test eax, eax
    jnz 8f
    jmp 1b
2:  lea rdx, [rsp + GM_PATH]    # the table's path, then the key's after it
    mov ecx, 3
    call toml_path
    test rax, rax
    js 8f
    mov r15, rax                # the table's segments
    mov ecx, 3
    mov rdx, r15
    cmp rdx, 3
    jbe 3f
    mov edx, 3
3:  sub ecx, edx
    shl rdx, 4
    lea rdx, [rsp + GM_PATH + rdx]
    mov rdi, [rbx + INI_key]
    mov rsi, [rbx + INI_keylen]
    call toml_path
    test rax, rax
    jle 8f
    add rax, r15
    mov [rsp + GM_N], rax
    mov rdi, [rsp + GM_PATH]
    mov rsi, [rsp + GM_PATH + 8]
    lea rdx, [rip + .Lk_model]
    call str_eq_cstr
    test eax, eax
    jz 1b                       # not about models
    cmp qword ptr [rsp + GM_N], 2
    ja 4f
    cmp qword ptr [rbx + INI_vallen], 0   # model or model.<name> itself: an inline table is unfollowed
    je 1b
    mov rax, [rbx + INI_val]
    cmp byte ptr [rax], '{'
    je 8f
    jmp 1b
4:  mov rdi, [rsp + GM_PATH + 32]
    mov rsi, [rsp + GM_PATH + 40]
    lea rdx, [rip + .Lt_api_key]
    call str_eq_cstr
    test eax, eax
    jnz 5f
    mov rdi, [rsp + GM_PATH + 32]
    mov rsi, [rsp + GM_PATH + 40]
    lea rdx, [rip + .Lt_env_key]
    call str_eq_cstr
    test eax, eax
    jz 1b                       # another key of a model, or of a table below one
5:  cmp r15, 2                  # a credential key: named only as a plain key of [model.<name>]
    jne 8f
    cmp qword ptr [rsp + GM_N], 3
    jne 8f
    mov rdi, [rsp + GM_PATH + 16]
    mov rsi, [rsp + GM_PATH + 24]
    test rsi, rsi
    jz 8f
    xor ecx, ecx
6:  cmp byte ptr [rdi + rcx], ' '   # names are space-separated: a blank in one is unfollowed
    je 8f
    cmp byte ptr [rdi + rcx], 9
    je 8f
    inc rcx
    cmp rcx, rsi
    jb 6b
    mov rax, [rbx + INI_sec]
    cmp rax, r14
    je 1b                       # named already
    mov r14, rax
    test r13d, r13d
    jz 7f
    mov rdi, r12
    mov esi, ' '
    call sb_push_byte
7:  mov rdi, r12
    mov rsi, [rsp + GM_PATH + 16]
    mov rdx, [rsp + GM_PATH + 24]
    call sb_push
    inc r13d
    jmp 1b
8:  mov qword ptr [rsp + GM_OK], 0
    jmp 1b
9:  mov rax, [rsp + GM_OK]
    EPILOGUE
