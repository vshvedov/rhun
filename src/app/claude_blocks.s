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
.equ US_PLAIN, 1                # user_said's answers: a plain text of a prompt, a chip (in pchips), else 0
.equ US_CHIP, 2
.equ CHIP_PATH_MAX, 4096        # a chip's path (the bundle's AD: at most 4096 characters)
.equ ECHO_NAME_MAX, 200          # a command echo's name

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
ptext: .zero SB_SIZE            # a prompt's text blocks, joined (ing_user)
pchips: .zero SB_SIZE           # its chips: "LABEL\tTARGET" a line each (AM_name, AMF_CHIPS)
utext: .zero SB_SIZE            # an echo's line, a meta line, a pill's text
pc_sb: .zero SB_SIZE            # a prompt's text with its pastes unwrapped (phase 4 task 4)
pc_tag: .zero SB_SIZE           #   and the closing tag it looks for

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
#   results, as children. ING_REPLAY: a replayed user record of the stream, only what the agent said in the
#   user's place (ing_user)
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
    cmp r13d, ING_REPLAY        # a replayed record: only what the agent said in the user's place
    je 1f
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
    jz 2f
    mov rdi, rbx
    mov rsi, r12
    call ing_user
    jmp 9f
2:  cmp r13d, ING_REPLAY
    je 9f
    mov rdi, r14
    lea rsi, [rip + .Lv_system]
    call json_is
    test eax, eax
    jz 9f
    mov rdi, rbx
    mov rsi, r12
    call ing_system
9:  mov eax, 1
    EPILOGUE

# ing_assistant(AS*, record): its content blocks: text (a reply row, read from a file only), tool_use (a
#   call), thinking and redacted_thinking (a thinking row), any other type (an unknown block's row); under a
#   call only the calls
ing_assistant:
    PROLOGUE 48
    mov rbx, rdi
    mov r12, rsi
    mov rdi, r12                # a command the CLI ran itself (the stream's <synthetic> record, finding 22):
    lea rsi, [rip + .Lk_lcs]    #   its output row, as the file's system/local_command gives it (31)
    call jstr
    test rdx, rdx
    jz 0f
    mov rdi, rbx
    mov rsi, rax
    call cmd_wrapped
    EPILOGUE
0:  mov rdi, r12                # the call it ran under, when it did
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
    test rax, rax
    js 2b
    mov [rsp + 32], rax
    mov rdi, r12                # a reply the API failed (assistant.error, the binary's schema: finding 35)
    lea rsi, [rip + .Lk_error]
    call jstr
    test rdx, rdx
    jz 2b
    mov rdi, rbx
    mov rsi, [rsp + 32]
    mov edx, AMF_FAILED
    call agents_row_flag
    jmp 2b
4:  mov rdi, [rsp + 24]         # thinking: a thinking row (its text: summarized; "" by default)
    lea rsi, [rip + .Lv_thinking]
    call json_is
    test eax, eax
    jz 41f
    mov rdi, r15
    lea rsi, [rip + .Lv_thinking]
    call jstr
    mov rcx, rdx
    mov rdx, rax
    jmp 42f
41: mov rdi, [rsp + 24]         # redacted_thinking (the API's schema only: never recorded): a static
    lea rsi, [rip + .Lv_redacted]   #   "Thinking" row, nothing of its data
    call json_is
    test eax, eax
    jz 43f
    xor edx, edx
    xor ecx, ecx
42: mov rdi, rbx
    mov rsi, r12
    lea r8d, [r14 - 1]
    call think_block
    jmp 2b
43:
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

# think_block(AS*, record, text ptr, len, the block's place in the record): a thinking row with the record's
#   duration (thinking_duration_ms in the stream, thinkingDurationMs in the file; -1 none). From a file a row
#   (an empty text too: "Thought for Ns"); from the stream the row that streamed under its key (h_stream made
#   it) gets its finished text and ends, or a finished row of its own when none streamed
think_block:
    PROLOGUE 112
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov [rsp], r8d
    mov rdi, r12
    lea rsi, [rip + .Lk_think_ms]
    call jnum_or
    cmp eax, -1
    jne 1f
    mov rdi, r12
    lea rsi, [rip + .Lk_think_ms_file]
    call jnum_or
1:  mov [rsp + 4], eax          # its milliseconds
    cmp dword ptr [rip + cb_flags], ING_LIVE
    jne 5f
    mov r15, [rbx + AS_live]
    test r15, r15
    jz 5f
    lea rdi, [r15 + AL_msgid]   # its key, as the stream's: "MESSAGE_ID#INDEX" (agent_claude.s item_key)
    call strlen
    cmp rax, 63
    jbe 2f
    mov eax, 63
2:  mov [rsp + 8], rax
    lea rdi, [rsp + 16]
    lea rsi, [r15 + AL_msgid]
    mov rdx, rax
    call memcpy
    mov rax, [rsp + 8]
    mov byte ptr [rsp + 16 + rax], '#'
    inc rax
    mov [rsp + 8], rax
    mov eax, [rsp]
    add rax, [r15 + AL_block]
    lea rdi, [rsp + 16]
    add rdi, [rsp + 8]
    mov rsi, rax
    call dec_into
    add [rsp + 8], rax
    mov rdi, r15
    lea rsi, [rsp + 16]
    mov rdx, [rsp + 8]
    mov rcx, r13
    mov r8, r14
    mov r9d, 1
    call ev_thought
    mov rdi, r15
    mov rsi, rax
    mov edx, [rsp + 4]
    mov ecx, -1
    call ev_thought_end
    EPILOGUE
5:  mov rdi, rbx                # from a file
    mov esi, R_THINK
    mov rdx, r13
    mov rcx, r14
    xor r8d, r8d
    call agents_row_add
    test rax, rax
    js 9f
    mov r12, rax
    imul rax, rax, AM_SIZE
    add rax, [rbx + AS_msgs + VEC_ptr]
    mov ecx, [rsp + 4]
    mov [rax + AM_ms], ecx
    mov rdi, rbx                # its fold counts its time (agentfold.s)
    mov rsi, r12
    call agfold_state
9:  EPILOGUE

# jnum_or(obj, key cstr) -> eax the member's value when it is a number from 0 to 2^31 - 1, else -1
jnum_or:
    PROLOGUE
    call json_get
    mov rbx, rax
    mov rdi, rax
    call json_type
    cmp eax, JT_NUM
    jne 8f
    mov rdi, rbx
    call json_int
    test rax, rax
    js 8f
    cmp rax, 0x7fffffff
    ja 8f
    EPILOGUE
8:  mov eax, -1
    EPILOGUE

# dec_into(buf, n) -> rax the bytes of n in decimal written at buf
dec_into:
    mov rax, rsi
    mov r8, rdi
    mov ecx, 10
    xor r9d, r9d
1:  xor edx, edx
    div rcx
    add edx, '0'
    push rdx
    inc r9
    test rax, rax
    jnz 1b
    mov rax, r9
2:  pop rdx
    mov [r8], dl
    inc r8
    dec r9
    jnz 2b
    ret

# ing_user(AS*, record): the user's side of a conversation. The results of calls go into their rows (found by
#   id). The rest is classified as the extension's dc classifies it (@3625700, user_said): from a file the
#   user's prompts (a prompt stops the calls of the turn before it that still wait; its image, document,
#   selection and opened-file blocks are its chips), command echoes, a command's output, interrupt marks,
#   task notifications, wrapped notices, diagnostics; from the stream, where the driver made the user's
#   prompts, only what the agent said in the user's place (a command's output, a task notification, an
#   interrupt mark; of a replayed record, ING_REPLAY, not the mark). A compaction's summary (isCompactSummary
#   in the file, isSynthetic in the stream: finding 30) is its marker's text, never a prompt. An isMeta line
#   is no row (a custom command's body, the local-command caveat, an image's "[Image: source: PATH]": 31, 33).
#   Frame: [0] the parent's id's length, [8] the structured result, [16] the waiting calls stopped, [24] a
#   block's type, [32] a summary, [40] a text's ptr, [48] its length
ing_user:
    PROLOGUE 64
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
    mov rdi, r12                # a compaction's summary
    lea rsi, [rip + .Lk_isCompactSummary]
    call jtrue
    mov [rsp + 32], eax
    mov rdi, r12
    lea rsi, [rip + .Lk_isSynthetic]
    call jtrue
    or [rsp + 32], eax
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
    cmp qword ptr [rsp], 0      # a text as a string
    jne 9f
    mov rdi, r13
    call json_str
    mov r14, rax
    mov r15, rdx
    cmp dword ptr [rsp + 32], 0
    je 2f
    mov rdi, rbx
    mov rsi, r14
    mov rdx, r15
    call compact_summary
    jmp 9f
2:  cmp dword ptr [rip + cb_flags], ING_FILE
    jne 21f
    mov rdi, rbx
    call agrow_stop
21: lea rdi, [rip + pchips]
    call sb_clear
    lea rdi, [rip + ptext]
    call sb_clear
    mov rdi, rbx
    mov rsi, r14
    mov rdx, r15
    call user_said
    test eax, eax
    jz 9f
    cmp eax, US_PLAIN
    jne 22f
    mov rdi, r14
    mov rsi, r15
    call push_plain
22: mov rdi, rbx
    call prompt_row
    jmp 9f
3:  mov dword ptr [rsp + 16], 0 # a prompt's blocks: the waiting calls stopped once
    lea rdi, [rip + ptext]
    call sb_clear
    lea rdi, [rip + pchips]
    call sb_clear
    xor r14d, r14d
4:  mov rdi, r13
    call json_len
    cmp r14d, eax
    jae 8f
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
    cmp dword ptr [rip + cb_flags], ING_REPLAY
    je 4b
    mov rdi, rbx
    mov rsi, r15
    mov rdx, [rsp + 8]
    call result_block
    jmp 4b
5:  cmp qword ptr [rsp], 0
    jne 4b
    cmp dword ptr [rip + cb_flags], ING_FILE
    jne 6f
    cmp dword ptr [rsp + 16], 0
    jne 6f
    mov dword ptr [rsp + 16], 1
    mov rdi, rbx
    call agrow_stop
6:  mov rdi, [rsp + 24]
    lea rsi, [rip + .Lv_text]
    call json_is
    test eax, eax
    jz 7f
    mov rdi, r15
    lea rsi, [rip + .Lv_text]
    call jstr
    mov [rsp + 40], rax
    mov [rsp + 48], rdx
    mov rdi, rbx
    mov rsi, rax
    call user_said
    cmp eax, US_PLAIN
    jne 4b
    lea rdi, [rip + ptext]      # a prompt's texts, a line feed between them
    cmp qword ptr [rdi + SB_len], 0
    je 61f
    mov esi, 10
    call sb_push_byte
61: mov rdi, [rsp + 40]
    mov rsi, [rsp + 48]
    call push_plain
    jmp 4b
7:  cmp dword ptr [rip + cb_flags], ING_FILE   # an image, a document: a chip of the prompt
    jne 4b
    mov rdi, r15
    mov rsi, [rsp + 24]
    call media_chip
    jmp 4b
8:  cmp dword ptr [rip + cb_flags], ING_FILE
    jne 9f
    cmp qword ptr [rsp], 0
    jne 9f
    mov rdi, rbx
    call prompt_row
9:  EPILOGUE

# push_plain(ptr, len): the user's own text onto ptext, a paste the CLI wrapped (finding 43) as the paste it
#   was (phase 4 task 4); a text that starts with another tag is kept as it is
push_plain:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    test r12, r12
    jz 2f
    call starts_paste
    test eax, eax
    jnz 1f
    cmp byte ptr [rbx], '<'
    je 2f
1:  mov rdi, rbx
    mov rsi, r12
    call unwrap_pastes
    mov rbx, rax
    mov r12, rdx
2:  lea rdi, [rip + ptext]
    mov rsi, rbx
    mov rdx, r12
    call sb_push
    EPILOGUE

# prompt_row(AS*): a prompt of the user's read from a file: ptext, with pchips as its chips (AM_name, LF
#   between them, AMF_CHIPS); nothing when both are empty
prompt_row:
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d              # the chips' cstr, or 0
    cmp qword ptr [rip + pchips + SB_len], 0
    je 1f
    lea rdi, [rip + pchips]
    xor esi, esi
    call sb_push_byte
    dec qword ptr [rip + pchips + SB_len]
    mov r12, [rip + pchips + SB_ptr]
1:  mov rdx, [rip + ptext + SB_ptr]
    mov rcx, [rip + ptext + SB_len]
    test rcx, rcx
    jnz 2f
    test r12, r12
    jz 9f
    lea rdx, [rip + .Lempty]
2:  mov rdi, rbx
    mov esi, R_USER
    mov r8, r12
    call agents_row_add
    test rax, rax
    js 9f
    test r12, r12
    jz 9f
    mov rdi, rbx
    mov rsi, rax
    mov edx, AMF_CHIPS
    call agents_row_flag
9:  EPILOGUE

# user_said(AS*, ptr, len) -> eax US_PLAIN, US_CHIP or 0: a text of the user's side (a text block, a string
#   content) as dc classifies it. Rows made here: an interrupt mark's ("Interrupted", "Tool interrupted": e4;
#   not for a replayed record), a task notification's summary as a meta line (DD), a command's output (MKt,
#   cmd_wrapped); from a file also a command's echo in either recorded form (sVe) or a bare "/x" (a prompt row
#   with AMF_ECHO, "/x A"), a diagnostics line (PKt), a wrapped notice (ND: a meta row with AMF_NOTICE). A
#   chip goes into pchips (US_CHIP); the user's own text is US_PLAIN (the caller makes the prompt). From the
#   stream everything else is 0: the driver made the user's prompts. A tag is matched whole at both ends: an
#   unbalanced or unknown one is the user's text
user_said:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    test r13, r13
    jz 8f
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lmark_stop]
    call text_is
    lea r14, [rip + .Linterrupted]
    test eax, eax
    jnz 1f
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lmark_tool]
    call text_is
    lea r14, [rip + .Ltool_interrupted]
    test eax, eax
    jz 2f
1:  cmp dword ptr [rip + cb_flags], ING_REPLAY
    je 8f
    mov rdi, r14
    call strlen
    mov rdi, rbx
    mov esi, R_INFO
    mov rdx, r14
    mov rcx, rax
    xor r8d, r8d
    call agents_row_add
    jmp 8f
2:  mov rdi, r12
    mov rsi, r13
    call trim_ws
    mov r14, rax
    mov r15, rdx
    test r15, r15
    jz 8f
    mov rdi, rbx                # a task's end (finding 34): its summary
    mov rsi, r14
    mov rdx, r15
    call task_note
    test eax, eax
    jnz 8f
    mov rdi, rbx                # a command's output
    mov rsi, r14
    mov rdx, r15
    call cmd_wrapped
    test eax, eax
    jnz 8f
    cmp dword ptr [rip + cb_flags], ING_FILE
    jne 8f
    mov rdi, rbx                # a command's echo
    mov rsi, r14
    mov rdx, r15
    call echo_tags
    test eax, eax
    jnz 8f
    mov rdi, rbx
    mov rsi, r14
    mov rdx, r15
    call diag_line
    test eax, eax
    jnz 8f
    mov rdi, rbx
    mov rsi, r14
    mov rdx, r15
    call notice_row
    test eax, eax
    jnz 8f
    mov rdi, r14
    mov rsi, r15
    call chip_of
    test eax, eax
    jz 4f
    mov eax, US_CHIP
    EPILOGUE
4:  cmp byte ptr [r14], '/'     # a bare "/x": the echo of a command (the file's "/compact": 30)
    jne 5f
    mov rdi, r14
    mov rsi, r15
    call slash_name
    test rax, rax
    jz 5f
    mov rdi, rbx
    mov rsi, r14
    mov rdx, r15
    lea rcx, [r14 + 1]
    mov r8, rax
    call echo_row
    jmp 8f
5:  mov eax, US_PLAIN
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# between(ptr, len, open cstr, close cstr) -> rax, rdx the text between the first open and the close after
#   it; 0, 0 when either is missing
between:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov rdi, r13
    call strlen
    mov r15, rax
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    mov rcx, r15
    call str_find
    test rax, rax
    js 8f
    add rax, r15
    add rbx, rax                # after the open tag
    sub r12, rax
    mov rdi, r14
    call strlen
    mov rcx, rax
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r14
    call str_find
    test rax, rax
    js 8f
    mov rdx, rax
    mov rax, rbx
    EPILOGUE
8:  xor eax, eax
    xor edx, edx
    EPILOGUE

# wrapped(ptr, len, open cstr, close cstr) -> rax, rdx what is between them when the text begins with open
#   and ends with close (and the close is there once); 0, 0 otherwise
wrapped:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    call starts
    test eax, eax
    jz 8f
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r14
    call ends
    test eax, eax
    jz 8f
    mov r15, rdx                # the close's length
    mov rdi, r13
    call strlen
    mov rcx, r12
    sub rcx, r15
    sub rcx, rax
    js 8f
    lea rax, [rbx + rax]
    push rax
    push rcx
    mov rdi, rax                # the close only once (t4(t, close) === 1)
    mov rsi, rcx
    mov rdx, r14
    mov rcx, r15
    call str_find
    mov rdi, rax
    pop rdx
    pop rax
    test rdi, rdi
    jns 8f
    EPILOGUE
8:  xor eax, eax
    xor edx, edx
    EPILOGUE

# task_note(AS*, ptr, len) -> eax 1 when it was a task's notification ("<task-notification>…": DD): its
#   summary as a meta line (none when it has none)
task_note:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Ltn_open]
    call starts
    test eax, eax
    jz 8f
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Ltn_close]
    call ends
    test eax, eax
    jz 8f
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lsum_open]
    lea rcx, [rip + .Lsum_close]
    call between
    test rax, rax
    jz 7f
    mov rdi, rax
    mov rsi, rdx
    call trim_ws
    test rdx, rdx
    jz 7f
    mov rdi, rbx
    mov rsi, rax
    call meta_once
7:  mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# meta_once(AS*, ptr, len): a task's end as a meta line, unless the conversation's last row is that line
#   already: live, the stream's task_notification made it (claude_task) and the replayed <task-notification>
#   string comes after it (task_note); the file has the string only
meta_once:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rcx, [rbx + AS_msgs + VEC_len]
    test rcx, rcx
    jz 1f
    dec rcx
    imul rax, rcx, AM_SIZE
    add rax, [rbx + AS_msgs + VEC_ptr]
    cmp dword ptr [rax + AM_role], R_META
    jne 1f
    cmp [rax + AM_len], r13
    jne 1f
    mov rdi, [rax + AM_text]
    mov rsi, r12
    mov rdx, r13
    call memeq
    test eax, eax
    jnz 9f
1:  mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    xor ecx, ecx
    call meta_row
9:  EPILOGUE

# meta_row(AS*, ptr, len, AMF_* flags): a grey line (R_META)
meta_row:
    PROLOGUE
    mov rbx, rdi
    mov r12d, ecx
    mov rcx, rdx
    mov rdx, rsi
    mov esi, R_META
    xor r8d, r8d
    call agents_row_add
    test rax, rax
    js 9f
    test r12d, r12d
    jz 9f
    mov rdi, rbx
    mov rsi, rax
    mov edx, r12d
    call agents_row_flag
9:  EPILOGUE

# cmd_wrapped(AS*, ptr, len) -> eax 1 when the text is a command's output, "<local-command-stdout>T</...>"
#   or its stderr form (MKt): its row (cmd_output)
cmd_wrapped:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, r12
    mov rsi, r13
    call trim_ws
    mov r12, rax
    mov r13, rdx
    xor r14d, r14d              # an error's
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lout_open]
    lea rcx, [rip + .Lout_close]
    call wrapped
    test rax, rax
    jnz 1f
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lerr_open]
    lea rcx, [rip + .Lerr_close]
    call wrapped
    mov r14d, 1
    test rax, rax
    jz 8f
1:  mov rdi, rbx
    mov rsi, rax
    mov ecx, r14d
    call cmd_output
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# cmd_output(AS*, ptr, len, error): a command's output row, one form from the file's system/local_command,
#   the <local-command-stdout> strings and the stream's <synthetic> record: one line (not an error's) a pill
#   ("Switched to NAME" for the model switch's "Set model to NAME", its backticks dropped: Sae, uTn), several
#   a reply without a label (its Markdown)
cmd_output:
    PROLOGUE
    mov rbx, rdi
    mov r14d, ecx
    mov rdi, rsi
    mov rsi, rdx
    call trim_ws
    mov r12, rax
    mov r13, rdx
    test r13, r13
    jz 9f
    test r14d, r14d
    jnz 5f
    mov rdi, r12
    mov rsi, r13
    mov edx, 10
    call mem_chr_n
    test rax, rax
    jns 5f
    lea rdi, [rip + utext]
    call sb_clear
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lset_model]
    call starts
    test eax, eax
    jz 3f
    lea rdi, [rip + utext]      # "Switched to " and the rest, its backticks dropped
    lea rsi, [rip + .Lswitched]
    call sb_push_cstr
    lea rdi, [rip + .Lset_model]
    call strlen
    add r12, rax
    sub r13, rax
    xor r15d, r15d
1:  cmp r15, r13
    jae 4f
    movzx esi, byte ptr [r12 + r15]
    inc r15
    cmp esi, '`'
    je 1b
    lea rdi, [rip + utext]
    call sb_push_byte
    jmp 1b
3:  lea rdi, [rip + utext]
    mov rsi, r12
    mov rdx, r13
    call sb_push
4:  mov rdi, rbx
    mov esi, R_INFO
    mov rdx, [rip + utext + SB_ptr]
    mov rcx, [rip + utext + SB_len]
    xor r8d, r8d
    call agents_row_add
    test rax, rax
    js 9f
    mov rdi, rbx
    mov rsi, rax
    mov edx, AMF_PILL
    call agents_row_flag
    EPILOGUE
5:  mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    mov ecx, 1
    call agents_reply_add
9:  EPILOGUE

# mem_chr_n(ptr, len, byte) -> rax its first index, -1
mem_chr_n:
    xor eax, eax
1:  cmp rax, rsi
    jae 8f
    cmp byte ptr [rdi + rax], dl
    je 9f
    inc rax
    jmp 1b
8:  mov rax, -1
9:  ret

# echo_tags(AS*, ptr, len) -> eax 1 when the text is a command's echo in a recorded form
#   ("<command-name>/x</command-name>…<command-args>A</command-args>", a custom command's
#   "<command-message>x</command-message>\n<command-name>/x</command-name>": sVe, 31): its row, "/x A"
echo_tags:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lcmd_tag]
    call starts
    test eax, eax
    jz 8f
    cmp byte ptr [r12 + r13 - 1], '>'
    jne 8f
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lname_open]
    lea rcx, [rip + .Lname_close]
    call between
    test rax, rax
    jz 8f
    mov rdi, rax
    mov rsi, rdx
    call trim_ws
    test rdx, rdx
    jz 8f
    cmp rdx, ECHO_NAME_MAX
    ja 8f
    cmp byte ptr [rax], '/'     # its name without the "/"
    jne 1f
    inc rax
    dec rdx
    jz 8f
1:  mov r14, rax
    mov r15, rdx
    mov rdi, rax
    mov rsi, rdx
    mov edx, 10
    call mem_chr_n
    test rax, rax
    jns 8f
    lea rdi, [rip + utext]
    call sb_clear
    lea rdi, [rip + utext]
    mov esi, '/'
    call sb_push_byte
    lea rdi, [rip + utext]
    mov rsi, r14
    mov rdx, r15
    call sb_push
    mov rdi, r12                # its arguments
    mov rsi, r13
    lea rdx, [rip + .Largs_open]
    lea rcx, [rip + .Largs_close]
    call between
    test rax, rax
    jz 2f
    mov rdi, rax
    mov rsi, rdx
    call trim_ws
    test rdx, rdx
    jz 2f
    mov [rsp], rax
    mov [rsp + 8], rdx
    lea rdi, [rip + utext]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + utext]
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    call sb_push
2:  lea rdi, [rip + utext]      # (the name stays where it is in the record: utext holds the line)
    mov rsi, [rip + utext + SB_ptr]
    mov rdx, [rip + utext + SB_len]
    mov rcx, rsi
    inc rcx
    mov r8, r15
    mov rdi, rbx
    call echo_row
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# slash_name(ptr, len) -> rax the length of a command's name after a leading "/" (letters, digits, "-", "_",
#   ":", "."), followed by the end or a blank; 0 when it is none
slash_name:
    mov eax, 1
1:  cmp rax, rsi
    jae 3f
    movzx ecx, byte ptr [rdi + rax]
    cmp ecx, ' '
    je 3f
    cmp ecx, 10
    je 3f
    cmp ecx, 9
    je 3f
    cmp ecx, '-'
    je 2f
    cmp ecx, '_'
    je 2f
    cmp ecx, ':'
    je 2f
    cmp ecx, '.'
    je 2f
    mov edx, ecx
    sub edx, '0'
    cmp edx, 9
    jbe 2f
    or ecx, 0x20
    sub ecx, 'a'
    cmp ecx, 25
    ja 8f
2:  inc rax
    jmp 1b
3:  dec rax
    ret
8:  xor eax, eax
    ret

# echo_row(AS*, line ptr, len, name ptr, len): a command's echo, a prompt row with AMF_ECHO. In a file the
#   /compact command's echo comes after its compaction's marker and summary (30); the marker that is the last
#   row then moves after it, so that the file gives echo, marker, output as the stream does (where rhun made
#   the echo when it was sent)
echo_row:
    PROLOGUE 48
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov qword ptr [rsp], 0      # the marker moved: its text (owned), length, n, flags, time
    cmp dword ptr [rip + cb_flags], ING_FILE
    jne 2f
    mov rdi, rcx
    mov rsi, r8
    lea rdx, [rip + .Lw_compact]
    call text_is
    test eax, eax
    jz 2f
    mov r14, [rbx + AS_msgs + VEC_len]
    test r14, r14
    jz 2f
    dec r14
    imul r15, r14, AM_SIZE
    add r15, [rbx + AS_msgs + VEC_ptr]
    cmp dword ptr [r15 + AM_role], R_COMPACT
    jne 2f
    mov rdi, [r15 + AM_text]
    mov rsi, [r15 + AM_len]
    call mem_dup
    mov [rsp], rax
    mov rax, [r15 + AM_len]
    mov [rsp + 8], rax
    mov eax, [r15 + AM_n]
    mov [rsp + 16], eax
    mov eax, [r15 + AM_flags]
    and eax, AMF_MANUAL
    mov [rsp + 20], eax
    mov rax, [r15 + AM_t]
    mov [rsp + 24], rax
    mov rdi, rbx
    mov rsi, r14
    call agents_rows_cut
2:  mov rdi, rbx
    mov esi, R_USER
    mov rdx, r12
    mov rcx, r13
    xor r8d, r8d
    call agents_row_add
    test rax, rax
    js 3f
    mov rdi, rbx
    mov rsi, rax
    mov edx, AMF_ECHO
    call agents_row_flag
3:  cmp qword ptr [rsp], 0
    je 9f
    mov rax, [rbx + AS_now]     # the marker again, with its own time
    mov [rsp + 32], rax
    mov rdi, rbx
    mov rsi, [rsp + 24]
    call agents_stamp
    mov rdi, rbx
    mov esi, R_COMPACT
    mov rdx, [rsp]
    mov rcx, [rsp + 8]
    xor r8d, r8d
    call agents_row_add
    test rax, rax
    js 4f
    imul rcx, rax, AM_SIZE
    add rcx, [rbx + AS_msgs + VEC_ptr]
    mov edx, [rsp + 16]
    mov [rcx + AM_n], edx
    mov rdi, rbx
    mov rsi, rax
    mov edx, [rsp + 20]
    call agents_row_flag
4:  mov rdi, rbx
    mov rsi, [rsp + 32]
    call agents_stamp
    mov rdi, [rsp]
    call mem_free
9:  EPILOGUE

# compact_summary(AS*, ptr, len): a compaction's summary (the user string after its boundary): the text of the
#   marker that is the last row and has none yet; nothing else
compact_summary:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, [rbx + AS_msgs + VEC_len]
    test r14, r14
    jz 9f
    dec r14
    imul rax, r14, AM_SIZE
    add rax, [rbx + AS_msgs + VEC_ptr]
    cmp dword ptr [rax + AM_role], R_COMPACT
    jne 9f
    cmp qword ptr [rax + AM_len], 0
    jne 9f
    mov rdi, rbx
    mov rsi, r14
    mov rdx, r12
    mov rcx, r13
    call agents_msg_set
9:  EPILOGUE

# diag_line(AS*, ptr, len) -> eax 1 when the text is a diagnostics hook's
#   ("<post-tool-use-hook><ide_diagnostics>[…]</ide_diagnostics></post-tool-use-hook>": PKt): a meta line
#   "Found N new problem(s)" (its Problems tab is phase 4); its JSON is counted, not parsed (the reader must
#   not parse while it reads)
diag_line:
    PROLOGUE
    mov rbx, rdi
    mov rdi, rsi
    mov rsi, rdx
    lea rdx, [rip + .Lhook_open]
    lea rcx, [rip + .Lhook_close]
    call wrapped
    test rax, rax
    jz 8f
    mov rdi, rax
    mov rsi, rdx
    call trim_ws
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + .Ldiag_open]
    lea rcx, [rip + .Ldiag_close]
    call wrapped
    test rax, rax
    jz 8f
    mov rdi, rax
    mov rsi, rdx
    call json_objects
    test eax, eax
    jz 8f
    mov r12d, eax
    lea rdi, [rip + utext]
    call sb_clear
    lea rdi, [rip + utext]
    lea rsi, [rip + .Lfound_sp]
    call sb_push_cstr
    lea rdi, [rip + utext]
    mov esi, r12d
    lea rdx, [rip + .Lnew_problem]
    call plural
    mov rdi, rbx
    mov rsi, [rip + utext + SB_ptr]
    mov rdx, [rip + utext + SB_len]
    xor ecx, ecx
    call meta_row
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# json_objects(ptr, len) -> eax the objects at the top level of a JSON array's text ("[{…}, {…}]"), counted
#   by their braces outside strings; 0 when it is no array
json_objects:
    xor eax, eax
    xor ecx, ecx                # the depth
    xor edx, edx                # in a string
    xor r8d, r8d
1:  cmp r8, rsi
    jae 9f
    movzx r9d, byte ptr [rdi + r8]
    inc r8
    test edx, edx
    jz 2f
    cmp r9d, '\\'
    jne 11f
    inc r8
    jmp 1b
11: cmp r9d, '"'
    jne 1b
    xor edx, edx
    jmp 1b
2:  cmp r9d, '"'
    jne 3f
    mov edx, 1
    jmp 1b
3:  cmp r9d, '['
    je 4f
    cmp r9d, '{'
    jne 5f
    cmp ecx, 1
    jne 4f
    inc eax
4:  inc ecx
    jmp 1b
5:  cmp r9d, ']'
    je 6f
    cmp r9d, '}'
    jne 1b
6:  dec ecx
    jmp 1b
9:  ret

# notice_row(AS*, ptr, len) -> eax 1 when the text is a wrapped notice (ND: a known tag around it, closed once
#   at its end; teammate, cross-session and channel messages too, whose own form is phase 7): a meta row with
#   AMF_NOTICE, its label, a line feed, the text inside the tags
notice_row:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    lea r14, [rip + notice_tags]
1:  mov rdx, [r14]
    test rdx, rdx
    jz 8f
    mov rdi, r12
    mov rsi, r13
    call starts
    test eax, eax
    jz 7f
    mov rdi, [r14]              # the open tag's end: ">" or a blank and attributes
    call strlen
    cmp rax, r13
    jae 7f
    movzx ecx, byte ptr [r12 + rax]
    cmp ecx, '>'
    je 2f
    cmp ecx, ' '
    je 2f
    cmp ecx, 9
    jne 7f
2:  mov rdi, r12
    mov rsi, r13
    mov rdx, [r14 + 8]
    call has
    test eax, eax
    jz 7f
    mov rdi, r12                # inside: after the open tag's ">", before the last "</"
    mov rsi, r13
    mov edx, '>'
    call mem_chr_n
    test rax, rax
    js 7f
    lea r15, [r12 + rax + 1]
    mov rcx, r13
3:  dec rcx
    js 7f
    cmp byte ptr [r12 + rcx], '<'
    jne 3b
    lea rax, [r12 + rcx]
    cmp rax, r15
    jb 7f
    sub rax, r15
    mov [rsp], rax
    lea rdi, [rip + utext]
    call sb_clear
    lea rdi, [rip + utext]
    mov rsi, [r14 + 16]
    call sb_push_cstr
    lea rdi, [rip + utext]
    mov esi, 10
    call sb_push_byte
    mov rdi, r15
    mov rsi, [rsp]
    call trim_ws
    lea rdi, [rip + utext]
    mov rsi, rax
    call sb_push
    mov rdi, rbx
    mov rsi, [rip + utext + SB_ptr]
    mov rdx, [rip + utext + SB_len]
    mov ecx, AMF_NOTICE
    call meta_row
    mov eax, 1
    EPILOGUE
7:  add r14, 24
    jmp 1b
8:  xor eax, eax
    EPILOGUE

# chip_of(ptr, len) -> eax 1 when the text is a chip of a prompt (pushed into pchips): an editor selection
#   ("<ide_selection>The user selected the lines A to B from PATH:…": "NAME#A-B", opening PATH:A-B; gKt), an
#   opened file ("<ide_opened_file>The user opened the file PATH in the IDE…": NAME, opening PATH; yKt), a
#   terminal ('<terminal name="N">…': N) or a browser tab ('<browser tabGroupId=…>URL</browser>': URL). A path
#   of more than 4096 bytes or with a control character is none (AD)
chip_of:
    PROLOGUE 48
    mov r12, rdi
    mov r13, rsi
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lsel_open]
    lea rcx, [rip + .Lsel_close]
    call wrapped
    test rax, rax
    jnz .Lchip_sel
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lfile_open]
    lea rcx, [rip + .Lfile_close]
    call wrapped
    test rax, rax
    jnz .Lchip_file
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lterm_open]
    lea rcx, [rip + .Lterm_close]
    call wrapped
    test rax, rax
    jnz .Lchip_term
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lbrowser_open]
    lea rcx, [rip + .Lbrowser_close]
    call wrapped
    test rax, rax
    jnz .Lchip_browser
8:  xor eax, eax
    EPILOGUE
.Lchip_sel:                     # "The user selected [the lines A to B ]from PATH:" then a line feed
    mov r12, rax
    mov r13, rdx
    mov qword ptr [rsp + 32], 0 # A, B (0: none)
    mov qword ptr [rsp + 40], 0
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lsel_said]
    call starts
    test eax, eax
    jz 8b
    lea rdi, [rip + .Lsel_said]
    call strlen
    add r12, rax
    sub r13, rax
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lsel_lines]
    call starts
    test eax, eax
    jz 2f
    lea rdi, [rip + .Lsel_lines]
    call strlen
    add r12, rax
    sub r13, rax
    mov rdi, r12
    mov rsi, r13
    call dec_at
    test rdx, rdx
    jz 8b
    mov [rsp + 32], rax
    add r12, rdx
    sub r13, rdx
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lsel_to]
    call starts
    test eax, eax
    jz 8b
    add r12, 4
    sub r13, 4
    mov rdi, r12
    mov rsi, r13
    call dec_at
    test rdx, rdx
    jz 8b
    mov [rsp + 40], rax
    add r12, rdx
    sub r13, rdx
    cmp r13, 1
    jb 8b
    cmp byte ptr [r12], ' '
    jne 8b
    inc r12
    dec r13
2:  mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lsel_from]
    call starts
    test eax, eax
    jz 8b
    add r12, 5
    sub r13, 5
    mov rdi, r12                # the path: to the line's end, less its ":"
    mov rsi, r13
    mov edx, 10
    call mem_chr_n
    test rax, rax
    jns 3f
    mov rax, r13
3:  cmp rax, 2
    jb 8b
    cmp byte ptr [r12 + rax - 1], ':'
    jne 8b
    lea r13, [rax - 1]
    mov rdi, r12
    mov rsi, r13
    call path_ok
    test eax, eax
    jz 8b
    lea rdi, [rip + t3]         # the target: PATH[:A-B]
    call sb_clear
    lea rdi, [rip + t3]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    mov rdi, r12                # the label: NAME[#A-B]
    mov rsi, r13
    call base
    mov [rsp], rax
    mov [rsp + 8], rdx
    lea rdi, [rip + t2]
    call sb_clear
    lea rdi, [rip + t2]
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    call sb_push
    cmp qword ptr [rsp + 32], 0
    je 4f
    lea rdi, [rip + t2]
    mov esi, '#'
    call sb_push_byte
    lea rdi, [rip + t3]
    mov esi, ':'
    call sb_push_byte
    lea rdi, [rip + t2]
    mov rsi, [rsp + 32]
    mov rdx, [rsp + 40]
    call lines_ab
    lea rdi, [rip + t3]
    mov rsi, [rsp + 32]
    mov rdx, [rsp + 40]
    call lines_ab
4:  mov rdi, [rip + t2 + SB_ptr]
    mov rsi, [rip + t2 + SB_len]
    mov rdx, [rip + t3 + SB_ptr]
    mov rcx, [rip + t3 + SB_len]
    call push_chip
    mov eax, 1
    EPILOGUE
.Lchip_file:                    # "The user opened [the ]file PATH in the IDE…"
    mov r12, rax
    mov r13, rdx
    lea r14, [rip + .Lfile_said]
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    call starts
    test eax, eax
    jnz 5f
    lea r14, [rip + .Lfile_said2]
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    call starts
    test eax, eax
    jz 8b
5:  mov rdi, r14
    call strlen
    add r12, rax
    sub r13, rax
    mov r14, r13                # the path ends at its last " in "
6:  dec r14
    js 8b
    cmp r14, 1
    jb 8b
    mov rdi, r12
    add rdi, r14
    mov rsi, r13
    sub rsi, r14
    lea rdx, [rip + .Lin_ide]
    call starts
    test eax, eax
    jz 6b
    mov r13, r14
    mov rdi, r12
    mov rsi, r13
    call path_ok
    test eax, eax
    jz 8b
    mov rdi, r12
    mov rsi, r13
    call base
    mov rdi, rax
    mov rsi, rdx
    mov rdx, r12
    mov rcx, r13
    call push_chip
    mov eax, 1
    EPILOGUE
.Lchip_term:                    # '<terminal name="N">': its name
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lterm_open]
    lea rcx, [rip + .Lquote_gt]
    call between
    test rax, rax
    jz 8b
    mov r12, rax
    mov r13, rdx
    mov rdi, r12
    mov rsi, r13
    call path_ok
    test eax, eax
    jz 8b
    mov rdi, r12
    mov rsi, r13
    xor edx, edx
    xor ecx, ecx
    call push_chip
    mov eax, 1
    EPILOGUE
.Lchip_browser:                 # its address, without its scheme
    mov rdi, r12
    mov rsi, r13
    call trim_ws
    mov rdi, rax
    mov rsi, rdx
    mov edx, '>'
    push rax
    push rdx
    call mem_chr_n
    pop rdx
    pop rcx
    test rax, rax
    js 8b
    lea r12, [rcx + rax + 1]
    lea r13, [rcx + rdx]
    lea rdi, [rip + .Lbrowser_close]
    call strlen
    sub r13, rax
    sub r13, r12
    jbe 8b
    mov rdi, r12                # (no "://": the whole is kept)
    mov rsi, r13
    lea rdx, [rip + .Lscheme]
    mov rcx, 3
    push rdi
    push rsi
    call str_find
    pop rsi
    pop rdi
    test rax, rax
    js 7f
    lea r12, [rdi + rax + 3]
    sub rsi, rax
    sub rsi, 3
    mov r13, rsi
7:  mov rdi, r12
    mov rsi, r13
    call path_ok
    test eax, eax
    jz 8b
    mov rdi, r12
    mov rsi, r13
    xor edx, edx
    xor ecx, ecx
    call push_chip
    mov eax, 1
    EPILOGUE

# lines_ab(sb, a, b): "A-B" pushed
lines_ab:
    PROLOGUE
    mov rbx, rdi
    mov r12, rdx
    call sb_push_u64
    mov rdi, rbx
    mov esi, '-'
    call sb_push_byte
    mov rdi, rbx
    mov rsi, r12
    call sb_push_u64
    EPILOGUE

# dec_at(ptr, len) -> rax the decimal number the text begins with, rdx its digits (0: none; 9 at most)
dec_at:
    xor eax, eax
    xor edx, edx
1:  cmp rdx, rsi
    jae 9f
    cmp rdx, 9
    jae 9f
    movzx ecx, byte ptr [rdi + rdx]
    sub ecx, '0'
    cmp ecx, 9
    ja 9f
    imul rax, rax, 10
    add rax, rcx
    inc rdx
    jmp 1b
9:  ret

# path_ok(ptr, len) -> eax 1 for a chip's path or name: 1 to 4096 bytes, no control character
path_ok:
    xor eax, eax
    test rsi, rsi
    jz 9f
    cmp rsi, CHIP_PATH_MAX
    ja 9f
    xor ecx, ecx
1:  cmp rcx, rsi
    jae 8f
    cmp byte ptr [rdi + rcx], ' '
    jb 9f
    cmp byte ptr [rdi + rcx], 127
    je 9f
    inc rcx
    jmp 1b
8:  mov eax, 1
9:  ret

# push_chip(label ptr, len, target ptr, len): a chip into pchips, "LABEL\tTARGET" (a line feed before it when
#   there are chips already; 16 at most)
push_chip:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    mov rdi, [rip + pchips + SB_ptr]
    mov rsi, [rip + pchips + SB_len]
    test rsi, rsi
    jz 2f
    call nlines
    cmp eax, 16
    jae 9f
    lea rdi, [rip + pchips]
    mov esi, 10
    call sb_push_byte
2:  xor ebx, ebx
3:  cmp rbx, r13
    jae 4f
    movzx esi, byte ptr [r12 + rbx]
    inc rbx
    cmp esi, ' '
    jae 31f
    mov esi, ' '
31: lea rdi, [rip + pchips]
    call sb_push_byte
    jmp 3b
4:  lea rdi, [rip + pchips]
    mov esi, 9
    call sb_push_byte
    test r15, r15
    jz 9f
    lea rdi, [rip + pchips]
    mov rsi, r14
    mov rdx, r15
    call sb_push
9:  EPILOGUE

# media_chip(block, type jv): an image block of a prompt is the chip "[Image]" (its thumbnail is phase 4), a
#   document its title, else "Document"; any other block nothing
media_chip:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, r12
    lea rsi, [rip + .Lv_image]
    call json_is
    test eax, eax
    jz 1f
    lea rdi, [rip + .Lchip_image]
    call strlen
    lea rdi, [rip + .Lchip_image]
    mov rsi, rax
    xor edx, edx
    xor ecx, ecx
    call push_chip
    EPILOGUE
1:  mov rdi, r12
    lea rsi, [rip + .Lv_document]
    call json_is
    test eax, eax
    jz 9f
    mov rdi, rbx
    lea rsi, [rip + .Lk_title]
    call jstr
    test rdx, rdx
    jnz 2f
    lea rdi, [rip + .Lchip_doc]
    call strlen
    mov rdx, rax
    lea rax, [rip + .Lchip_doc]
2:  cmp rdx, 200
    jbe 3f
    mov edx, 200
3:  mov rdi, rax
    mov rsi, rdx
    xor edx, edx
    xor ecx, ecx
    call push_chip
9:  EPILOGUE

# ---------------- system records (task 8) ----------------

# ing_system(AS*, record): a system record of the stream or line of the file, by its subtype:
#   compact_boundary (a compaction's marker: the stream's compact_metadata {trigger, pre_tokens}, the file's
#   compactMetadata {trigger, preTokens}: finding 30), informational with a text (a prompt a hook blocked: a
#   meta line, 32), local_command (the file's output of a command the CLI ran itself, 31); the rest (hooks,
#   stop_hook_summary, permission_denied, …) no row
ing_system:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, r12
    lea rsi, [rip + .Lk_subtype]
    call json_get
    mov r13, rax
    mov rdi, r13
    lea rsi, [rip + .Lv_boundary]
    call json_is
    test eax, eax
    jz 1f
    mov rdi, rbx
    mov rsi, r12
    call compact_row
    EPILOGUE
1:  mov rdi, r13
    lea rsi, [rip + .Lv_informational]
    call json_is
    test eax, eax
    jz 2f
    mov rdi, r12
    lea rsi, [rip + .Lk_content]
    call jstr
    test rdx, rdx
    jz 9f
    mov rdi, rbx
    mov rsi, rax
    xor ecx, ecx
    call meta_row
    EPILOGUE
2:  mov rdi, r13
    lea rsi, [rip + .Lv_local_command]
    call json_is
    test eax, eax
    jz 9f
    mov rdi, r12
    lea rsi, [rip + .Lk_content]
    call jstr
    test rdx, rdx
    jz 9f
    mov rdi, rbx
    mov rsi, rax
    call cmd_wrapped
9:  EPILOGUE

# compact_row(AS*, record): a compaction's marker (R_COMPACT): the thousands of tokens it freed (its tokens
#   before it, rounded: $Rt), manual or automatic; its summary is its text when the user string after it
#   comes (compact_summary)
compact_row:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, r12
    lea rsi, [rip + .Lk_cmeta]
    call json_get
    test rax, rax
    jnz 1f
    mov rdi, r12
    lea rsi, [rip + .Lk_cmeta_file]
    call json_get
1:  mov r13, rax
    mov rdi, r13
    lea rsi, [rip + .Lk_pre]
    call jnum_or
    cmp eax, -1
    jne 2f
    mov rdi, r13
    lea rsi, [rip + .Lk_pre_file]
    call jnum_or
    cmp eax, -1
    jne 2f
    xor eax, eax
2:  add eax, 500
    xor edx, edx
    mov ecx, 1000
    div ecx
    mov r14d, eax
    xor r15d, r15d
    mov rdi, r13
    lea rsi, [rip + .Lk_trigger]
    call jstr
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + .Lw_manual]
    call text_is
    test eax, eax
    jz 3f
    mov r15d, AMF_MANUAL
3:  mov rdi, rbx
    mov esi, R_COMPACT
    lea rdx, [rip + .Lempty]
    xor ecx, ecx
    xor r8d, r8d
    call agents_row_add
    test rax, rax
    js 9f
    imul rcx, rax, AM_SIZE
    add rcx, [rbx + AS_msgs + VEC_ptr]
    mov [rcx + AM_n], r14d
    mov rdi, rbx
    mov rsi, rax
    mov edx, r15d
    call agents_row_flag
9:  EPILOGUE

# ---- phase 4 task 4: long pastes (finding 43) ----
# The CLI wraps each long paste the message named in inline_pastes where it stands in the text:
# "\n\n<pasted_content id=\"XXXX\">\nPASTE\n</pasted_content id=\"XXXX\">\n" (XXXX four hex digits). The row
# shows the paste as it was: the tags and the line feeds around them (two at most each side) go, the paste
# stays (the extension's EE and jje, WV@3699613).

# starts_paste(ptr, len) -> eax 1 when the text begins with an opening tag
starts_paste:
    xor eax, eax
    cmp rsi, 20
    jb 9f
    sub rsp, 8
    lea rsi, [rip + .Lpc_open]
    mov edx, 20
    call memeq
    add rsp, 8
9:  ret

# find(hay ptr, hay len, from, needle ptr, needle len) -> rax the needle's offset at or after from, or -1
find:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov r15, r8
1:  mov rax, r13
    add rax, r15
    cmp rax, r12
    ja 8f
    mov al, [r14]
    cmp [rbx + r13], al
    jne 2f
    lea rdi, [rbx + r13]
    mov rsi, r14
    mov rdx, r15
    call memeq
    test eax, eax
    jz 2f
    mov rax, r13
    EPILOGUE
2:  inc r13
    jmp 1b
8:  mov rax, -1
    EPILOGUE

# hex4(ptr) -> eax 1 when the four bytes are lower-case hex digits
hex4:
    xor ecx, ecx
1:  movzx eax, byte ptr [rdi + rcx]
    lea edx, [rax - '0']
    cmp edx, 9
    jbe 2f
    lea edx, [rax - 'a']
    cmp edx, 5
    ja 8f
2:  inc ecx
    cmp ecx, 4
    jb 1b
    mov eax, 1
    ret
8:  xor eax, eax
    ret

# unwrap_pastes(ptr, len) -> rax ptr, rdx len: the text with its wrapped pastes as they were (pc_sb, valid
#   until the next call), or the text itself when it holds none. Locals: [rsp] i, [rsp + 8] n, [rsp + 16] a,
#   [rsp + 24] d, [rsp + 32] the closing tag's length, [rsp + 40] the id's place
unwrap_pastes:
    PROLOGUE 64
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rbx
    mov rsi, r12
    xor edx, edx
    lea rcx, [rip + .Lpc_open]
    mov r8d, 20
    call find
    test rax, rax
    js .Lup_same
    lea rdi, [rip + pc_sb]
    call sb_clear
    mov qword ptr [rsp], 0
    mov qword ptr [rsp + 8], 0
.Lup_next:
    mov rdi, rbx                # o: the next opening tag
    mov rsi, r12
    mov rdx, [rsp]
    lea rcx, [rip + .Lpc_open]
    mov r8d, 20
    call find
    test rax, rax
    js .Lup_end
    mov r13, rax                # o
    lea r14, [rax + 20]         # r: the id
    lea rax, [r14 + 7]
    cmp rax, r12
    ja .Lup_skip
    lea rdi, [rbx + r14]
    call hex4
    test eax, eax
    jz .Lup_skip
    cmp byte ptr [rbx + r14 + 4], '"'
    jne .Lup_skip
    cmp byte ptr [rbx + r14 + 5], '>'
    jne .Lup_skip
    cmp byte ptr [rbx + r14 + 6], 10
    jne .Lup_skip
    lea rax, [r14 + 7]
    mov [rsp + 16], rax         # a: the paste's start
    lea rdi, [rip + pc_tag]         # "\n</pasted_content id=\"XXXX\">"
    call sb_clear
    lea rdi, [rip + pc_tag]
    mov esi, 10
    call sb_push_byte
    lea rdi, [rip + pc_tag]
    lea rsi, [rip + .Lpc_close]
    call sb_push_cstr
    lea rdi, [rip + pc_tag]
    lea rsi, [rbx + r14]
    mov edx, 4
    call sb_push
    lea rdi, [rip + pc_tag]
    lea rsi, [rip + .Lpc_end]
    call sb_push_cstr
    mov rdi, rbx                # d: where "\n</..." begins, + 1
    mov rsi, r12
    mov rdx, [rsp + 16]
    dec rdx
    mov rcx, [rip + pc_tag + SB_ptr]
    mov r8, [rip + pc_tag + SB_len]
    call find
    test rax, rax
    js .Lup_end
    inc rax
    mov [rsp + 24], rax
    mov r15, r13                # u: back over two line feeds at most, not before n
    xor ecx, ecx
1:  cmp ecx, 2
    jae 2f
    cmp r15, [rsp + 8]
    jbe 2f
    cmp byte ptr [rbx + r15 - 1], 10
    jne 2f
    dec r15
    inc ecx
    jmp 1b
2:  mov rdx, r15                # the text before it
    sub rdx, [rsp + 8]
    jbe 3f
    lea rdi, [rip + pc_sb]
    mov rsi, [rsp + 8]
    add rsi, rbx
    call sb_push
3:  mov rdx, [rsp + 24]         # the paste: [a, d - 1)
    dec rdx
    sub rdx, [rsp + 16]
    jbe 4f
    lea rdi, [rip + pc_sb]
    mov rsi, [rsp + 16]
    add rsi, rbx
    call sb_push
4:  mov rax, [rip + pc_tag + SB_len]        # n: after the closing tag and two line feeds at most
    dec rax
    add rax, [rsp + 24]
    xor ecx, ecx
5:  cmp ecx, 2
    jae 6f
    cmp rax, r12
    jae 6f
    cmp byte ptr [rbx + rax], 10
    jne 6f
    inc rax
    inc ecx
    jmp 5b
6:  mov [rsp + 8], rax
    mov [rsp], rax
    jmp .Lup_next
.Lup_skip:
    mov [rsp], r14
    jmp .Lup_next
.Lup_end:
    mov rdx, r12                # the text after the last one
    sub rdx, [rsp + 8]
    jbe 7f
    lea rdi, [rip + pc_sb]
    mov rsi, [rsp + 8]
    add rsi, rbx
    call sb_push
7:  mov rax, [rip + pc_sb + SB_ptr]
    mov rdx, [rip + pc_sb + SB_len]
    test rax, rax
    jnz 9f
    lea rax, [rip + .Lpc_open]  # (nothing left: an empty text)
    xor edx, edx
9:  EPILOGUE
.Lup_same:
    mov rax, rbx
    mov rdx, r12
    EPILOGUE

.section .rodata
.Lpc_open: .ascii "<pasted_content id=\""
.byte 0
.Lpc_close: .asciz "</pasted_content id=\""
.Lpc_end: .asciz "\">"
.text

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

# ---------------- task 11: a subagent's calls from its file; the stream's task records ----------------

# FN claude_kids(AS*, AT*) -> eax 1 when its subagent's calls were read from their file (agrow_kids, once, when
#   its line is first opened: a conversation of 500 agents opens without reading 500 files). They are never in
#   the conversation's file (finding 34): <its file without .jsonl>/subagents/agent-<agentId>.jsonl, the id
#   its result gave (AT_aux's more), else the agent-*.meta.json whose toolUseId is the call's (at most 256
#   looked at; two that claim it: neither). Files on disk are untrusted: an id of other characters than
#   letters, digits, "-" and "_" names no file; a link (the conversation's folder, subagents, the file) is not
#   followed; at most AT_REREAD_MAX bytes are read, a last line without its line feed is not; its assistant
#   lines (a block a line) and tool_result lines go through the stream's fillers, each call an AT under this
#   one with its place in that file (AT_file), so its texts open as any row's. Nothing: the line stays and the
#   toast says so
FN claude_kids
    PROLOGUE 48
    mov rbx, rdi
    mov r12, rsi
    mov rdi, [r12 + AT_id]      # its children are made under it: it must be findable by its id
    call strlen
    mov rdi, rbx
    mov rsi, [r12 + AT_id]
    mov rdx, rax
    call agrow_find
    cmp rax, r12
    jne .Lkid_none
    mov r13, [rbx + AS_path]    # the folder: the conversation's file without ".jsonl"
    test r13, r13
    jz .Lkid_none
    mov rdi, r13
    call strlen
    mov r14, rax
    cmp r14, 6
    jbe .Lkid_none
    mov rdi, r13
    mov rsi, r14
    lea rdx, [rip + .Lt11_jsonl]
    call ends
    test eax, eax
    jz .Lkid_none
    lea rdi, [rip + kp]
    call sb_clear
    lea rdi, [rip + kp]
    mov rsi, r13
    lea rdx, [r14 - 6]
    call sb_push
    lea rdi, [rip + kp]
    mov esi, 0x4000
    call kid_nolink
    test eax, eax
    jz .Lkid_none
    lea rdi, [rip + kp]
    lea rsi, [rip + .Lt11_subagents]
    call sb_push_cstr
    lea rdi, [rip + kp]
    mov esi, 0x4000
    call kid_nolink
    test eax, eax
    jz .Lkid_none
    lea rdi, [rip + kp]
    mov esi, '/'
    call sb_push_byte
    lea rdi, [rip + kf]         # the agent's file: by the id its result gave
    call sb_clear
    lea rdi, [rip + kf]
    mov rsi, [rip + kp + SB_ptr]
    mov rdx, [rip + kp + SB_len]
    call sb_push
    mov rdi, r12
    call aux_more
    mov rdi, rax
    mov rsi, rdx
    call kid_id_ok
    test eax, eax
    jz 1f
    mov rdi, r12
    call aux_more
    mov r13, rax
    mov r14, rdx
    lea rdi, [rip + kf]
    lea rsi, [rip + .Lt11_agent]
    call sb_push_cstr
    lea rdi, [rip + kf]
    mov rsi, r13
    mov rdx, r14
    call sb_push
    jmp 2f
1:  lea rdi, [rip + km]         # else the .meta.json that names the call
    call sb_clear
    mov dword ptr [rip + mk_n], 0
    mov dword ptr [rip + mk_hits], 0
    lea rdi, [rip + kp]
    call kid_cstr
    mov rdi, rax
    lea rsi, [rip + kid_meta]
    mov rdx, r12
    call vfs_dir_each_names
    cmp dword ptr [rip + mk_hits], 1
    jne .Lkid_none
    lea rdi, [rip + kf]
    mov rsi, [rip + km + SB_ptr]
    mov rdx, [rip + km + SB_len]
    sub rdx, 10                 # without ".meta.json"
    call sb_push
2:  lea rdi, [rip + kf]
    lea rsi, [rip + .Lt11_jsonl]
    call sb_push_cstr
    lea rdi, [rip + kf]         # a file, not a link
    mov esi, 0x8000
    call kid_nolink
    test eax, eax
    jz .Lkid_none
    lea rdi, [rip + kf]
    call kid_cstr
    mov rdi, rax
    mov esi, AT_REREAD_MAX
    xor edx, edx
    call agent_read_window
    test rax, rax
    jz .Lkid_none
    mov r13, rax                # the text
    mov r14, rdx                # its length
    mov rax, [rbx + AS_line]    # (the conversation's own place goes back after)
    mov [rsp], rax
    mov rax, [rbx + AS_linelen]
    mov [rsp + 8], rax
    mov [rip + cb_as], rbx
    mov dword ptr [rip + cb_flags], ING_FILE
    mov dword ptr [rip + tm_which], -1
    xor r15d, r15d              # a line's start
3:  cmp r15, r14
    jae 7f
    mov rax, r15
31: cmp rax, r14
    jae 7f                      # a last line without its line feed: cut off, not read
    cmp byte ptr [r13 + rax], 10
    je 32f
    inc rax
    jmp 31b
32: mov [rsp + 16], rax         # its line feed
    mov rcx, rax
    sub rcx, r15
    jz 6f
    mov [rbx + AS_line], r15
    mov [rbx + AS_linelen], rcx
    lea rdi, [r13 + r15]
    mov rsi, rcx
    call json_parse
    test rax, rax
    jz 6f
    mov rdi, rbx
    mov rsi, rax
    mov rdx, r12
    call kid_line
6:  mov r15, [rsp + 16]
    inc r15
    jmp 3b
7:  mov rax, [rsp]
    mov [rbx + AS_line], rax
    mov rax, [rsp + 8]
    mov [rbx + AS_linelen], rax
    mov rdi, r13
    call mem_free
    xor r15d, r15d              # the children read: their records are in that file
8:  cmp r15, [r12 + AT_kids + VEC_len]
    jae 9f
    mov rax, [r12 + AT_kids + VEC_ptr]
    mov r13, [rax + r15*8]
    inc r15
    cmp qword ptr [r13 + AT_file], 0
    jne 8b
    cmp qword ptr [r13 + AT_uoff], 0
    jl 8b
    lea rdi, [rip + kf]
    call kid_cstr
    mov rdi, rax
    mov rsi, [rip + kf + SB_len]
    call mem_dup
    mov [r13 + AT_file], rax
    jmp 8b
9:  mov eax, 1
    EPILOGUE
.Lkid_none:
    lea rdi, [rip + .Lt11_not_on_disk]
    call app_toast
    xor eax, eax
    EPILOGUE

# kid_line(AS*, line jv, AT*): a line of a subagent's file: an assistant line's calls under the agent's call,
#   a user line's results into them; nothing else (its prompt, its text and thinking are not shown)
kid_line:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov [rsp], rdx
    mov rdi, r12
    lea rsi, [rip + .Lk_type]
    call json_get
    mov r13, rax
    mov rdi, r12
    lea rsi, [rip + .Lk_message]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lk_content]
    call json_get
    mov r14, rax
    mov rdi, r14
    call json_type
    cmp eax, JT_ARR
    jne 9f
    xor r15d, r15d
1:  mov rdi, r14
    call json_len
    cmp r15d, eax
    jae 9f
    mov rdi, r14
    mov esi, r15d
    call json_at
    mov r12, rax
    inc r15d
    mov rdi, r12
    lea rsi, [rip + .Lk_type]
    call json_get
    mov [rsp + 8], rax
    mov rdi, r13
    lea rsi, [rip + .Lv_assistant]
    call json_is
    test eax, eax
    jz 2f
    mov rdi, [rsp + 8]
    lea rsi, [rip + .Lv_tool_use]
    call json_is
    test eax, eax
    jz 1b
    mov rax, [rsp]
    mov rdi, [rax + AT_id]
    call strlen
    mov rcx, rax
    mov rax, [rsp]
    mov rdx, [rax + AT_id]
    mov rdi, rbx
    mov rsi, r12
    call call_block
    jmp 1b
2:  mov rdi, r13
    lea rsi, [rip + .Lv_user]
    call json_is
    test eax, eax
    jz 9f
    mov rdi, [rsp + 8]
    lea rsi, [rip + .Lv_tool_result]
    call json_is
    test eax, eax
    jz 1b
    mov rdi, rbx
    mov rsi, r12
    xor edx, edx
    call result_block
    jmp 1b
9:  EPILOGUE

# kid_cstr(sb) -> rax its text as a cstr (a NUL after it, not counted)
kid_cstr:
    PROLOGUE
    mov rbx, rdi
    mov esi, 0
    call sb_push_byte
    dec qword ptr [rbx + SB_len]
    mov rax, [rbx + SB_ptr]
    EPILOGUE

# kid_nolink(sb, S_IF type) -> eax 1 when that path is of that type itself (lstat: a link is none)
kid_nolink:
    PROLOGUE
    mov r12d, esi
    call kid_cstr
    mov rdi, rax
    call vfs_lstat
    test rax, rax
    js 8f
    mov eax, [rip + vfs_statbuf + 24]
    and eax, 0xf000
    cmp eax, r12d
    jne 8f
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# kid_id_ok(ptr, len) -> eax 1 for an agent's id that can name a file: 1 to 64 letters, digits, "-", "_"
kid_id_ok:
    xor eax, eax
    test rsi, rsi
    jz 9f
    cmp rsi, 64
    ja 9f
    xor ecx, ecx
1:  movzx edx, byte ptr [rdi + rcx]
    cmp edx, '-'
    je 2f
    cmp edx, '_'
    je 2f
    lea r8d, [rdx - '0']
    cmp r8d, 9
    jbe 2f
    or edx, 0x20
    sub edx, 'a'
    cmp edx, 25
    ja 9f
2:  inc rcx
    cmp rcx, rsi
    jb 1b
    mov eax, 1
9:  ret

# kid_meta(AT*, name cstr): dir_each's callback over subagents/: an agent-*.meta.json (256 looked at) whose
#   toolUseId is the call's id is a hit (km: its name)
kid_meta:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    cmp dword ptr [rip + mk_n], 256
    jae 9f
    mov rdi, r12
    call strlen
    mov r13, rax
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lt11_agent]
    call starts
    test eax, eax
    jz 9f
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lt11_meta]
    call ends
    test eax, eax
    jz 9f
    inc dword ptr [rip + mk_n]
    lea rdi, [rip + kq]
    call sb_clear
    lea rdi, [rip + kq]
    mov rsi, [rip + kp + SB_ptr]
    mov rdx, [rip + kp + SB_len]
    call sb_push
    lea rdi, [rip + kq]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    lea rdi, [rip + kq]
    mov esi, 0x8000
    call kid_nolink
    test eax, eax
    jz 9f
    lea rdi, [rip + kq]
    call kid_cstr
    mov rdi, rax
    mov esi, 65536
    xor edx, edx
    call agent_read_window
    test rax, rax
    jz 9f
    mov r14, rax
    mov rdi, rax
    mov rsi, rdx
    call json_parse
    test rax, rax
    jz 8f
    mov rdi, rax
    lea rsi, [rip + .Lt11_toolUseId]
    call jstr
    test rdx, rdx
    jz 8f
    mov rdi, rax
    mov rsi, rdx
    mov rdx, [rbx + AT_id]
    call text_is
    test eax, eax
    jz 8f
    inc dword ptr [rip + mk_hits]
    lea rdi, [rip + km]
    call sb_clear
    lea rdi, [rip + km]
    mov rsi, r12
    mov rdx, r13
    call sb_push
8:  mov rdi, r14
    call mem_free
9:  EPILOGUE

# FN claude_task(AS*, record) -> eax 1 when it was a task record: the stream's task records (finding 34) into the conversation's tasks
#   (agenttask.s): task_started {task_id, tool_use_id, description, task_type, is_backgrounded}, task_progress
#   {usage {tool_uses, total_tokens}, summary, last_tool_name} (the agent's call count: the row's count),
#   task_updated {patch {status, is_backgrounded[, error]}}, task_notification {status, summary},
#   background_tasks_changed {tasks [...]}. A foreground shell task's call may be sent to the background
#   (ATF_CANBG) until it ends or goes there; a backgrounded task's end is a meta line of its summary (as the
#   file's <task-notification> string gives it). Nothing here keeps a JSON value
FN claude_task
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    test rbx, rbx
    jz .Lct_no
    mov rdi, r12
    lea rsi, [rip + .Lt11_subtype]
    call json_get
    mov r13, rax
    mov rdi, r13
    lea rsi, [rip + .Lt11_bg_changed]
    call json_is
    test eax, eax
    jnz .Lct_list
    lea r15, [rip + .Lt11_started]  # one of the four task records, else not taken
    mov rdi, r13
    mov rsi, r15
    call json_is
    test eax, eax
    jnz 0f
    mov rdi, r13
    lea rsi, [rip + .Lt11_progress]
    call json_is
    test eax, eax
    jnz 0f
    mov rdi, r13
    lea rsi, [rip + .Lt11_updated]
    call json_is
    test eax, eax
    jnz 0f
    mov rdi, r13
    lea rsi, [rip + .Lt11_notification]
    call json_is
    test eax, eax
    jz .Lct_no
0:  mov rdi, r12
    lea rsi, [rip + .Lk_task_id]
    call jstr
    test rdx, rdx
    jz 9f
    mov rdi, rbx
    mov rsi, rax
    call agtask_get
    test rax, rax
    jz 9f
    mov r14, rax
    mov rdi, r12                # the call it runs for
    lea rsi, [rip + .Lk_tool_use_id]
    call jstr
    test rdx, rdx
    jz 1f
    mov rdi, r14
    mov esi, AKX_CALL
    mov rcx, rdx
    mov rdx, rax
    call agtask_text
1:  mov rdi, r13
    lea rsi, [rip + .Lt11_started]
    call json_is
    test eax, eax
    jz 2f
    mov rdi, r12
    lea rsi, [rip + .Lk_description]
    call jstr
    mov rdi, r14
    mov esi, AKX_LABEL
    mov rcx, rdx
    mov rdx, rax
    call agtask_text
    mov rdi, r12
    lea rsi, [rip + .Lt11_task_type]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lt11_local_bash]
    call json_is
    mov edx, AKK_AGENT
    test eax, eax
    jz 11f
    mov edx, AKK_SHELL
11: mov rdi, r14
    mov esi, AKN_KIND
    call agtask_num
    mov rdi, r12
    lea rsi, [rip + .Lt11_is_bg]
    call jtrue
    mov r15d, eax
    mov rdi, r14
    mov esi, AKN_BG
    mov edx, eax
    call agtask_num
    test r15d, r15d             # a foreground shell task: its call may go to the background
    jnz 8f
    cmp dword ptr [r14 + AK_kind], AKK_SHELL
    jne 8f
    mov rdi, rbx
    mov rsi, r14
    mov edx, 1
    call task_canbg
    jmp 8f
2:  mov rdi, r13
    lea rsi, [rip + .Lt11_progress]
    call json_is
    test eax, eax
    jz 3f
    mov rdi, r12
    lea rsi, [rip + .Lt11_usage]
    call json_get
    mov r15, rax
    mov rdi, r15
    lea rsi, [rip + .Lt11_tokens]
    call jnum_or
    xor edx, edx
    test eax, eax
    cmovns edx, eax
    mov rdi, r14
    mov esi, AKN_TOKENS
    call agtask_num
    mov rdi, r15
    lea rsi, [rip + .Lt11_uses]
    call jnum_or
    mov r15d, eax
    test eax, eax
    js 21f
    mov rdi, r14
    mov esi, AKN_USES
    mov edx, eax
    call agtask_num
    mov rdi, rbx                # the agent's call count (a background agent's result has none)
    mov rsi, r14
    mov edx, r15d
    call task_count
21: mov rdi, r12                # what it does: its summary, else the last tool it ran (nAt)
    lea rsi, [rip + .Lt11_summary]
    call jstr
    test rdx, rdx
    jnz 22f
    mov rdi, r12
    lea rsi, [rip + .Lt11_last_tool]
    call jstr
    test rdx, rdx
    jz 8f
22: mov rdi, r14
    mov esi, AKX_ACT
    mov rcx, rdx
    mov rdx, rax
    call agtask_text
    jmp 8f
3:  mov rdi, r13
    lea rsi, [rip + .Lt11_updated]
    call json_is
    test eax, eax
    jz 4f
    mov rdi, r12
    lea rsi, [rip + .Lt11_patch]
    call json_get
    mov r15, rax
    mov rdi, r15
    lea rsi, [rip + .Lt11_is_bg]
    call jtrue
    test eax, eax
    jz 31f
    mov rdi, r14                # sent to the background: a line now, no more "Run in background"
    mov esi, AKN_BG
    mov edx, 1
    call agtask_num
    mov rdi, rbx
    mov rsi, r14
    xor edx, edx
    call task_canbg
31: mov rdi, r15                # (failed's "error" is the schema's form only: never recorded)
    lea rsi, [rip + .Lt11_error]
    call jstr
    test rdx, rdx
    jz 32f
    mov rdi, r14
    mov esi, AKX_ERR
    mov rcx, rdx
    mov rdx, rax
    call agtask_text
32: mov rdi, r15
    lea rsi, [rip + .Lk_status]
    call json_get
    mov rdi, rbx
    mov rsi, r14
    mov rdx, rax
    call task_status
    jmp 8f
4:  mov rdi, r13
    lea rsi, [rip + .Lt11_notification]
    call json_is
    test eax, eax
    jz 8f
    mov rdi, r12
    lea rsi, [rip + .Lk_status]
    call json_get
    mov rdi, rbx
    mov rsi, r14
    mov rdx, rax
    call task_status
    mov rdi, rbx
    mov rsi, r14
    xor edx, edx
    call task_canbg
    cmp dword ptr [r14 + AK_bg], 0
    je 8f
    mov rdi, r12                # a backgrounded task's end: its summary as a meta line
    lea rsi, [rip + .Lt11_summary]
    call jstr
    test rdx, rdx
    jz 8f
    mov rdi, rbx                # (once: the replayed <task-notification> may have made it, task_note)
    mov rsi, rax
    call meta_once
8:  mov rdi, rbx
    mov rsi, r14
    call agtask_touch
9:  mov eax, 1
    EPILOGUE
.Lct_no:
    xor eax, eax
    EPILOGUE
.Lct_list:                      # the tasks in the background now: each one known, with its line
    mov rdi, r12
    lea rsi, [rip + .Lt11_tasks]
    call json_get
    mov r13, rax
    xor r15d, r15d
1:  mov rdi, r13
    call json_len
    cmp r15d, eax
    jae 9b
    mov rdi, r13
    mov esi, r15d
    call json_at
    mov r12, rax
    inc r15d
    mov rdi, r12
    lea rsi, [rip + .Lk_task_id]
    call jstr
    test rdx, rdx
    jz 1b
    mov rdi, rbx
    mov rsi, rax
    call agtask_get
    test rax, rax
    jz 1b
    mov r14, rax
    mov rdi, r14
    mov esi, AKN_BG
    mov edx, 1
    call agtask_num
    cmp qword ptr [r14 + AK_label], 0
    jne 2f
    mov rdi, r12
    lea rsi, [rip + .Lk_description]
    call jstr
    mov rdi, r14
    mov esi, AKX_LABEL
    mov rcx, rdx
    mov rdx, rax
    call agtask_text
    mov rdi, r12
    lea rsi, [rip + .Lt11_task_type]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lt11_local_bash]
    call json_is
    mov edx, AKK_AGENT
    test eax, eax
    jz 11f
    mov edx, AKK_SHELL
11: mov rdi, r14
    mov esi, AKN_KIND
    call agtask_num
2:  mov rdi, rbx
    mov rsi, r14
    call agtask_touch
    jmp 1b

# task_status(AS*, AK*, status jv): completed: finished; failed: failed; killed, stopped: stopped
task_status:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, r13
    lea rsi, [rip + .Lv_completed]
    call json_is
    mov edx, AKS_FINISHED
    test eax, eax
    jnz 8f
    mov rdi, r13
    lea rsi, [rip + .Lt11_failed]
    call json_is
    mov edx, AKS_FAILED
    test eax, eax
    jnz 8f
    mov rdi, r13
    lea rsi, [rip + .Lt11_killed]
    call json_is
    mov edx, AKS_STOPPED
    test eax, eax
    jnz 8f
    mov rdi, r13
    lea rsi, [rip + .Lt11_stopped]
    call json_is
    mov edx, AKS_STOPPED
    test eax, eax
    jz 9f
8:  mov rdi, r12
    mov esi, AKN_STATE
    call agtask_num
9:  EPILOGUE

# task_call(AS*, AK*) -> rax the call it runs for (agrow_find: waiting, or a parent), or 0
task_call:
    PROLOGUE
    mov rbx, rdi
    mov r12, [rsi + AK_call]
    xor eax, eax
    test r12, r12
    jz 9f
    mov rdi, r12
    call strlen
    mov rdi, rbx
    mov rsi, r12
    mov rdx, rax
    call agrow_find
9:  EPILOGUE

# task_canbg(AS*, AK*, on): its call may be sent to the background (ATF_CANBG) or not any more
task_canbg:
    PROLOGUE
    mov rbx, rdi
    mov r13d, edx
    call task_call
    test rax, rax
    jz 9f
    mov r12, rax
    mov eax, [r12 + AT_flags]
    and eax, ATF_CANBG
    test r13d, r13d
    jz 1f
    test eax, eax
    jnz 9f
    mov esi, ATV_SET
    jmp 2f
1:  test eax, eax
    jz 9f
    mov esi, ATV_CLEAR
2:  mov rdi, r12
    mov edx, ATF_CANBG
    call agrow_num
    mov rdi, rbx
    mov rsi, r12
    call agrow_touch
9:  EPILOGUE

# task_count(AS*, AK*, n): an agent's call count as its task records give it (usage.tool_uses), on its row
task_count:
    PROLOGUE
    mov rbx, rdi
    mov r13d, edx
    cmp dword ptr [rsi + AK_kind], AKK_AGENT
    jne 9f
    call task_call
    test rax, rax
    jz 9f
    mov r12, rax
    cmp [r12 + AT_nkids], r13d
    je 9f
    mov rdi, r12
    mov esi, ATV_NKIDS
    mov edx, r13d
    call agrow_num
    mov rdi, rbx
    mov rsi, r12
    call agrow_touch
9:  EPILOGUE

.bss
.p2align 3
kp: .zero SB_SIZE               # claude_kids: the subagents folder, the agent's file, a .meta.json's path,
kf: .zero SB_SIZE               #   the name of the one that names the call
kq: .zero SB_SIZE
km: .zero SB_SIZE
mk_n: .long 0                   # .meta.json files looked at, and those that named the call
mk_hits: .long 0
.section .rodata
.Lt11_jsonl: .asciz ".jsonl"
.Lt11_subagents: .asciz "/subagents"
.Lt11_agent: .asciz "agent-"
.Lt11_meta: .asciz ".meta.json"
.Lt11_toolUseId: .asciz "toolUseId"
.Lt11_not_on_disk: .asciz "This agent's calls are not on disk."
.Lt11_subtype: .asciz "subtype"
.Lt11_bg_changed: .asciz "background_tasks_changed"
.Lt11_started: .asciz "task_started"
.Lt11_progress: .asciz "task_progress"
.Lt11_updated: .asciz "task_updated"
.Lt11_notification: .asciz "task_notification"
.Lt11_task_type: .asciz "task_type"
.Lt11_local_bash: .asciz "local_bash"
.Lt11_is_bg: .asciz "is_backgrounded"
.Lt11_usage: .asciz "usage"
.Lt11_tokens: .asciz "total_tokens"
.Lt11_uses: .asciz "tool_uses"
.Lt11_summary: .asciz "summary"
.Lt11_last_tool: .asciz "last_tool_name"
.Lt11_patch: .asciz "patch"
.Lt11_error: .asciz "error"
.Lt11_failed: .asciz "failed"
.Lt11_killed: .asciz "killed"
.Lt11_stopped: .asciz "stopped"
.Lt11_tasks: .asciz "tasks"
.text

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
    mov rdi, r12                # p7c: Claude Code's own browser server as the extension names it (3.31)
    mov rsi, r14
    lea rdx, [rip + .Lp7c_chrome_srv]
    call str_eq_cstr
    test eax, eax
    jz 31f
    lea rdi, [rip + t1]
    lea rsi, [rip + .Lp7c_chrome_name]
    call sb_push_cstr
    jmp 32f
31: mov rdi, r12
    mov rsi, r14
    call humanize
32: lea rdi, [rip + t1]
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
notice_tags:                    # notice_row's {open tag, close tag, label} (ND's HVe, and the peer messages)
    .quad .Lnt_tm, .Lnt_tm_c, .Lnl_tm, .Lnt_bo, .Lnt_bo_c, .Lnl_bo, .Lnt_be, .Lnt_be_c, .Lnl_be
    .quad .Lnt_tick, .Lnt_tick_c, .Lnl_tick, .Lnt_mr, .Lnt_mr_c, .Lnl_mr, .Lnt_mp, .Lnt_mp_c, .Lnl_mp
    .quad .Lnt_cc, .Lnt_cc_c, .Lnl_cc, .Lnt_xs, .Lnt_xs_c, .Lnl_xs, .Lnt_ch, .Lnt_ch_c, .Lnl_ch
    .quad .Lnt_am, .Lnt_am_c, .Lnl_am, 0
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
.Lp7c_chrome_srv: .asciz "claude-in-chrome"     # p7c
.Lp7c_chrome_name: .asciz "Claude in Chrome"
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
.Lk_think_ms: .asciz "thinking_duration_ms"
.Lk_think_ms_file: .asciz "thinkingDurationMs"
.Lv_redacted: .asciz "redacted_thinking"
.Lv_completed: .asciz "completed"
.Lv_in_progress: .asciz "in_progress"
.Lv_deleted: .asciz "deleted"
.Lmark_stop: .asciz "[Request interrupted by user]"
.Lmark_tool: .asciz "[Request interrupted by user for tool use]"
.Linterrupted: .asciz "Interrupted"
.Ltool_interrupted: .asciz "Tool interrupted"
.Lk_subtype: .asciz "subtype"
.Lk_lcs: .asciz "local_command_source"
.Lk_error: .asciz "error"
.Lk_isCompactSummary: .asciz "isCompactSummary"
.Lk_isSynthetic: .asciz "isSynthetic"
.Lk_cmeta: .asciz "compact_metadata"
.Lk_cmeta_file: .asciz "compactMetadata"
.Lk_pre: .asciz "pre_tokens"
.Lk_pre_file: .asciz "preTokens"
.Lk_trigger: .asciz "trigger"
.Lv_system: .asciz "system"
.Lv_boundary: .asciz "compact_boundary"
.Lv_informational: .asciz "informational"
.Lv_local_command: .asciz "local_command"
.Lv_image: .asciz "image"
.Lv_document: .asciz "document"
.Lw_manual: .asciz "manual"
.Lw_compact: .asciz "compact"
.Ltn_open: .asciz "<task-notification"
.Ltn_close: .asciz "</task-notification>"
.Lsum_open: .asciz "<summary>"
.Lsum_close: .asciz "</summary>"
.Lout_open: .asciz "<local-command-stdout>"
.Lout_close: .asciz "</local-command-stdout>"
.Lerr_open: .asciz "<local-command-stderr>"
.Lerr_close: .asciz "</local-command-stderr>"
.Lset_model: .asciz "Set model to "
.Lswitched: .asciz "Switched to "
.Lcmd_tag: .asciz "<command-"
.Lname_open: .asciz "<command-name>"
.Lname_close: .asciz "</command-name>"
.Largs_open: .asciz "<command-args>"
.Largs_close: .asciz "</command-args>"
.Lhook_open: .asciz "<post-tool-use-hook>"
.Lhook_close: .asciz "</post-tool-use-hook>"
.Ldiag_open: .asciz "<ide_diagnostics>"
.Ldiag_close: .asciz "</ide_diagnostics>"
.Lfound_sp: .asciz "Found "
.Lnew_problem: .asciz "new problem"
.Lsel_open: .asciz "<ide_selection>"
.Lsel_close: .asciz "</ide_selection>"
.Lsel_said: .asciz "The user selected "
.Lsel_lines: .asciz "the lines "
.Lsel_to: .asciz " to "
.Lsel_from: .asciz "from "
.Lfile_open: .asciz "<ide_opened_file>"
.Lfile_close: .asciz "</ide_opened_file>"
.Lfile_said: .asciz "The user opened the file "
.Lfile_said2: .asciz "The user opened file "
.Lin_ide: .asciz " in "
.Lterm_open: .asciz "<terminal name=\""
.Lterm_close: .asciz "</terminal>"
.Lquote_gt: .asciz "\">"
.Lbrowser_open: .asciz "<browser tabGroupId=\""
.Lbrowser_close: .asciz "</browser>"
.Lchip_image: .asciz "[Image]"
.Lchip_doc: .asciz "Document"
.Lnt_tm: .asciz "<teammate-message"
.Lnt_tm_c: .asciz "</teammate-message>"
.Lnl_tm: .asciz "Teammate message"
.Lnt_bo: .asciz "<bash-stdout"
.Lnt_bo_c: .asciz "</bash-stdout>"
.Lnl_bo: .asciz "Terminal command output"
.Lnt_be: .asciz "<bash-stderr"
.Lnt_be_c: .asciz "</bash-stderr>"
.Lnl_be: .asciz "Terminal command error output"
.Lnt_tick: .asciz "<tick"
.Lnt_tick_c: .asciz "</tick>"
.Lnl_tick: .asciz "Autonomous prompt"
.Lnt_mr: .asciz "<mcp-resource-update"
.Lnt_mr_c: .asciz "</mcp-resource-update>"
.Lnl_mr: .asciz "MCP resource update"
.Lnt_mp: .asciz "<mcp-polling-update"
.Lnt_mp_c: .asciz "</mcp-polling-update>"
.Lnl_mp: .asciz "MCP polling update"
.Lnt_cc: .asciz "<local-command-caveat"
.Lnt_cc_c: .asciz "</local-command-caveat>"
.Lnl_cc: .asciz "Command caveat"
.Lnt_xs: .asciz "<cross-session-message"
.Lnt_xs_c: .asciz "</cross-session-message>"
.Lnl_xs: .asciz "Message from another session"
.Lnt_ch: .asciz "<channel"
.Lnt_ch_c: .asciz "</channel>"
.Lnl_ch: .asciz "Channel message"
.Lnt_am: .asciz "<agent-message"
.Lnt_am_c: .asciz "</agent-message>"
.Lnl_am: .asciz "Agent message"
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
