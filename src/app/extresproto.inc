# The resources group's messages (docs/extensions/v1.1.md: idle, secrets, urls, uris, files,
# scoped-settings, workspace-folders), part of extproto.s: it uses the line's fields, the replies
# and `cur`.
.equ LK_URL_MAX_WIRE, 8192      # links.s's LK_URL_MAX
.equ FSK_FIND_WIRE, 1           # filesearch.s's kinds
.equ FSK_SEARCH_WIRE, 2
.text

# res_agreed(feature) -> eax 1 when cur agreed the feature (FEAT_*), else 0 after "error ID unknown"
res_agreed:
    PROLOGUE
    mov esi, edi
    mov rdi, [rip + cur]
    call ext_feature
    test eax, eax
    jnz 9f
    mov rdi, [rip + cur_id]
    lea rsi, [rip + .Le_unknown]
    call reply_error
    xor eax, eax
9:  EPILOGUE

# extproto_prompt_owner() -> the extension whose prompt is open, or 0
FN extproto_prompt_owner
    xor eax, eax
    cmp qword ptr [rip + pr_id], 0
    je 1f
    mov rax, [rip + pr_ext]
1:  ret

# ---------------- idle ----------------

# ID busy yes|no -> ok ID: while yes, an idle = stop extension is never stopped for idleness
h_res_busy:
    PROLOGUE
    mov edi, FEAT_IDLE
    call res_agreed
    test eax, eax
    jz 9f
    mov edi, 2
    lea rsi, [rip + .Lo_yes]
    call field_is
    mov r12d, eax
    test eax, eax
    jnz 1f
    mov edi, 2
    lea rsi, [rip + .Lo_no]
    call field_is
    test eax, eax
    jz 8f
1:  cmp qword ptr [rip + nfields], 3
    jne 8f
    mov rdi, [rip + cur]
    mov esi, r12d
    call extres_busy
    mov rdi, [rip + cur_id]
    call reply_ok
    EPILOGUE
8:  mov rdi, [rip + cur_id]
    call reply_syntax
9:  EPILOGUE

# ---------------- secrets ----------------

# ID secret-get KEY -> ok ID 1 LEN + value, or ok ID 0 0 when nothing is stored
h_res_secret_get:
    mov edi, SECO_GET
    jmp res_secret
# ID secret-set KEY LEN + value -> ok ID
h_res_secret_set:
    mov edi, SECO_SET
    jmp res_secret
# ID secret-delete KEY -> ok ID (also when nothing was stored)
h_res_secret_delete:
    mov edi, SECO_DELETE
    jmp res_secret
# ID secret-keys -> ok ID LEN + the keys, each followed by LF
h_res_secret_keys:
    mov edi, SECO_KEYS

# res_secret(op): checks, then the request joins the queue (secrets.s answers it)
res_secret:
    PROLOGUE 80
    mov r12d, edi
    mov edi, FEAT_SECRETS
    call res_agreed
    test eax, eax
    jz 9f
    mov rbx, [rip + cur]
    test dword ptr [rbx + EXT_needs], NEEDS_SECRETS
    jnz 1f
    mov rdi, [rip + cur_id]
    lea rsi, [rip + .Lres_e_needs_secrets]
    call reply_error
    jmp 9f
1:  mov eax, 3
    cmp r12d, SECO_SET
    jne 11f
    mov eax, 4
11: cmp r12d, SECO_KEYS
    jne 12f
    mov eax, 2
12: cmp [rip + nfields], rax
    jne 8f
    xor r13d, r13d
    cmp r12d, SECO_KEYS
    je 3f
    # KEY: [a-z0-9_.-], 1 to 64 bytes
    lea r8, [rip + fields]
    mov rsi, [r8 + 32]
    mov rdx, [r8 + 40]
    test rdx, rdx
    jz 8f
    cmp rdx, SECRET_KEY_MAX
    ja 8f
    xor ecx, ecx
2:  movzx eax, byte ptr [rsi + rcx]
    mov [rsp + rcx], al
    lea edi, [rax - 'a']
    cmp edi, 25
    jbe 21f
    lea edi, [rax - '0']
    cmp edi, 9
    jbe 21f
    cmp eax, '_'
    je 21f
    cmp eax, '.'
    je 21f
    cmp eax, '-'
    jne 8f
21: inc rcx
    cmp rcx, rdx
    jb 2b
    mov byte ptr [rsp + rcx], 0
    lea r13, [rsp]
    cmp r12d, SECO_SET
    jne 3f
    cmp qword ptr [rip + body_len], SECRET_VALUE_MAX
    jbe 3f
    mov rdi, [rip + cur_id]
    lea rsi, [rip + .Lres_e_value_big]
    call reply_error
    jmp 9f
3:  mov rdi, rbx
    mov rsi, [rip + cur_id]
    mov edx, r12d
    mov rcx, r13
    mov r8, [rip + body_ptr]
    mov r9, [rip + body_len]
    call secrets_queue
    test rax, rax
    jns 9f
    mov rdi, [rip + cur_id]
    lea rsi, [rip + .Lres_e_secret_busy]
    call reply_error
    jmp 9f
8:  mov rdi, [rip + cur_id]
    call reply_syntax
9:  EPILOGUE

# FN extproto_secret_reply(sr): the store's answer to a secret request (secrets.s)
FN extproto_secret_reply
    PROLOGUE
    mov rbx, rdi
    mov r12, [rip + cur]
    mov rax, [rbx + SECR_ext]
    mov [rip + cur], rax
    mov eax, [rbx + SECR_status]
    lea rsi, [rip + .Lres_e_refused]
    cmp eax, SECS_REFUSED
    je 7f
    lea rsi, [rip + .Lres_e_nostore]
    cmp eax, SECS_NOSTORE
    je 7f
    lea rsi, [rip + .Lres_e_keys_big]
    cmp eax, SECS_TOOBIG
    je 7f
    mov eax, [rbx + SECR_op]
    cmp eax, SECO_GET
    je 1f
    cmp eax, SECO_KEYS
    je 2f
    mov rdi, [rbx + SECR_id]
    call reply_ok
    jmp 9f
1:  call out_begin
    lea rdi, [rip + .Lw_ok_sp]
    call out_cstr
    mov rdi, [rbx + SECR_id]
    call out_u64
    cmp dword ptr [rbx + SECR_status], SECS_NONE
    jne 11f
    lea rdi, [rip + .Lres_none]
    call out_cstr
    call out_end
    jmp 9f
11: lea rdi, [rip + .Lres_one]
    call out_cstr
    jmp 3f
2:  call out_begin
    lea rdi, [rip + .Lw_ok_sp]
    call out_cstr
    mov rdi, [rbx + SECR_id]
    call out_u64
    mov edi, ' '
    call out_byte
3:  mov rdi, [rbx + SECR_outlen]
    call out_u64
    mov edi, 10
    call out_byte
    lea rdi, [rbx + SECR_buf]
    mov rsi, [rbx + SECR_outlen]
    call out_bytes
    call out_end
    jmp 9f
7:  mov rdi, [rbx + SECR_id]
    call reply_error
9:  mov [rip + cur], r12
    EPILOGUE

.section .rodata
.Lres_v_secret_get: .asciz "secret-get"
.Lres_v_secret_set: .asciz "secret-set"
.Lres_v_secret_delete: .asciz "secret-delete"
.Lres_v_secret_keys: .asciz "secret-keys"
.Lres_e_needs_secrets: .asciz "needs secrets=yes"
.Lres_e_value_big: .asciz "toobig a value is at most 8192 bytes"
.Lres_e_keys_big: .asciz "toobig 64 keys"
.Lres_e_secret_busy: .asciz "busy 8 secret requests are waiting"
.Lres_e_refused: .asciz "refused the keychain is locked, or access was cancelled or denied"
.Lres_e_nostore: .asciz "refused no keychain is available"
.Lres_none: .asciz " 0 0\n"
.Lres_one: .asciz " 1 "
.text

# ---------------- uris and virtual documents (vdoc.s) ----------------

# FN extproto_host_line(ext, line ptr, len) -> rax the id of "ID LINE" sent to the extension, or 0:
# a request about no document (content)
FN extproto_host_line
    PROLOGUE
    mov rbx, rdi
    mov r13, rsi
    mov r14, rdx
    cmp dword ptr [rbx + EXT_status], ES_RUNNING
    jne 8f
    cmp qword ptr [rbx + EXT_hreq], 2147483647
    jae 8f
    mov r12, [rip + cur]
    mov [rip + cur], rbx
    inc qword ptr [rbx + EXT_hreq]
    mov r15, [rbx + EXT_hreq]
    call out_begin
    mov rdi, r15
    call out_u64
    mov edi, ' '
    call out_byte
    mov rdi, r13
    mov rsi, r14
    call out_bytes
    mov edi, 10
    call out_byte
    call out_end
    mov [rip + cur], r12
    test rax, rax
    js 8f
    mov rdi, r13
    mov rsi, r14
    call next_word
    mov rcx, rdx
    mov rdx, rax
    mov rdi, rbx
    mov rsi, r15
    call extres_req_sent
    mov rax, r15
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN extproto_content_closed(ext, uri cstr): "0 content-closed URI"
FN extproto_content_closed
    PROLOGUE
    mov rbx, rdi
    mov r13, rsi
    mov r12, [rip + cur]
    mov [rip + cur], rbx
    call out_begin
    lea rdi, [rip + .Lres_ev_closed]
    call out_cstr
    mov rdi, r13
    call out_cstr
    mov edi, 10
    call out_byte
    call out_end
    mov [rip + cur], r12
    EPILOGUE

# ID content-changed URI -> ok ID: an open virtual document of the extension is asked again
h_res_content_changed:
    PROLOGUE
    mov edi, FEAT_URIS
    call res_agreed
    test eax, eax
    jz 9f
    cmp qword ptr [rip + nfields], 3
    jb 8f                       # the URI is the rest of the line (its REST may hold spaces)
    mov edi, 2
    call rest_from
    mov rbx, rax
    mov r12, rdx
    mov rdi, rax
    mov rsi, rdx
    call uri_scheme_len
    test rax, rax
    jz 8f
    mov rdi, [rip + cur]
    mov rsi, rbx
    mov rdx, r12
    call vdoc_changed
    mov rdi, [rip + cur_id]
    call reply_ok
    EPILOGUE
8:  mov rdi, [rip + cur_id]
    call reply_syntax
9:  EPILOGUE

# res_open_uri(ptr, len, line, col) -> rax -1 when open's resource was a URI and the request is
# answered; else rax, rdx the resource to open as a path (a file: URI decoded, or as it came)
res_open_uri:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov rdi, [rip + cur]
    mov esi, FEAT_URIS
    call ext_feature
    test eax, eax
    jz 7f
    mov rdi, rbx
    mov rsi, r12
    call uri_scheme_len
    test rax, rax
    jz 7f
    mov rdi, rbx
    mov rsi, r12
    call uri_file_path
    test rax, rax
    jz 1f
    EPILOGUE
1:  cmp r12, 5
    jb 2f
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lres_file_colon]
    mov ecx, 5
    call str_starts
    test eax, eax
    jnz 6f                      # a file: URI that is no local path
2:  mov rdi, [rip + cur]
    mov rsi, rbx
    mov rdx, r12
    mov ecx, r13d
    mov r8d, r14d
    call vdoc_open
    test rax, rax
    js 5f
    mov rsi, [rax + DOC_id]
    mov rdi, [rip + cur_id]
    call reply_ok_u64
    mov rax, -1
    EPILOGUE
5:  lea rsi, [rip + .Le_nofile]
    cmp rax, -27
    jne 51f
    lea rsi, [rip + .Lres_e_vdocs]
51: mov rdi, [rip + cur_id]
    call reply_error
    mov rax, -1
    EPILOGUE
6:  mov rdi, [rip + cur_id]
    lea rsi, [rip + .Le_nofile]
    call reply_error
    mov rax, -1
    EPILOGUE
7:  mov rax, rbx
    mov rdx, r12
    EPILOGUE

# FN extproto_uri_segment(doc) -> rax the cstr subscriptions match a virtual document by (its URI's
# last segment), or 0 for an ordinary document
FN extproto_uri_segment
    mov rax, [rdi + DOC_uri]
    test rax, rax
    jz 9f
    mov rdi, rax
    jmp uri_last_segment
9:  ret

.section .rodata
.Lres_v_content_changed: .asciz "content-changed"
.Lres_ev_closed: .asciz "0 content-closed "
.Lres_file_colon: .asciz "file:"
.Lres_e_vdocs: .asciz "toobig too many virtual documents are open"
.text

# ---------------- urls: open-url, external-uri, link (links.s) ----------------

# res_url_body() -> rax the URL as an owned cstr when the body is an http(s) URL, else 0
res_url_body:
    PROLOGUE
    mov rdi, [rip + body_ptr]
    mov rsi, [rip + body_len]
    call links_url_ok
    test eax, eax
    jz 8f
    mov rdi, [rip + body_ptr]
    mov rsi, [rip + body_len]
    call mem_dup
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# ID open-url LEN + URL -> ok ID opened | ok ID copied | error ID cancelled: the user is asked
# (Open, Copy Link, Cancel, Always open links from it) unless it may open links without asking
h_res_open_url:
    PROLOGUE 16
    mov edi, FEAT_URLS
    call res_agreed
    test eax, eax
    jz 9f
    cmp qword ptr [rip + nfields], 3
    jne 8f
    call res_url_body
    test rax, rax
    jz 8f
    mov r12, rax
    mov rbx, [rip + cur]
    mov rdi, rbx
    call extres_row
    test rax, rax
    jz 1f
    test dword ptr [rax + EL_flags], ELF_OPEN_URLS
    jz 1f
    mov rdi, r12
    call links_open
    mov rdi, r12
    call mem_free
    mov rdi, [rip + cur_id]
    lea rsi, [rip + .Lres_opened]
    call res_reply_word
    EPILOGUE
1:  call prompt_busy
    test eax, eax
    jz 2f
    mov rdi, r12
    call mem_free
    EPILOGUE
2:  mov [rip + pr_body], r12
    # "Title wants to open host in your browser: URL" (links.s, as a reply's link asks)
    mov rdi, rbx
    call ext_title
    lea rdi, [rip + res_url_label]
    mov rsi, rax
    mov rdx, r12
    call links_ask_label
    mov rdi, [rip + res_url_label + SB_ptr]
    mov rsi, [rip + res_url_label + SB_len]
    call set_label
    lea rdi, [rip + pr_label]
    call palette_choose_open
    lea rdi, [rip + .Lres_i_open]
    mov esi, 1
    call res_choose_item
    lea rdi, [rip + .Lres_i_copy]
    mov esi, 2
    call res_choose_item
    lea rdi, [rip + .Lres_i_cancel]
    mov esi, 3
    call res_choose_item
    # "Always open links from Title"
    lea rdi, [rip + res_url_label]
    call sb_clear
    lea rdi, [rip + res_url_label]
    lea rsi, [rip + .Lres_i_always]
    call sb_push_cstr
    mov rdi, rbx
    call ext_title
    lea rdi, [rip + res_url_label]
    mov rsi, rax
    call sb_push_cstr
    lea rdi, [rip + res_url_label]
    xor esi, esi
    call sb_push_byte
    mov rdi, [rip + res_url_label + SB_ptr]
    mov esi, 4
    call res_choose_item
    call palette_choose_ready
    mov edi, 4                  # pr_kind 4: open-url (res_url_chose answers it)
    call prompt_begin
    EPILOGUE
8:  mov rdi, [rip + cur_id]
    call reply_syntax
9:  EPILOGUE

# res_choose_item(cstr, n): a pick-list item
res_choose_item:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    call strlen
    mov rsi, rax
    mov rdi, rsi
    mov rsi, rbx
    mov edx, 200
    call utf8_cut
    mov rdi, rbx
    mov rsi, rax
    mov edx, r12d
    call palette_choose_add
    EPILOGUE

# res_reply_word(id, word cstr): "ok ID WORD"
res_reply_word:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call out_begin
    lea rdi, [rip + .Lw_ok_sp]
    call out_cstr
    mov rdi, rbx
    call out_u64
    mov edi, ' '
    call out_byte
    mov rdi, r12
    call out_cstr
    mov edi, 10
    call out_byte
    call out_end
    EPILOGUE

# res_url_chose(n): the user's answer to an open-url prompt (pr_kind 4): 1 Open, 2 Copy Link,
# 3 Cancel, 4 Always open links from this extension
res_url_chose:
    PROLOGUE
    mov r12, rdi
    mov rbx, [rip + cur]
    mov rax, [rip + pr_ext]
    mov [rip + cur], rax
    cmp r12, 2
    je 2f
    cmp r12, 3
    je 3f
    cmp r12, 4
    jne 1f
    mov rdi, [rip + pr_ext]     # always: remembered in extensions.ini
    call extres_row
    test rax, rax
    jz 1f
    or dword ptr [rax + EL_flags], ELF_OPEN_URLS
    call ext_settings_save
1:  mov rdi, [rip + pr_body]
    call links_open
    mov rdi, [rip + pr_id]
    lea rsi, [rip + .Lres_opened]
    call res_reply_word
    jmp 9f
2:  mov rdi, [rip + pr_body]
    call strlen
    mov rsi, rax
    mov rdi, [rip + pr_body]
    xor edx, edx
    call ed_clip_set
    mov rdi, [rip + pr_id]
    lea rsi, [rip + .Lres_copied]
    call res_reply_word
    jmp 9f
3:  mov rdi, [rip + pr_id]
    lea rsi, [rip + .Le_cancelled]
    call reply_error
9:  mov [rip + cur], rbx
    call prompt_clear
    EPILOGUE

# ID external-uri LEN + URI -> ok ID LEN + the URI the user's browser can use: in a remote window a
# loopback URL of the host comes back as the forwarded port's here (remote_forward_url); other
# http(s) URLs and rhun: links come back unchanged
h_res_external_uri:
    PROLOGUE
    mov edi, FEAT_URLS
    call res_agreed
    test eax, eax
    jz 9f
    cmp qword ptr [rip + nfields], 3
    jne 8f
    mov rdi, [rip + body_ptr]
    mov rsi, [rip + body_len]
    call links_url_ok
    test eax, eax
    jz 0f
    # a remote window: a loopback URL of the host becomes the forwarded one here (remotefwd.s)
    mov rdi, [rip + body_ptr]
    mov rsi, [rip + body_len]
    call remote_forward_url
    test rax, rax
    jz 1f
    mov rbx, rax
    mov rdi, rax
    call strlen
    mov r12, rax
    call out_begin
    lea rdi, [rip + .Lw_ok_sp]
    call out_cstr
    mov rdi, [rip + cur_id]
    call out_u64
    mov edi, ' '
    call out_byte
    mov rdi, r12
    call out_u64
    mov edi, 10
    call out_byte
    mov rdi, rbx
    mov rsi, r12
    call out_bytes
    call out_end
    mov rdi, rbx
    call mem_free
    EPILOGUE
0:  mov rdi, [rip + body_ptr]
    mov rsi, [rip + body_len]
    lea rdx, [rip + .Lres_rhun_colon]
    mov ecx, 5
    call str_starts
    test eax, eax
    jz 8f
    cmp qword ptr [rip + body_len], LK_URL_MAX_WIRE
    ja 8f
1:  call out_begin
    lea rdi, [rip + .Lw_ok_sp]
    call out_cstr
    mov rdi, [rip + cur_id]
    call out_u64
    mov edi, ' '
    call out_byte
    mov rdi, [rip + body_len]
    call out_u64
    mov edi, 10
    call out_byte
    mov rdi, [rip + body_ptr]
    mov rsi, [rip + body_len]
    call out_bytes
    call out_end
    EPILOGUE
8:  mov rdi, [rip + cur_id]
    call reply_syntax
9:  EPILOGUE

# ID link -> ok ID LEN + rhun://ext/OWNER/NAME/TOKEN: one-shot, ten minutes, four pending at most
h_res_link:
    PROLOGUE
    mov edi, FEAT_URLS
    call res_agreed
    test eax, eax
    jz 9f
    cmp qword ptr [rip + nfields], 2
    jne 8f
    mov rdi, [rip + cur]
    mov rsi, [rip + cur_id]
    call links_new
    test rax, rax
    js 7f
    mov rbx, rax
    mov rdi, rax
    call strlen
    mov r12, rax
    call out_begin
    lea rdi, [rip + .Lw_ok_sp]
    call out_cstr
    mov rdi, [rip + cur_id]
    call out_u64
    mov edi, ' '
    call out_byte
    mov rdi, r12
    call out_u64
    mov edi, 10
    call out_byte
    mov rdi, rbx
    mov rsi, r12
    call out_bytes
    call out_end
    EPILOGUE
7:  lea rsi, [rip + .Lres_e_links]
    cmp rax, -27
    je 71f
    lea rsi, [rip + .Lres_e_random]
71: mov rdi, [rip + cur_id]
    call reply_error
    EPILOGUE
8:  mov rdi, [rip + cur_id]
    call reply_syntax
9:  EPILOGUE

# FN extproto_send_link(ext, id, ptr, len): "0 link ID LEN" and the link
FN extproto_send_link
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov r15, [rip + cur]
    mov [rip + cur], rbx
    call out_begin
    lea rdi, [rip + .Lres_ev_link]
    call out_cstr
    mov rdi, r12
    call out_u64
    mov edi, ' '
    call out_byte
    mov rdi, r14
    call out_u64
    mov edi, 10
    call out_byte
    mov rdi, r13
    mov rsi, r14
    call out_bytes
    call out_end
    mov [rip + cur], r15
    EPILOGUE

# ---------------- files: find-files, search-text (filesearch.s) ----------------

# ID find-files FOLDER MAX FLAGS LEN + globs -> "0 found ID LEN" batches, then ok ID COUNT STATUS
h_res_find_files:
    mov edi, FSK_FIND_WIRE
    jmp res_files
# ID search-text FOLDER MAX FLAGS LEN + PATTERN_LEN GLOBS_LEN LF pattern globs -> batches, then
# ok ID MATCHES FILES SKIPPED STATUS
h_res_search_text:
    mov edi, FSK_SEARCH_WIRE
res_files:
    PROLOGUE 16
    mov [rsp], rdi
    mov edi, FEAT_FILES
    call res_agreed
    test eax, eax
    jz 9f
    mov rbx, [rip + cur]
    test dword ptr [rbx + EXT_needs], NEEDS_PROJECT_READ
    jz 7f
    cmp qword ptr [rip + nfields], 6
    jne 8f
    mov edi, 2
    call field_u64
    test edx, edx
    jz 8f
    mov r12, rax                # FOLDER
    mov edi, 3
    call field_u64
    test edx, edx
    jz 8f
    mov r13, rax                # MAX
    mov edi, 4
    call field_u64
    test edx, edx
    jz 8f
    cmp rax, 0xffff
    ja 8f
    mov r14, rax                # FLAGS
    mov rdi, [rip + body_ptr]
    mov rsi, [rip + body_len]
    call filesearch_body
    mov rdi, rbx
    mov rsi, [rip + cur_id]
    mov edx, [rsp]
    mov rcx, r12
    mov r8, r13
    mov r9, r14
    call filesearch_start
    test rax, rax
    jz 9f
    mov rdi, [rip + cur_id]
    mov rsi, rax
    call reply_error
    EPILOGUE
7:  mov rdi, [rip + cur_id]
    lea rsi, [rip + .Lres_e_needs_project]
    call reply_error
    EPILOGUE
8:  mov rdi, [rip + cur_id]
    call reply_syntax
9:  EPILOGUE

# ---------------- workspace-folders (workspace.s) ----------------

# FN extproto_send_folders(ext): "0 folders LEN" and N LF, then N records FOLDER LOCATION FLAGS
# NAME_LEN PATH_LEN LF NAME PATH, for an extension that agreed workspace-folders
FN extproto_send_folders
    PROLOGUE
    mov rbx, rdi
    FEAT_TEST rbx, FEAT_WORKSPACE_FOLDERS
    jz 9f
    lea r13, [rip + res_folders]
    mov rdi, r13
    call sb_clear
    call wfold_count
    mov rdi, r13
    mov rsi, rax
    call sb_push_u64
    mov rdi, r13
    mov esi, 10
    call sb_push_byte
    xor r12d, r12d
1:  call wfold_count
    cmp r12, rax
    jae 2f
    mov rdi, r12
    call wfold_id
    mov rdi, r13
    mov rsi, rax
    call sb_push_u64
    mov rdi, r13
    lea rsi, [rip + .Lres_local]
    call sb_push_cstr
    mov rdi, r12
    call wfold_flags
    mov rdi, r13
    mov esi, eax
    call sb_push_u64
    mov rdi, r13
    mov esi, ' '
    call sb_push_byte
    mov rdi, r12
    call wfold_name
    mov rdi, rax
    call strlen
    mov rdi, r13
    mov rsi, rax
    call sb_push_u64
    mov rdi, r13
    mov esi, ' '
    call sb_push_byte
    mov rdi, r12
    call wfold_path
    mov rdi, rax
    call strlen
    mov rdi, r13
    mov rsi, rax
    call sb_push_u64
    mov rdi, r13
    mov esi, 10
    call sb_push_byte
    mov rdi, r12
    call wfold_name
    mov rdi, r13
    mov rsi, rax
    call sb_push_cstr
    mov rdi, r12
    call wfold_path
    mov rdi, r13
    mov rsi, rax
    call sb_push_cstr
    inc r12
    jmp 1b
2:  mov r14, [rip + cur]
    mov [rip + cur], rbx
    call out_begin
    lea rdi, [rip + .Lres_ev_folders]
    call out_cstr
    mov rdi, [r13 + SB_len]
    call out_u64
    mov edi, 10
    call out_byte
    mov rdi, [r13 + SB_ptr]
    mov rsi, [r13 + SB_len]
    call out_bytes
    call out_end
    mov [rip + cur], r14
9:  EPILOGUE

# ID folder-of PATH -> ok ID FOLDER: the workspace folder the path is in, 0 for none (a file: URI
# too with uris); links are resolved when the path as written is in none
h_res_folder_of:
    PROLOGUE 4096
    mov edi, FEAT_WORKSPACE_FOLDERS
    call res_agreed
    test eax, eax
    jz 9f
    cmp qword ptr [rip + nfields], 3
    jb 8f
    mov edi, 2
    call rest_from
    mov rdi, rax
    mov rsi, rdx
    call uri_file_path          # a file: URI's path, or 0
    test rax, rax
    jz 0f
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    jmp 1f
0:  mov edi, 2
    call rest_from
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
1:  mov rbx, rax
    mov rdi, rax
    call wfold_of
    test rax, rax
    jns 3f
    mov rdi, rbx
    mov rsi, rsp
    call vfs_realpath
    test rax, rax
    js 2f
    mov rdi, rsp
    call wfold_of
    test rax, rax
    jns 3f
2:  xor r12d, r12d
    jmp 4f
3:  mov rdi, rax
    call wfold_id
    mov r12, rax
4:  mov rdi, rbx
    call mem_free
    mov rdi, [rip + cur_id]
    mov rsi, r12
    call reply_ok_u64
    EPILOGUE
8:  mov rdi, [rip + cur_id]
    call reply_syntax
9:  EPILOGUE

# ---------------- scoped-settings: setting-get (extconfig.s) ----------------

# ID setting-get KEY FOLDER LANG -> ok ID LEN + the value in force for that folder (0: the window)
# and language (- for none)
h_res_setting_get:
    PROLOGUE
    mov edi, FEAT_SCOPED_SETTINGS
    call res_agreed
    test eax, eax
    jz 9f
    cmp qword ptr [rip + nfields], 5
    jne 8f
    mov edi, 2
    call field_at
    mov rdi, rax
    mov rsi, rdx
    mov rdx, [rip + cur]
    call sdef_find
    test rax, rax
    jz 7f
    mov rbx, rax
    mov edi, 3
    call field_u64
    test edx, edx
    jz 8f
    mov r12, rax
    test r12, r12
    jz 1f
    mov rdi, r12
    call wfold_index
    test rax, rax
    js 6f
1:  mov edi, 4
    call field_at
    mov r13, rax
    mov r14, rdx
    cmp r14, 1
    jne 2f
    cmp byte ptr [r13], '-'
    jne 2f
    xor r14d, r14d
2:  mov rdi, [rip + cur]
    mov rsi, rbx
    mov rdx, r12
    mov rcx, r13
    mov r8, r14
    call extconfig_get
    mov r15, rax
    mov rdi, rax
    call strlen
    mov r14, rax
    call out_begin
    lea rdi, [rip + .Lw_ok_sp]
    call out_cstr
    mov rdi, [rip + cur_id]
    call out_u64
    mov edi, ' '
    call out_byte
    mov rdi, r14
    call out_u64
    mov edi, 10
    call out_byte
    mov rdi, r15
    mov rsi, r14
    call out_bytes
    call out_end
    EPILOGUE
6:  mov rdi, [rip + cur_id]
    lea rsi, [rip + .Lres_e_no_folder]
    call reply_error
    EPILOGUE
7:  mov rdi, [rip + cur_id]
    lea rsi, [rip + .Lres_e_not_setting]
    call reply_error
    EPILOGUE
8:  mov rdi, [rip + cur_id]
    call reply_syntax
9:  EPILOGUE

.bss
.p2align 3
res_url_label: .zero SB_SIZE
res_folders: .zero SB_SIZE
.section .rodata
.Lres_v_open_url: .asciz "open-url"
.Lres_v_external_uri: .asciz "external-uri"
.Lres_v_link: .asciz "link"
.Lres_ev_link: .asciz "0 link "
.Lres_opened: .asciz "opened"
.Lres_copied: .asciz "copied"
.Lres_i_open: .asciz "Open"
.Lres_i_copy: .asciz "Copy Link"
.Lres_i_cancel: .asciz "Cancel"
.Lres_i_always: .asciz "Always open links from "
.Lres_rhun_colon: .asciz "rhun:"
.Lres_e_links: .asciz "toobig 4 links are pending"
.Lres_e_random: .asciz "refused no random source"
.text

.section .rodata
.Lres_v_busy: .asciz "busy"
.Lres_v_find_files: .asciz "find-files"
.Lres_v_search_text: .asciz "search-text"
.Lres_e_needs_project: .asciz "needs project=read"
.Lres_v_setting_get: .asciz "setting-get"
.Lres_v_folder_of: .asciz "folder-of"
.Lres_ev_folders: .asciz "0 folders "
.Lres_local: .asciz " local "
.Lres_e_not_setting: .asciz "refused not a setting of this extension"
.Lres_e_no_folder: .asciz "nofile no such folder"
.text
