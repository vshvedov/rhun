# agents panel: Claude Code and Codex sessions of the current project, live
.include "rhun.inc"

STRUCT
F AS_path, 8
F AS_title, 8
F AS_mtime, 8
F AS_off, 8             # bytes parsed
F AS_msgs, VEC_SIZE     # AM
F AS_part, SB_SIZE      # incomplete trailing line
F AS_kind, 4            # 1 claude, 2 codex
F AS_loaded, 4          # messages parsed (opened at least once)
F AS_titled, 4          # has a custom title
F AS_pad, 4
F AS_changed, 8         # time_ms of the last growth
F AS_stamp, 8           # file_stamp, to see every write
ENDSTRUCT AS_SIZE

STRUCT
F AM_role, 4
F AM_h, 4
F AM_w, 4
F AM_pad, 4
F AM_text, 8
F AM_len, 8
F AM_name, 8
ENDSTRUCT AM_SIZE

.equ R_USER, 1
.equ R_ASSIST, 2
.equ R_TOOL, 3
.equ R_RESULT, 4

.equ ID_AG_ROW, 0x6000
.equ ID_AG_BACK, 0x5f00
.equ ID_AG_REFRESH, 0x5f01
.equ ID_AG_SCROLL, 0x5f02
.equ ID_AG_TSCROLL, 0x5f03
.equ ID_AG_FOLLOW, 0x5f04

.bss
.p2align 3
sessions: .zero VEC_SIZE        # AS*
rejected: .zero VEC_SIZE        # codex paths of other projects (cstr*)
claude_dir: .quad 0
list_scroll: .long 0
th_scroll: .long 0
th_content: .long 0
last_poll: .quad 0
last_scan: .quad 0
panel_rect: .zero 16
tmp: .zero SB_SIZE
line: .zero SB_SIZE
buf: .zero 96
codex_budget: .long 0

.text

FN agents_init
    ret

# ---------- discovery ----------

# has_source(name cstr) -> 1 if listed in cfg_agent_sources
has_source:
    push rbx
    push r12
    push r13
    mov r12, rdi
    call strlen
    mov r13, rax
    mov rdi, [rip + cfg_agent_sources]
    call strlen
    mov rdi, [rip + cfg_agent_sources]
    mov rsi, rax
    mov rdx, r12
    mov rcx, r13
    call str_find
    xor ecx, ecx
    test rax, rax
    setns cl
    mov eax, ecx
    pop r13
    pop r12
    pop rbx
    ret

FN agents_set_project
    PROLOGUE
    # drop current sessions
    xor ebx, ebx
1:  cmp rbx, [rip + sessions + VEC_len]
    jae 2f
    mov rax, [rip + sessions + VEC_ptr]
    mov rdi, [rax + rbx*8]
    call session_free
    inc rbx
    jmp 1b
2:  mov qword ptr [rip + sessions + VEC_len], 0
    mov qword ptr [rip + view], -1
    mov dword ptr [rip + list_scroll], 0
    mov rdi, [rip + claude_dir]
    call mem_free
    mov qword ptr [rip + claude_dir], 0
    mov rsi, [rip + g_project]
    test rsi, rsi
    jz 9f
    # ~/.claude/projects/<path with every non-alphanumeric char as '-'>
    lea rdi, [rip + tmp]
    call sb_clear
    lea rdi, [rip + .Lhome]
    call getenv
    test rax, rax
    jz 9f
    lea rdi, [rip + tmp]
    mov rsi, rax
    call sb_push_cstr
    lea rdi, [rip + tmp]
    lea rsi, [rip + .Lclaude_projects]
    call sb_push_cstr
    mov r12, [rip + g_project]
3:  movzx eax, byte ptr [r12]
    test eax, eax
    jz 4f
    mov esi, eax
    lea ecx, [rax - '0']
    cmp ecx, 9
    jbe 31f
    or eax, 0x20
    sub eax, 'a'
    cmp eax, 25
    jbe 31f
    mov esi, '-'
31: lea rdi, [rip + tmp]
    call sb_push_byte
    inc r12
    jmp 3b
4:  mov rdi, [rip + tmp + SB_ptr]
    mov rsi, [rip + tmp + SB_len]
    call mem_dup
    mov [rip + claude_dir], rax
    mov rdi, rax
    call watch_agents_dir
    call agents_scan
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

session_free:
    PROLOGUE
    mov rbx, rdi
    call session_clear_msgs
    lea rdi, [rbx + AS_msgs]
    call vec_free
    lea rdi, [rbx + AS_part]
    call sb_free
    mov rdi, [rbx + AS_path]
    call mem_free
    mov rdi, [rbx + AS_title]
    call mem_free
    mov rdi, rbx
    call mem_free
    EPILOGUE

session_clear_msgs:
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12, [rbx + AS_msgs + VEC_len]
    jae 2f
    imul r13, r12, AM_SIZE
    add r13, [rbx + AS_msgs + VEC_ptr]
    mov rdi, [r13 + AM_text]
    call mem_free
    mov rdi, [r13 + AM_name]
    call mem_free
    inc r12
    jmp 1b
2:  mov qword ptr [rbx + AS_msgs + VEC_len], 0
    EPILOGUE

# find_session(path) -> AS* or 0
find_session:
    PROLOGUE
    mov r12, rdi
    xor ebx, ebx
1:  cmp rbx, [rip + sessions + VEC_len]
    jae 2f
    mov rax, [rip + sessions + VEC_ptr]
    mov r13, [rax + rbx*8]
    mov rdi, [r13 + AS_path]
    mov rsi, r12
    call strcmp_eq
    test eax, eax
    jnz 3f
    inc rbx
    jmp 1b
2:  xor eax, eax
    EPILOGUE
3:  mov rax, r13
    EPILOGUE

# add_session(path, kind) -> AS*
add_session:
    PROLOGUE
    mov r12, rdi
    mov r13d, esi
    mov edi, AS_SIZE
    call mem_alloc
    mov rbx, rax
    mov rdi, r12
    call strlen
    mov rdi, r12
    mov rsi, rax
    call mem_dup
    mov [rbx + AS_path], rax
    mov [rbx + AS_kind], r13d
    mov rdi, rax
    call file_mtime
    mov [rbx + AS_mtime], rax
    mov rdi, [rbx + AS_path]
    call file_stamp
    mov [rbx + AS_stamp], rax
    lea rdi, [rip + sessions]
    mov esi, 8
    call vec_push
    mov [rax], rbx
    mov rdi, rbx
    call session_header
    mov rax, rbx
    EPILOGUE

# claude dir entries
claude_cb:
    PROLOGUE
    mov r12, rsi
    test edx, edx
    jnz 9f
    mov rdi, rsi
    call strlen
    mov rdi, r12
    mov rsi, rax
    lea rdx, [rip + .Ljsonl]
    mov ecx, 6
    call str_ends
    test eax, eax
    jz 9f
    mov rdi, [rip + claude_dir]
    mov rsi, r12
    call path_join
    mov r13, rax
    mov rdi, rax
    call find_session
    test rax, rax
    jnz 8f
    mov rdi, r13
    mov esi, 1
    call add_session
8:  mov rdi, r13
    call mem_free
9:  EPILOGUE

# agents_scan(): pick up new session files, sort by recency
FN agents_scan
    PROLOGUE
    call time_ms
    mov [rip + last_scan], rax
    cmp qword ptr [rip + claude_dir], 0
    je 1f
    lea rdi, [rip + .Lclaude]
    call has_source
    test eax, eax
    jz 1f
    mov rdi, [rip + claude_dir]
    lea rsi, [rip + claude_cb]
    xor edx, edx
    call dir_each
1:  lea rdi, [rip + .Lcodex]
    call has_source
    test eax, eax
    jz 2f
    call codex_scan
2:  call sort_sessions
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# codex: ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl, newest first, filtered by cwd
codex_scan:
    PROLOGUE
    lea rdi, [rip + tmp]
    call sb_clear
    lea rdi, [rip + .Lhome]
    call getenv
    test rax, rax
    jz 9f
    lea rdi, [rip + tmp]
    mov rsi, rax
    call sb_push_cstr
    lea rdi, [rip + tmp]
    lea rsi, [rip + .Lcodex_sessions]
    call sb_push_cstr
    mov dword ptr [rip + codex_budget], 400
    mov rdi, [rip + tmp + SB_ptr]
    mov rsi, [rip + tmp + SB_len]
    call mem_dup
    mov rbx, rax
    mov rdi, rax
    xor esi, esi
    call codex_walk
    mov rdi, rbx
    call mem_free
9:  EPILOGUE

# codex_walk(dir, depth): recurse three date levels, then files
codex_walk:
    PROLOGUE 16
    mov [rsp], rdi
    mov [rsp + 8], esi
    cmp dword ptr [rip + codex_budget], 0
    jle 9f
    mov rdi, [rsp]
    lea rsi, [rip + codex_cb]
    mov rdx, rsp
    call dir_each
9:  EPILOGUE

# codex_cb(ctx=[dir, depth], name, is_dir)
codex_cb:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    cmp dword ptr [rip + codex_budget], 0
    jle 9f
    mov rdi, [rbx]
    mov rsi, r12
    call path_join
    mov r14, rax
    test r13d, r13d
    jz 1f
    cmp dword ptr [rbx + 8], 3
    jae 8f
    mov rdi, r14
    mov esi, [rbx + 8]
    inc esi
    call codex_walk
    jmp 8f
1:  mov rdi, r12
    call strlen
    mov rdi, r12
    mov rsi, rax
    lea rdx, [rip + .Ljsonl]
    mov ecx, 6
    call str_ends
    test eax, eax
    jz 8f
    dec dword ptr [rip + codex_budget]
    mov rdi, r14
    call find_session
    test rax, rax
    jnz 8f
    mov rdi, r14
    call is_rejected
    test eax, eax
    jnz 8f
    mov rdi, r14
    call codex_matches
    test eax, eax
    jnz 2f
    mov rdi, r14
    call strlen
    mov rdi, r14
    mov rsi, rax
    call mem_dup
    mov r15, rax
    lea rdi, [rip + rejected]
    mov esi, 8
    call vec_push
    mov [rax], r15
    jmp 8f
2:  mov rdi, r14
    mov esi, 2
    call add_session
8:  mov rdi, r14
    call mem_free
9:  EPILOGUE

is_rejected:
    PROLOGUE
    mov r12, rdi
    xor ebx, ebx
1:  cmp rbx, [rip + rejected + VEC_len]
    jae 2f
    mov rax, [rip + rejected + VEC_ptr]
    mov rdi, [rax + rbx*8]
    mov rsi, r12
    call strcmp_eq
    test eax, eax
    jnz 3f
    inc rbx
    jmp 1b
2:  xor eax, eax
3:  EPILOGUE

# read_head(path, max) -> rax buf (NUL-terminated, mem_alloc), rdx len
read_head:
    PROLOGUE
    mov r12, rsi
    call file_open_read
    test rax, rax
    js 8f
    mov ebx, eax
    lea rdi, [r12 + 1]
    call mem_alloc
    mov r13, rax
    mov edi, ebx
    mov rsi, r13
    mov rdx, r12
    SYS SYS_read
    mov r14, rax
    test rax, rax
    jns 1f
    xor r14d, r14d
1:  mov byte ptr [r13 + r14], 0
    mov edi, ebx
    SYS SYS_close
    mov rax, r13
    mov rdx, r14
    EPILOGUE
8:  xor eax, eax
    xor edx, edx
    EPILOGUE

# codex_matches(path) -> 1 if the session_meta cwd equals the project
codex_matches:
    PROLOGUE
    mov esi, 16384
    call read_head
    test rax, rax
    jz 8f
    mov rbx, rax
    # first line
    mov rcx, rdx
    xor r12d, r12d
1:  cmp r12, rcx
    jae 2f
    cmp byte ptr [rbx + r12], 10
    je 2f
    inc r12
    jmp 1b
2:  mov rdi, rbx
    mov rsi, r12
    call json_parse
    xor r13d, r13d
    test rax, rax
    jz 7f
    mov rdi, rax
    lea rsi, [rip + .Lpayload]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lcwd]
    call json_get
    mov rdi, rax
.ifdef WINDOWS
    call json_str
    test rax, rax
    jz 7f
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov r14, rax
    mov rdi, rax
    mov rsi, [rip + g_project]
    call win_path_equal
    mov r13d, eax
    mov rdi, r14
    call mem_free
.else
    mov rsi, [rip + g_project]
    call json_is
    mov r13d, eax
.endif
7:  mov rdi, rbx
    call mem_free
    mov eax, r13d
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# session_header(s): title from the first part of the file
session_header:
    PROLOGUE 16
    mov rbx, rdi
    mov rdi, [rbx + AS_path]
    mov esi, 262144
    call read_head
    test rax, rax
    jz 9f
    mov r12, rax
    mov r13, rdx
    xor r14d, r14d              # line start
1:  cmp r14, r13
    jae 8f
    mov r15, r14
2:  cmp r15, r13
    jae 8f                      # incomplete last line: stop
    cmp byte ptr [r12 + r15], 10
    je 3f
    inc r15
    jmp 2b
3:  mov rdi, rbx
    lea rsi, [r12 + r14]
    mov rdx, r15
    sub rdx, r14
    xor ecx, ecx                # title only
    call ingest_line
    lea r14, [r15 + 1]
    # a custom title wins; stop once we have one
    cmp dword ptr [rbx + AS_titled], 0
    jne 8f
    jmp 1b
8:  mov rdi, r12
    call mem_free
9:  EPILOGUE

sort_sessions:
    mov r8, [rip + sessions + VEC_ptr]
    mov r9, [rip + sessions + VEC_len]
    mov ecx, 1
1:  cmp rcx, r9
    jae 4f
    mov rdx, rcx
2:  test rdx, rdx
    jz 3f
    mov rax, [r8 + rdx*8]
    mov r10, [r8 + rdx*8 - 8]
    mov r11, [rax + AS_mtime]
    cmp r11, [r10 + AS_mtime]
    jle 3f
    mov [r8 + rdx*8], r10
    mov [r8 + rdx*8 - 8], rax
    dec rdx
    jmp 2b
3:  inc rcx
    jmp 1b
4:  ret

# ---------- parsing ----------

# set_title(s, ptr, len, strong): keep a short one-line title (strong = custom title)
set_title:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14d, ecx
    test r14d, r14d
    jnz 1f
    cmp dword ptr [rbx + AS_titled], 0
    jne 9f
    cmp qword ptr [rbx + AS_title], 0
    jne 9f
1:  # first line, trimmed, at most 120 bytes
    xor ecx, ecx
2:  cmp rcx, r13
    jae 3f
    cmp byte ptr [r12 + rcx], 10
    je 3f
    inc rcx
    jmp 2b
3:  cmp rcx, 120
    jbe 4f
    mov ecx, 120
    # don't cut a utf-8 sequence
5:  movzx eax, byte ptr [r12 + rcx]
    and eax, 0xc0
    cmp eax, 0x80
    jne 4f
    dec rcx
    jmp 5b
4:  mov rdi, r12
    mov rsi, rcx
    call trim
    test rdx, rdx
    jz 9f
    push rax
    push rdx
    mov rdi, [rbx + AS_title]
    call mem_free
    pop rsi
    pop rdi
    call mem_dup
    mov [rbx + AS_title], rax
    test r14d, r14d
    jz 9f
    mov dword ptr [rbx + AS_titled], 1
9:  EPILOGUE

# add_msg(s, role, ptr, len, name cstr or 0)
add_msg:
    PROLOGUE 16
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    mov r15, r8
    # trim, skip empty
    mov rdi, r13
    mov rsi, r14
    call trim
    test rdx, rdx
    jnz 1f
    test r15, r15
    jz 9f
1:  mov r13, rax
    mov r14, rdx
    # results are shown as a short excerpt
    cmp r12d, R_RESULT
    jne 3f
    xor ecx, ecx
    xor edx, edx
2:  cmp rcx, r14
    jae 3f
    cmp byte ptr [r13 + rcx], 10
    jne 21f
    inc edx
    cmp edx, 4
    je 22f
21: inc rcx
    cmp rcx, 360
    jb 2b
22: mov r14, rcx
3:  lea rdi, [rbx + AS_msgs]
    mov esi, AM_SIZE
    call vec_push
    mov [rsp], rax
    mov [rax + AM_role], r12d
    # sanitize: tabs -> spaces, drop CR and other controls
    lea rdi, [r14 + 1]
    call mem_alloc
    mov rcx, [rsp]
    mov [rcx + AM_text], rax
    xor ecx, ecx
    xor edx, edx
4:  cmp rcx, r14
    jae 6f
    movzx r8d, byte ptr [r13 + rcx]
    inc rcx
    cmp r8d, 10
    je 5f
    cmp r8d, 13
    je 4b
    cmp r8d, 32
    jae 5f
    mov r8d, ' '
5:  mov [rax + rdx], r8b
    inc rdx
    jmp 4b
6:  mov byte ptr [rax + rdx], 0
    mov rcx, [rsp]
    mov [rcx + AM_len], rdx
    test r15, r15
    jz 7f
    mov rdi, r15
    call strlen
    mov rdi, r15
    mov rsi, rax
    call mem_dup
    mov rcx, [rsp]
    mov [rcx + AM_name], rax
7:  mov qword ptr [rbx + AS_changed], 0
9:  EPILOGUE

# text_of(jv) -> rax ptr, rdx len : string, or concatenated "text" parts of an array (in tmp)
text_of:
    PROLOGUE
    mov rbx, rdi
    call json_type
    cmp eax, JT_STR
    jne 1f
    mov rdi, rbx
    call json_str
    EPILOGUE
1:  mov r14d, eax
    lea rdi, [rip + tmp]
    call sb_clear
    cmp r14d, JT_ARR
    jne 8f
    xor r12d, r12d
2:  mov rdi, rbx
    call json_len
    cmp r12d, eax
    jae 8f
    mov rdi, rbx
    mov esi, r12d
    call json_at
    mov r13, rax
    mov rdi, r13
    lea rsi, [rip + .Ltext]
    call json_get
    mov rdi, rax
    call json_str
    test rax, rax
    jz 3f
    push rax
    push rdx
    cmp qword ptr [rip + tmp + SB_len], 0
    je 21f
    lea rdi, [rip + tmp]
    mov esi, 10
    call sb_push_byte
21: pop rdx
    pop rsi
    lea rdi, [rip + tmp]
    call sb_push
3:  inc r12d
    jmp 2b
8:  mov rax, [rip + tmp + SB_ptr]
    mov rdx, [rip + tmp + SB_len]
    test rax, rax
    jnz 9f
    lea rax, [rip + .Lempty]
9:  EPILOGUE

# tool_summary(input jv) -> rax ptr, rdx len : the most telling field of a tool input,
# paths inside the project shown relative to it
tool_summary:
    push rbx
    push r12
    push r13
    call tool_field
    mov rbx, rax
    mov r12, rdx
    mov rdi, [rip + g_project]
    test rdi, rdi
    jz 1f
    call strlen
    mov r13, rax
    lea rax, [r13 + 1]
    cmp r12, rax
    jbe 1f
    mov rdi, rbx
    mov rsi, r12
    mov rdx, [rip + g_project]
    mov rcx, r13
    call str_starts
    test eax, eax
    jz 1f
    cmp byte ptr [rbx + r13], '/'
    jne 1f
    lea rbx, [rbx + r13 + 1]
    sub r12, r13
    dec r12
1:  mov rax, rbx
    mov rdx, r12
    pop r13
    pop r12
    pop rbx
    ret

tool_field:
    PROLOGUE
    mov rbx, rdi
    call json_type
    cmp eax, JT_STR
    jne 1f
    mov rdi, rbx
    call json_str
    EPILOGUE
1:  lea r12, [rip + summary_keys]
2:  mov rsi, [r12]
    test rsi, rsi
    jz 3f
    mov rdi, rbx
    call json_get
    mov rdi, rax
    call json_str
    test rax, rax
    jnz 4f
    add r12, 8
    jmp 2b
3:  lea rax, [rip + .Lempty]
    xor edx, edx
4:  EPILOGUE

# ingest_line(s, ptr, len, full): full=0 only looks for a title
FN ingest_line
    PROLOGUE 32
    mov rbx, rdi
    mov [rsp], ecx
    mov rdi, rsi
    mov rsi, rdx
    call json_parse
    test rax, rax
    jz .Lil_ret
    mov r12, rax
    cmp dword ptr [rbx + AS_kind], 2
    je .Lil_codex
    # ---- claude ----
    mov rdi, r12
    lea rsi, [rip + .Ltype]
    call json_get
    mov r13, rax
    mov rdi, r13
    lea rsi, [rip + .Lcustom_title]
    call json_is
    test eax, eax
    jz 1f
    mov rdi, r12
    lea rsi, [rip + .LcustomTitle]
    call json_get
    mov rdi, rax
    call json_str
    mov rdi, rbx
    mov rsi, rax
    mov ecx, 1
    call set_title
    jmp .Lil_ret
1:  mov rdi, r13
    lea rsi, [rip + .Luser]
    call json_is
    test eax, eax
    jnz .Lil_user
    mov rdi, r13
    lea rsi, [rip + .Lassistant]
    call json_is
    test eax, eax
    jnz .Lil_assist
    jmp .Lil_ret
.Lil_user:
    # skip meta / command records
    mov rdi, r12
    lea rsi, [rip + .LisMeta]
    call json_get
    mov rdi, rax
    call json_type
    cmp eax, JT_TRUE
    je .Lil_ret
    mov rdi, r12
    lea rsi, [rip + .Lmessage]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lcontent]
    call json_get
    mov r13, rax
    mov rdi, rax
    call json_type
    cmp eax, JT_STR
    jne .Lil_user_arr
    mov rdi, r13
    call json_str
    cmp byte ptr [rax], '<'
    je .Lil_ret
    mov r14, rax
    mov r15, rdx
    mov rdi, rbx
    mov rsi, rax
    xor ecx, ecx
    call set_title
    cmp dword ptr [rsp], 0
    je .Lil_ret
    mov rdi, rbx
    mov esi, R_USER
    mov rdx, r14
    mov rcx, r15
    xor r8d, r8d
    call add_msg
    jmp .Lil_ret
.Lil_user_arr:
    cmp dword ptr [rsp], 0
    je .Lil_ret
    xor r14d, r14d
2:  mov rdi, r13
    call json_len
    cmp r14d, eax
    jae .Lil_ret
    mov rdi, r13
    mov esi, r14d
    call json_at
    mov r15, rax
    mov rdi, rax
    lea rsi, [rip + .Ltype]
    call json_get
    mov [rsp + 8], rax
    mov rdi, rax
    lea rsi, [rip + .Ltool_result]
    call json_is
    test eax, eax
    jz 3f
    mov rdi, r15
    lea rsi, [rip + .Lcontent]
    call json_get
    mov rdi, rax
    call text_of
    mov rdi, rbx
    mov esi, R_RESULT
    mov rcx, rdx
    mov rdx, rax
    xor r8d, r8d
    call add_msg
    jmp 4f
3:  mov rdi, [rsp + 8]
    lea rsi, [rip + .Ltext]
    call json_is
    test eax, eax
    jz 4f
    mov rdi, r15
    lea rsi, [rip + .Ltext]
    call json_get
    mov rdi, rax
    call json_str
    cmp byte ptr [rax], '<'
    je 4f
    mov rdi, rbx
    mov esi, R_USER
    mov rcx, rdx
    mov rdx, rax
    xor r8d, r8d
    call add_msg
4:  inc r14d
    jmp 2b
.Lil_assist:
    cmp dword ptr [rsp], 0
    je .Lil_ret
    mov rdi, r12
    lea rsi, [rip + .Lmessage]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lcontent]
    call json_get
    mov r13, rax
    xor r14d, r14d
5:  mov rdi, r13
    call json_len
    cmp r14d, eax
    jae .Lil_ret
    mov rdi, r13
    mov esi, r14d
    call json_at
    mov r15, rax
    mov rdi, rax
    lea rsi, [rip + .Ltype]
    call json_get
    mov [rsp + 8], rax
    mov rdi, rax
    lea rsi, [rip + .Ltext]
    call json_is
    test eax, eax
    jz 6f
    mov rdi, r15
    lea rsi, [rip + .Ltext]
    call json_get
    mov rdi, rax
    call json_str
    mov rdi, rbx
    mov esi, R_ASSIST
    mov rcx, rdx
    mov rdx, rax
    xor r8d, r8d
    call add_msg
    jmp 7f
6:  mov rdi, [rsp + 8]
    lea rsi, [rip + .Ltool_use]
    call json_is
    test eax, eax
    jz 7f
    mov rdi, r15
    lea rsi, [rip + .Lname]
    call json_get
    mov rdi, rax
    call json_str
    mov [rsp + 16], rax
    mov rdi, r15
    lea rsi, [rip + .Linput]
    call json_get
    mov rdi, rax
    call tool_summary
    mov r8, [rsp + 16]
    test r8, r8
    jnz 61f
    lea r8, [rip + .Ltool]
61: mov rdi, rbx
    mov esi, R_TOOL
    mov rcx, rdx
    mov rdx, rax
    call add_msg
7:  inc r14d
    jmp 5b
.Lil_codex:
    mov rdi, r12
    lea rsi, [rip + .Lpayload]
    call json_get
    mov r13, rax
    mov rdi, rax
    lea rsi, [rip + .Ltype]
    call json_get
    mov r14, rax
    mov rdi, r14
    lea rsi, [rip + .Lmessage]
    call json_is
    test eax, eax
    jz .Lcx_tool
    mov rdi, r13
    lea rsi, [rip + .Lrole]
    call json_get
    mov r15, rax
    mov rdi, r13
    lea rsi, [rip + .Lcontent]
    call json_get
    mov rdi, rax
    call text_of
    test rdx, rdx
    jz .Lil_ret
    cmp byte ptr [rax], '<'
    je .Lil_ret
    cmp byte ptr [rax], '#'
    je .Lil_ret
    mov [rsp + 8], rax
    mov [rsp + 16], rdx
    mov rdi, r15
    lea rsi, [rip + .Luser]
    call json_is
    test eax, eax
    jz 8f
    mov rdi, rbx
    mov rsi, [rsp + 8]
    mov rdx, [rsp + 16]
    xor ecx, ecx
    call set_title
    mov esi, R_USER
    jmp 81f
8:  mov rdi, r15
    lea rsi, [rip + .Lassistant]
    call json_is
    test eax, eax
    jz .Lil_ret
    mov esi, R_ASSIST
81: cmp dword ptr [rsp], 0
    je .Lil_ret
    mov rdi, rbx
    mov rdx, [rsp + 8]
    mov rcx, [rsp + 16]
    xor r8d, r8d
    call add_msg
    jmp .Lil_ret
.Lcx_tool:
    cmp dword ptr [rsp], 0
    je .Lil_ret
    mov rdi, r14
    lea rsi, [rip + .Lfunction_call]
    call json_is
    test eax, eax
    jnz 9f
    mov rdi, r14
    lea rsi, [rip + .Lcustom_tool_call]
    call json_is
    test eax, eax
    jnz 9f
    mov rdi, r14
    lea rsi, [rip + .Lfunction_call_output]
    call json_is
    test eax, eax
    jnz 10f
    mov rdi, r14
    lea rsi, [rip + .Lcustom_tool_call_output]
    call json_is
    test eax, eax
    jnz 10f
    jmp .Lil_ret
9:  # name and arguments are copied out: the arguments are JSON text themselves
    mov rdi, r13
    lea rsi, [rip + .Lname]
    call json_get
    mov rdi, rax
    call json_str
    test rax, rax
    jnz 90f
    lea rax, [rip + .Ltool]
    mov edx, 4
90: mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov [rsp + 16], rax
    mov rdi, r13
    lea rsi, [rip + .Larguments]
    call json_get
    test rax, rax
    jnz 91f
    mov rdi, r13
    lea rsi, [rip + .Linput]
    call json_get
91: mov rdi, rax
    call tool_summary
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov [rsp + 24], rax
    mov rdi, rax
    call strlen
    mov rdi, [rsp + 24]
    mov rsi, rax
    call json_parse
    test rax, rax
    jz 93f
    mov r14, rax
    mov rdi, rax
    lea rsi, [rip + .Ls_command]
    call json_get
    test rax, rax
    jz 94f
    mov r15, rax
    mov rdi, rax
    call json_type
    cmp eax, JT_ARR
    jne 95f
    # command array -> words joined by spaces
    lea rdi, [rip + tmp]
    call sb_clear
    xor r14d, r14d
96: mov rdi, r15
    call json_len
    cmp r14d, eax
    jae 97f
    test r14d, r14d
    jz 98f
    lea rdi, [rip + tmp]
    mov esi, ' '
    call sb_push_byte
98: mov rdi, r15
    mov esi, r14d
    call json_at
    mov rdi, rax
    call json_str
    lea rdi, [rip + tmp]
    mov rsi, rax
    call sb_push
    inc r14d
    jmp 96b
97: mov rax, [rip + tmp + SB_ptr]
    mov rdx, [rip + tmp + SB_len]
    jmp 99f
95: mov rdi, r15
    call json_str
    test rax, rax
    jnz 99f
94: mov rdi, r14
    call tool_summary
    jmp 99f
93: mov rdi, [rsp + 24]
    call strlen
    mov rdx, rax
    mov rax, [rsp + 24]
99: mov rdi, rbx
    mov esi, R_TOOL
    mov rcx, rdx
    mov rdx, rax
    mov r8, [rsp + 16]
    call add_msg
    mov rdi, [rsp + 16]
    call mem_free
    mov rdi, [rsp + 24]
    call mem_free
    jmp .Lil_ret
10: mov rdi, r13
    lea rsi, [rip + .Loutput]
    call json_get
    mov rdi, rax
    call text_of
    mov rdi, rbx
    mov esi, R_RESULT
    mov rcx, rdx
    mov rdx, rax
    xor r8d, r8d
    call add_msg
.Lil_ret:
    EPILOGUE

# session_update(s): parse bytes appended since the last read
FN session_update
    PROLOGUE 16
    mov rbx, rdi
    mov rdi, [rbx + AS_path]
    call file_open_read
    test rax, rax
    js 9f
    mov r12d, eax
    mov edi, eax
    call file_size
    mov r13, rax
    cmp rax, [rbx + AS_off]
    jb 10f                      # truncated: reload
    je 8f
    # read the new bytes into the partial-line buffer
    mov r14, r13
    sub r14, [rbx + AS_off]
    lea rdi, [rbx + AS_part]
    mov rsi, r14
    call sb_reserve
    mov rsi, rax
    mov edi, r12d
    mov rdx, r14
    mov r10, [rbx + AS_off]
    mov eax, 17                 # pread64
    XSYS
    test rax, rax
    jle 8f
    add [rbx + AS_off], rax
    add [rbx + AS_part + SB_len], rax
    # complete lines
    mov r14, [rbx + AS_part + SB_ptr]
    mov r15, [rbx + AS_part + SB_len]
    xor ecx, ecx                # line start
    mov [rsp], rcx
    xor edx, edx
1:  cmp rdx, r15
    jae 3f
    cmp byte ptr [r14 + rdx], 10
    jne 2f
    mov [rsp + 8], rdx
    mov rdi, rbx
    mov rcx, [rsp]
    lea rsi, [r14 + rcx]
    mov rdx, [rsp + 8]
    sub rdx, rcx
    mov ecx, 1
    call ingest_line
    mov rdx, [rsp + 8]
    lea rcx, [rdx + 1]
    mov [rsp], rcx
2:  inc rdx
    jmp 1b
3:  # keep the tail
    mov rcx, [rsp]
    mov rdx, r15
    sub rdx, rcx
    mov rdi, r14
    lea rsi, [r14 + rcx]
    push rdx
    push rdx
    call memmove
    pop rdx
    pop rdx
    mov [rbx + AS_part + SB_len], rdx
    call time_ms
    mov [rbx + AS_changed], rax
    mov dword ptr [rip + g_dirty], 1
8:  mov edi, r12d
    SYS SYS_close
9:  EPILOGUE
10: mov qword ptr [rbx + AS_off], 0
    mov qword ptr [rbx + AS_part + SB_len], 0
    mov rdi, rbx
    call session_clear_msgs
    mov edi, r12d
    SYS SYS_close
    mov rdi, rbx
    call session_update
    EPILOGUE

# ---------- refresh ----------

# agents_poll(): new bytes / mtimes (cheap stat of every session)
FN agents_poll
    PROLOGUE
    call time_ms
    mov [rip + last_poll], rax
    xor ebx, ebx
    xor r13d, r13d              # order changed
1:  cmp rbx, [rip + sessions + VEC_len]
    jae 3f
    mov rax, [rip + sessions + VEC_ptr]
    mov r12, [rax + rbx*8]
    mov rdi, [r12 + AS_path]
    call file_stamp
    cmp rax, [r12 + AS_stamp]
    je 2f
    mov [r12 + AS_stamp], rax
    mov rdi, [r12 + AS_path]
    call file_mtime
    mov [r12 + AS_mtime], rax
    mov r13d, 1
    call time_ms
    mov [r12 + AS_changed], rax
    cmp dword ptr [r12 + AS_loaded], 0
    je 2f
    mov rdi, r12
    call session_update
2:  inc rbx
    jmp 1b
3:  test r13d, r13d
    jz 4f
    # keep the open session selected across the re-sort
    mov rax, [rip + view]
    xor r14d, r14d
    test rax, rax
    js 31f
    mov rcx, [rip + sessions + VEC_ptr]
    mov r14, [rcx + rax*8]
31: call sort_sessions
    test r14, r14
    jz 32f
    xor ecx, ecx
33: mov rax, [rip + sessions + VEC_ptr]
    cmp [rax + rcx*8], r14
    je 34f
    inc rcx
    jmp 33b
34: mov [rip + view], rcx
32: mov dword ptr [rip + g_dirty], 1
4:  EPILOGUE

# called by the watcher when an agents directory changes
FN agents_on_change
    call agents_scan
    jmp agents_poll

FN agents_timeout
    cmp qword ptr [rip + claude_dir], 0
    je 1f
    call time_ms
    mov rcx, [rip + last_poll]
    add rcx, 1000
    sub rcx, rax
    jns 2f
    xor ecx, ecx
2:  mov eax, ecx
    ret
1:  mov eax, -1
    ret

FN agents_tick
    push rbx
    cmp qword ptr [rip + claude_dir], 0
    je 9f
    call time_ms
    mov rbx, rax
    sub rax, [rip + last_poll]
    cmp rax, 1000
    jb 1f
    call agents_poll
    # relative times in the list
    cmp dword ptr [rip + cfg_agents], 0
    je 1f
    mov dword ptr [rip + g_dirty], 1
1:  mov rax, rbx
    sub rax, [rip + last_scan]
    cmp rax, 10000
    jb 9f
    call agents_scan
9:  pop rbx
    ret

# open_session(i)
open_session:
    PROLOGUE
    mov [rip + view], rdi
    mov rax, [rip + sessions + VEC_ptr]
    mov rbx, [rax + rdi*8]
    mov dword ptr [rbx + AS_loaded], 1
    mov rdi, rbx
    call session_update
    mov dword ptr [rip + th_follow], 1
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

FN cmd_focus_agents
    mov dword ptr [rip + cfg_agents], 1
    mov dword ptr [rip + g_focus], FOCUS_AGENTS
    mov dword ptr [rip + g_dirty], 1
    ret

# agents_dump(sb): sessions (kind, title, messages) and the open thread, for tests
FN agents_dump
    PROLOGUE
    mov r15, rdi
    xor ebx, ebx
1:  cmp rbx, [rip + sessions + VEC_len]
    jae 3f
    mov rax, [rip + sessions + VEC_ptr]
    mov r12, [rax + rbx*8]
    lea rsi, [rip + .Lclaude_name]
    cmp dword ptr [r12 + AS_kind], 2
    jne 2f
    lea rsi, [rip + .Lcodex_name]
2:  mov rdi, r15
    call sb_push_cstr
    mov rdi, r15
    mov esi, ':'
    call sb_push_byte
    mov rdi, r15
    mov esi, ' '
    call sb_push_byte
    mov rsi, [r12 + AS_title]
    test rsi, rsi
    jnz 21f
    lea rsi, [rip + .Luntitled]
21: mov rdi, r15
    call sb_push_cstr
    mov rdi, r15
    mov esi, 10
    call sb_push_byte
    inc rbx
    jmp 1b
3:  mov rax, [rip + view]
    test rax, rax
    js 9f
    mov rcx, [rip + sessions + VEC_ptr]
    mov r12, [rcx + rax*8]
    xor ebx, ebx
4:  cmp rbx, [r12 + AS_msgs + VEC_len]
    jae 9f
    imul r13, rbx, AM_SIZE
    add r13, [r12 + AS_msgs + VEC_ptr]
    mov eax, [r13 + AM_role]
    lea rcx, [rip + role_names]
    mov rsi, [rcx + rax*8]
    mov rdi, r15
    call sb_push_cstr
    mov rsi, [r13 + AM_name]
    test rsi, rsi
    jz 5f
    mov rdi, r15
    mov esi, '('
    call sb_push_byte
    mov rdi, r15
    mov rsi, [r13 + AM_name]
    call sb_push_cstr
    mov rdi, r15
    mov esi, ')'
    call sb_push_byte
5:  mov rdi, r15
    mov esi, ' '
    call sb_push_byte
    # first line, at most 60 bytes
    mov rsi, [r13 + AM_text]
    mov rdx, [r13 + AM_len]
    xor ecx, ecx
6:  cmp rcx, rdx
    jae 7f
    cmp rcx, 60
    jae 7f
    cmp byte ptr [rsi + rcx], 10
    je 7f
    inc rcx
    jmp 6b
7:  mov rdi, r15
    mov rdx, rcx
    call sb_push
    mov rdi, r15
    mov esi, 10
    call sb_push_byte
    inc rbx
    jmp 4b
9:  EPILOGUE

# agents_open(i): open session i (tests / control socket)
FN agents_open
    cmp rdi, [rip + sessions + VEC_len]
    jae 1f
    jmp open_session
1:  ret

FN agents_key
    cmp edi, KEY_ESCAPE
    jne 1f
    cmp qword ptr [rip + view], 0
    jl 2f
    mov qword ptr [rip + view], -1
    jmp 3f
2:  mov dword ptr [rip + g_focus], FOCUS_EDITOR
3:  mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    ret
1:  xor eax, eax
    ret

# ---------- drawing ----------

# rel_time(unix seconds) -> cstr in buf ("now", "5m", "3h", "2d")
rel_time:
    push rbx
    mov rbx, rdi
    call time_now
    sub rax, rbx
    jns 1f
    xor eax, eax
1:  lea rdi, [rip + buf]
    cmp rax, 60
    jae 2f
    lea rsi, [rip + .Lnow]
    call cstr_copy
    pop rbx
    ret
2:  mov ecx, 'm'
    xor edx, edx
    mov r8d, 60
    div r8
    cmp rax, 60
    jb 3f
    mov ecx, 'h'
    xor edx, edx
    div r8
    cmp rax, 24
    jb 3f
    mov ecx, 'd'
    xor edx, edx
    mov r8d, 24
    div r8
3:  push rcx
    mov rsi, rax
    call fmt_u64
    pop rcx
    mov [rdi], cl
    lea rsi, [rip + .Lago]
    inc rdi
    call cstr_copy
    pop rbx
    ret

# is_live(s) -> 1 if written in the last 20 seconds
is_live:
    push rbx
    mov rbx, rdi
    call time_now
    sub rax, [rbx + AS_mtime]
    cmp rax, 20
    setbe al
    movzx eax, al
    pop rbx
    ret

# wrap(face, text, len, x, y, width, lh, color, draw) -> lines   (args via stack frame struct at rdi)
# rdi -> WR block: face, text, len, x, y, w, lh, color, draw, clip_top, clip_bottom
STRUCT
F WR_face, 8
F WR_text, 8
F WR_len, 8
F WR_x, 4
F WR_y, 4
F WR_w, 4
F WR_lh, 4
F WR_color, 4
F WR_draw, 4
F WR_top, 4
F WR_bot, 4
ENDSTRUCT WR_SIZE

wrap:
    PROLOGUE 48
    mov rbx, rdi
    xor r15d, r15d              # lines
    xor r12d, r12d              # p
.Lwr_line:
    cmp r12, [rbx + WR_len]
    jae .Lwr_done
    mov r13, r12                # line start
    xor r14d, r14d              # width 26.6
    mov qword ptr [rsp], -1     # last break
    mov rax, [rbx + WR_len]
    mov [rsp + 8], rax          # end (default)
    mov [rsp + 16], rax         # next
    mov eax, [rbx + WR_w]
    shl eax, 6
    mov [rsp + 24], eax
.Lwr_ch:
    cmp r12, [rbx + WR_len]
    jae .Lwr_emit
    mov rax, [rbx + WR_text]
    cmp byte ptr [rax + r12], 10
    jne 1f
    mov [rsp + 8], r12
    lea rcx, [r12 + 1]
    mov [rsp + 16], rcx
    jmp .Lwr_emit2
1:  cmp byte ptr [rax + r12], ' '
    jne 2f
    mov [rsp], r12
2:  lea rdi, [rax + r12]
    mov rsi, [rbx + WR_len]
    sub rsi, r12
    call utf8_decode
    mov [rsp + 32], edx
    mov rdi, [rbx + WR_face]
    mov esi, eax
    call face_glyph
    mov eax, [rax + GL_adv]
    lea ecx, [r14 + rax]
    cmp ecx, [rsp + 24]
    jle 4f
    cmp r12, r13
    je 4f
    # break the line
    mov rax, [rsp]
    cmp rax, r13
    jle 3f
    cmp rax, -1
    je 3f
    mov [rsp + 8], rax
    inc rax
    mov [rsp + 16], rax
    jmp .Lwr_emit2
3:  mov [rsp + 8], r12
    mov [rsp + 16], r12
    jmp .Lwr_emit2
4:  mov r14d, ecx
    mov eax, [rsp + 32]
    add r12, rax
    jmp .Lwr_ch
.Lwr_emit:
    mov [rsp + 8], r12
    mov [rsp + 16], r12
.Lwr_emit2:
    cmp dword ptr [rbx + WR_draw], 0
    je 5f
    mov eax, r15d
    imul eax, [rbx + WR_lh]
    add eax, [rbx + WR_y]
    mov ecx, eax
    add ecx, [rbx + WR_lh]
    cmp ecx, [rbx + WR_top]
    jl 5f
    cmp eax, [rbx + WR_bot]
    jg 5f
    mov rdx, [rbx + WR_face]
    add eax, [rdx + FACE_ascent]
    mov edx, eax
    mov rdi, [rbx + WR_face]
    mov esi, [rbx + WR_x]
    mov rcx, [rbx + WR_text]
    add rcx, r13
    mov r8, [rsp + 8]
    sub r8, r13
    mov r9d, [rbx + WR_color]
    call text_draw
5:  inc r15d
    mov r12, [rsp + 16]
    jmp .Lwr_line
.Lwr_done:
    test r15d, r15d
    jnz 6f
    mov r15d, 1
6:  mov eax, r15d
    EPILOGUE

# msg_height(msg, width) -> px (cached)
msg_height:
    PROLOGUE 96
    mov rbx, rdi
    mov r12d, esi
    cmp [rbx + AM_w], r12d
    jne 1f
    mov eax, [rbx + AM_h]
    EPILOGUE
1:  mov [rbx + AM_w], r12d
    mov eax, [rbx + AM_role]
    cmp eax, R_TOOL
    jne 2f
    M eax, MI_32
    jmp 9f
2:  lea rdi, [rsp]
    call wr_setup
    mov dword ptr [rsp + WR_draw], 0
    lea rdi, [rsp]
    call wrap
    imul eax, [rsp + WR_lh]
    mov ecx, [rbx + AM_role]
    cmp ecx, R_RESULT
    jne 3f
    add eax, [rip + g_mt + 4*MI_20]
    jmp 9f
3:  add eax, [rip + g_mt + 4*MI_40]
9:  mov [rbx + AM_h], eax
    EPILOGUE

# wr_setup(WR*) using rbx = msg, r12d = width
wr_setup:
    mov rax, [rbx + AM_text]
    mov [rdi + WR_text], rax
    mov rax, [rbx + AM_len]
    mov [rdi + WR_len], rax
    mov [rdi + WR_w], r12d
    lea rax, [rip + g_face_ui]
    mov ecx, [rip + g_face_ui + FACE_lineh]
    cmp dword ptr [rbx + AM_role], R_RESULT
    jne 1f
    lea rax, [rip + g_face_small]
    mov ecx, [rip + g_face_small + FACE_lineh]
1:  mov [rdi + WR_face], rax
    add ecx, [rip + g_mt + 4*MI_3]
    mov [rdi + WR_lh], ecx
    ret

# agents_draw(x, y, w, h)
FN agents_draw
    PROLOGUE 64
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    mov [rip + panel_rect], edi
    mov [rip + panel_rect + 4], esi
    mov [rip + panel_rect + 8], edx
    mov [rip + panel_rect + 12], ecx
    COLOR r8d, T_PANEL
    call gfx_fill
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    call gfx_clip_push
    cmp qword ptr [rip + view], 0
    jl 1f
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    call thread_draw
    jmp 9f
1:  mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    call list_draw
9:  call gfx_clip_pop
    EPILOGUE

list_draw:
    PROLOGUE 64
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    # header
    M r15d, MI_40
    lea rdi, [rip + g_face_small]
    mov esi, [rsp]
    add esi, [rip + g_mt + 4*MI_16]
    mov edx, [rsp + 4]
    mov ecx, r15d
    lea r8, [rip + .Lheader]
    COLOR r9d, T_UI_MUTED
    call ui_text_c
    M r12d, MI_28
    mov edi, ID_AG_REFRESH
    mov esi, [rsp]
    add esi, [rsp + 8]
    sub esi, r12d
    sub esi, [rip + g_mt + 4*MI_8]
    mov edx, r15d
    sub edx, r12d
    sar edx, 1
    add edx, [rsp + 4]
    mov ecx, r12d
    mov r8d, r12d
    mov r9d, IC_REFRESH
    call ui_icon_btn
    test eax, UB_CLICK
    jz 1f
    call agents_scan
1:  cmp qword ptr [rip + sessions + VEC_len], 0
    jne 2f
    lea rdi, [rip + g_face_small]
    mov esi, [rsp]
    add esi, [rip + g_mt + 4*MI_16]
    mov edx, [rsp + 4]
    add edx, r15d
    M ecx, MI_24
    lea r8, [rip + .Lnone]
    cmp qword ptr [rip + g_project], 0
    jne 11f
    lea r8, [rip + .Lnoproj]
11: COLOR r9d, T_UI_MUTED
    call ui_text_c
    jmp .Lld_ret
2:  mov eax, [rsp + 4]
    add eax, r15d
    mov [rsp + 16], eax         # list y
    mov eax, [rsp + 12]
    sub eax, r15d
    mov [rsp + 20], eax         # list h
    mov edi, [rsp]
    mov esi, [rsp + 16]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 20]
    call ui_in
    test eax, eax
    jz 3f
    mov eax, [rip + g_scroll_y]
    add [rip + list_scroll], eax
3:  M ebx, MI_48
    add ebx, [rip + g_mt + 4*MI_8]      # row h
    mov rax, [rip + sessions + VEC_len]
    imul eax, ebx
    sub eax, [rsp + 20]
    jns 31f
    xor eax, eax
31: cmp [rip + list_scroll], eax
    jle 32f
    mov [rip + list_scroll], eax
32: cmp dword ptr [rip + list_scroll], 0
    jge 33f
    mov dword ptr [rip + list_scroll], 0
33: mov edi, [rsp]
    mov esi, [rsp + 16]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 20]
    call gfx_clip_push
    xor r12d, r12d
    mov r13d, [rsp + 16]
    sub r13d, [rip + list_scroll]
.Lld_row:
    cmp r12, [rip + sessions + VEC_len]
    jae .Lld_rows_done
    mov eax, [rsp + 16]
    add eax, [rsp + 20]
    cmp r13d, eax
    jge .Lld_rows_done
    mov eax, r13d
    add eax, ebx
    cmp eax, [rsp + 16]
    jl .Lld_next
    mov rax, [rip + sessions + VEC_ptr]
    mov r14, [rax + r12*8]
    lea edi, [r12 + ID_AG_ROW]
    mov esi, [rsp]
    mov edx, r13d
    mov ecx, [rsp + 8]
    mov r8d, ebx
    call ui_btn
    mov [rsp + 24], eax
    test eax, UB_HOVER
    jz 4f
    M eax, MI_6
    mov edi, [rsp]
    add edi, eax
    mov esi, r13d
    add esi, [rip + g_mt + 4*MI_2]
    mov edx, [rsp + 8]
    sub edx, eax
    sub edx, eax
    mov ecx, ebx
    sub ecx, [rip + g_mt + 4*MI_4]
    M r8d, MI_RADIUS
    COLOR r9d, T_HOVER
    call gfx_round_rect
4:  # status dot
    M ecx, MI_8
    mov edi, [rsp]
    add edi, [rip + g_mt + 4*MI_16]
    mov esi, r13d
    add esi, [rip + g_mt + 4*MI_16]
    mov edx, ecx
    mov r8d, ecx
    shr r8d, 1
    COLOR r9d, T_BORDER
    push rdi
    push rsi
    mov rdi, r14
    call is_live
    pop rsi
    pop rdi
    test eax, eax
    jz 5f
    COLOR r9d, T_SUCCESS
5:  mov ecx, edx
    call gfx_round_rect
    # title
    mov r8, [r14 + AS_title]
    test r8, r8
    jnz 6f
    lea r8, [rip + .Luntitled]
6:  mov [rsp + 32], r8
    mov rdi, r8
    call strlen
    mov r9, rax
    lea rdi, [rip + g_face_ui]
    mov esi, [rsp]
    add esi, [rip + g_mt + 4*MI_32]
    mov edx, r13d
    add edx, [rip + g_mt + 4*MI_6]
    M ecx, MI_24
    mov r8, [rsp + 32]
    COLOR r10d, T_UI_FG
    mov r11d, [rsp + 8]
    sub r11d, [rip + g_mt + 4*MI_48]
    push r11
    push r10
    call ui_text_v_fit
    add rsp, 16
    # meta line: agent · time
    lea rdi, [rip + tmp]
    call sb_clear
    lea rsi, [rip + .Lclaude_name]
    cmp dword ptr [r14 + AS_kind], 2
    jne 7f
    lea rsi, [rip + .Lcodex_name]
7:  lea rdi, [rip + tmp]
    call sb_push_cstr
    lea rdi, [rip + tmp]
    lea rsi, [rip + .Ldot]
    call sb_push_cstr
    mov rdi, [r14 + AS_mtime]
    call rel_time
    lea rdi, [rip + tmp]
    lea rsi, [rip + buf]
    call sb_push_cstr
    mov rdi, r14
    call is_live
    test eax, eax
    jz 8f
    lea rdi, [rip + tmp]
    lea rsi, [rip + .Llive]
    call sb_push_cstr
8:  lea rdi, [rip + g_face_small]
    mov esi, [rsp]
    add esi, [rip + g_mt + 4*MI_32]
    mov edx, r13d
    add edx, [rip + g_mt + 4*MI_28]
    M ecx, MI_20
    mov r8, [rip + tmp + SB_ptr]
    mov r9, [rip + tmp + SB_len]
    COLOR eax, T_UI_MUTED
    push rax
    push rax
    call ui_text_v
    add rsp, 16
    test dword ptr [rsp + 24], UB_CLICK
    jz .Lld_next
    mov rdi, r12
    call open_session
    mov dword ptr [rip + g_focus], FOCUS_AGENTS
.Lld_next:
    add r13d, ebx
    inc r12
    jmp .Lld_row
.Lld_rows_done:
    call gfx_clip_pop
.Lld_ret:
    EPILOGUE

thread_draw:
    PROLOGUE 176
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    mov rax, [rip + view]
    mov rcx, [rip + sessions + VEC_ptr]
    mov rbx, [rcx + rax*8]      # session
    # header: back + title
    M r15d, MI_40
    M r12d, MI_28
    mov edi, ID_AG_BACK
    mov esi, [rsp]
    add esi, [rip + g_mt + 4*MI_8]
    mov edx, r15d
    sub edx, r12d
    sar edx, 1
    add edx, [rsp + 4]
    mov ecx, r12d
    mov r8d, r12d
    mov r9d, IC_BACK
    call ui_icon_btn
    test eax, UB_CLICK
    jz 1f
    mov qword ptr [rip + view], -1
    mov dword ptr [rip + g_dirty], 1
    jmp .Ltd_ret
1:  mov r8, [rbx + AS_title]
    test r8, r8
    jnz 2f
    lea r8, [rip + .Luntitled]
2:  mov [rsp + 16], r8
    mov rdi, r8
    call strlen
    mov r9, rax
    lea rdi, [rip + g_face_ui]
    mov esi, [rsp]
    add esi, [rip + g_mt + 4*MI_40]
    mov edx, [rsp + 4]
    mov ecx, r15d
    mov r8, [rsp + 16]
    COLOR r10d, T_UI_FG
    mov r11d, [rsp + 8]
    sub r11d, [rip + g_mt + 4*MI_64]
    push r11
    push r10
    call ui_text_v_fit
    add rsp, 16
    mov rdi, rbx
    call is_live
    test eax, eax
    jz 3f
    M ecx, MI_8
    mov edi, [rsp]
    add edi, [rsp + 8]
    sub edi, [rip + g_mt + 4*MI_16]
    mov esi, r15d
    sub esi, ecx
    sar esi, 1
    add esi, [rsp + 4]
    mov edx, ecx
    mov r8d, ecx
    shr r8d, 1
    COLOR r9d, T_SUCCESS
    call gfx_round_rect
3:  mov edi, [rsp]
    mov esi, [rsp + 4]
    add esi, r15d
    dec esi
    mov edx, [rsp + 8]
    M ecx, MI_1
    COLOR r8d, T_BORDER
    call gfx_fill
    # message area
    mov eax, [rsp + 4]
    add eax, r15d
    mov [rsp + 20], eax         # area y
    mov eax, [rsp + 12]
    sub eax, r15d
    mov [rsp + 24], eax         # area h
    M eax, MI_16
    mov [rsp + 28], eax         # pad
    mov eax, [rsp + 8]
    sub eax, [rsp + 28]
    sub eax, [rsp + 28]
    sub eax, [rip + g_mt + 4*MI_24]
    mov [rsp + 32], eax         # text width
    # total height
    xor r13d, r13d
    xor r12d, r12d
4:  cmp r12, [rbx + AS_msgs + VEC_len]
    jae 5f
    imul rdi, r12, AM_SIZE
    add rdi, [rbx + AS_msgs + VEC_ptr]
    mov esi, [rsp + 32]
    call msg_height
    add r13d, eax
    add r13d, [rip + g_mt + 4*MI_8]
    inc r12
    jmp 4b
5:  add r13d, [rip + g_mt + 4*MI_32]
    mov [rip + th_content], r13d
    # scrolling / follow
    mov edi, [rsp]
    mov esi, [rsp + 20]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 24]
    call ui_in
    test eax, eax
    jz 6f
    mov eax, [rip + g_scroll_y]
    test eax, eax
    jz 6f
    add [rip + th_scroll], eax
    mov dword ptr [rip + th_follow], 0
6:  mov eax, r13d
    sub eax, [rsp + 24]
    jns 61f
    xor eax, eax
61: mov [rsp + 36], eax         # max scroll
    cmp dword ptr [rip + th_follow], 0
    je 62f
    mov [rip + th_scroll], eax
62: cmp [rip + th_scroll], eax
    jl 63f
    mov [rip + th_scroll], eax
    mov dword ptr [rip + th_follow], 1
63: cmp dword ptr [rip + th_scroll], 0
    jge 64f
    mov dword ptr [rip + th_scroll], 0
64: mov edi, [rsp]
    mov esi, [rsp + 20]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 24]
    call gfx_clip_push
    cmp qword ptr [rbx + AS_msgs + VEC_len], 0
    jne 65f
    lea rdi, [rip + g_face_small]
    mov esi, [rsp]
    add esi, [rsp + 28]
    mov edx, [rsp + 20]
    add edx, [rip + g_mt + 4*MI_8]
    M ecx, MI_24
    lea r8, [rip + .Lempty_thread]
    COLOR r9d, T_UI_MUTED
    call ui_text_c
65: # messages
    mov r13d, [rsp + 20]
    add r13d, [rip + g_mt + 4*MI_12]
    sub r13d, [rip + th_scroll]
    xor r12d, r12d
.Ltd_msg:
    cmp r12, [rbx + AS_msgs + VEC_len]
    jae .Ltd_msgs_done
    mov eax, [rsp + 20]
    add eax, [rsp + 24]
    cmp r13d, eax
    jge .Ltd_msgs_done
    imul r14, r12, AM_SIZE
    add r14, [rbx + AS_msgs + VEC_ptr]
    mov rdi, r14
    mov esi, [rsp + 32]
    call msg_height
    mov r15d, eax
    mov eax, r13d
    add eax, r15d
    cmp eax, [rsp + 20]
    jl .Ltd_next
    mov rdi, r14
    mov esi, r13d
    mov edx, r15d
    lea rcx, [rsp]
    call draw_msg
.Ltd_next:
    add r13d, r15d
    add r13d, [rip + g_mt + 4*MI_8]
    inc r12
    jmp .Ltd_msg
.Ltd_msgs_done:
    call gfx_clip_pop
    # scrollbar
    mov eax, [rsp + 24]
    push rax
    mov eax, [rip + th_content]
    push rax
    mov edi, ID_AG_TSCROLL
    mov esi, [rsp + 16]
    add esi, [rsp + 16 + 8]
    M eax, MI_12
    sub esi, eax
    mov edx, [rsp + 16 + 20]
    mov ecx, eax
    mov r8d, [rsp + 16 + 24]
    lea r9, [rip + th_scroll]
    call ui_scrollbar
    add rsp, 16
    cmp dword ptr [rip + g_active], ID_AG_TSCROLL
    jne 7f
    mov dword ptr [rip + th_follow], 0
    mov eax, [rip + th_scroll]
    cmp eax, [rsp + 36]
    jl 7f
    mov dword ptr [rip + th_follow], 1
7:  # jump-to-latest button when not following
    cmp dword ptr [rip + th_follow], 0
    jne .Ltd_ret
    M r12d, MI_32
    mov esi, [rsp]
    add esi, [rsp + 8]
    sub esi, r12d
    sub esi, [rip + g_mt + 4*MI_20]
    mov edx, [rsp + 20]
    add edx, [rsp + 24]
    sub edx, r12d
    sub edx, [rip + g_mt + 4*MI_16]
    mov [rsp + 40], esi
    mov [rsp + 44], edx
    mov edi, esi
    mov esi, edx
    mov edx, r12d
    mov ecx, r12d
    call ui_card
    mov edi, ID_AG_FOLLOW
    mov esi, [rsp + 40]
    mov edx, [rsp + 44]
    mov ecx, r12d
    mov r8d, r12d
    mov r9d, IC_ARROW_DN
    call ui_icon_btn
    test eax, UB_CLICK
    jz .Ltd_ret
    mov dword ptr [rip + th_follow], 1
    mov dword ptr [rip + g_dirty], 1
.Ltd_ret:
    EPILOGUE

# draw_msg(msg, y, h, frame*) ; frame: x at [0], w at [8], pad [28], text width [32]
draw_msg:
    PROLOGUE 112
    mov rbx, rdi
    mov r12d, esi               # y
    mov r13d, edx               # h
    mov r14, rcx                # frame
    mov r15d, [r14]
    add r15d, [r14 + 28]        # left
    mov eax, [rbx + AM_role]
    cmp eax, R_TOOL
    je .Ldm_tool
    cmp eax, R_RESULT
    je .Ldm_result
    # user / assistant: label line + wrapped text
    cmp eax, R_USER
    jne 1f
    # user bubble
    mov edi, r15d
    sub edi, [rip + g_mt + 4*MI_8]
    mov esi, r12d
    mov edx, [r14 + 32]
    add edx, [rip + g_mt + 4*MI_16]
    mov ecx, r13d
    sub ecx, [rip + g_mt + 4*MI_4]
    M r8d, MI_RADIUS
    COLOR r9d, T_HOVER
    call gfx_round_rect
    lea r8, [rip + .Lyou]
    COLOR r9d, T_UI_MUTED
    jmp 2f
1:  lea r8, [rip + .Lagent]
    COLOR r9d, T_ACCENT
2:  lea rdi, [rip + g_face_small]
    mov esi, r15d
    mov edx, r12d
    add edx, [rip + g_mt + 4*MI_4]
    M ecx, MI_20
    call ui_text_c
    lea rdi, [rsp]
    push r12
    push r12
    mov r12d, [r14 + 32]
    call wr_setup
    pop r12
    pop r12
    mov [rsp + WR_x], r15d
    mov eax, r12d
    add eax, [rip + g_mt + 4*MI_28]
    mov [rsp + WR_y], eax
    COLOR eax, T_UI_FG
    mov [rsp + WR_color], eax
    mov dword ptr [rsp + WR_draw], 1
    mov eax, [rip + g_cv + CV_cy0]
    mov [rsp + WR_top], eax
    mov eax, [rip + g_cv + CV_cy1]
    mov [rsp + WR_bot], eax
    lea rdi, [rsp]
    call wrap
    EPILOGUE
.Ldm_tool:
    M ecx, MI_16
    mov edi, IC_TERMINAL
    mov esi, r15d
    mov edx, r13d
    sub edx, ecx
    sar edx, 1
    add edx, r12d
    COLOR r8d, T_UI_MUTED
    call icon_draw
    mov r8, [rbx + AM_name]
    test r8, r8
    jz 3f
    lea rdi, [rip + g_face_small]
    mov esi, r15d
    add esi, [rip + g_mt + 4*MI_24]
    mov edx, r12d
    mov ecx, r13d
    COLOR r9d, T_UI_FG
    call ui_text_c
    mov [rsp + 96], eax
    jmp 4f
3:  mov eax, r15d
    add eax, [rip + g_mt + 4*MI_24]
    mov [rsp + 96], eax
4:  mov r9, [rbx + AM_len]
    test r9, r9
    jz 5f
    # first line of the summary
    mov rax, [rbx + AM_text]
    xor ecx, ecx
41: cmp rcx, r9
    jae 42f
    cmp byte ptr [rax + rcx], 10
    je 42f
    inc rcx
    jmp 41b
42: mov r9, rcx
    lea rdi, [rip + g_face_small]
    mov esi, [rsp + 96]
    add esi, [rip + g_mt + 4*MI_8]
    mov edx, r12d
    mov ecx, r13d
    mov r8, [rbx + AM_text]
    COLOR r10d, T_UI_MUTED
    mov r11d, [r14]
    add r11d, [r14 + 8]
    sub r11d, esi
    sub r11d, [rip + g_mt + 4*MI_24]
    push r11
    push r10
    call ui_text_v_fit
    add rsp, 16
5:  EPILOGUE
.Ldm_result:
    mov edi, r15d
    mov esi, r12d
    mov edx, [r14 + 32]
    mov ecx, r13d
    sub ecx, [rip + g_mt + 4*MI_8]
    M r8d, MI_4
    COLOR r9d, T_BG
    call gfx_round_rect
    mov edi, r15d
    mov esi, r12d
    M edx, MI_2
    mov ecx, r13d
    sub ecx, [rip + g_mt + 4*MI_8]
    COLOR r8d, T_BORDER
    call gfx_fill
    lea rdi, [rsp]
    push r12
    push r12
    mov r12d, [r14 + 32]
    sub r12d, [rip + g_mt + 4*MI_16]
    call wr_setup
    pop r12
    pop r12
    mov eax, r15d
    add eax, [rip + g_mt + 4*MI_10]
    mov [rsp + WR_x], eax
    mov eax, r12d
    add eax, [rip + g_mt + 4*MI_6]
    mov [rsp + WR_y], eax
    COLOR eax, T_MUTED
    mov [rsp + WR_color], eax
    mov dword ptr [rsp + WR_draw], 1
    mov eax, [rip + g_cv + CV_cy0]
    mov [rsp + WR_top], eax
    mov eax, [rip + g_cv + CV_cy1]
    mov [rsp + WR_bot], eax
    lea rdi, [rsp]
    call wrap
    EPILOGUE

.section .rodata
.Lhome: .asciz "HOME"
.Lr0: .asciz "?"
.Lr1: .asciz "user"
.Lr2: .asciz "agent"
.Lr3: .asciz "tool"
.Lr4: .asciz "result"
.p2align 3
role_names: .quad .Lr0, .Lr1, .Lr2, .Lr3, .Lr4
.Lclaude_projects: .asciz "/.claude/projects/"
.Lcodex_sessions: .asciz "/.codex/sessions"
.Ljsonl: .ascii ".jsonl"
.Lclaude: .asciz "claude"
.Lcodex: .asciz "codex"
.Lheader: .asciz "AGENTS"
.Lnone: .asciz "No agent sessions for this project yet"
.Lnoproj: .asciz "Open a folder to see its agent sessions"
.Luntitled: .asciz "Untitled session"
.Lempty_thread: .asciz "Nothing here yet"
.Lclaude_name: .asciz "Claude Code"
.Lcodex_name: .asciz "Codex"
.Ldot: .asciz "  \302\267  "
.Llive: .asciz "  \302\267  live"
.Lnow: .asciz "just now"
.Lago: .asciz " ago"
.Lyou: .asciz "You"
.Lagent: .asciz "Agent"
.Lempty: .asciz ""
.Ltool: .asciz "tool"
.Ltype: .asciz "type"
.Ltext: .asciz "text"
.Luser: .asciz "user"
.Lassistant: .asciz "assistant"
.Lmessage: .asciz "message"
.Lcontent: .asciz "content"
.Lcustom_title: .asciz "custom-title"
.LcustomTitle: .asciz "customTitle"
.LisMeta: .asciz "isMeta"
.Ltool_result: .asciz "tool_result"
.Ltool_use: .asciz "tool_use"
.Lname: .asciz "name"
.Linput: .asciz "input"
.Lpayload: .asciz "payload"
.Lcwd: .asciz "cwd"
.Lrole: .asciz "role"
.Lfunction_call: .asciz "function_call"
.Lcustom_tool_call: .asciz "custom_tool_call"
.Lfunction_call_output: .asciz "function_call_output"
.Lcustom_tool_call_output: .asciz "custom_tool_call_output"
.Larguments: .asciz "arguments"
.Loutput: .asciz "output"
.Ls_command: .asciz "command"
.Ls_file_path: .asciz "file_path"
.Ls_path: .asciz "path"
.Ls_pattern: .asciz "pattern"
.Ls_url: .asciz "url"
.Ls_description: .asciz "description"
.Ls_prompt: .asciz "prompt"
.Ls_query: .asciz "query"
.p2align 3
summary_keys:
    .quad .Ls_command, .Ls_file_path, .Ls_path, .Ls_pattern, .Ls_url, .Ls_description
    .quad .Ls_prompt, .Ls_query, 0

.data
view: .quad -1
th_follow: .long 1
