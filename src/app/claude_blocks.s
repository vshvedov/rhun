# Claude Code's records into a conversation's rows: the content blocks of the stream's records and of the
# lines of a conversation's file, the tool table, results and their texts, a part's whole text from a record
# read again, a subagent's file, special user texts, system records, tasks. The only reader that knows
# Claude's tools and record shapes; the rows it makes are the generic ones of agentrows.s (agrow_*) and
# agents.s (agents_row_add, agents_reply_add, agents_row_flag). agent_drv.s reaches it through its reader
# table (readers), by AS_kind, with or without a driver.
#
#   claude_ingest(AS*, record jv, ING_*) -> eax 1 taken     a record of the stream (ING_LIVE) or a line of the
#                                                           file (ING_FILE); 0: the caller reads it itself
#   claude_text(AS*, AT*, ATX_IN..ATX_B, record jv, sb) -> eax 1   that part's whole text from its record read
#                                                           again, when the record is that call's
#   claude_kids(AS*, AT*) -> eax 1                          its subagent's calls, from their file
#   claude_seen(AL*, record jv) -> eax 1                    the stream gave a record of this uuid before
#                                                           (finding 30: after a compaction it may send a
#                                                           preserved record again): it is dropped
#
# One mapping for the stream and the file (README.txt findings 27 to 37): only user, assistant and system
# records are read, by their type (a file's api-request-blob lines hold copies of messages); a message is a
# record (a line) a content block, and nothing here assumes it; a result goes into its call's row (found by
# id), whenever it comes; the names that differ between the stream and the file are both read
# (tool_use_result / toolUseResult). The tool table follows the extension's renderers (webview index.js of
# 2.1.328, the classes from @5217542 to @5270821): each tool has an input filler (when its call is read) and
# a result filler (when its result is). A filler writes a part through put, which in claude_text's mode
# writes only the part asked for, whole, into the caller's buffer: the row and its tab come from the same
# code. A call's AT_aux is this file's own: the tool's name, and after a space what its result needs later
# (an agent's id, the count of a question's questions); a name starting with "*" is a call drawn in the
# generic form (its input is not as recorded).
.include "rhun.inc"

.equ CR_TASKS_MAX, 200          # the conversation's tasks (TaskCreate, TaskUpdate), in AS_rdata
.equ CRT_ID, 0                  #   cstr, 15 bytes at most
.equ CRT_SUBJ, 16               #   cstr, cut at 119 bytes
.equ CRT_STATE, 136             #   TODO_*
.equ CRT_SIZE, 144
.equ CR_N, 0                    # AS_rdata: the tasks in use, then the tasks
.equ CR_TASKS, 8
.equ CR_SIZE, 28808             # CR_TASKS + CRT_SIZE * CR_TASKS_MAX
.equ SEEN_FIRST, 64             # claude_seen's table: first slots (doubled at half full)
.equ REASON_MAX, 2000           # U7: a rejection's reason longer than this is an OUT, not a note
.equ CUT_KEY, 40                # an MCP call's second text: characters, then "…" (a URL's host: 30)
.equ CUT_URL, 30

.data
.p2align 2
tm_which: .long -1              # claude_text's part (-1: rows are being made)
.bss
.p2align 3
cb_as: .quad 0                  # the conversation being read
cb_at: .quad 0                  # the call a filler fills
tm_sb: .quad 0                  # claude_text's buffer
tm_hit: .long 0                 # claude_text's part was written
tm_pad: .long 0
cb_err: .long 0                 # the result read is an error
cb_str: .long 0                 #   its content is a string
cb_flags: .long 0               # the record's ING_*
cb_pad: .long 0
rtext: .zero SB_SIZE            # a result's text (the extension's toOutputContent)
t1: .zero SB_SIZE               # scratch
t2: .zero SB_SIZE
t3: .zero SB_SIZE

.text

# ---------------- small helpers ----------------

# jstr(obj, key cstr) -> rax ptr, rdx len of a string member (0, 0 otherwise)
jstr:
    push rbx
    call json_get
    mov rdi, rax
    call json_str
    pop rbx
    ret

# jtrue(obj, key cstr) -> eax 1 when the member is true
jtrue:
    push rbx
    call json_get
    mov rdi, rax
    call json_type
    xor ecx, ecx
    cmp eax, JT_TRUE
    sete cl
    mov eax, ecx
    pop rbx
    ret

# put(ATX_*, ptr, len): a part of the call being filled (cb_at); in claude_text's mode only the part asked
#   for, into its buffer
put:
    mov eax, [rip + tm_which]
    test eax, eax
    js 1f
    cmp eax, edi
    jne 9f
    mov dword ptr [rip + tm_hit], 1
    test rdx, rdx
    jz 9f
    mov rdi, [rip + tm_sb]
    jmp sb_push
1:  mov eax, edi
    mov rdi, [rip + cb_at]
    mov rcx, rdx
    mov rdx, rsi
    mov esi, eax
    jmp agrow_set
9:  ret

# put_c(ATX_*, cstr)
put_c:
    push rbx
    push rdi
    push rsi
    mov rdi, rsi
    call strlen
    mov rdx, rax
    pop rsi
    pop rdi
    pop rbx
    jmp put

# put_sb(ATX_*, SB*)
put_sb:
    mov rdx, [rsi + SB_len]
    mov rsi, [rsi + SB_ptr]
    jmp put

# num(ATV_*, value): the call's state, flags, lines or count (nothing in claude_text's mode)
num:
    cmp dword ptr [rip + tm_which], 0
    jge 9f
    mov edx, esi
    mov esi, edi
    mov rdi, [rip + cb_at]
    jmp agrow_num
9:  ret

# state(ATS_*)
state:
    mov esi, edi
    mov edi, ATV_STATE
    jmp num

# flag(ATF_*): flags on
flag:
    mov esi, edi
    mov edi, ATV_SET
    jmp num

# making() -> eax 1 when rows are being made (not claude_text's mode)
making:
    xor eax, eax
    cmp dword ptr [rip + tm_which], 0
    setl al
    ret

# base(ptr, len) -> rax, rdx the last component of a path (after the last "/")
base:
    mov rax, rdi
    mov rdx, rsi
    mov rcx, rsi
1:  test rcx, rcx
    jz 9f
    cmp byte ptr [rdi + rcx - 1], '/'
    je 2f
    dec rcx
    jmp 1b
2:  lea rax, [rdi + rcx]
    sub rdx, rcx
9:  ret

# nlines(ptr, len) -> eax the lines a text splits into at its line feeds ("" is one)
nlines:
    mov eax, 1
    xor ecx, ecx
1:  cmp rcx, rsi
    jae 9f
    cmp byte ptr [rdi + rcx], 10
    jne 2f
    inc eax
2:  inc rcx
    jmp 1b
9:  ret

# starts(ptr, len, cstr) -> eax 1 when the text begins with the cstr
starts:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, rdx
    call strlen
    mov rcx, rax
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call str_starts
    EPILOGUE

# ends(ptr, len, cstr) -> eax 1 when the text ends with the cstr, edx its length
ends:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, rdx
    call strlen
    mov r14, rax
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    mov rcx, r14
    call str_ends
    mov rdx, r14
    EPILOGUE

# has(ptr, len, cstr) -> eax 1 when the text holds the cstr
has:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, rdx
    call strlen
    mov rcx, rax
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call str_find
    xor ecx, ecx
    test rax, rax
    setns cl
    mov eax, ecx
    EPILOGUE

# text_is(ptr, len, cstr) -> eax 1 when the text is the cstr
text_is:
    jmp str_eq_cstr

# isws(byte) -> eax 1 for a blank, a TAB, CR or LF
isws:
    xor eax, eax
    cmp dil, ' '
    je 1f
    cmp dil, 9
    jb 9f
    cmp dil, 13
    ja 9f
1:  mov eax, 1
9:  ret

# trim(ptr, len) -> rax, rdx without blanks around it
trim_ws:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
1:  test r12, r12
    jz 8f
    movzx edi, byte ptr [rbx]
    call isws
    test eax, eax
    jz 2f
    inc rbx
    dec r12
    jmp 1b
2:  movzx edi, byte ptr [rbx + r12 - 1]
    call isws
    test eax, eax
    jz 8f
    dec r12
    jnz 2b
8:  mov rax, rbx
    mov rdx, r12
    EPILOGUE

# plural(sb, n, word cstr): "N WORD" and an "s" unless N is 1
plural:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    mov esi, r12d
    call sb_push_u64
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rdi, rbx
    mov rsi, r13
    call sb_push_cstr
    cmp r12d, 1
    je 9f
    mov rdi, rbx
    mov esi, 's'
    call sb_push_byte
9:  EPILOGUE

# cut_chars(sb, ptr, len, n): the text, its first n characters and "…" when it has more
cut_chars:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14d, ecx
    xor ecx, ecx
    xor edx, edx
1:  cmp rcx, r13
    jae 8f
    movzx eax, byte ptr [r12 + rcx]
    and eax, 0xc0
    cmp eax, 0x80
    je 2f
    cmp edx, r14d
    je 3f
    inc edx
2:  inc rcx
    jmp 1b
3:  mov rdi, rbx
    mov rsi, r12
    mov rdx, rcx
    call sb_push
    mov rdi, rbx
    lea rsi, [rip + .Lellipsis]
    call sb_push_cstr
    EPILOGUE
8:  mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call sb_push
    EPILOGUE

# aux_name(AT*) -> rax, rdx the tool's name kept in AT_aux (up to its first blank), 0, 0 when none
aux_name:
    mov rax, [rdi + AT_aux]
    xor edx, edx
    test rax, rax
    jz 9f
1:  cmp byte ptr [rax + rdx], 0
    je 9f
    cmp byte ptr [rax + rdx], ' '
    je 9f
    inc rdx
    jmp 1b
9:  ret

# aux_more(AT*) -> rax, rdx what AT_aux holds after its first blank, 0, 0 when nothing
aux_more:
    PROLOGUE
    mov rbx, rdi
    call aux_name
    test rax, rax
    jz 8f
    cmp byte ptr [rax + rdx], ' '
    jne 8f
    lea rbx, [rax + rdx + 1]
    mov rdi, rbx
    call strlen
    mov rdx, rax
    mov rax, rbx
    EPILOGUE
8:  xor eax, eax
    xor edx, edx
    EPILOGUE

# aux_set(name ptr, len, more ptr, len): AT_aux of the call being filled: the name and, when given, a blank
#   and more (nothing in claude_text's mode)
aux_set:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    call making
    test eax, eax
    jz 9f
    lea rdi, [rip + t3]
    call sb_clear
    lea rdi, [rip + t3]
    mov rsi, rbx
    mov rdx, r12
    call sb_push
    test r14, r14
    jz 1f
    lea rdi, [rip + t3]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + t3]
    mov rsi, r13
    mov rdx, r14
    call sb_push
1:  mov rdi, [rip + cb_at]
    mov esi, ATX_AUX
    mov rdx, [rip + t3 + SB_ptr]
    mov rcx, [rip + t3 + SB_len]
    call agrow_set
9:  EPILOGUE

# ---------------- records sent twice (finding 30) ----------------

# FN claude_seen(AL*, record jv) -> eax 1 when the stream gave a record of this uuid since its program started
#   (the record is dropped); else its uuid is noted. The table (AL_dseen: slots, used, then the hashes of the
#   uuids, 0 empty) is the driver's own and goes with the live record
FN claude_seen
    PROLOGUE
    mov rbx, rdi
    mov rdi, rsi
    lea rsi, [rip + .Lk_uuid]
    call jstr
    test rdx, rdx
    jz 8f
    mov rdi, rax
    mov rsi, rdx
    call hash_line
    cmp rax, 1
    ja 1f
    add rax, 2
1:  mov r12, rax
    mov r13, [rbx + AL_dseen]
    test r13, r13
    jnz 2f
    mov edi, 8 + 8 * SEEN_FIRST
    call mem_alloc
    mov dword ptr [rax], SEEN_FIRST
    mov [rbx + AL_dseen], rax
    mov r13, rax
2:  mov r14d, [r13]
    lea r15, [r14 - 1]
    mov rcx, r12
    and rcx, r15
3:  mov rax, [r13 + 8 + rcx*8]
    test rax, rax
    jz 4f
    cmp rax, r12
    je 7f
    inc rcx
    and rcx, r15
    jmp 3b
4:  mov [r13 + 8 + rcx*8], r12
    inc dword ptr [r13 + 4]
    mov eax, [r13 + 4]
    add eax, eax
    cmp eax, r14d
    jbe 8f
    mov rdi, rbx                # past half full: twice the slots
    call seen_grow
8:  xor eax, eax
    EPILOGUE
7:  mov eax, 1
    EPILOGUE

# seen_grow(AL*): claude_seen's table with twice the slots
seen_grow:
    PROLOGUE
    mov rbx, rdi
    mov r12, [rbx + AL_dseen]
    mov r13d, [r12]
    lea eax, [r13 + r13]
    mov r14d, eax
    lea rdi, [rax*8 + 8]
    call mem_alloc
    mov [rax], r14d
    mov ecx, [r12 + 4]
    mov [rax + 4], ecx
    mov [rbx + AL_dseen], rax
    lea r15, [r14 - 1]
    xor ecx, ecx
1:  cmp ecx, r13d
    jae 8f
    mov rdx, [r12 + 8 + rcx*8]
    test rdx, rdx
    jz 3f
    mov r8, rdx
    and r8, r15
2:  cmp qword ptr [rax + 8 + r8*8], 0
    je 21f
    inc r8
    and r8, r15
    jmp 2b
21: mov [rax + 8 + r8*8], rdx
3:  inc ecx
    jmp 1b
8:  mov rdi, r12
    call mem_free
    EPILOGUE

# ---------------- records ----------------

# FN claude_ingest(AS*, record jv, ING_*) -> eax 1: a record of the stream (ING_LIVE: the driver made the
#   reply's text rows and the user's own prompts itself) or a line of the file (ING_FILE) into rows. Only
#   user, assistant and system records are read, by their type; every other type is taken and left (a file's
#   api-request-blob lines copy whole messages: read, they would double every call; the others are
#   bookkeeping). A file's line of a subagent (isSidechain) is skipped (2.1.330 writes them into the agent's
#   own file); a record that ran under a call (the stream's parent_tool_use_id) gives only its calls and
#   results, as children
FN claude_ingest
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov [rip + cb_as], rbx
    mov [rip + cb_flags], r13d
    mov dword ptr [rip + tm_which], -1
    mov rdi, r12
    lea rsi, [rip + .Lk_isSidechain]
    call jtrue
    test eax, eax
    jnz 9f
    mov rdi, r12
    lea rsi, [rip + .Lk_type]
    call json_get
    mov r14, rax
    mov rdi, r14
    lea rsi, [rip + .Lv_assistant]
    call json_is
    test eax, eax
    jz 1f
    mov rdi, rbx
    mov rsi, r12
    call ing_assistant
    jmp 9f
1:  mov rdi, r14
    lea rsi, [rip + .Lv_user]
    call json_is
    test eax, eax
    jz 9f
    mov rdi, rbx
    mov rsi, r12
    call ing_user
9:  mov eax, 1                  # system records: their rows come with the next tasks
    EPILOGUE

# ing_assistant(AS*, record): its content blocks: text (a reply row, read from a file only), tool_use (a
#   call), thinking (not shown yet), any other type (an unknown block's row); under a call only the calls
ing_assistant:
    PROLOGUE 48
    mov rbx, rdi
    mov r12, rsi
    mov rdi, r12                # the call it ran under, when it did
    lea rsi, [rip + .Lk_parent]
    call jstr
    mov [rsp], rax
    mov [rsp + 8], rdx
    mov rdi, r12
    lea rsi, [rip + .Lk_message]
    call json_get
    mov r13, rax
    mov rdi, r13
    lea rsi, [rip + .Lk_model]
    call jstr
    xor ecx, ecx                # Claude Code's own notices ("<synthetic>") are no model's replies
    test rdx, rdx
    jz 1f
    cmp byte ptr [rax], '<'
    sete cl
1:  mov [rsp + 16], ecx
    mov rdi, r13
    lea rsi, [rip + .Lk_content]
    call json_get
    mov r13, rax
    xor r14d, r14d
2:  mov rdi, r13
    call json_len
    cmp r14d, eax
    jae 9f
    mov rdi, r13
    mov esi, r14d
    call json_at
    mov r15, rax
    inc r14d
    mov rdi, r15
    lea rsi, [rip + .Lk_type]
    call json_get
    mov [rsp + 24], rax
    mov rdi, rax
    lea rsi, [rip + .Lv_tool_use]
    call json_is
    test eax, eax
    jz 3f
    mov rdi, rbx
    mov rsi, r15
    mov rdx, [rsp]
    mov rcx, [rsp + 8]
    call call_block
    jmp 2b
3:  cmp qword ptr [rsp + 8], 0  # a subagent's text and thinking are not shown
    jne 2b
    mov rdi, [rsp + 24]
    lea rsi, [rip + .Lv_text]
    call json_is
    test eax, eax
    jz 4f
    cmp dword ptr [rip + cb_flags], ING_FILE
    jne 2b
    mov rdi, r15
    lea rsi, [rip + .Lv_text]
    call jstr
    mov rdi, rbx
    mov rsi, rax
    mov ecx, [rsp + 16]
    call agents_reply_add
    jmp 2b
4:  mov rdi, [rsp + 24]         # thinking: its own rows come with task 6
    lea rsi, [rip + .Lv_thinking]
    call json_is
    test eax, eax
    jnz 2b
    mov rdi, [rsp + 24]
    lea rsi, [rip + .Lv_redacted]
    call json_is
    test eax, eax
    jnz 2b
    mov rdi, [rsp + 24]         # any other block: "Unsupported content type: TYPE"
    call json_str
    test rdx, rdx
    jz 2b
    mov rdi, rbx
    mov esi, R_UNKNOWN
    mov rcx, rdx
    mov rdx, rax
    xor r8d, r8d
    call agents_row_add
    jmp 2b
9:  EPILOGUE

# ing_user(AS*, record): the results of calls into their rows (found by id); from a file also the user's
#   prompts (a prompt stops the calls of the turn before it that still wait), the interrupt marks, nothing
#   of a meta line or of a text that begins with "<" (commands, notifications: their rows come with task 8)
ing_user:
    PROLOGUE 48
    mov rbx, rdi
    mov r12, rsi
    mov rdi, r12
    lea rsi, [rip + .Lk_isMeta]
    call jtrue
    test eax, eax
    jnz 9f
    mov rdi, r12
    lea rsi, [rip + .Lk_parent]
    call jstr
    mov [rsp], rdx              # under a call: its results only
    mov rdi, r12                # the structured result: the stream's name, the file's name
    lea rsi, [rip + .Lk_tur]
    call json_get
    test rax, rax
    jnz 1f
    mov rdi, r12
    lea rsi, [rip + .Lk_turFile]
    call json_get
1:  mov [rsp + 8], rax
    mov rdi, r12
    lea rsi, [rip + .Lk_message]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lk_content]
    call json_get
    mov r13, rax
    mov rdi, r13
    call json_type
    cmp eax, JT_STR
    jne 3f
    cmp qword ptr [rsp], 0      # a prompt as a string
    jne 9f
    cmp dword ptr [rip + cb_flags], ING_FILE
    jne 9f
    mov rdi, rbx
    call agrow_stop
    mov rdi, r13
    call json_str
    mov rdi, rbx
    mov rsi, rax
    call user_text
    jmp 9f
3:  mov dword ptr [rsp + 16], 0 # a prompt's blocks: the waiting calls stopped once
    xor r14d, r14d
4:  mov rdi, r13
    call json_len
    cmp r14d, eax
    jae 9f
    mov rdi, r13
    mov esi, r14d
    call json_at
    mov r15, rax
    inc r14d
    mov rdi, r15
    lea rsi, [rip + .Lk_type]
    call json_get
    mov [rsp + 24], rax
    mov rdi, rax
    lea rsi, [rip + .Lv_tool_result]
    call json_is
    test eax, eax
    jz 5f
    mov rdi, rbx
    mov rsi, r15
    mov rdx, [rsp + 8]
    call result_block
    jmp 4b
5:  cmp qword ptr [rsp], 0
    jne 4b
    cmp dword ptr [rip + cb_flags], ING_FILE
    jne 4b
    cmp dword ptr [rsp + 16], 0
    jne 6f
    mov dword ptr [rsp + 16], 1
    mov rdi, rbx
    call agrow_stop
6:  mov rdi, [rsp + 24]
    lea rsi, [rip + .Lv_text]
    call json_is
    test eax, eax
    jz 4b
    mov rdi, r15
    lea rsi, [rip + .Lv_text]
    call jstr
    mov rdi, rbx
    mov rsi, rax
    call user_text
    jmp 4b
9:  EPILOGUE

# user_text(AS*, ptr, len): a text of the user's read from a file: an interrupt mark is the "Interrupted"
#   row (as the stream's turn end gives it), one beginning with "<" no row, any other a prompt row
user_text:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    test r13, r13
    jz 9f
    cmp byte ptr [r12], '<'
    je 9f
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lmark_stop]
    call text_is
    test eax, eax
    jnz 1f
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lmark_tool]
    call text_is
    test eax, eax
    jnz 1f
    mov rdi, rbx
    mov esi, R_USER
    mov rdx, r12
    mov rcx, r13
    xor r8d, r8d
    call agents_row_add
    EPILOGUE
1:  mov rdi, rbx
    mov esi, R_INFO
    lea rdx, [rip + .Linterrupted]
    mov ecx, 11
    xor r8d, r8d
    call agents_row_add
9:  EPILOGUE

# call_block(AS*, block, parent id ptr, len): a tool_use block: its call (a row, or a child of the call it
#   ran under), its parts by its tool's input filler, its one-line summary and name for print-agents
call_block:
    PROLOGUE 32
    mov rbx, rdi
    mov r12, rsi
    mov [rsp], rdx
    mov [rsp + 8], rcx
    mov rdi, r12
    lea rsi, [rip + .Lk_id]
    call jstr
    mov rdi, rbx
    mov rsi, rax
    mov rdx, rdx
    mov rcx, [rsp]
    mov r8, [rsp + 8]
    call agrow_tool
    test rax, rax
    jz 9f                       # past the limits: counted only
    mov r13, rax
    mov [rip + cb_at], rax
    mov rdi, r12
    lea rsi, [rip + .Lk_name]
    call jstr
    mov r14, rax
    mov r15, rdx
    mov rdi, rax
    mov rsi, rdx
    xor edx, edx
    xor ecx, ecx
    call aux_set
    mov rdi, r12
    lea rsi, [rip + .Lk_input]
    call json_get
    mov [rsp + 16], rax
    mov rdi, r14
    mov rsi, r15
    call tool_of
    mov rdi, [rsp + 16]
    mov rsi, r14
    mov rdx, r15
    call [rax + 8]              # its input filler
    cmp qword ptr [r13 + AT_up], 0
    jne 8f
    mov rdi, [rsp + 16]         # print-agents: "tool(NAME) SUMMARY"
    call agents_tool_summary
    mov rdi, rbx
    mov rsi, r13
    mov rcx, rdx
    mov rdx, rax
    call agrow_summary
    test r15, r15
    jz 8f
    mov rdi, rbx
    mov rsi, r13
    mov rdx, r14
    mov rcx, r15
    call agrow_tag
8:  mov rdi, rbx
    mov rsi, r13
    call agrow_ready
9:  EPILOGUE

# result_block(AS*, block, structured jv or 0): a tool_result block into its call's row: its result filler,
#   then the call is done. A result for a call nobody saw (or without an id) is dropped
result_block:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov [rsp], rdx
    mov rdi, r12
    lea rsi, [rip + .Lk_tool_use_id]
    call jstr
    test rdx, rdx
    jz 9f
    mov rdi, rbx
    mov rsi, rax
    call agrow_find
    test rax, rax
    jz 9f
    mov r13, rax
    mov [rip + cb_at], rax
    mov rdi, r12
    mov rsi, [rsp]
    call fill_result
    mov rdi, rbx
    mov rsi, r13
    call agrow_done
9:  EPILOGUE

# fill_result(block, structured): the result's text and error read (rtext, cb_err, cb_str), then the call's
#   tool's result filler (by the name AT_aux keeps)
fill_result:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rbx
    lea rsi, [rip + .Lk_is_error]
    call jtrue
    mov [rip + cb_err], eax
    mov rdi, rbx
    call result_text
    mov rdi, [rip + cb_at]
    call aux_name
    mov rdi, rax
    mov rsi, rdx
    call tool_of
    mov rdi, rbx
    mov rsi, r12
    call [rax + 16]
    EPILOGUE

# result_text(block): rtext, the result's text as the extension reads it (a string, or the text parts joined
#   by line feeds; an image part gives nothing); cb_str 1 for a string
result_text:
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rip + rtext]
    call sb_clear
    mov rdi, rbx
    lea rsi, [rip + .Lk_content]
    call json_get
    mov r12, rax
    mov rdi, r12
    call json_type
    mov dword ptr [rip + cb_str], 0
    cmp eax, JT_STR
    jne 1f
    mov dword ptr [rip + cb_str], 1
    mov rdi, r12
    call json_str
    lea rdi, [rip + rtext]
    mov rsi, rax
    call sb_push
    EPILOGUE
1:  xor r13d, r13d
2:  mov rdi, r12
    call json_len
    cmp r13d, eax
    jae 9f
    mov rdi, r12
    mov esi, r13d
    call json_at
    mov r14, rax
    inc r13d
    mov rdi, r14
    lea rsi, [rip + .Lk_type]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lv_text]
    call json_is
    test eax, eax
    jz 2b
    mov rdi, r14
    lea rsi, [rip + .Lv_text]
    call jstr
    test rdx, rdx
    jz 2b
    mov r14, rax
    mov r15, rdx
    cmp qword ptr [rip + rtext + SB_len], 0
    je 3f
    lea rdi, [rip + rtext]
    mov esi, 10
    call sb_push_byte
3:  lea rdi, [rip + rtext]
    mov rsi, r14
    mov rdx, r15
    call sb_push
    jmp 2b
9:  EPILOGUE

# FN claude_text(AS*, AT*, ATX_IN..ATX_B, record jv, sb) -> eax 1: that part's whole text from its record
#   read again: IN, A and B from the call's record (a tool_use block with the call's id), OUT from its
#   result's (a tool_result block for that id), by the same fillers that made the row. 0: the record is
#   not that call's, or it gives no such part
FN claude_text
    PROLOGUE 16
    mov [rip + cb_as], rdi
    mov [rip + cb_at], rsi
    mov r12, rsi
    mov r13d, edx
    mov r14, rcx
    mov [rip + tm_sb], r8
    mov dword ptr [rip + tm_hit], 0
    mov rdi, r14
    lea rsi, [rip + .Lk_message]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lk_content]
    call json_get
    mov r15, rax
    xor ebx, ebx
1:  mov rdi, r15
    call json_len
    cmp ebx, eax
    jae 9f
    mov rdi, r15
    mov esi, ebx
    call json_at
    mov [rsp], rax
    inc ebx
    mov rdi, rax                # the block that names the call
    lea rsi, [rip + .Lk_id]
    cmp r13d, ATX_OUT
    jne 2f
    lea rsi, [rip + .Lk_tool_use_id]
2:  call jstr
    test rdx, rdx
    jz 1b
    mov rdi, rax
    mov rsi, rdx
    mov rdx, [r12 + AT_id]
    call text_is
    test eax, eax
    jz 1b
    mov [rip + tm_which], r13d
    cmp r13d, ATX_OUT
    jne 3f
    mov rdi, r14                # the result: its filler, with the structured result of its record
    lea rsi, [rip + .Lk_tur]
    call json_get
    test rax, rax
    jnz 21f
    mov rdi, r14
    lea rsi, [rip + .Lk_turFile]
    call json_get
21: mov rsi, rax
    mov rdi, [rsp]
    call fill_result
    jmp 8f
3:  mov rdi, [rsp]              # the call: its input filler
    lea rsi, [rip + .Lk_name]
    call jstr
    mov [rsp + 8], rdx
    mov rbx, rax
    mov rdi, r12                # the form the row was made in (a generic one is named "*NAME")
    call aux_name
    test rdx, rdx
    jz 31f
    cmp byte ptr [rax], '*'
    jne 31f
    mov rdi, rax
    mov rsi, rdx
    jmp 32f
31: mov rdi, rbx
    mov rsi, [rsp + 8]
32: call tool_of
    mov r15, rax
    mov rdi, [rsp]
    lea rsi, [rip + .Lk_input]
    call json_get
    mov rdi, rax
    mov rsi, rbx
    mov rdx, [rsp + 8]
    call [r15 + 8]
8:  mov dword ptr [rip + tm_which], -1
    mov eax, [rip + tm_hit]
    EPILOGUE
9:  xor eax, eax
    EPILOGUE

# FN claude_kids(AS*, AT*) -> eax 0: no children read yet (phase 3 task 11)
FN claude_kids
    xor eax, eax
    ret

# ---------------- the tool table ----------------

# tool_of(name ptr, len) -> rax its entry {name, input filler, result filler}: names are matched whole, only
#   "mcp__" is a prefix; any other name, the generic one
tool_of:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    lea rbx, [rip + tools]
    test r13, r13
    jz 8f
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lmcp]
    call starts
    test eax, eax
    jz 1f
    lea rax, [rip + tool_mcp]
    EPILOGUE
1:  mov rdx, [rbx]
    test rdx, rdx
    jz 8f
    mov rdi, r12
    mov rsi, r13
    call text_is
    test eax, eax
    jnz 9f
    add rbx, 24
    jmp 1b
8:  lea rbx, [rip + tool_generic]
9:  mov rax, rbx
    EPILOGUE

# ---------------- input fillers (input jv, name ptr, len) ----------------

# in_generic: the tool's name; IN the input as JSON (JSON.stringify(input, null, 2)) when it has members
in_generic:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    cmp byte ptr [r12], '*'     # (a call of a known tool in the generic form keeps its name with a "*")
    jne 1f
    test r13, r13
    jz 1f
    inc r12
    dec r13
    mov rdi, r12
    mov rsi, r13
    call tool_star
1:  mov edi, ATX_NAME
    mov rsi, r12
    mov rdx, r13
    call put
    mov rdi, rbx
    call in_json
    EPILOGUE

# tool_star(name ptr, len): AT_aux names the generic form ("*NAME")
tool_star:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea rdi, [rip + t2]
    call sb_clear
    lea rdi, [rip + t2]
    mov esi, '*'
    call sb_push_byte
    lea rdi, [rip + t2]
    mov rsi, rbx
    mov rdx, r12
    call sb_push
    mov rdi, [rip + t2 + SB_ptr]
    mov rsi, [rip + t2 + SB_len]
    xor edx, edx
    xor ecx, ecx
    call aux_set
    EPILOGUE

# generic_as(input, name ptr, len): a known tool whose input is not as recorded, in the generic form
generic_as:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, r12
    mov rsi, r13
    call tool_star
    mov edi, ATX_NAME
    mov rsi, r12
    mov rdx, r13
    call put
    mov rdi, rbx
    call in_json
    EPILOGUE

# in_json(input): IN the input as JSON with two-space indents, when it is an object with members or a
#   value that is not an object
in_json:
    PROLOGUE
    mov rbx, rdi
    test rbx, rbx
    jz 9f
    mov rdi, rbx
    call json_type
    cmp eax, JT_NULL
    je 9f
    cmp eax, JT_OBJ
    jne 1f
    mov rdi, rbx
    call json_npairs
    test eax, eax
    jz 9f
1:  lea rdi, [rip + t1]
    call sb_clear
    lea rdi, [rip + t1]
    mov rsi, rbx
    call json_pretty
    mov edi, ATX_IN
    lea rsi, [rip + t1]
    call put_sb
9:  EPILOGUE

# in_none: nothing of the input but the name (AgentOutputTool)
in_name:
    mov edi, ATX_NAME
    jmp put

# file_head(input, name cstr, key cstr, find key cstr or 0): "NAME" and the path's last component, a link to
#   the path (its find text the input's member of that key); without a path "NAME" and "file"
file_head:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rdx
    mov [rsp], rcx
    mov edi, ATX_NAME
    call put_c
    mov rdi, rbx
    mov rsi, r12
    call jstr
    mov r13, rax
    mov r14, rdx
    test rdx, rdx
    jnz 1f
    mov edi, ATX_SECOND
    lea rsi, [rip + .Lfile]
    call put_c
    EPILOGUE
1:  mov rdi, r13
    mov rsi, r14
    call base
    mov edi, ATX_SECOND
    mov rsi, rax
    call put
    mov edi, ATX_LINK
    mov rsi, r13
    mov rdx, r14
    call put
    mov rsi, [rsp]
    test rsi, rsi
    jz 9f
    mov rdi, rbx
    call jstr
    mov edi, ATX_FIND
    mov rsi, rax
    call put
9:  EPILOGUE

# in_bash: the name; the description; IN the command (a Copy button)
in_bash:
    PROLOGUE
    mov rbx, rdi
    mov edi, ATX_NAME
    call put
    mov rdi, rbx
    lea rsi, [rip + .Lk_description]
    call jstr
    mov edi, ATX_SECOND
    mov rsi, rax
    call put
    mov rdi, rbx
    lea rsi, [rip + .Lk_command]
    call jstr
    mov edi, ATX_IN
    mov rsi, rax
    call put
    mov edi, ATF_SHELL
    call flag
    EPILOGUE

# lines_tail(sb, input): " (lines A-B)" with offset and limit, " (from line A)" with offset alone (the
#   tail, without its blank); the link's lines
lines_tail:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov rdi, r12
    lea rsi, [rip + .Lk_offset]
    call json_get
    mov rdi, rax
    call json_int
    mov r13, rax
    mov r15d, edx               # offset given
    mov rdi, r12
    lea rsi, [rip + .Lk_limit]
    call json_get
    mov rdi, rax
    call json_int
    mov r14, rax
    mov [rsp], edx              # limit given
    test r15d, r15d
    jz 5f
    lea rdi, [r13 + 1]
    mov [rsp + 4], edi
    cmp dword ptr [rsp], 0
    je 2f
    mov rdi, rbx
    lea rsi, [rip + .Llines]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rsp + 4]
    call sb_push_u64
    mov rdi, rbx
    mov esi, '-'
    call sb_push_byte
    lea rsi, [r13 + r14]
    mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    mov esi, ')'
    call sb_push_byte
    jmp 4f
2:  mov rdi, rbx
    lea rsi, [rip + .Lfrom_line]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rsp + 4]
    call sb_push_u64
    mov rdi, rbx
    mov esi, ')'
    call sb_push_byte
4:  mov edi, ATV_L0
    mov esi, [rsp + 4]
    call num
5:  cmp dword ptr [rsp], 0      # the lines the link opens at: offset + 1 (or 1) to offset + limit
    je 9f
    test r14, r14
    jle 9f
    mov eax, r13d
    test r15d, r15d
    jnz 6f
    xor eax, eax
    mov edi, ATV_L0
    mov esi, 1
    push rax
    push rax
    call num
    pop rax
    pop rax
6:  lea rsi, [rax + r14]
    mov edi, ATV_L1
    call num
9:  EPILOGUE

# in_read: "Read", the file (a link at its lines), the lines read
in_read:
    PROLOGUE
    mov rbx, rdi
    mov rdi, rbx
    lea rsi, [rip + .Lk_file_path]
    call jstr
    test rdx, rdx
    jnz 1f
    mov edi, ATX_NAME
    lea rsi, [rip + .Ln_read]
    call put_c
    EPILOGUE
1:  mov rdi, rbx
    lea rsi, [rip + .Ln_read]
    lea rdx, [rip + .Lk_file_path]
    xor ecx, ecx
    call file_head
    lea rdi, [rip + t1]
    call sb_clear
    lea rdi, [rip + t1]
    mov rsi, rbx
    call lines_tail
    mov edi, ATX_TAIL
    lea rsi, [rip + t1]
    call put_sb
    EPILOGUE

# in_coalesced: "Read" and the files' names, ", " between (the first a link)
in_coalesced:
    PROLOGUE
    mov rdi, rdi
    lea rsi, [rip + .Lk_fileReads]
    call json_get
    mov rbx, rax
    mov edi, ATX_NAME
    lea rsi, [rip + .Ln_read]
    call put_c
    lea rdi, [rip + t1]
    call sb_clear
    xor r12d, r12d
1:  mov rdi, rbx
    call json_len
    cmp r12d, eax
    jae 8f
    mov rdi, rbx
    mov esi, r12d
    call json_at
    mov rdi, rax
    lea rsi, [rip + .Lk_file_path]
    call jstr
    inc r12d
    test rdx, rdx
    jz 1b
    mov r13, rax
    mov r14, rdx
    cmp qword ptr [rip + t1 + SB_len], 0
    jne 2f
    mov edi, ATX_LINK
    mov rsi, r13
    call put
    jmp 3f
2:  lea rdi, [rip + t1]
    lea rsi, [rip + .Lcomma]
    call sb_push_cstr
3:  mov rdi, r13
    mov rsi, r14
    call base
    lea rdi, [rip + t1]
    mov rsi, rax
    call sb_push
    jmp 1b
8:  mov edi, ATX_SECOND
    lea rsi, [rip + t1]
    call put_sb
    EPILOGUE

# in_edit: "Edit", the file (a link that looks for the new text), the note by the line counts, the diff of
#   old_string to new_string
in_edit:
    PROLOGUE 16
    mov rbx, rdi
    lea rsi, [rip + .Ln_edit]
    lea rdx, [rip + .Lk_file_path]
    lea rcx, [rip + .Lk_new_string]
    call file_head
    mov rdi, rbx
    lea rsi, [rip + .Lk_old_string]
    call jstr
    mov r12, rax
    mov r13, rdx
    mov rdi, rbx
    lea rsi, [rip + .Lk_new_string]
    call jstr
    mov r14, rax
    mov r15, rdx
    mov edi, ATX_A
    mov rsi, r12
    mov rdx, r13
    call put
    mov edi, ATX_B
    mov rsi, r14
    mov rdx, r15
    call put
    mov edi, ATF_DIFF
    call flag
    mov rdi, r12                # "Added N lines" / "Removed N lines" / "Modified"
    mov rsi, r13
    call nlines
    mov [rsp], eax
    mov rdi, r14
    mov rsi, r15
    call nlines
    lea rdi, [rip + t1]
    push rax
    push rax
    call sb_clear
    pop rax
    pop rax
    sub eax, [rsp]
    jle 1f
    lea rdi, [rip + t1]
    lea rsi, [rip + .Ladded]
    push rax
    push rax
    call sb_push_cstr
    pop rsi
    pop rax
    lea rdi, [rip + t1]
    lea rdx, [rip + .Lline]
    call plural
    jmp 3f
1:  jz 2f
    neg eax
    lea rdi, [rip + t1]
    lea rsi, [rip + .Lremoved]
    push rax
    push rax
    call sb_push_cstr
    pop rsi
    pop rax
    lea rdi, [rip + t1]
    lea rdx, [rip + .Lline]
    call plural
    jmp 3f
2:  lea rdi, [rip + t1]
    lea rsi, [rip + .Lmodified]
    call sb_push_cstr
3:  mov edi, ATX_NOTE
    lea rsi, [rip + t1]
    call put_sb
    EPILOGUE

# in_write: "Write", the file (a link), the note ("N lines", "Write succeeded" when the content is no
#   string), the file's text under it (its tab "Write NAME")
in_write:
    PROLOGUE
    mov rbx, rdi
    lea rsi, [rip + .Ln_write]
    lea rdx, [rip + .Lk_file_path]
    xor ecx, ecx
    call file_head
    lea rdi, [rip + t1]         # the title
    call sb_clear
    lea rdi, [rip + t1]
    lea rsi, [rip + .Lwrite_sp]
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Lk_file_path]
    call jstr
    mov rdi, rax
    mov rsi, rdx
    call base
    test rdx, rdx
    jnz 1f
    lea rax, [rip + .Lfile]
    mov edx, 4
1:  lea rdi, [rip + t1]
    mov rsi, rax
    call sb_push
    mov edi, ATX_TITLE
    lea rsi, [rip + t1]
    call put_sb
    mov rdi, rbx
    lea rsi, [rip + .Lk_content]
    call json_get
    mov r12, rax
    lea rdi, [rip + t1]
    call sb_clear
    mov rdi, r12
    call json_type
    cmp eax, JT_STR
    je 2f
    lea rdi, [rip + t1]
    lea rsi, [rip + .Lwrite_ok]
    call sb_push_cstr
    mov edi, ATX_NOTE
    lea rsi, [rip + t1]
    call put_sb
    test r12, r12
    jz 9f
    lea rdi, [rip + t1]
    call sb_clear
    lea rdi, [rip + t1]
    mov rsi, r12
    call json_pretty
    jmp 3f
2:  mov rdi, r12
    call json_str
    mov r13, rax
    mov r14, rdx
    mov rdi, rax
    mov rsi, rdx
    call nlines
    lea rdi, [rip + t1]
    mov esi, eax
    lea rdx, [rip + .Lline]
    call plural
    mov edi, ATX_NOTE
    lea rsi, [rip + t1]
    call put_sb
    lea rdi, [rip + t1]
    call sb_clear
    lea rdi, [rip + t1]
    mov rsi, r13
    mov rdx, r14
    call sb_push
3:  mov edi, ATX_B
    lea rsi, [rip + t1]
    call put_sb
    mov edi, ATF_PRE
    call flag
9:  EPILOGUE

# in_notebook: "Edit Notebook Cell", the notebook (and ":CELL"), a link; "Pending"; the cell's new source,
#   "[No content]" without one (no recording: the bundle's form, @5261274)
in_notebook:
    PROLOGUE
    mov rbx, rdi
    mov edi, ATX_NAME
    lea rsi, [rip + .Ln_cell]
    call put_c
    mov rdi, rbx
    lea rsi, [rip + .Lk_notebook_path]
    call jstr
    test rdx, rdx
    jz 2f
    mov r12, rax
    mov r13, rdx
    mov edi, ATX_LINK
    mov rsi, rax
    call put
    lea rdi, [rip + t1]
    call sb_clear
    mov rdi, r12
    mov rsi, r13
    call base
    lea rdi, [rip + t1]
    mov rsi, rax
    call sb_push
    mov rdi, rbx
    lea rsi, [rip + .Lk_cell_id]
    call jstr
    test rdx, rdx
    jz 1f
    mov r12, rax
    mov r13, rdx
    lea rdi, [rip + t1]
    mov esi, ':'
    call sb_push_byte
    lea rdi, [rip + t1]
    mov rsi, r12
    mov rdx, r13
    call sb_push
1:  mov edi, ATX_SECOND
    lea rsi, [rip + t1]
    call put_sb
2:  mov edi, ATX_NOTE
    lea rsi, [rip + .Lpending]
    call put_c
    mov rdi, rbx
    lea rsi, [rip + .Lk_new_source]
    call jstr
    test rdx, rdx
    jnz 3f
    lea rax, [rip + .Lno_content]
    mov edx, 12
3:  mov edi, ATX_B
    mov rsi, rax
    call put
    mov edi, ATF_PRE
    call flag
    EPILOGUE

# quoted(sb, prefix cstr, input, key cstr): PREFIX"VALUE" (the value as given; "…" without one)
quoted:
    PROLOGUE
    mov rbx, rdi
    mov r12, rdx
    mov r13, rcx
    call sb_push_cstr
    mov rdi, rbx
    mov esi, '"'
    call sb_push_byte
    mov rdi, r12
    mov rsi, r13
    call jstr
    mov rdi, rbx
    mov rsi, rax
    call sb_push
    mov rdi, rbx
    mov esi, '"'
    call sb_push_byte
    EPILOGUE

# in_glob: "Glob", pattern: "P"
in_glob:
    PROLOGUE
    mov rbx, rdi
    mov edi, ATX_NAME
    lea rsi, [rip + .Ln_glob]
    call put_c
    jmp in_pattern

# in_search: "Search", pattern: "P", and IN the input as JSON (the bundle's class draws the generic body)
in_search:
    PROLOGUE
    mov rbx, rdi
    mov edi, ATX_NAME
    lea rsi, [rip + .Ln_search]
    call put_c
    mov rdi, rbx
    call in_json
in_pattern:
    lea rdi, [rip + t1]
    call sb_clear
    lea rdi, [rip + t1]
    lea rsi, [rip + .Lpattern]
    mov rdx, rbx
    lea rcx, [rip + .Lk_pattern]
    call quoted
    mov edi, ATX_SECOND
    lea rsi, [rip + t1]
    call put_sb
    EPILOGUE

# in_grep: "Grep", "P", and the tail " (in PATH, glob: G, type: T)" with those that are set
in_grep:
    PROLOGUE
    mov rbx, rdi
    mov edi, ATX_NAME
    lea rsi, [rip + .Ln_grep]
    call put_c
    lea rdi, [rip + t1]
    call sb_clear
    lea rdi, [rip + t1]
    lea rsi, [rip + .Lempty]
    mov rdx, rbx
    lea rcx, [rip + .Lk_pattern]
    call quoted
    mov edi, ATX_SECOND
    lea rsi, [rip + t1]
    call put_sb
    lea rdi, [rip + t1]
    call sb_clear
    xor r12d, r12d
    lea r13, [rip + grep_keys]
1:  mov rsi, [r13]
    test rsi, rsi
    jz 5f
    mov rdi, rbx
    call jstr
    test rdx, rdx
    jz 4f
    mov r14, rax
    mov r15, rdx
    lea rdi, [rip + t1]
    lea rsi, [rip + .Lcomma]
    test r12d, r12d
    jnz 2f
    lea rsi, [rip + .Lparen]
2:  call sb_push_cstr
    inc r12d
    lea rdi, [rip + t1]
    mov rsi, [r13 + 8]
    call sb_push_cstr
    lea rdi, [rip + t1]
    mov rsi, r14
    mov rdx, r15
    call sb_push
4:  add r13, 16
    jmp 1b
5:  test r12d, r12d
    jz 9f
    lea rdi, [rip + t1]
    mov esi, ')'
    call sb_push_byte
    mov edi, ATX_TAIL
    lea rsi, [rip + t1]
    call put_sb
9:  EPILOGUE

# web_link(url ptr, len): the header's link when it is an http(s) URL
web_link:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea rdx, [rip + .Lhttps]
    call starts
    test eax, eax
    jnz 1f
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lhttp]
    call starts
    test eax, eax
    jz 9f
1:  mov edi, ATX_LINK
    mov rsi, rbx
    mov rdx, r12
    call put
9:  EPILOGUE

# in_fetch: "Web Fetch", the URL (a link)
in_fetch:
    PROLOGUE
    mov rbx, rdi
    mov edi, ATX_NAME
    lea rsi, [rip + .Ln_fetch]
    call put_c
    mov rdi, rbx
    lea rsi, [rip + .Lk_url]
    call jstr
    mov r12, rax
    mov r13, rdx
    mov edi, ATX_SECOND
    mov rsi, rax
    call put
    mov rdi, r12
    mov rsi, r13
    call web_link
    EPILOGUE

# domains(sb, input, key cstr, label cstr): "LABEL: a, b" when the member is a list with strings
domains:
    PROLOGUE
    mov rbx, rdi
    mov r12, rcx
    mov rdi, rsi
    mov rsi, rdx
    call json_get
    mov r13, rax
    xor r14d, r14d
    xor r15d, r15d              # written
1:  mov rdi, r13
    call json_len
    cmp r14d, eax
    jae 9f
    mov rdi, r13
    mov esi, r14d
    call json_at
    mov rdi, rax
    call json_str
    inc r14d
    test rdx, rdx
    jz 1b
    push rax
    push rdx
    test r15d, r15d
    jnz 2f
    cmp qword ptr [rbx + SB_len], 0
    je 3f
    mov rdi, rbx
    lea rsi, [rip + .Lmiddot]
    call sb_push_cstr
3:  mov rdi, rbx
    mov rsi, r12
    call sb_push_cstr
    jmp 4f
2:  mov rdi, rbx
    lea rsi, [rip + .Lcomma]
    call sb_push_cstr
4:  pop rdx
    pop rsi
    mov rdi, rbx
    call sb_push
    inc r15d
    jmp 1b
9:  EPILOGUE

# in_websearch: "Web Search", the query; "Allowed: a, b · Blocked: c"
in_websearch:
    PROLOGUE
    mov rbx, rdi
    mov edi, ATX_NAME
    lea rsi, [rip + .Ln_websearch]
    call put_c
    mov rdi, rbx
    lea rsi, [rip + .Lk_query]
    call jstr
    mov edi, ATX_SECOND
    mov rsi, rax
    call put
    lea rdi, [rip + t1]
    call sb_clear
    lea rdi, [rip + t1]
    mov rsi, rbx
    lea rdx, [rip + .Lk_allowed]
    lea rcx, [rip + .Lallowed]
    call domains
    lea rdi, [rip + t1]
    mov rsi, rbx
    lea rdx, [rip + .Lk_blocked]
    lea rcx, [rip + .Lblocked]
    call domains
    mov edi, ATX_DESC
    lea rsi, [rip + t1]
    call put_sb
    EPILOGUE

# in_agent: "Agent:", the description; IN the prompt (its tab "Agent tool input"); it may get children
in_agent:
    PROLOGUE
    mov rbx, rdi
    mov edi, ATX_NAME
    lea rsi, [rip + .Ln_agent]
    call put_c
    mov rdi, rbx
    lea rsi, [rip + .Lk_description]
    call jstr
    mov edi, ATX_SECOND
    mov rsi, rax
    call put
    mov rdi, rbx
    lea rsi, [rip + .Lk_prompt]
    call jstr
    mov edi, ATX_IN
    mov rsi, rax
    call put
    mov edi, ATX_TITLE
    lea rsi, [rip + .Lagent_input]
    call put_c
    mov edi, ATF_PARENT
    call flag
    EPILOGUE

# in_todo: "Update Todos" and an item per todos entry; a todos that is not a list: the generic form
in_todo:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, rbx
    lea rsi, [rip + .Lk_todos]
    call json_get
    mov r14, rax
    mov rdi, rax
    call json_type
    cmp eax, JT_ARR
    je 1f
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call generic_as
    EPILOGUE
1:  mov edi, ATX_NAME
    lea rsi, [rip + .Ln_todos]
    call put_c
    call making
    test eax, eax
    jz 9f
    xor r15d, r15d
2:  mov rdi, r14
    call json_len
    cmp r15d, eax
    jae 9f
    mov rdi, r14
    mov esi, r15d
    call json_at
    inc r15d
    mov rbx, rax
    mov rdi, rax
    lea rsi, [rip + .Lk_content]
    call jstr
    test rdx, rdx
    jz 2b
    mov r12, rax
    mov r13, rdx
    mov rdi, rbx
    lea rsi, [rip + .Lk_status]
    call json_get
    mov rdi, rax
    call todo_state
    mov ecx, eax
    mov rdi, [rip + cb_at]
    mov rsi, r12
    mov rdx, r13
    call agrow_item
    jmp 2b
9:  EPILOGUE

# todo_state(status jv) -> eax TODO_*: completed done, in_progress active, anything else pending; -1 for
#   "deleted"
todo_state:
    PROLOGUE
    mov rbx, rdi
    lea rsi, [rip + .Lv_completed]
    call json_is
    test eax, eax
    jz 1f
    mov eax, TODO_DONE
    EPILOGUE
1:  mov rdi, rbx
    lea rsi, [rip + .Lv_in_progress]
    call json_is
    test eax, eax
    jz 2f
    mov eax, TODO_ACTIVE
    EPILOGUE
2:  mov rdi, rbx
    lea rsi, [rip + .Lv_deleted]
    call json_is
    test eax, eax
    jz 3f
    mov eax, -1
    EPILOGUE
3:  mov eax, TODO_PENDING
    EPILOGUE

# in_task_create: "Update Todos" when the input has a subject (the list comes with its result); else generic
in_task_create:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, rbx
    lea rsi, [rip + .Lk_subject]
    call jstr
    test rdx, rdx
    jnz 1f
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call generic_as
    EPILOGUE
1:  mov edi, ATX_NAME
    lea rsi, [rip + .Ln_todos]
    call put_c
    EPILOGUE

# in_task_update: "Update Todos" when the input names a task of the conversation and a status; else generic
in_task_update:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, rbx
    lea rsi, [rip + .Lk_status]
    call jstr
    test rdx, rdx
    jz 8f
    mov rdi, rbx
    lea rsi, [rip + .Lk_taskId]
    call jstr
    test rdx, rdx
    jz 8f
    mov rdi, rax
    mov rsi, rdx
    call task_find
    test rax, rax
    jz 8f
    mov edi, ATX_NAME
    lea rsi, [rip + .Ln_todos]
    call put_c
    EPILOGUE
8:  mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call generic_as
    EPILOGUE

# in_plan: "Claude’s Plan" and the plan file (a link), "Claude’s Plan" or "Plan Mode" without one; IN the
#   plan, Markdown (its tab a Markdown tab, "Plan")
in_plan:
    PROLOGUE
    mov rbx, rdi
    mov rdi, rbx
    lea rsi, [rip + .Lk_planFilePath]
    call jstr
    test rdx, rdx
    jz 1f
    mov r12, rax
    mov r13, rdx
    mov edi, ATX_NAME
    lea rsi, [rip + .Ln_plan]
    call put_c
    mov rdi, r12
    mov rsi, r13
    call base
    mov edi, ATX_SECOND
    mov rsi, rax
    call put
    mov edi, ATX_LINK
    mov rsi, r12
    mov rdx, r13
    call put
    jmp 2f
1:  mov rdi, rbx
    lea rsi, [rip + .Lk_plan]
    call jstr
    mov edi, ATX_NAME
    lea rsi, [rip + .Ln_plan]
    test rdx, rdx
    jnz 11f
    lea rsi, [rip + .Ln_planmode]
11: call put_c
2:  mov rdi, rbx
    lea rsi, [rip + .Lk_plan]
    call jstr
    test rdx, rdx
    jz 9f
    mov edi, ATX_IN
    mov rsi, rax
    call put
    mov edi, ATX_TITLE
    lea rsi, [rip + .Lplan_title]
    call put_c
    mov edi, ATF_MD
    call flag
9:  EPILOGUE

# in_ask: "Question" / "Questions" by the questions that have a text; their count kept for the result
in_ask:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, rbx
    lea rsi, [rip + .Lk_questions]
    call json_get
    mov r14, rax
    xor r15d, r15d              # questions with a text
    xor ebx, ebx
1:  mov rdi, r14
    call json_len
    cmp ebx, eax
    jae 2f
    mov rdi, r14
    mov esi, ebx
    call json_at
    inc ebx
    mov rdi, rax
    lea rsi, [rip + .Lk_question]
    call jstr
    test rax, rax
    jz 1b
    inc r15d
    jmp 1b
2:  mov edi, ATX_NAME
    lea rsi, [rip + .Ln_questions]
    cmp r15d, 1
    jne 3f
    lea rsi, [rip + .Ln_question]
3:  call put_c
    lea rdi, [rip + t1]
    call sb_clear
    lea rdi, [rip + t1]
    mov esi, r15d
    call sb_push_u64
    mov rdi, r12
    mov rsi, r13
    mov rdx, [rip + t1 + SB_ptr]
    mov rcx, [rip + t1 + SB_len]
    call aux_set
    EPILOGUE

# in_skill: the skill's name (without "/") and "skill" (no recording: the bundle's form, @5265900)
in_skill:
    PROLOGUE
    mov rbx, rdi
    lea rsi, [rip + .Lk_skill]
    call jstr
    test rdx, rdx
    jz 1f
    cmp byte ptr [rax], '/'
    jne 1f
    inc rax
    dec rdx
1:  mov edi, ATX_NAME
    mov rsi, rax
    call put
    mov edi, ATX_SECOND
    lea rsi, [rip + .Lskill]
    call put_c
    EPILOGUE

# in_taskoutput: "TaskOutput", task: "ID"
in_taskoutput:
    PROLOGUE
    mov rbx, rdi
    mov edi, ATX_NAME
    lea rsi, [rip + .Ln_taskoutput]
    call put_c
    mov rdi, rbx
    lea rsi, [rip + .Lk_task_id]
    call jstr
    test rdx, rdx
    jz 9f
    lea rdi, [rip + t1]
    call sb_clear
    lea rdi, [rip + t1]
    lea rsi, [rip + .Ltask_q]
    mov rdx, rbx
    lea rcx, [rip + .Lk_task_id]
    call quoted
    mov edi, ATX_SECOND
    lea rsi, [rip + t1]
    call put_sb
9:  EPILOGUE

# in_toolsearch: a call with no row
in_toolsearch:
    PROLOGUE
    mov edi, ATX_NAME
    call put
    mov edi, ATF_HIDDEN
    call flag
    EPILOGUE

# in_network: "Network Access", the host
in_network:
    PROLOGUE
    mov rbx, rdi
    mov edi, ATX_NAME
    lea rsi, [rip + .Ln_network]
    call put_c
    mov rdi, rbx
    lea rsi, [rip + .Lk_host]
    call jstr
    mov edi, ATX_SECOND
    mov rsi, rax
    call put
    EPILOGUE

# in_project: "Send to project", IN the input as JSON
in_project:
    PROLOGUE
    mov rbx, rdi
    mov edi, ATX_NAME
    lea rsi, [rip + .Ln_project]
    call put_c
    mov rdi, rbx
    call in_json
    EPILOGUE

# in_artifact: "Artifact", the file
in_artifact:
    PROLOGUE
    mov rbx, rdi
    mov edi, ATX_NAME
    lea rsi, [rip + .Ln_artifact]
    call put_c
    mov rdi, rbx
    lea rsi, [rip + .Lk_file_path]
    call jstr
    mov edi, ATX_SECOND
    mov rsi, rax
    call put
    EPILOGUE

# in_sendfile: "Sent" and the files' names, ", " between (the first a link unless it is a URL); the caption
#   (no recording: the bundle's form, @5265176)
in_sendfile:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    lea rdi, [rip + t1]
    call sb_clear
    mov rdi, rbx
    lea rsi, [rip + .Lk_files]
    call json_get
    mov r14, rax
    mov rdi, rax
    call json_type
    cmp eax, JT_STR
    jne 1f
    mov rdi, r14
    call json_str
    mov rdi, rax
    mov rsi, rdx
    call sent_name
    jmp 3f
1:  xor r15d, r15d
2:  mov rdi, r14
    call json_len
    cmp r15d, eax
    jae 3f
    mov rdi, r14
    mov esi, r15d
    call json_at
    inc r15d
    mov rdi, rax
    call json_str
    mov rdi, rax
    mov rsi, rdx
    call sent_name
    jmp 2b
3:  cmp qword ptr [rip + t1 + SB_len], 0
    jne 4f
    mov edi, ATX_NAME
    mov rsi, r12
    mov rdx, r13
    call put
    jmp 5f
4:  mov edi, ATX_NAME
    lea rsi, [rip + .Ln_sent]
    call put_c
    mov edi, ATX_SECOND
    lea rsi, [rip + t1]
    call put_sb
5:  mov rdi, rbx
    lea rsi, [rip + .Lk_caption]
    call jstr
    mov edi, ATX_DESC
    mov rsi, rax
    call put
    EPILOGUE

# sent_name(ptr, len): one of SendUserFile's files into t1 (trimmed; none when blank); the first is the link
sent_name:
    PROLOGUE
    call trim_ws
    test rdx, rdx
    jz 9f
    mov rbx, rax
    mov r12, rdx
    cmp qword ptr [rip + t1 + SB_len], 0
    je 1f
    lea rdi, [rip + t1]
    lea rsi, [rip + .Lcomma]
    call sb_push_cstr
    jmp 2f
1:  mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lscheme]
    call has
    test eax, eax
    jnz 2f
    mov edi, ATX_LINK
    mov rsi, rbx
    mov rdx, r12
    call put
2:  mov rdi, rbx
    mov rsi, r12
    call base
    lea rdi, [rip + t1]
    mov rsi, rax
    call sb_push
9:  EPILOGUE

# in_mcp: an MCP server's tool: "Server Name [tool]" and the first of the input's telling members
in_mcp:
    PROLOGUE
    mov rbx, rdi
    lea r12, [rsi + 5]          # past "mcp__"
    lea r13, [rdx - 5]
    xor ecx, ecx                # the server: up to "__"
1:  lea rax, [rcx + 1]
    cmp rax, r13
    jae 2f
    cmp word ptr [r12 + rcx], 0x5f5f
    je 3f
    inc rcx
    jmp 1b
2:  mov rcx, r13
3:  mov r14, rcx
    lea rdi, [rip + t1]
    call sb_clear
    mov rdi, r12
    mov rsi, r14
    call humanize
    lea rdi, [rip + t1]
    lea rsi, [rip + .Lbra]
    call sb_push_cstr
    lea rax, [r14 + 2]          # the tool: the rest
    cmp rax, r13
    ja 4f
    lea rdi, [rip + t1]
    lea rsi, [r12 + rax]
    mov rdx, r13
    sub rdx, rax
    call sb_push
4:  lea rdi, [rip + t1]
    mov esi, ']'
    call sb_push_byte
    mov edi, ATX_NAME
    lea rsi, [rip + t1]
    call put_sb
    lea rdi, [rip + t1]
    call sb_clear
    lea r12, [rip + mcp_keys]
5:  mov rsi, [r12]
    test rsi, rsi
    jz 9f
    mov rdi, rbx
    call jstr
    test rdx, rdx
    jnz 6f
    add r12, 8
    jmp 5b
6:  mov r13, rax
    mov r14, rdx
    lea rax, [rip + .Lk_channel]
    cmp [r12], rax
    jne 7f
    lea rdi, [rip + t1]
    mov esi, '#'
    call sb_push_byte
    lea rdi, [rip + t1]
    mov rsi, r13
    mov rdx, r14
    call sb_push
    jmp 8f
7:  mov ecx, CUT_KEY
    lea rax, [rip + .Lk_url]
    cmp [r12], rax
    jne 71f
    mov rdi, r13
    mov rsi, r14
    call host_of
    test rax, rax
    jz 70f
    lea rdi, [rip + t1]
    mov rsi, rax
    call sb_push
    jmp 8f
70: mov ecx, CUT_URL
71: lea rdi, [rip + t1]
    mov rsi, r13
    mov rdx, r14
    call cut_chars
8:  mov edi, ATX_SECOND
    lea rsi, [rip + t1]
    call put_sb
9:  EPILOGUE

# humanize(ptr, len): into t1 an MCP server's name as the extension words it: split at "_", each word with a
#   capital first letter and the rest small, GitHub, PubMed and AI kept so, blanks between
humanize:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    xor r13d, r13d              # the word's start
1:  mov r14, r13                # its end
2:  cmp r14, r12
    jae 3f
    cmp byte ptr [rbx + r14], '_'
    je 3f
    inc r14
    jmp 2b
3:  test r13, r13
    jz 31f
    lea rdi, [rip + t1]
    mov esi, ' '
    call sb_push_byte
31: mov r15, [rip + t1 + SB_len]
    mov rcx, r13
4:  cmp rcx, r14
    jae 5f
    movzx esi, byte ptr [rbx + rcx]
    cmp rcx, r13
    jne 41f
    cmp sil, 'a'
    jb 42f
    cmp sil, 'z'
    ja 42f
    sub sil, 32
    jmp 42f
41: cmp sil, 'A'
    jb 42f
    cmp sil, 'Z'
    ja 42f
    add sil, 32
42: mov [rsp], rcx
    lea rdi, [rip + t1]
    call sb_push_byte
    mov rcx, [rsp]
    inc rcx
    jmp 4b
5:  mov rdi, [rip + t1 + SB_ptr]    # the words kept as written
    add rdi, r15
    mov rsi, [rip + t1 + SB_len]
    sub rsi, r15
    mov [rsp], rdi
    mov [rsp + 8], rsi
    lea r8, [rip + human_words]
6:  mov rdx, [r8]
    test rdx, rdx
    jz 7f
    push r8
    push r8
    mov rdi, [rsp + 16]
    mov rsi, [rsp + 24]
    call text_is
    pop r8
    pop r8
    test eax, eax
    jnz 61f
    add r8, 16
    jmp 6b
61: mov [rip + t1 + SB_len], r15
    lea rdi, [rip + t1]
    mov rsi, [r8 + 8]
    call sb_push_cstr
7:  lea r13, [r14 + 1]
    cmp r14, r12
    jb 1b
    EPILOGUE

# host_of(url ptr, len) -> rax, rdx the host of a URL ("SCHEME://[USER@]HOST[:PORT]/..."), small letters, in t2;
#   0 when it is no URL
host_of:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lscheme]
    call has
    test eax, eax
    jz 8f
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lscheme]
    mov ecx, 3
    call str_find
    lea r13, [rax + 3]          # the authority's start
    mov r14, r13
1:  cmp r14, r12
    jae 2f
    movzx eax, byte ptr [rbx + r14]
    cmp al, '/'
    je 2f
    cmp al, '?'
    je 2f
    cmp al, '#'
    je 2f
    cmp al, '@'
    jne 11f
    lea r13, [r14 + 1]
11: inc r14
    jmp 1b
2:  lea rdi, [rip + t2]
    call sb_clear
    mov r15, r13
3:  cmp r15, r14
    jae 4f
    movzx esi, byte ptr [rbx + r15]
    cmp sil, ':'
    je 4f
    cmp sil, 'A'
    jb 31f
    cmp sil, 'Z'
    ja 31f
    add sil, 32
31: lea rdi, [rip + t2]
    call sb_push_byte
    inc r15
    jmp 3b
4:  mov rax, [rip + t2 + SB_ptr]
    mov rdx, [rip + t2 + SB_len]
    test rdx, rdx
    jz 8f
    EPILOGUE
8:  xor eax, eax
    xor edx, edx
    EPILOGUE

# ---------------- result fillers (block, structured jv or 0; rtext, cb_err, cb_str read) ----------------

# rejected() -> eax 1 when the result is a rejection: the plain one (Yb) or one with a reason (Xb)
rejected:
    PROLOGUE
    call text_core
    mov rbx, rax
    mov r12, rdx
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lyb]
    call text_is
    test eax, eax
    jnz 9f
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lxb]
    call starts
9:  EPILOGUE

# text_core() -> rax, rdx rtext without the note the CLI may add to a rejection (dA)
text_core:
    PROLOGUE
    mov rbx, [rip + rtext + SB_ptr]
    mov r12, [rip + rtext + SB_len]
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lda]
    call ends
    test eax, eax
    jz 1f
    sub r12, rdx
1:  mov rax, rbx
    mov rdx, r12
    test rax, rax
    jnz 9f
    lea rax, [rip + .Lempty]
9:  EPILOGUE

# err_state(): the call failed, or was denied (a rejection)
err_state:
    PROLOGUE
    call rejected
    mov edi, ATS_FAILED
    test eax, eax
    jz 1f
    mov edi, ATS_DENIED
1:  call state
    EPILOGUE

# done_state(): ok, or what an error result makes it
done_state:
    cmp dword ptr [rip + cb_err], 0
    jne err_state
    mov edi, ATS_OK
    jmp state

# err_shown() -> rax, rdx (t2) an error's text as the row shows it (the bundle's W7): the CLI's note off, nothing for
#   the standard rejections and interrupts, a rejection's reason without its prefix or the text out of its
#   <tool_use_error> wrapper, the denial's advice off, blanks around it off
err_shown:
    PROLOGUE
    lea rdi, [rip + t2]
    call sb_clear
    call text_core
    mov rbx, rax
    mov r12, rdx
    lea r13, [rip + silent]
1:  mov rdx, [r13]
    test rdx, rdx
    jz 2f
    mov rdi, rbx
    mov rsi, r12
    call text_is
    test eax, eax
    jnz 8f
    add r13, 8
    jmp 1b
2:  mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lxb]
    call starts
    test eax, eax
    jz 3f
    lea rdi, [rip + .Lxb]
    call strlen
    add rbx, rax
    sub r12, rax
    jmp 4f
3:  mov rdi, rbx
    mov rsi, r12
    call unwrap
    mov rbx, rax
    mov r12, rdx
4:  mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lhie]
    call ends
    test eax, eax
    jz 5f
    sub r12, rdx
5:  mov rdi, rbx
    mov rsi, r12
    call trim_ws
    lea rdi, [rip + t2]
    mov rsi, rax
    call sb_push
8:  mov rax, [rip + t2 + SB_ptr]
    mov rdx, [rip + t2 + SB_len]
    EPILOGUE

# unwrap(ptr, len) -> rax, rdx the text inside "<tool_use_error>…</tool_use_error>" (blanks around it
#   allowed) when the inside holds no such tag; else the text as it is
unwrap:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call trim_ws
    mov r13, rax
    mov r14, rdx
    mov rdi, r13
    mov rsi, r14
    lea rdx, [rip + .Ltue_open]
    call starts
    test eax, eax
    jz 8f
    mov rdi, r13
    mov rsi, r14
    lea rdx, [rip + .Ltue_close]
    call ends
    test eax, eax
    jz 8f
    sub r14, rdx
    lea rdi, [rip + .Ltue_open]
    call strlen
    add r13, rax
    sub r14, rax
    js 8f
    mov rdi, r13
    mov rsi, r14
    lea rdx, [rip + .Ltue_tag]
    call has
    test eax, eax
    jnz 8f
    mov rdi, r13
    mov rsi, r14
    lea rdx, [rip + .Ltue_end]
    call has
    test eax, eax
    jnz 8f
    mov rax, r13
    mov rdx, r14
    EPILOGUE
8:  mov rax, rbx
    mov rdx, r12
    EPILOGUE

# reason() -> eax 1 when a rejection gave its reason (the bundle's U7): a string content without
#   <tool_use_error>, not the plain rejection, beginning with the reason's prefix, the reason at most 2000
#   characters (UTF-16 units). The reason is a note, "Reason: R" (the description line when the tool has a
#   note of its own); the call shows no OUT then
reason:
    PROLOGUE
    cmp dword ptr [rip + cb_err], 0
    je 8f
    cmp dword ptr [rip + cb_str], 0
    je 8f
    mov rdi, [rip + rtext + SB_ptr]
    mov rsi, [rip + rtext + SB_len]
    test rdi, rdi
    jz 8f
    lea rdx, [rip + .Ltue_open]
    call has
    test eax, eax
    jnz 8f
    mov rdi, [rip + rtext + SB_ptr]
    mov rsi, [rip + rtext + SB_len]
    lea rdx, [rip + .Lyb]
    call text_is
    test eax, eax
    jnz 8f
    mov rdi, [rip + rtext + SB_ptr]
    mov rsi, [rip + rtext + SB_len]
    lea rdx, [rip + .Lxb]
    call starts
    test eax, eax
    jz 8f
    call text_core
    mov rbx, rax
    mov r12, rdx
    lea rdi, [rip + .Lxb]
    call strlen
    lea rdi, [rbx + rax]
    mov rsi, r12
    sub rsi, rax
    call agent_units
    cmp rax, REASON_MAX
    ja 8f
    call err_shown
    mov rbx, rax
    mov r12, rdx
    lea rdi, [rip + t1]
    call sb_clear
    lea rdi, [rip + t1]
    lea rsi, [rip + .Lreason]
    call sb_push_cstr
    lea rdi, [rip + t1]
    mov rsi, rbx
    mov rdx, r12
    call sb_push
    mov edi, ATX_NOTE
    mov rax, [rip + cb_at]
    cmp qword ptr [rax + AT_note], 0
    je 1f
    mov edi, ATX_DESC
1:  lea rsi, [rip + t1]
    call put_sb
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# res_error(): an error result as the extension's errorNote: the state, the reason's note, else OUT the
#   error's text (none when it is a standard rejection)
res_error:
    PROLOGUE
    call err_state
    call reason
    test eax, eax
    jnz 9f
    call err_shown
    test rdx, rdx
    jz 9f
    mov edi, ATX_OUT
    mov rsi, rax
    call put
9:  EPILOGUE

# res_generic: the generic body: an error as res_error, else OUT the result's text
res_generic:
    cmp dword ptr [rip + cb_err], 0
    jne res_error
    PROLOGUE
    mov edi, ATS_OK
    call state
    mov edi, ATX_OUT
    lea rsi, [rip + rtext]
    call put_sb
    EPILOGUE

# res_errnote: an error as res_error, nothing else
res_errnote:
    cmp dword ptr [rip + cb_err], 0
    jne res_error
    mov edi, ATS_OK
    jmp state

# res_none: the state only
res_none:
    jmp done_state

# res_edit: "Edit failed" and the error; else nothing more
res_edit:
    cmp dword ptr [rip + cb_err], 0
    je res_errnote
    PROLOGUE
    mov edi, ATX_NOTE
    lea rsi, [rip + .Ledit_failed]
    call put_c
    call res_error
    EPILOGUE

# res_write: "Write failed" and the error (its tab the tool's output, not the file's text)
res_write:
    cmp dword ptr [rip + cb_err], 0
    je res_errnote
    PROLOGUE
    mov edi, ATX_NOTE
    lea rsi, [rip + .Lwrite_failed]
    call put_c
    mov edi, ATX_TITLE
    xor esi, esi
    xor edx, edx
    call put
    call res_error
    EPILOGUE

# res_notebook: "Failed" or "Success", and the error
res_notebook:
    PROLOGUE
    mov edi, ATX_NOTE
    lea rsi, [rip + .Lsuccess]
    cmp dword ptr [rip + cb_err], 0
    je 1f
    lea rsi, [rip + .Lfailed]
1:  call put_c
    call res_errnote
    EPILOGUE

# count_lines() -> eax the non-empty lines of rtext, the time limit's note at its start not counted
count_lines:
    PROLOGUE
    mov rdi, [rip + rtext + SB_ptr]
    mov rsi, [rip + rtext + SB_len]
    xor eax, eax
    test rdi, rdi
    jz 9f
    call trim_ws
    mov rbx, rax
    mov r12, rdx
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lrte]
    call starts
    test eax, eax
    jz 1f
    lea rdi, [rip + .Lrte]
    call strlen
    add rbx, rax
    sub r12, rax
1:  xor eax, eax
    xor ecx, ecx
    xor edx, edx                # the line so far is not empty
2:  cmp rcx, r12
    jae 4f
    cmp byte ptr [rbx + rcx], 10
    jne 3f
    add eax, edx
    xor edx, edx
    jmp 31f
3:  mov edx, 1
31: inc rcx
    jmp 2b
4:  add eax, edx
9:  EPILOGUE

# res_count(kind 0 glob, 1 grep): the count note ("Found N files" / "N lines of output"), the output kept for
#   its tab ("Glob output" / "Grep output"); an error as res_error
res_glob:
    xor edi, edi
    jmp res_count
res_grep:
    mov edi, 1
res_count:
    cmp dword ptr [rip + cb_err], 0
    jne res_error
    PROLOGUE
    mov ebx, edi
    mov edi, ATS_OK
    call state
    call count_lines
    mov r12d, eax
    test ebx, ebx
    jnz 1f
    cmp r12d, 1                 # Glob: the one line "No files found" is none
    jne 1f
    call text_core
    mov rdi, rax
    mov rsi, rdx
    call trim_ws
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + .Lno_files]
    call text_is
    test eax, eax
    jz 1f
    xor r12d, r12d
1:  lea rdi, [rip + t1]
    call sb_clear
    test ebx, ebx
    jnz 3f
    lea rsi, [rip + .Lno_files]
    test r12d, r12d
    jz 2f
    lea rsi, [rip + .Lfound_1]
    cmp r12d, 1
    je 2f
    lea rdi, [rip + t1]
    lea rsi, [rip + .Lfound]
    call sb_push_cstr
    lea rdi, [rip + t1]
    mov esi, r12d
    call sb_push_u64
    lea rsi, [rip + .Lfiles]
2:  lea rdi, [rip + t1]
    call sb_push_cstr
    jmp 5f
3:  lea rsi, [rip + .Lno_matches]
    test r12d, r12d
    jz 4f
    lea rsi, [rip + .Lone_line]
    cmp r12d, 1
    je 4f
    lea rdi, [rip + t1]
    mov esi, r12d
    call sb_push_u64
    lea rsi, [rip + .Lnlines]
4:  lea rdi, [rip + t1]
    call sb_push_cstr
5:  mov edi, ATX_NOTE
    lea rsi, [rip + t1]
    call put_sb
    cmp qword ptr [rip + rtext + SB_len], 0
    je 9f
    mov edi, ATX_OUT
    lea rsi, [rip + rtext]
    call put_sb
    mov edi, ATX_TITLE
    lea rsi, [rip + .Lglob_out]
    test ebx, ebx
    jz 6f
    lea rsi, [rip + .Lgrep_out]
6:  call put_c
9:  EPILOGUE

# res_fetch: "Fetched from URL" for a fetch that worked; else the generic body
res_fetch:
    cmp dword ptr [rip + cb_err], 0
    jne res_error
    PROLOGUE
    mov rax, [rip + cb_at]
    mov rbx, [rax + AT_link]
    test rbx, rbx
    jnz 1f
    mov rbx, [rax + AT_second]
    test rbx, rbx
    jnz 1f
    call res_generic
    EPILOGUE
1:  mov edi, ATS_OK
    call state
    lea rdi, [rip + t1]
    call sb_clear
    lea rdi, [rip + t1]
    lea rsi, [rip + .Lfetched]
    call sb_push_cstr
    lea rdi, [rip + t1]
    mov rsi, rbx
    call sb_push_cstr
    mov edi, ATX_NOTE
    lea rsi, [rip + t1]
    call put_sb
    EPILOGUE

# res_agent: the error; from its result the agent's id (where its children are on disk) and, when it has
#   one, its call count (a foreground agent's: totalToolUseCount; a background agent's result has none)
res_agent:
    PROLOGUE
    mov rbx, rsi
    call res_errnote
    call making
    test eax, eax
    jz 9f
    test rbx, rbx
    jz 9f
    mov rdi, rbx
    lea rsi, [rip + .Lk_agentId]
    call jstr
    test rdx, rdx
    jz 1f
    mov rcx, rdx
    mov rdx, rax
    lea rdi, [rip + .Ln_agent_t]
    mov esi, 5
    call aux_set
1:  mov rdi, rbx
    lea rsi, [rip + .Lk_total]
    call json_get
    mov rdi, rax
    call json_int
    test edx, edx
    jz 9f
    test rax, rax
    js 9f
    mov edi, ATV_NKIDS
    mov esi, eax
    call num
9:  EPILOGUE

# res_plan: "User approved the plan" / "Stayed in plan mode"; no OUT
res_plan:
    PROLOGUE
    call done_state
    mov edi, ATX_NOTE
    lea rsi, [rip + .Lapproved]
    cmp dword ptr [rip + cb_err], 0
    je 1f
    lea rsi, [rip + .Lstayed]
1:  call put_c
    EPILOGUE

# res_ask: the question's outcome as the extension words it (Answered, Declined, No answer, Session ended
#   before an answer) and the count of questions; the answers, "QUESTION → ANSWER" a line, as OUT; a result
#   of another form: the generic body (the bundle's YIe, d8n @5229741)
res_ask:
    PROLOGUE 16
    mov [rsp], rsi
    call text_core
    mov rdi, rax
    mov rsi, rdx
    call trim_ws
    mov rbx, rax
    mov r12, rdx
    xor r13d, r13d              # the status word
    cmp dword ptr [rip + cb_err], 0
    je 2f
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Led]
    call starts
    lea r13, [rip + .Lsession_ended]
    test eax, eax
    jnz 5f
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lmark_tool]
    call starts
    lea r13, [rip + .Lno_answer]
    test eax, eax
    jnz 5f
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Laj]
    call starts
    test eax, eax
    jnz 5f
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lrejection]
    call starts
    lea r13, [rip + .Ldeclined]
    test eax, eax
    jnz 5f
    jmp 7f
2:  mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lbtt]
    call text_is
    lea r13, [rip + .Lno_answer]
    test eax, eax
    jnz 5f
    lea r13, [rip + .Lanswered]
    lea r14, [rip + answer_heads]
3:  mov rdx, [r14]
    test rdx, rdx
    jz 7f
    mov rdi, rbx
    mov rsi, r12
    call starts
    test eax, eax
    jnz 5f
    add r14, 8
    jmp 3b
5:  call done_state             # the note: "STATUS · N questions"
    lea rdi, [rip + t1]
    call sb_clear
    lea rdi, [rip + t1]
    mov rsi, r13
    call sb_push_cstr
    mov rdi, [rip + cb_at]
    call aux_more
    test rdx, rdx
    jz 51f
    mov rdi, rax
    mov rsi, rdx
    call parse_u64
    test eax, eax
    jz 51f
    mov r14d, eax
    lea rdi, [rip + t1]
    lea rsi, [rip + .Lmiddot]
    call sb_push_cstr
    lea rdi, [rip + t1]
    mov esi, r14d
    lea rdx, [rip + .Lquestion_w]
    call plural
51: mov edi, ATX_NOTE
    lea rsi, [rip + t1]
    call put_sb
    lea rax, [rip + .Lanswered]
    cmp r13, rax
    jne 6f
    mov rdi, [rsp]              # the answers
    mov rsi, rbx
    mov rdx, r12
    call answers
    mov edi, ATX_OUT
    lea rsi, [rip + t1]
    call put_sb
    EPILOGUE
6:  lea rax, [rip + .Ldeclined]
    cmp r13, rax
    jne 9f
    mov rax, [rip + cb_at]      # a reason: on the description line (the note is the status)
    cmp dword ptr [rip + tm_which], 0
    jge 9f
    call reason
    EPILOGUE
7:  call res_generic
9:  EPILOGUE

# answers(structured, text ptr, len): into t1 "QUESTION → ANSWER" a line: from the structured result's
#   answers when it has them, else from the result's text ("…: "Q"="A", "Q2"="B". …", the bundle's u8n)
answers:
    PROLOGUE 32
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    lea rdi, [rip + t1]
    call sb_clear
    mov rdi, rbx
    lea rsi, [rip + .Lk_answers]
    call json_get
    mov r14, rax
    mov rdi, rax
    call json_npairs
    test eax, eax
    jz 3f
    xor r15d, r15d
1:  mov rdi, r14
    call json_npairs
    cmp r15d, eax
    jae 9f
    mov rdi, r14
    mov esi, r15d
    call json_pair
    inc r15d
    mov [rsp], rax
    mov rdi, rdx
    call json_str
    test rdx, rdx
    jz 1b
    mov [rsp + 8], rax
    mov [rsp + 16], rdx
    mov rdi, [rsp]
    call json_str
    mov rdi, rax
    mov rsi, rdx
    mov rdx, [rsp + 8]
    mov rcx, [rsp + 16]
    call answer_line
    jmp 1b
3:  lea r14, [rip + answer_heads]   # the text: after its head, before its tail
4:  mov rdx, [r14]
    test rdx, rdx
    jz 9f
    mov rdi, r12
    mov rsi, r13
    call starts
    test eax, eax
    jnz 5f
    add r14, 8
    jmp 4b
5:  mov rdi, [r14]
    call strlen
    add r12, rax
    sub r13, rax
    lea r14, [rip + answer_tails]
51: mov rdx, [r14]
    test rdx, rdx
    jz 6f
    mov rdi, r12
    mov rsi, r13
    call ends
    test eax, eax
    jnz 52f
    add r14, 8
    jmp 51b
52: sub r13, rdx
6:  xor r15d, r15d              # the pairs: "Q"="A", "Q2"="B"
7:  cmp r15, r13
    jae 9f
    cmp byte ptr [r12 + r15], '"'
    jne 9f
    lea rdi, [r12 + r15]        # the question: to its closing quote, before "="
    mov rsi, r13
    sub rsi, r15
    lea rdx, [rip + .Lqa]
    mov ecx, 3
    call str_find
    test rax, rax
    js 9f
    lea rcx, [r15 + 1]
    mov [rsp], rcx              # the question's start and length
    lea rcx, [rax - 1]
    mov [rsp + 8], rcx
    lea r14, [r15 + rax + 2]    # the answer's opening quote
    lea rdi, [r12 + r14]        # its closing quote: before the next ", "Q"=" or at the text's end
    mov rsi, r13
    sub rsi, r14
    lea rdx, [rip + .Lnext_q]
    mov ecx, 4
    call str_find
    mov rcx, r13
    sub rcx, r14
    test rax, rax
    js 8f
    mov [rsp + 16], rax
    lea rdi, [r12 + r14 + 3]    # only when another "…"= follows
    add rdi, rax
    mov rsi, r13
    sub rsi, r14
    sub rsi, rax
    sub rsi, 3
    lea rdx, [rip + .Lqa]
    mov ecx, 3
    call str_find
    mov rcx, r13
    sub rcx, r14
    test rax, rax
    js 8f
    mov rcx, [rsp + 16]
    inc rcx
8:  mov [rsp + 16], rcx         # the answer's length, quotes included
    cmp rcx, 2
    jb 9f
    cmp byte ptr [r12 + r14], '"'
    jne 9f
    lea rax, [r12 + r14]
    cmp byte ptr [rax + rcx - 1], '"'
    jne 9f
    mov rax, [rsp]
    lea rdi, [r12 + rax]
    mov rsi, [rsp + 8]
    lea rdx, [r12 + r14 + 1]
    sub rcx, 2
    call answer_line
    mov r15, r14
    add r15, [rsp + 16]
    add r15, 2                  # past ", "
    jmp 7b
9:  EPILOGUE

# answer_line(q ptr, len, a ptr, len): "Q → A" and a line feed between lines, into t1
answer_line:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    cmp qword ptr [rip + t1 + SB_len], 0
    je 1f
    lea rdi, [rip + t1]
    mov esi, 10
    call sb_push_byte
1:  lea rdi, [rip + t1]
    mov rsi, rbx
    mov rdx, r12
    call sb_push
    lea rdi, [rip + t1]
    lea rsi, [rip + .Larrow]
    call sb_push_cstr
    lea rdi, [rip + t1]
    mov rsi, r13
    mov rdx, r14
    call sb_push
    EPILOGUE

# res_sendfile: OUT only for an error or a text that says a file did not arrive
res_sendfile:
    cmp dword ptr [rip + cb_err], 0
    jne res_error
    PROLOGUE
    mov edi, ATS_OK
    call state
    mov rdi, [rip + rtext + SB_ptr]
    mov rsi, [rip + rtext + SB_len]
    test rdi, rdi
    jz 9f
    lea rdx, [rip + .Lone_viewer]
    call has
    test eax, eax
    jnz 1f
    mov rdi, [rip + rtext + SB_ptr]
    mov rsi, [rip + rtext + SB_len]
    lea rdx, [rip + .Lnot_sp]
    call has
    test eax, eax
    jz 9f
    mov rdi, [rip + rtext + SB_ptr]
    mov rsi, [rip + rtext + SB_len]
    lea rdx, [rip + .Ldelivered]
    call has
    test eax, eax
    jz 9f
1:  mov edi, ATX_OUT
    lea rsi, [rip + rtext]
    call put_sb
9:  EPILOGUE

# res_artifact: "Opened", "Created" or "Published", " — Open artifact ↗" and the artifact's URL as the
#   header's link, when the result names one ("… at https://…"); else the generic body
res_artifact:
    cmp dword ptr [rip + cb_err], 0
    jne res_error
    cmp dword ptr [rip + cb_str], 0
    je res_generic
    PROLOGUE
    mov rbx, [rip + rtext + SB_ptr]
    mov r12, [rip + rtext + SB_len]
    lea r13, [rip + .Lpublished]
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lopened_at]
    call starts
    test eax, eax
    jz 1f
    lea r13, [rip + .Lopened]
    jmp 3f
1:  mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lcreated_sp]
    call starts
    test eax, eax
    jz 2f
    lea r13, [rip + .Lcreated]
    jmp 3f
2:  mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lpublished_sp]
    call starts
    test eax, eax
    jz 8f
3:  mov rdi, rbx                # the one URL: after " at "
    mov rsi, r12
    lea rdx, [rip + .Lat_http]
    mov ecx, 8
    call str_find
    test rax, rax
    js 8f
    lea r14, [rbx + rax + 4]
    mov r15, r12
    sub r15, rax
    sub r15, 4
    xor ecx, ecx
4:  cmp rcx, r15
    jae 5f
    movzx eax, byte ptr [r14 + rcx]
    mov edi, eax
    push rcx
    push rcx
    call isws
    pop rcx
    pop rcx
    test eax, eax
    jnz 5f
    inc rcx
    jmp 4b
5:  mov r15, rcx
    mov edi, ATS_OK
    call state
    mov rdi, r14
    mov rsi, r15
    call web_link
    lea rdi, [rip + t1]
    call sb_clear
    lea rdi, [rip + t1]
    mov rsi, r13
    call sb_push_cstr
    lea rdi, [rip + t1]
    lea rsi, [rip + .Lopen_artifact]
    call sb_push_cstr
    mov edi, ATX_NOTE
    lea rsi, [rip + t1]
    call put_sb
    EPILOGUE
8:  call res_generic
    EPILOGUE

# ---------------- the task tools' list (AS_rdata) ----------------

# tasks() -> rax the conversation's table (made when first needed)
tasks:
    PROLOGUE
    mov rbx, [rip + cb_as]
    mov rax, [rbx + AS_rdata]
    test rax, rax
    jnz 9f
    mov edi, CR_SIZE
    call mem_alloc
    mov [rbx + AS_rdata], rax
9:  EPILOGUE

# task_find(id ptr, len) -> rax its entry, or 0
task_find:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov rbx, [rip + cb_as]
    mov rbx, [rbx + AS_rdata]
    test rbx, rbx
    jz 8f
    xor r14d, r14d
1:  cmp r14d, [rbx + CR_N]
    jae 8f
    imul r15, r14, CRT_SIZE
    lea r15, [rbx + r15 + CR_TASKS]
    mov rdi, r12
    mov rsi, r13
    lea rdx, [r15 + CRT_ID]
    call text_is
    test eax, eax
    jnz 9f
    inc r14d
    jmp 1b
8:  xor eax, eax
    EPILOGUE
9:  mov rax, r15
    EPILOGUE

# task_items(): the call's items: the conversation's tasks as they stand, in the order they were made
task_items:
    PROLOGUE
    call making
    test eax, eax
    jz 9f
    mov rdi, [rip + cb_at]
    call agrow_items_clear
    call tasks
    mov rbx, rax
    xor r12d, r12d
1:  cmp r12d, [rbx + CR_N]
    jae 9f
    imul r13, r12, CRT_SIZE
    lea r13, [rbx + r13 + CR_TASKS]
    lea rdi, [r13 + CRT_SUBJ]
    call strlen
    mov rdi, [rip + cb_at]
    lea rsi, [r13 + CRT_SUBJ]
    mov rdx, rax
    mov ecx, [r13 + CRT_STATE]
    call agrow_item
    inc r12d
    jmp 1b
9:  EPILOGUE

# res_task_create: TaskCreate's result {task {id, subject}}: the task joins the list (pending), the call shows
#   the list; an error, or a result not of that form, or a 201st task: the generic body
res_task_create:
    cmp dword ptr [rip + cb_err], 0
    jne res_generic
    PROLOGUE
    test rsi, rsi
    jz 8f
    mov rdi, rsi
    lea rsi, [rip + .Lk_task]
    call json_get
    mov rbx, rax
    mov rdi, rbx
    lea rsi, [rip + .Lk_id]
    call jstr
    test rdx, rdx
    jz 8f
    cmp rdx, 15
    ja 8f
    mov r12, rax
    mov r13, rdx
    mov rdi, rbx
    lea rsi, [rip + .Lk_subject]
    call jstr
    test rdx, rdx
    jz 8f
    mov r14, rax
    mov r15, rdx
    call making
    test eax, eax
    jz 7f
    mov rdi, r12
    mov rsi, r13
    call task_find
    test rax, rax
    jnz 7f                      # (its result read again)
    call tasks
    mov rbx, rax
    cmp dword ptr [rbx + CR_N], CR_TASKS_MAX
    jae 8f
    mov eax, [rbx + CR_N]
    inc dword ptr [rbx + CR_N]
    imul rax, rax, CRT_SIZE
    lea rbx, [rbx + rax + CR_TASKS]
    lea rdi, [rbx + CRT_ID]
    mov rsi, r12
    mov rdx, r13
    call memcpy
    mov byte ptr [rbx + CRT_ID + r13], 0
    cmp r15, 119
    jbe 1f
    mov rdi, r14
    mov esi, 119
    call char_end
    mov r15, rax
1:  lea rdi, [rbx + CRT_SUBJ]
    mov rsi, r14
    mov rdx, r15
    call memcpy
    mov byte ptr [rbx + CRT_SUBJ + r15], 0
    mov dword ptr [rbx + CRT_STATE], TODO_PENDING
7:  mov edi, ATS_OK
    call state
    call task_items
    EPILOGUE
8:  call res_generic
    EPILOGUE

# char_end(ptr, n) -> rax n, less a character it would cut
char_end:
    mov rax, rsi
1:  test rax, rax
    jz 9f
    movzx ecx, byte ptr [rdi + rax]
    and ecx, 0xc0
    cmp ecx, 0x80
    jne 9f
    dec rax
    jmp 1b
9:  ret

# res_task_update: TaskUpdate's success: the task's new state (deleted: it leaves the list), from the call's
#   input read again with the result's taskId; the call shows the list. An error: the generic body
res_task_update:
    cmp dword ptr [rip + cb_err], 0
    jne res_generic
    PROLOGUE
    test rsi, rsi
    jz 8f
    mov rbx, rsi
    mov rdi, rbx                # {success, taskId, updatedFields, statusChange {from, to}}
    lea rsi, [rip + .Lk_taskId]
    call jstr
    test rdx, rdx
    jz 8f
    mov rdi, rax
    mov rsi, rdx
    call task_find
    test rax, rax
    jz 8f
    mov r12, rax
    mov rdi, rbx
    lea rsi, [rip + .Lk_statusChange]
    call json_get
    test rax, rax
    jz 7f
    mov rdi, rax
    lea rsi, [rip + .Lk_to]
    call json_get
    test rax, rax
    jz 7f
    mov rdi, rax
    call todo_state
    mov r13d, eax
    call making
    test eax, eax
    jz 7f
    test r13d, r13d
    js 5f
    mov [r12 + CRT_STATE], r13d
    jmp 7f
5:  call tasks                  # deleted: the ones after it move up
    mov rbx, rax
    mov ecx, [rbx + CR_N]
    imul rcx, rcx, CRT_SIZE
    lea rcx, [rbx + rcx + CR_TASKS]
    lea rsi, [r12 + CRT_SIZE]
    mov rdx, rcx
    sub rdx, rsi
    mov rdi, r12
    call memmove
    dec dword ptr [rbx + CR_N]
7:  mov edi, ATS_OK
    call state
    call task_items
    EPILOGUE
8:  call res_generic
    EPILOGUE

# ---------------- data ----------------

.section .rodata
.p2align 3
# {name, input filler, result filler}; the names Claude Code 2.1.330 gives its tools (finding 28) and those
#   the extension's renderers know (Ng @5270821)
tools:
    .quad .Ln_bash, in_bash, res_generic
    .quad .Ln_pwsh, in_bash, res_generic
    .quad .Ln_read, in_read, res_errnote
    .quad .Ln_coalesced, in_coalesced, res_none
    .quad .Ln_edit, in_edit, res_edit
    .quad .Ln_write, in_write, res_write
    .quad .Ln_notebook, in_notebook, res_notebook
    .quad .Ln_glob, in_glob, res_glob
    .quad .Ln_grep, in_grep, res_grep
    .quad .Ln_search, in_search, res_generic
    .quad .Ln_webfetch, in_fetch, res_fetch
    .quad .Ln_websearch_t, in_websearch, res_generic
    .quad .Ln_agent_t, in_agent, res_agent
    .quad .Ln_task_t, in_agent, res_agent
    .quad .Ln_todowrite, in_todo, res_errnote
    .quad .Ln_taskcreate, in_task_create, res_task_create
    .quad .Ln_taskupdate, in_task_update, res_task_update
    .quad .Ln_exitplan, in_plan, res_plan
    .quad .Ln_ask, in_ask, res_ask
    .quad .Ln_skill_t, in_skill, res_errnote
    .quad .Ln_taskoutput, in_taskoutput, res_generic
    .quad .Ln_toolsearch, in_toolsearch, res_none
    .quad .Ln_agentoutput, in_name, res_none
    .quad .Ln_network_t, in_network, res_generic
    .quad .Ln_sendfile, in_sendfile, res_sendfile
    .quad .Ln_sendproject, in_project, res_generic
    .quad .Ln_artifact, in_artifact, res_artifact
    .quad 0, 0, 0
tool_mcp: .quad .Lmcp, in_mcp, res_generic
tool_generic: .quad 0, in_generic, res_generic
grep_keys: .quad .Lk_path, .Lin_sp, .Lk_glob, .Lglob_sp, .Lk_typekey, .Ltype_sp, 0, 0
mcp_keys: .quad .Lk_query, .Lk_message, .Lk_channel, .Lk_repo, .Lk_url, .Lk_path, .Lk_title, .Lk_search
    .quad .Lk_text, 0
human_words: .quad .Lw_github, .Lw_github2, .Lw_pubmed, .Lw_pubmed2, .Lw_ai, .Lw_ai2, 0, 0
silent: .quad .Lyb, .Lctt, .Ldtt, .Ldue, .Lmark_tool, 0    # the bundle's GEn: nothing shown
answer_heads: .quad .Lzie1, .Lzie2, .Lo8n, 0
answer_tails: .quad .Lvtt1, .Lvtt2, 0

.Ln_bash: .asciz "Bash"
.Ln_pwsh: .asciz "PowerShell"
.Ln_read: .asciz "Read"
.Ln_coalesced: .asciz "ReadCoalesced"
.Ln_edit: .asciz "Edit"
.Ln_write: .asciz "Write"
.Ln_notebook: .asciz "NotebookEdit"
.Ln_cell: .asciz "Edit Notebook Cell"
.Ln_glob: .asciz "Glob"
.Ln_grep: .asciz "Grep"
.Ln_search: .asciz "Search"
.Ln_webfetch: .asciz "WebFetch"
.Ln_fetch: .asciz "Web Fetch"
.Ln_websearch_t: .asciz "WebSearch"
.Ln_websearch: .asciz "Web Search"
.Ln_agent_t: .asciz "Agent"
.Ln_task_t: .asciz "Task"
.Ln_agent: .asciz "Agent:"
.Ln_todowrite: .asciz "TodoWrite"
.Ln_taskcreate: .asciz "TaskCreate"
.Ln_taskupdate: .asciz "TaskUpdate"
.Ln_todos: .asciz "Update Todos"
.Ln_exitplan: .asciz "ExitPlanMode"
.Ln_plan: .asciz "Claude’s Plan"
.Ln_planmode: .asciz "Plan Mode"
.Ln_ask: .asciz "AskUserQuestion"
.Ln_question: .asciz "Question"
.Ln_questions: .asciz "Questions"
.Ln_skill_t: .asciz "Skill"
.Ln_taskoutput: .asciz "TaskOutput"
.Ln_toolsearch: .asciz "ToolSearch"
.Ln_agentoutput: .asciz "AgentOutputTool"
.Ln_network_t: .asciz "SandboxNetworkAccess"
.Ln_network: .asciz "Network Access"
.Ln_sendfile: .asciz "SendUserFile"
.Ln_sent: .asciz "Sent"
.Ln_sendproject: .asciz "SendToProject"
.Ln_project: .asciz "Send to project"
.Ln_artifact: .asciz "Artifact"
.Lmcp: .asciz "mcp__"
.Lk_type: .asciz "type"
.Lk_uuid: .asciz "uuid"
.Lk_isSidechain: .asciz "isSidechain"
.Lk_isMeta: .asciz "isMeta"
.Lk_parent: .asciz "parent_tool_use_id"
.Lk_message: .asciz "message"
.Lk_model: .asciz "model"
.Lk_content: .asciz "content"
.Lk_id: .asciz "id"
.Lk_name: .asciz "name"
.Lk_input: .asciz "input"
.Lk_tool_use_id: .asciz "tool_use_id"
.Lk_is_error: .asciz "is_error"
.Lk_tur: .asciz "tool_use_result"
.Lk_turFile: .asciz "toolUseResult"
.Lk_description: .asciz "description"
.Lk_command: .asciz "command"
.Lk_file_path: .asciz "file_path"
.Lk_offset: .asciz "offset"
.Lk_limit: .asciz "limit"
.Lk_fileReads: .asciz "fileReads"
.Lk_old_string: .asciz "old_string"
.Lk_new_string: .asciz "new_string"
.Lk_notebook_path: .asciz "notebook_path"
.Lk_cell_id: .asciz "cell_id"
.Lk_new_source: .asciz "new_source"
.Lk_pattern: .asciz "pattern"
.Lk_path: .asciz "path"
.Lk_glob: .asciz "glob"
.Lk_typekey: .asciz "type"
.Lk_url: .asciz "url"
.Lk_query: .asciz "query"
.Lk_allowed: .asciz "allowed_domains"
.Lk_blocked: .asciz "blocked_domains"
.Lk_prompt: .asciz "prompt"
.Lk_todos: .asciz "todos"
.Lk_status: .asciz "status"
.Lk_subject: .asciz "subject"
.Lk_taskId: .asciz "taskId"
.Lk_task: .asciz "task"
.Lk_statusChange: .asciz "statusChange"
.Lk_to: .asciz "to"
.Lk_planFilePath: .asciz "planFilePath"
.Lk_plan: .asciz "plan"
.Lk_questions: .asciz "questions"
.Lk_question: .asciz "question"
.Lk_answers: .asciz "answers"
.Lk_skill: .asciz "skill"
.Lk_task_id: .asciz "task_id"
.Lk_host: .asciz "host"
.Lk_files: .asciz "files"
.Lk_caption: .asciz "caption"
.Lk_agentId: .asciz "agentId"
.Lk_total: .asciz "totalToolUseCount"
.Lk_message2: .asciz "message"
.Lk_channel: .asciz "channel"
.Lk_repo: .asciz "repo"
.Lk_title: .asciz "title"
.Lk_search: .asciz "search"
.Lk_text: .asciz "text"
.Lv_assistant: .asciz "assistant"
.Lv_user: .asciz "user"
.Lv_tool_use: .asciz "tool_use"
.Lv_tool_result: .asciz "tool_result"
.Lv_text: .asciz "text"
.Lv_thinking: .asciz "thinking"
.Lv_redacted: .asciz "redacted_thinking"
.Lv_completed: .asciz "completed"
.Lv_in_progress: .asciz "in_progress"
.Lv_deleted: .asciz "deleted"
.Lmark_stop: .asciz "[Request interrupted by user]"
.Lmark_tool: .asciz "[Request interrupted by user for tool use]"
.Linterrupted: .asciz "Interrupted"
.Lempty: .asciz ""
.Lellipsis: .asciz "…"
.Lfile: .asciz "file"
.Llines: .asciz "(lines "
.Lfrom_line: .asciz "(from line "
.Lcomma: .asciz ", "
.Lparen: .asciz "("
.Lin_sp: .asciz "in "
.Lglob_sp: .asciz "glob: "
.Ltype_sp: .asciz "type: "
.Lpattern: .asciz "pattern: "
.Ltask_q: .asciz "task: "
.Ladded: .asciz "Added "
.Lremoved: .asciz "Removed "
.Lline: .asciz "line"
.Lmodified: .asciz "Modified"
.Lwrite_sp: .asciz "Write "
.Lwrite_ok: .asciz "Write succeeded"
.Lwrite_failed: .asciz "Write failed"
.Ledit_failed: .asciz "Edit failed"
.Lpending: .asciz "Pending"
.Lsuccess: .asciz "Success"
.Lfailed: .asciz "Failed"
.Lno_content: .asciz "[No content]"
.Lno_files: .asciz "No files found"
.Lfound_1: .asciz "Found 1 file"
.Lfound: .asciz "Found "
.Lfiles: .asciz " files"
.Lno_matches: .asciz "No matches found"
.Lone_line: .asciz "1 line of output"
.Lnlines: .asciz " lines of output"
.Lglob_out: .asciz "Glob output"
.Lgrep_out: .asciz "Grep output"
.Lfetched: .asciz "Fetched from "
.Lallowed: .asciz "Allowed: "
.Lblocked: .asciz "Blocked: "
.Lmiddot: .asciz " · "
.Lagent_input: .asciz "Agent tool input"
.Lplan_title: .asciz "Plan"
.Lapproved: .asciz "User approved the plan"
.Lstayed: .asciz "Stayed in plan mode"
.Lskill: .asciz "skill"
.Lbra: .asciz " ["
.Lhttps: .asciz "https://"
.Lhttp: .asciz "http://"
.Lscheme: .asciz "://"
.Lreason: .asciz "Reason: "
.Lanswered: .asciz "Answered"
.Ldeclined: .asciz "Declined"
.Lno_answer: .asciz "No answer"
.Lsession_ended: .asciz "Session ended before an answer"
.Lquestion_w: .asciz "question"
.Larrow: .asciz " → "
.Lqa: .asciz "\"=\""
.Lnext_q: .asciz "\", \""
.Lone_viewer: .asciz "reached only one of its viewers"
.Lnot_sp: .asciz "NOT "
.Ldelivered: .asciz " delivered"
.Lopened: .asciz "Opened"
.Lcreated: .asciz "Created"
.Lpublished: .asciz "Published"
.Lopened_at: .asciz "Opened the Artifact at http"
.Lcreated_sp: .asciz "Created a new Artifact at http"
.Lpublished_sp: .asciz "Published "
.Lat_http: .asciz " at http"
.Lopen_artifact: .asciz " — Open artifact ↗"
.Lw_github: .asciz "Github"
.Lw_github2: .asciz "GitHub"
.Lw_pubmed: .asciz "Pubmed"
.Lw_pubmed2: .asciz "PubMed"
.Lw_ai: .asciz "Ai"
.Lw_ai2: .asciz "AI"
.Ltue_open: .asciz "<tool_use_error>"
.Ltue_close: .asciz "</tool_use_error>"
.Ltue_tag: .asciz "<tool_use_error"
.Ltue_end: .asciz "</tool_use_error"
# the bundle's rejection and interrupt texts (@5214522-5217700, @3597520; finding 36)
.Lrejection: .ascii "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a "
    .asciz "file edit, the new_string was NOT written to the file). "
.Lyb: .ascii "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file "
    .ascii "edit, the new_string was NOT written to the file). STOP what you are doing and wait for the user to "
    .asciz "tell you how to proceed."
.Lxb: .ascii "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file "
    .ascii "edit, the new_string was NOT written to the file). The user provided the following reason for the "
    .asciz "rejection: "
.Lctt: .ascii "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file "
    .ascii "edit, the new_string was NOT written to the file). STOP what you are doing and wait for the user to "
    .ascii "tell you how to proceed. Correction to the text above: this call was stopped while running, not "
    .ascii "refused before it ran. It may have run in part or in full, and its changes may have been written. No "
    .ascii "permission prompt was involved. Work it started elsewhere (a remote command, a background process) "
    .ascii "may still be running, so check before starting the same work again. The instruction to stop and wait "
    .asciz "still stands."
.Ldtt: .ascii "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file "
    .ascii "edit, the new_string was NOT written to the file). STOP what you are doing and wait for the user to "
    .ascii "tell you how to proceed. Correction to the text above: this call was stopped while running, not "
    .ascii "refused before it ran. It may have run in part or in full, and files it sends may have reached the "
    .ascii "connector. Tell the user before sending any of them again. The instruction to stop and wait still "
    .asciz "stands."
.Ldue: .ascii "The user doesn't want to take this action right now. STOP what you are doing and wait for the user "
    .asciz "to tell you how to proceed."
.Lda: .ascii "\n\nNote: The user's next message may contain a correction or preference. Pay close attention — if "
    .ascii "they explain what went wrong or how they'd prefer you to work, consider saving that to memory for "
    .asciz "future sessions."
.Lhie: .ascii "IMPORTANT: You *may* attempt to accomplish this action using other tools that might naturally be "
    .ascii "used to accomplish this goal, e.g. using head instead of cat. But you *should not* attempt to work "
    .ascii "around this denial in malicious ways, e.g. do not use your ability to run tests to execute non-test "
    .ascii "actions. You should only try to work around this restriction in reasonable ways that do not attempt "
    .ascii "to bypass the intent behind this denial. If you believe this capability is essential to complete "
    .ascii "the user's request, STOP and explain to the user what you were trying to do and why you need this "
    .asciz "permission. Let the user decide how to proceed."
.Led: .asciz "[Tool call interrupted: the session ended before this call's result was recorded"
.Laj: .asciz "[Tool call result not in this copy: this session was copied from another session"
.Lbtt: .asciz "The user did not answer the questions."
.Lzie1: .asciz "Your questions have been answered: "
.Lzie2: .asciz "The user answered: "
.Lo8n: .asciz "The user responded: "
.Lvtt1: .asciz ". You can now continue with these answers in mind."
.Lvtt2: .ascii ". Read the answers carefully — they may request clarification, changes, or that you not proceed — "
    .asciz "and follow what they actually say."
.Lrte: .ascii "The search stopped before it finished, most likely at its time limit, so these results are incomplete: "
    .asciz "more matches may exist. Search a more specific path or pattern."
