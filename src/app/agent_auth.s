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

# auth_codex_login(ptr, len) -> AUTH_*: `codex login status` text
FN auth_codex_login
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea rdx, [rip + .Lcx_ok]
    mov ecx, 23
    call has
    test eax, eax
    jnz 1f
    mov rdi, rbx
    mov rsi, r12
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
    PROLOGUE 24
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
