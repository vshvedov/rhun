# Claude Code's fork from a message, rewind and export (phase 6, claude-chat-p6b), and a turn cut off by quitting
# continued after a restart. Everything here is Claude's; the generic half is agentfork.s and the dialog shell
# agentdlg.s. Reached through DRV_action (claude_action passes ACT_REWIND .. ACT_OPENED to claude_fork_action),
# the answers through agent_claude.s's h_response (OA_FORK_*: claude_fork_answer). README findings 102 to 106.
#
# The prompts: read from the conversation's file when asked for (a user action: the Rewind picker, a prompt's
# context menu): each prompt line's uuid, parentUuid, time and text. The file's prompts and the rows are matched
# from the end by their text (pl_align), so a row knows its line. Rewind code: rewind_files {user_message_id,
# dry_run} with the prompt line's uuid (Claude Code keeps a checkpoint per prompt when it runs with
# CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING=true, which every start of rhun's sets). A fork: a new conversation
# (agent_fork_at) holding the rows before the prompt, the prompt in its box, started as
# --resume=SRC --fork-session --session-id=NEW --resume-session-at=PARENT (PARENT: the prompt line's parentUuid,
# the last entry the copy keeps). The first prompt has no parent: a new conversation with that prompt. Export:
# export_conversation {text, default_filename}: copied, or opened in a new editor tab under that name.
#
# A turn cut off by quitting: rhun's quitting tells the driver (ACT_CUT): the conversation's id and the time go
# to the project's state file session_project_file(".agents-cut") (lines "ID\tUNIX_MS\tRERUNS"). When that
# conversation is opened again ([agents] continue_after_restart, within an hour, at most two re-runs that did
# not finish) its program starts at once with CLAUDE_CODE_RESUME_INTERRUPTED_TURN=1 and
# CLAUDE_CODE_RESUME_INTERRUPTED_TURN_MAX_AGE_MS=3600000 (claude_fork_env): Claude Code runs the cut turn again by
# itself, its records carrying resume_reason. The first such record is a working turn (ev_turn_begin) with the
# line "Continuing the step that was interrupted when rhun quit."; its result takes the conversation off the list.
#
#   claude_fork_action(AL* or 0, act, ptr, len) -> eax 1   ACT_REWIND .. ACT_OPENED
#   claude_fork_answer(AL*, control_response's response, act, n)
#   claude_fork_record(AL*, record jv)       a record of a start that re-runs a cut turn (cl_line)
#   claude_fork_rerun(AL*) -> eax 1          this start re-runs a cut turn (cl_start: the environment)
#   claude_fork_c_print(out, rest, len)      print-agent-fork: the open conversation's fork source and entry
.include "rhun.inc"

.equ LINE_VALUES, 1000000       # json_parse_lim's limits for a line of the file
.equ LINE_DEPTH, 200
.equ PE_uuid, 0                 # a prompt of the file: its uuid, its parentUuid (cstrs, empty none),
.equ PE_parent, 40              #   unix ms, its text (owned), its length, its row (-1: none)
.equ PE_t, 80
.equ PE_text, 88
.equ PE_len, 96
.equ PE_row, 104
.equ PE_SIZE, 112
.equ ID_MAX, 39                 # an id's characters at most
.equ LOOK_AHEAD, 8              # pl_align: file prompts skipped at most to match a row
.equ FL_PICK, 0                 # the Rewind dialog's flows: the picker's (three choices), Rewind code to here,
.equ FL_CODE, 1                 #   Fork conversation and rewind code; the export dialog
.equ FL_BOTH, 2
.equ FL_EXPORT, 3
.equ ST_LIST, 0                 # its stages: the picker's list, the dry run asked, its answer shown
.equ ST_CHECK, 1
.equ ST_SHOWN, 2
.equ CH_BOTH, 0                 # the picker's choices, in the extension's order (sPn)
.equ CH_CONV, 1
.equ CH_CODE, 2
.equ CA_PICK, 1                 # the dialog's acts: a prompt picked (arg: its index), a choice (arg), Restore,
.equ CA_CHOICE, 2               #   Never mind, Copy to clipboard, Save to file, Close
.equ CA_GO, 3
.equ CA_NEVER, 4
.equ CA_COPY, 5
.equ CA_SAVE, 6
.equ CA_CLOSE, 7
.equ RQ_CHECK, 1                # what to ask once the process is up
.equ RQ_EXPORT, 2
.equ CUT_sid, 0                 # a cut conversation: its id, unix ms, re-runs begun
.equ CUT_t, 40
.equ CUT_n, 48
.equ CUT_SIZE, 56
.equ CUT_MAX_AGE, 3600000       # an hour (the extension's NJe; the CLI's MAX_AGE_MS)
.equ RERUNS_MAX, 2              # the extension's mSr
.equ CUT_FILE_MAX, 65536

.bss
.p2align 3
pes: .zero VEC_SIZE             # PE: the prompts of pe_as's file, in the file's order
pe_as: .quad 0
fsb: .zero SB_SIZE              # scratch
fsb2: .zero SB_SIZE
files: .zero VEC_SIZE           # owned cstrs: the dry run's files
fd_as: .quad 0                  # the dialog's conversation
fd_flow: .quad 0
fd_stage: .quad 0
fd_choice: .quad 0
fd_pend: .quad 0                # RQ_* asked once the process is up
fd_open: .quad 0                # 1 while one of these dialogs is open
sel_uuid: .zero 40              # the prompt picked: its line's uuid and parentUuid, its text, its row
sel_parent: .zero 40
sel_text: .quad 0
sel_len: .quad 0
sel_row: .quad 0
chk_ok: .quad 0                 # the dry run's answer: it came, canRewind, insertions, deletions, its error
chk_can: .quad 0
chk_ins: .quad 0
chk_del: .quad 0
chk_err: .quad 0                # owned cstr or 0
rw_as: .quad 0                  # a rewind sent: its conversation, whether a fork follows, the fork's prompt
rw_after: .quad 0
rw_parent: .zero 40
rw_text: .quad 0
rw_len: .quad 0
rw_row: .quad 0
ex_text: .quad 0                # the export: its text (owned), length, file name (owned), status line, wanted name
ex_len: .quad 0
ex_name: .quad 0
ex_status: .quad 0              # static cstr or 0
ex_want: .quad 0                # owned cstr: /export NAME's name, 0 none (the dialog)
cuts: .zero VEC_SIZE            # CUT
csb: .zero SB_SIZE              # the cut file's text

.text

# ---------------- the acts ----------------

# FN claude_fork_action(AL* or 0, act, ptr, len) -> eax 1
FN claude_fork_action
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    cmp r12d, ACT_OPENED
    jne 1f
    mov rdi, r13
    call opened
    jmp 8f
1:  test rbx, rbx
    jz 9f
    cmp r12d, ACT_CUT
    jne 2f
    mov rdi, rbx
    call cut_note
    jmp 8f
2:  cmp r12d, ACT_REWIND
    jne 3f
    mov rdi, rbx
    call open_picker
    jmp 8f
3:  cmp r12d, ACT_EXPORT
    jne 4f
    mov rdi, rbx
    mov rsi, r13
    mov rdx, r14
    call open_export
    jmp 8f
4:  cmp r12d, ACT_MSGACT
    jne 9f
    mov rdi, rbx
    mov rsi, r13
    mov edx, r14d
    call msg_action
8:  mov eax, 1
    EPILOGUE
9:  xor eax, eax
    EPILOGUE

# ---------------- the prompts of the file ----------------

# pl_free(): the list emptied (texts freed)
pl_free:
    PROLOGUE
    xor ebx, ebx
1:  cmp rbx, [rip + pes + VEC_len]
    jae 2f
    imul rax, rbx, PE_SIZE
    add rax, [rip + pes + VEC_ptr]
    mov rdi, [rax + PE_text]
    call mem_free
    inc rbx
    jmp 1b
2:  mov qword ptr [rip + pes + VEC_len], 0
    mov qword ptr [rip + pe_as], 0
    EPILOGUE

# pl_load(AS*): the prompts of its file (none when it has no file yet), then matched with its rows (pl_align)
pl_load:
    PROLOGUE 16
    mov rbx, rdi
    call pl_free
    mov [rip + pe_as], rbx
    mov rdi, [rbx + AS_path]
    test rdi, rdi
    jz 8f
    call vfs_read_all
    test rax, rax
    jz 8f
    mov r12, rax                # the file
    mov r13, rdx
    xor r14d, r14d              # a line's start
1:  cmp r14, r13
    jae 7f
    mov r15, r14                # its end
2:  cmp r15, r13
    jae 3f
    cmp byte ptr [r12 + r15], 10
    je 3f
    inc r15
    jmp 2b
3:  lea rdi, [r12 + r14]
    mov rsi, r15
    sub rsi, r14
    mov [rsp], r15
    call pl_line
    mov r14, [rsp]
    inc r14
    jmp 1b
7:  mov rdi, r12
    call mem_free
8:  mov rdi, rbx
    call pl_align
    EPILOGUE

# pl_line(ptr, len): a line of the file: a prompt of the user's is added to the list
pl_line:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rbx                # cheap first: only a line that names "user" is parsed
    mov rsi, r12
    lea rdx, [rip + .Lq_user]
    mov ecx, 6
    call str_find
    test rax, rax
    js 9f
    mov rdi, rbx
    mov rsi, r12
    mov edx, LINE_VALUES
    mov ecx, LINE_DEPTH
    call json_parse_lim
    test rax, rax
    jz 9f
    mov r13, rax
    mov rdi, r13
    lea rsi, [rip + .Lk_type]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lv_user]
    call json_is
    test eax, eax
    jz 9f
    lea r14, [rip + skip_keys]  # isMeta, isSidechain, isCompactSummary, isVisibleInTranscriptOnly: not a prompt
1:  mov rsi, [r14]
    test rsi, rsi
    jz 2f
    mov rdi, r13
    call json_get
    mov rdi, rax
    call json_type
    cmp eax, JT_TRUE
    je 9f
    add r14, 8
    jmp 1b
2:  lea rdi, [rip + fsb]        # its text: a string, or its text blocks with a line feed between them
    call sb_clear
    mov rdi, r13
    lea rsi, [rip + .Lk_message]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lk_content]
    call json_get
    mov r14, rax
    mov rdi, rax
    call json_type
    cmp eax, JT_STR
    jne 3f
    mov rdi, r14
    call json_str
    lea rdi, [rip + fsb]
    mov rsi, rax
    call sb_push
    jmp 5f
3:  cmp eax, JT_ARR
    jne 9f
    xor r15d, r15d
4:  mov rdi, r14
    call json_len
    cmp r15, rax
    jae 5f
    mov rdi, r14
    mov rsi, r15
    call json_at
    mov [rsp], rax
    inc r15
    mov rdi, rax
    lea rsi, [rip + .Lk_type]
    call json_get
    mov [rsp + 8], rax
    mov rdi, rax
    lea rsi, [rip + .Lv_tool_result]
    call json_is
    test eax, eax
    jnz 9f                      # a tool's result: not a prompt
    mov rdi, [rsp + 8]
    lea rsi, [rip + .Lv_text]
    call json_is
    test eax, eax
    jz 4b
    mov rdi, [rsp]
    lea rsi, [rip + .Lv_text]
    call json_get
    mov rdi, rax
    call json_str
    test rdx, rdx
    jz 4b
    mov [rsp], rax
    mov [rsp + 8], rdx
    cmp qword ptr [rip + fsb + SB_len], 0
    je 41f
    lea rdi, [rip + fsb]
    mov esi, 10
    call sb_push_byte
41: lea rdi, [rip + fsb]
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    call sb_push
    jmp 4b
5:  mov rdi, [rip + fsb + SB_ptr]   # trimmed; empty, or a command's echo or output, or a mark: not a prompt
    mov rsi, [rip + fsb + SB_len]
    call trim
    test rdx, rdx
    jz 9f
    mov r14, rax
    mov r15, rdx
    lea rcx, [rip + skip_heads]
6:  mov rdx, [rcx]
    test rdx, rdx
    jz 61f
    mov [rsp], rcx
    mov rdi, rdx
    call strlen
    mov rcx, rax
    mov rdi, r14
    mov rsi, r15
    mov rax, [rsp]
    mov rdx, [rax]
    call str_starts
    test eax, eax
    jnz 9f
    mov rcx, [rsp]
    add rcx, 8
    jmp 6b
61: lea rdi, [rip + pes]
    mov esi, PE_SIZE
    call vec_push
    mov rbx, rax
    mov qword ptr [rbx + PE_row], -1
    mov rdi, r14
    mov rsi, r15
    call mem_dup
    mov [rbx + PE_text], rax
    mov [rbx + PE_len], r15
    mov rdi, r13
    lea rsi, [rip + .Lk_uuid]
    call json_get
    mov rdi, rax
    lea rsi, [rbx + PE_uuid]
    call id_copy
    mov rdi, r13
    lea rsi, [rip + .Lk_parent]
    call json_get
    mov rdi, rax
    lea rsi, [rbx + PE_parent]
    call id_copy
    mov rdi, r13
    lea rsi, [rip + .Lk_timestamp]
    call json_get
    mov rdi, rax
    call json_str
    mov rdi, rax
    mov rsi, rdx
    call agtime_iso
    mov [rbx + PE_t], rax
9:  EPILOGUE

# id_copy(jv, buf 40): a string of at most ID_MAX bytes into buf, else an empty buf
id_copy:
    PROLOGUE
    mov rbx, rsi
    mov byte ptr [rbx], 0
    call json_str
    test rdx, rdx
    jz 9f
    cmp rdx, ID_MAX
    ja 9f
    mov r12, rdx
    mov rdi, rbx
    mov rsi, rax
    call memcpy
    mov byte ptr [rbx + r12], 0
9:  EPILOGUE

# trim(ptr, len) -> rax ptr, rdx len: without the white space at both ends
trim:
    mov rax, rdi
    mov rdx, rsi
1:  test rdx, rdx
    jz 3f
    cmp byte ptr [rax], ' '
    ja 2f
    inc rax
    dec rdx
    jmp 1b
2:  cmp byte ptr [rax + rdx - 1], ' '
    ja 3f
    dec rdx
    jmp 2b
3:  ret

# is_prompt_row(AS*, i) -> eax 1 when row i is a prompt of the user's with text (not an echo, not waiting)
is_prompt_row:
    imul rax, rsi, AM_SIZE
    add rax, [rdi + AS_msgs + VEC_ptr]
    xor ecx, ecx
    cmp dword ptr [rax + AM_role], R_USER
    jne 1f
    test dword ptr [rax + AM_flags], AMF_ECHO | AMF_QUEUED
    jnz 1f
    cmp qword ptr [rax + AM_len], 0
    je 1f
    mov ecx, 1
1:  mov eax, ecx
    ret

# fits(AS*, row, PE*) -> eax 1 when the row shows that prompt: the same text, or the prompt's text holds the row's
#   (the row shows only what the user typed; the line may carry the editor's context as well)
fits:
    PROLOGUE
    mov rbx, rdx
    imul rax, rsi, AM_SIZE
    add rax, [rdi + AS_msgs + VEC_ptr]
    mov rdi, [rax + AM_text]
    mov rsi, [rax + AM_len]
    call trim
    xor ecx, ecx
    test rdx, rdx
    jz 9f
    mov r12, rax
    mov r13, rdx
    mov rdi, [rbx + PE_text]
    mov rsi, [rbx + PE_len]
    mov rdx, r12
    mov rcx, r13
    call str_find
    xor ecx, ecx
    test rax, rax
    js 9f
    mov ecx, 1
9:  mov eax, ecx
    EPILOGUE

# pl_align(AS*): each prompt of the list gets its row (PE_row), matched from the end; a row no prompt fits is
#   passed over, so are up to LOOK_AHEAD prompts that have no row (a prompt the reader shows otherwise)
pl_align:
    PROLOGUE
    mov rbx, rdi
    mov r12, [rbx + AS_msgs + VEC_len]
    dec r12                     # the row
    mov r13, [rip + pes + VEC_len]
    dec r13                     # the prompt
1:  test r12, r12
    js 9f
    test r13, r13
    js 9f
    mov rdi, rbx
    mov rsi, r12
    call is_prompt_row
    test eax, eax
    jnz 2f
    dec r12
    jmp 1b
2:  xor r14d, r14d              # how far back the prompt that fits is
3:  cmp r14, LOOK_AHEAD
    ja 5f
    mov r15, r13
    sub r15, r14
    js 5f
    imul rdx, r15, PE_SIZE
    add rdx, [rip + pes + VEC_ptr]
    mov rdi, rbx
    mov rsi, r12
    call fits
    test eax, eax
    jnz 4f
    inc r14
    jmp 3b
4:  imul rax, r15, PE_SIZE
    add rax, [rip + pes + VEC_ptr]
    mov [rax + PE_row], r12
    lea r13, [r15 - 1]
5:  dec r12
    jmp 1b
9:  EPILOGUE

# pe_of_row(row) -> rax the PE matched with that row, or 0
pe_of_row:
    xor eax, eax
    xor ecx, ecx
1:  cmp rcx, [rip + pes + VEC_len]
    jae 9f
    imul rdx, rcx, PE_SIZE
    add rdx, [rip + pes + VEC_ptr]
    inc rcx
    cmp [rdx + PE_row], rdi
    jne 1b
    mov rax, rdx
9:  ret

# sel_take(PE*): the prompt picked (its ids, text and row copied)
sel_take:
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rip + sel_uuid]
    lea rsi, [rbx + PE_uuid]
    call cstr_copy
    lea rdi, [rip + sel_parent]
    lea rsi, [rbx + PE_parent]
    call cstr_copy
    mov rdi, [rip + sel_text]
    call mem_free
    mov rdi, [rbx + PE_text]
    mov rsi, [rbx + PE_len]
    call mem_dup
    mov [rip + sel_text], rax
    mov rax, [rbx + PE_len]
    mov [rip + sel_len], rax
    mov rax, [rbx + PE_row]     # a prompt with no row: its fork holds the rows before the next matched one
    test rax, rax
    jns 3f
    mov rax, [rip + pe_as]
    mov rax, [rax + AS_msgs + VEC_len]
    mov rcx, rbx
    sub rcx, [rip + pes + VEC_ptr]
1:  add rcx, PE_SIZE
    mov rdx, [rip + pes + VEC_len]
    imul rdx, rdx, PE_SIZE
    cmp rcx, rdx
    jae 3f
    mov rdx, [rip + pes + VEC_ptr]
    mov rdx, [rdx + rcx + PE_row]
    test rdx, rdx
    js 1b
    mov rax, rdx
3:  mov [rip + sel_row], rax
    EPILOGUE

# ---------------- the fork ----------------

# do_fork(AS* src, parent cstr, text, len, row): a fork holding src's rows before row and the prompt in its box;
#   with a parent, started as a copy of src up to it (ALF_FORK, AL_fork, AL_forkat); without, a new conversation
do_fork:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov r15, r8
    mov rdi, rbx
    mov rsi, r15
    mov rdx, r13
    mov rcx, r14
    call agent_fork_at
    test rax, rax
    jz 8f
    cmp byte ptr [r12], 0
    je 9f
    mov r15, rax
    or dword ptr [r15 + AL_flags], ALF_FORK
    lea rdi, [r15 + AL_forkat]
    mov rsi, r12
    call cstr_copy
    mov rdi, rbx
    lea rsi, [r15 + AL_fork]
    call as_sid
    mov rdi, rbx
    call agent_live
    test rax, rax
    jz 9f
    mov rdi, r15                # the copy lives where its source does
    mov rsi, rax
    call claude_fork_dir
9:  EPILOGUE
8:  lea rdi, [rip + .Lfork_failed]
    call app_toast
    EPILOGUE

# as_sid(AS*, buf 40) -> eax 1: its id, its file's name without ".jsonl" (an empty buf when it has none)
as_sid:
    PROLOGUE
    mov rbx, rsi
    mov byte ptr [rbx], 0
    mov r12, [rdi + AS_path]
    xor eax, eax
    test r12, r12
    jz 9f
    mov rdi, r12
    call strlen
    mov r13, rax
    mov rcx, rax
1:  test rcx, rcx
    jz 2f
    cmp byte ptr [r12 + rcx - 1], '/'
    je 2f
    cmp byte ptr [r12 + rcx - 1], '\\'
    je 2f
    dec rcx
    jmp 1b
2:  lea r14, [r12 + rcx]
    mov r15, r13
    sub r15, rcx
    cmp r15, 6
    jb 3f
    lea rdi, [r14 + r15 - 6]
    lea rsi, [rip + .Ljsonl]
    mov edx, 6
    call memeq
    test eax, eax
    jz 3f
    sub r15, 6
3:  xor eax, eax
    test r15, r15
    jz 9f
    cmp r15, ID_MAX
    ja 9f
    mov rdi, rbx
    mov rsi, r14
    mov rdx, r15
    call memcpy
    mov byte ptr [rbx + r15], 0
    mov eax, 1
9:  EPILOGUE

# msg_action(AL*, row, MSG_*): a prompt row's action: Fork conversation from here at once; Rewind code to here and
#   Fork conversation and rewind code through their dialog (the dry run first)
msg_action:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov r14, [rbx + AL_as]
    mov rdi, r14
    call pl_load
    mov rdi, r12
    call pe_of_row
    test rax, rax
    jnz 1f
    lea rdi, [rip + .Lnot_found]
    cmp r13d, MSG_FORK
    je 11f
    lea rdi, [rip + .Lno_checkpoint]
11: call app_toast
    EPILOGUE
1:  mov rdi, rax
    call sel_take
    cmp r13d, MSG_FORK
    jne 2f
    mov rdi, r14
    lea rsi, [rip + sel_parent]
    mov rdx, [rip + sel_text]
    mov rcx, [rip + sel_len]
    mov r8, [rip + sel_row]
    call do_fork
    EPILOGUE
2:  mov ecx, FL_CODE
    mov edx, FL_BOTH
    cmp r13d, MSG_BOTH
    cmove ecx, edx
    mov r15d, ecx
    lea rdx, [rip + .Lt_code]
    lea rax, [rip + .Lt_both]
    cmp r15d, FL_BOTH
    cmove rdx, rax
    mov rdi, r14
    lea rsi, [rip + .Ln_rewind]
    lea rcx, [rip + fd_ops]
    call agentdlg_open
    call fd_reset
    mov [rip + fd_as], r14
    mov [rip + fd_flow], r15
    mov qword ptr [rip + fd_open], 1
    call check_begin
    EPILOGUE

# fd_reset(): the dialog's state as new (its answers freed)
fd_reset:
    PROLOGUE
    call chk_clear
    mov qword ptr [rip + fd_stage], ST_LIST
    mov qword ptr [rip + fd_choice], CH_BOTH
    mov qword ptr [rip + fd_pend], 0
    mov qword ptr [rip + ex_status], 0
    EPILOGUE

# chk_clear(): the dry run's answer forgotten
chk_clear:
    PROLOGUE
    mov qword ptr [rip + chk_ok], 0
    mov qword ptr [rip + chk_can], 0
    mov qword ptr [rip + chk_ins], 0
    mov qword ptr [rip + chk_del], 0
    mov rdi, [rip + chk_err]
    call mem_free
    mov qword ptr [rip + chk_err], 0
    xor ebx, ebx
1:  cmp rbx, [rip + files + VEC_len]
    jae 2f
    mov rax, [rip + files + VEC_ptr]
    mov rdi, [rax + rbx*8]
    call mem_free
    inc rbx
    jmp 1b
2:  mov qword ptr [rip + files + VEC_len], 0
    EPILOGUE

# check_begin(): the dry run for the prompt picked: the dialog says it checks, the request goes (or waits for the
#   process)
check_begin:
    PROLOGUE
    call chk_clear
    mov qword ptr [rip + fd_stage], ST_CHECK
    call build_rewind
    mov edi, RQ_CHECK
    call ask
    EPILOGUE

# ---------------- the Rewind picker ----------------

# open_picker(AL*): "Rewind to…": the prompts of the file, the newest first
open_picker:
    PROLOGUE
    mov rbx, rdi
    mov r12, [rbx + AL_as]
    mov rdi, r12
    lea rsi, [rip + .Ln_rewind]
    lea rdx, [rip + .Lt_pick]
    lea rcx, [rip + fd_ops]
    call agentdlg_open
    call fd_reset
    mov [rip + fd_as], r12
    mov qword ptr [rip + fd_flow], FL_PICK
    mov qword ptr [rip + fd_open], 1
    mov rdi, r12
    call pl_load
    call build_list
    EPILOGUE

# build_list(): the picker's rows
build_list:
    PROLOGUE
    mov qword ptr [rip + fd_stage], ST_LIST
    lea rdi, [rip + .Lt_pick]
    call agentdlg_title
    call agentdlg_begin
    cmp qword ptr [rip + pes + VEC_len], 0
    jne 1f
    lea rsi, [rip + .Lp_empty]
    call text_row_muted
    EPILOGUE
1:  lea rsi, [rip + .Lp_hint]
    call text_row_muted
    mov rbx, [rip + pes + VEC_len]
2:  dec rbx
    js 3f
    imul r12, rbx, PE_SIZE
    add r12, [rip + pes + VEC_ptr]
    mov edi, DGK_ITEM
    xor esi, esi
    mov edx, CA_PICK
    call agentdlg_row
    mov r13, rax
    mov [r13 + DGR_arg], rbx
    mov rdi, [r12 + PE_text]    # its first line
    mov rsi, [r12 + PE_len]
    xor ecx, ecx
21: cmp rcx, rsi
    jae 22f
    cmp byte ptr [rdi + rcx], 10
    je 22f
    inc rcx
    jmp 21b
22: mov rdx, rdi
    mov rdi, r13
    xor esi, esi
    call agentdlg_text
    lea rdi, [rip + fsb]
    call sb_clear
    lea rdi, [rip + fsb]
    mov rsi, [r12 + PE_t]
    call rel_time
    mov rdi, r13
    mov esi, 2
    mov rdx, [rip + fsb + SB_ptr]
    mov rcx, [rip + fsb + SB_len]
    call agentdlg_text
    jmp 2b
3:  mov edi, DGK_TEXT
    mov esi, DGF_MUTED | DGF_SMALL
    xor edx, edx
    call agentdlg_row
    mov rdi, rax
    xor esi, esi
    lea rdx, [rip + .Lp_keys]
    call agentdlg_ctext
    xor edi, edi
    call agentdlg_focus
    EPILOGUE

# text_row_muted(-, cstr), text_row(-, cstr), text_row_flags(flags, cstr): a TEXT row
text_row_muted:
    mov edi, DGF_MUTED
    jmp text_row_flags
text_row:
    xor edi, edi
text_row_flags:
    PROLOGUE
    mov rbx, rsi
    mov esi, edi
    mov edi, DGK_TEXT
    xor edx, edx
    call agentdlg_row
    mov rdi, rax
    xor esi, esi
    mov rdx, rbx
    call agentdlg_ctext
    EPILOGUE

# rel_time(sb, unix ms): "just now", "5m ago", "3h ago", "2d ago" (the extension's PAe); nothing for 0
rel_time:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    test r12, r12
    jz 9f
    call agtime_now
    sub rax, r12
    jns 1f
    xor eax, eax
1:  xor edx, edx
    mov ecx, 1000
    div rcx
    cmp rax, 60
    jae 2f
    mov rdi, rbx
    lea rsi, [rip + .Lr_now]
    call sb_push_cstr
    EPILOGUE
2:  xor edx, edx
    mov ecx, 60
    div rcx                     # minutes
    lea r13, [rip + .Lr_m]
    cmp rax, 60
    jb 3f
    xor edx, edx
    div rcx                     # hours
    lea r13, [rip + .Lr_h]
    cmp rax, 24
    jb 3f
    xor edx, edx
    mov ecx, 24
    div rcx                     # days
    lea r13, [rip + .Lr_d]
3:  mov rdi, rbx
    mov rsi, rax
    call sb_push_u64
    mov rdi, rbx
    mov rsi, r13
    call sb_push_cstr
9:  EPILOGUE

# ---------------- the Rewind dialog ----------------

# avail(choice) -> eax 1 when the picker offers it: the conversation always, code only when the dry run says
#   there is code to restore (rPn)
avail:
    mov eax, 1
    cmp edi, CH_CONV
    je 1f
    xor eax, eax
    cmp qword ptr [rip + chk_ok], 0
    je 1f
    cmp qword ptr [rip + chk_can], 0
    je 1f
    cmp qword ptr [rip + files + VEC_len], 0
    je 1f
    mov eax, 1
1:  ret

# choice() -> eax the picker's choice in effect (CH_CONV when the one picked is not offered)
choice:
    push rbx
    mov rbx, [rip + fd_choice]
    mov edi, ebx
    call avail
    test eax, eax
    mov eax, ebx
    jnz 1f
    mov eax, CH_CONV
1:  pop rbx
    ret

# build_rewind(): the Rewind dialog's rows and buttons for its flow and stage (Ple @5633900)
build_rewind:
    PROLOGUE
    mov rax, [rip + fd_flow]
    lea rdi, [rip + .Lt_rewind]
    cmp eax, FL_CODE
    jne 1f
    lea rdi, [rip + .Lt_code]
1:  cmp eax, FL_BOTH
    jne 2f
    lea rdi, [rip + .Lt_both]
2:  call agentdlg_title
    call agentdlg_begin
    cmp qword ptr [rip + fd_flow], FL_BOTH
    jne 3f
    lea rsi, [rip + .Lw_fork_note]
    call text_row
3:  cmp qword ptr [rip + fd_flow], FL_PICK
    jne 5f
    call choice                 # What to restore: the choices offered
    mov r13d, eax
    xor ebx, ebx
4:  cmp ebx, 3
    jae 5f
    mov edi, ebx
    call avail
    test eax, eax
    jz 41f
    xor esi, esi
    cmp ebx, r13d
    jne 42f
    mov esi, DGF_CHECK
42: mov edi, DGK_ITEM
    mov edx, CA_CHOICE
    call agentdlg_row
    mov r12, rax
    mov [r12 + DGR_arg], rbx
    mov r14, rbx
    shl r14, 4
    lea rax, [rip + choices]
    add r14, rax
    mov rdx, [r14]
    mov rdi, r12
    xor esi, esi
    call agentdlg_ctext
    mov rdx, [r14 + 8]
    mov rdi, r12
    mov esi, 1
    call agentdlg_ctext
41: inc ebx
    jmp 4b
5:  cmp qword ptr [rip + fd_stage], ST_CHECK
    jne 6f
    lea rsi, [rip + .Lw_checking]
    call text_row_muted
    jmp 8f
6:  mov rbx, [rip + chk_err]    # the dry run failed: its words
    test rbx, rbx
    jz 61f
    mov edi, DGK_TEXT
    mov esi, DGF_ERROR
    xor edx, edx
    call agentdlg_row
    mov rdi, rax
    xor esi, esi
    mov rdx, rbx
    call agentdlg_ctext
    jmp 8f
61: cmp qword ptr [rip + chk_can], 0
    je 8f
    cmp qword ptr [rip + fd_flow], FL_PICK
    jne 62f
    call choice
    cmp eax, CH_CONV
    je 8f
62: cmp qword ptr [rip + files + VEC_len], 0
    jne 63f
    lea rsi, [rip + .Lw_unchanged]
    call text_row
    jmp 66f
63: call summary_row
    xor ebx, ebx
64: cmp rbx, [rip + files + VEC_len]
    jae 66f
    mov rax, [rip + files + VEC_ptr]
    mov rdi, [rax + rbx*8]
    call shown_path
    mov r12, rax
    mov r13, rdx
    mov edi, DGK_TEXT
    mov esi, DGF_SMALL
    xor edx, edx
    call agentdlg_row
    mov rdi, rax
    xor esi, esi
    mov rdx, r12
    mov rcx, r13
    call agentdlg_text
    inc rbx
    jmp 64b
66: lea rsi, [rip + .Lw_warning]
    call text_row_muted
8:  call buttons
    EPILOGUE

# buttons(): "1 Restore" (Continue, Rewind) when it can go, "2 Never mind"
buttons:
    PROLOGUE
    mov rax, [rip + fd_flow]
    cmp eax, FL_PICK
    je 2f                       # the picker's Restore always goes (its conversation choice needs no check)
    cmp qword ptr [rip + fd_stage], ST_SHOWN
    jne 8f
    cmp qword ptr [rip + chk_can], 0
    je 8f
    cmp qword ptr [rip + files + VEC_len], 0
    jne 2f
    cmp eax, FL_BOTH
    jne 8f
2:  lea rdi, [rip + .Lb_restore]
    cmp eax, FL_CODE
    jne 21f
    lea rdi, [rip + .Lb_rewind]
21: cmp eax, FL_BOTH
    jne 22f
    lea rdi, [rip + .Lb_continue]
22: mov esi, CA_GO
    mov edx, DBF_PRIMARY | DBF_NUM
    call agentdlg_button
8:  lea rdi, [rip + .Lb_never]
    mov esi, CA_NEVER
    mov edx, DBF_NUM
    call agentdlg_button
    EPILOGUE

# summary_row(): "N lines will be removed and M lines will be added across K files:"
summary_row:
    PROLOGUE
    lea rdi, [rip + fsb]
    call sb_clear
    mov rdi, [rip + chk_del]
    call count_lines
    lea rdi, [rip + fsb]
    lea rsi, [rip + .Lw_removed]
    call sb_push_cstr
    mov rdi, [rip + chk_ins]
    call count_lines
    lea rdi, [rip + fsb]
    lea rsi, [rip + .Lw_added]
    call sb_push_cstr
    lea rdi, [rip + fsb]
    mov rsi, [rip + files + VEC_len]
    call sb_push_u64
    lea rdi, [rip + fsb]
    lea rsi, [rip + .Lw_file]
    call sb_push_cstr
    cmp qword ptr [rip + files + VEC_len], 1
    je 1f
    lea rdi, [rip + fsb]
    mov esi, 's'
    call sb_push_byte
1:  lea rdi, [rip + fsb]
    mov esi, ':'
    call sb_push_byte
    mov edi, DGK_TEXT
    xor esi, esi
    xor edx, edx
    call agentdlg_row
    mov rdi, rax
    xor esi, esi
    mov rdx, [rip + fsb + SB_ptr]
    mov rcx, [rip + fsb + SB_len]
    call agentdlg_text
    EPILOGUE

# count_lines(n): "N line" or "N lines" onto fsb
count_lines:
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rip + fsb]
    mov rsi, rbx
    call sb_push_u64
    lea rdi, [rip + fsb]
    lea rsi, [rip + .Lw_line]
    call sb_push_cstr
    cmp rbx, 1
    je 9f
    lea rdi, [rip + fsb]
    mov esi, 's'
    call sb_push_byte
9:  EPILOGUE

# shown_path(cstr) -> rax ptr, rdx len: a file under the conversation's folder relative to it (uE), else whole
shown_path:
    PROLOGUE
    mov rbx, rdi
    call strlen
    mov r12, rax
    mov rax, [rip + fd_as]
    mov r13, [rax + AS_cwd]
    test r13, r13
    jnz 1f
    mov r13, [rip + g_project]
    test r13, r13
    jz 8f
1:  mov rdi, r13
    call strlen
    mov r14, rax
    test r14, r14
    jz 8f
    cmp r14, r12
    jae 8f
    mov rdi, rbx
    mov rsi, r13
    mov rdx, r14
    call memeq
    test eax, eax
    jz 8f
    movzx eax, byte ptr [rbx + r14]
    cmp eax, '/'
    je 2f
    cmp eax, '\\'
    jne 8f
2:  lea rax, [rbx + r14 + 1]
    mov rdx, r12
    sub rdx, r14
    dec rdx
    EPILOGUE
8:  mov rax, rbx
    mov rdx, r12
    EPILOGUE

# ---------------- asking ----------------

# is_up(AL*) -> eax 1 when its process is up and past its handshake
is_up:
    xor eax, eax
    test rdi, rdi
    jz 9f
    cmp dword ptr [rdi + AL_cn + CN_state], CN_UP
    jne 9f
    mov ecx, [rdi + AL_state]
    cmp ecx, ALS_READY
    je 1f
    cmp ecx, ALS_WORKING
    je 1f
    cmp ecx, ALS_WAITING
    jne 9f
1:  mov eax, 1
9:  ret

# ask(rq): the dialog's request now (the process up), once it is ready (starting), or after starting it quietly
#   (off), as the extension's launchClaude before rewind_code and export_conversation
ask:
    PROLOGUE
    mov r12d, edi
    mov rdi, [rip + fd_as]
    test rdi, rdi
    jz 9f
    call agent_live
    mov rbx, rax
    test rax, rax
    jz 9f
    mov rdi, rbx
    call is_up
    test eax, eax
    jnz 5f
    mov eax, [rbx + AL_state]
    cmp eax, ALS_STARTING
    je 3f
    cmp eax, ALS_HELD
    je 3f
    mov rdi, [rbx + AL_as]
    call agent_run
    mov rdi, [rip + fd_as]
    call agent_live
    mov rbx, rax
    mov rdi, rax
    call is_up
    test eax, eax
    jnz 5f
    mov eax, [rbx + AL_state]
    cmp eax, ALS_STARTING
    je 3f
    cmp eax, ALS_HELD
    je 3f
    lea rdi, [rip + fsb]        # it could not start: what it said, else that
    call sb_clear
    mov rdx, [rbx + AL_report + SB_len]
    lea rdi, [rip + fsb]
    mov rsi, [rbx + AL_report + SB_ptr]
    test rdx, rdx
    jnz 1f
    lea rsi, [rip + .Lno_start]
    call sb_push_cstr
    jmp 2f
1:  call sb_push
2:  mov rdi, [rip + fsb + SB_ptr]
    mov rsi, [rip + fsb + SB_len]
    call agentdlg_fail
    jmp 9f
3:  mov [rip + fd_pend], r12
    mov rdi, rbx
    call agentdlg_pend
    jmp 9f
5:  mov edi, r12d
    mov rsi, rbx
    call send
9:  EPILOGUE

# send(rq, AL*): the request written, the dialog waiting for its answer
send:
    PROLOGUE
    mov r12d, edi
    mov rbx, rsi
    mov rdi, rbx
    cmp r12d, RQ_EXPORT
    jne 1f
    mov esi, OA_FORK_EXPORT
    lea rdx, [rip + .Lv_export]
    xor ecx, ecx
    call claude_side_req
    jmp 2f
1:  mov esi, OA_FORK_CHECK
    lea rdx, [rip + .Lv_rewind_files]
    lea rcx, [rip + fill_check]
    call claude_side_req
2:  test eax, eax
    jz 8f
    mov rdi, rbx
    mov esi, edx
    call agentdlg_wait
    EPILOGUE
8:  lea rdi, [rip + .Lnot_sent]
    call strlen
    mov rsi, rax
    lea rdi, [rip + .Lnot_sent]
    call agentdlg_fail
    EPILOGUE

# fill_check(cw), fill_rewind(cw): rewind_files' members: the prompt's uuid, and dry_run for the check
fill_check:
    PROLOGUE
    mov rbx, rdi
    lea rsi, [rip + sel_uuid]
    call fill_id
    mov rdi, rbx
    lea rsi, [rip + .Lk_dry_run]
    call jw_key
    mov rdi, rbx
    mov esi, 1
    call jw_bool
    EPILOGUE
fill_rewind:
    lea rsi, [rip + rw_uuid]
fill_id:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea rsi, [rip + .Lk_user_message_id]
    call jw_key
    mov rdi, rbx
    mov rsi, r12
    call jw_cstr
    EPILOGUE

# ---------------- the dialog's acts ----------------

# fd_act(act, arg, DGR* or 0)
fd_act:
    PROLOGUE
    mov r12d, edi
    mov r13, rsi
    cmp r12d, DA_ASK            # the handshake is done: ask now
    jne 1f
    mov rdi, [rip + fd_as]
    call agent_live
    test rax, rax
    jz 9f
    cmp dword ptr [rax + AL_cn + CN_state], CN_UP
    jne 9f
    mov rdi, [rip + fd_pend]
    mov rsi, rax
    call send
    jmp 9f
1:  cmp r12d, CA_PICK
    jne 2f
    cmp r13, [rip + pes + VEC_len]
    jae 9f
    imul rdi, r13, PE_SIZE
    add rdi, [rip + pes + VEC_ptr]
    call sel_take
    mov qword ptr [rip + fd_choice], CH_BOTH
    call check_begin
    jmp 9f
2:  cmp r12d, CA_CHOICE
    jne 3f
    mov [rip + fd_choice], r13
    call build_rewind
    jmp 9f
3:  cmp r12d, CA_NEVER
    jne 4f
    cmp qword ptr [rip + fd_flow], FL_PICK
    jne 31f
    call chk_clear              # back to the list
    call build_list
    jmp 9f
31: call agentdlg_close
    jmp 9f
4:  cmp r12d, CA_GO
    jne 5f
    call go
    jmp 9f
5:  cmp r12d, CA_COPY
    jne 6f
    mov rdi, [rip + ex_text]
    test rdi, rdi
    jz 9f
    mov rsi, [rip + ex_len]
    xor edx, edx
    call ed_clip_set
    lea rax, [rip + .Le_copied]
    mov [rip + ex_status], rax
    call build_export
    jmp 9f
6:  cmp r12d, CA_SAVE
    jne 7f
    cmp qword ptr [rip + ex_text], 0
    je 9f
    mov rdi, [rip + ex_name]
    call save_export
    call agentdlg_close
    jmp 9f
7:  cmp r12d, CA_CLOSE
    jne 9f
    call agentdlg_close
9:  EPILOGUE

# fd_free(): the dialog closed
fd_free:
    PROLOGUE
    mov qword ptr [rip + fd_open], 0
    mov qword ptr [rip + fd_as], 0
    call chk_clear
    call ex_clear
    EPILOGUE

# go(): Restore (Continue, Rewind): the dialog closes, then the conversation is forked, the code rewound, or both
#   (the code first, the fork once it is done: qBn)
go:
    PROLOGUE
    mov rbx, [rip + fd_as]
    mov r12d, CH_CODE
    mov rax, [rip + fd_flow]
    cmp eax, FL_CODE
    je 1f
    mov r12d, CH_BOTH
    cmp eax, FL_BOTH
    je 1f
    call choice
    mov r12d, eax
1:  lea rdi, [rip + rw_uuid]    # what the rewind and the fork need, kept past the dialog
    lea rsi, [rip + sel_uuid]
    call cstr_copy
    lea rdi, [rip + rw_parent]
    lea rsi, [rip + sel_parent]
    call cstr_copy
    mov rdi, [rip + rw_text]
    call mem_free
    mov rdi, [rip + sel_text]
    mov rsi, [rip + sel_len]
    call mem_dup
    mov [rip + rw_text], rax
    mov rax, [rip + sel_len]
    mov [rip + rw_len], rax
    mov rax, [rip + sel_row]
    mov [rip + rw_row], rax
    call agentdlg_close
    mov [rip + rw_as], rbx
    cmp r12d, CH_CONV
    jne 2f
    call fork_kept
    EPILOGUE
2:  xor eax, eax
    cmp r12d, CH_BOTH
    sete al
    mov [rip + rw_after], rax
    mov rdi, rbx
    call agent_live
    mov r13, rax
    mov rdi, rax
    call is_up
    test eax, eax
    jz 8f
    mov rdi, r13
    mov esi, OA_FORK_REWIND
    lea rdx, [rip + .Lv_rewind_files]
    lea rcx, [rip + fill_rewind]
    call claude_side_req
    test eax, eax
    jnz 9f
8:  lea rdi, [rip + .Lrw_not_running]
    call app_toast
9:  EPILOGUE

# fork_kept(): the fork of the prompt kept by go (rw_*), of rw_as or the dialog's conversation
fork_kept:
    PROLOGUE
    mov rdi, [rip + rw_as]
    test rdi, rdi
    jnz 1f
    mov rdi, rbx
1:  test rdi, rdi
    jz 9f
    lea rsi, [rip + rw_parent]
    mov rdx, [rip + rw_text]
    mov rcx, [rip + rw_len]
    mov r8, [rip + rw_row]
    call do_fork
9:  mov qword ptr [rip + rw_as], 0
    EPILOGUE

# ---------------- the answers ----------------

# FN claude_fork_answer(AL*, control_response's response, act, n)
FN claude_fork_answer
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov r14, rcx
    mov rdi, r12
    lea rsi, [rip + .Lk_subtype]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lv_success]
    call json_is
    mov r15d, eax               # 1 success
    cmp r13d, OA_FORK_REWIND
    je .Lan_rewind
    mov rdi, rbx                # the dry run and the export: the open dialog's
    mov rsi, r14
    call agentdlg_waits
    test eax, eax
    jz 9f
    cmp r13d, OA_FORK_EXPORT
    je .Lan_export
    call chk_clear              # the dry run: {canRewind, error?, filesChanged?, insertions?, deletions?}
    mov qword ptr [rip + fd_stage], ST_SHOWN
    mov qword ptr [rip + chk_ok], 1
    test r15d, r15d
    jz 5f
    mov rdi, r12
    lea rsi, [rip + .Lk_response]
    call json_get
    mov r13, rax
    mov rdi, r13
    lea rsi, [rip + .Lk_can]
    call json_get
    mov rdi, rax
    call json_type
    xor ecx, ecx
    cmp eax, JT_TRUE
    sete cl
    mov [rip + chk_can], rcx
    mov rdi, r13
    lea rsi, [rip + .Lk_insertions]
    call json_get
    mov rdi, rax
    call json_int
    mov [rip + chk_ins], rax
    mov rdi, r13
    lea rsi, [rip + .Lk_deletions]
    call json_get
    mov rdi, rax
    call json_int
    mov [rip + chk_del], rax
    mov rdi, r13
    lea rsi, [rip + .Lk_files]
    call json_get
    mov r14, rax
    xor r15d, r15d
1:  mov rdi, r14
    call json_len
    cmp r15, rax
    jae 2f
    mov rdi, r14
    mov rsi, r15
    call json_at
    inc r15
    mov rdi, rax
    call json_str
    test rdx, rdx
    jz 1b
    mov rdi, rax
    mov rsi, rdx
    call mem_dup                # (mem_dup ends it with a NUL)
    mov [rsp], rax
    lea rdi, [rip + files]
    mov esi, 8
    call vec_push
    mov rcx, [rsp]
    mov [rax], rcx
    jmp 1b
2:  mov rdi, r13                # a refusal's words
    lea rsi, [rip + .Lk_error]
    call json_get
    mov rdi, rax
    call json_str
    test rdx, rdx
    jz 3f
    jmp 6f
3:  cmp qword ptr [rip + chk_can], 0
    jne 8f
    lea rax, [rip + .Lrw_failed]
    mov rdi, rax
    call strlen
    mov rdx, rax
    lea rax, [rip + .Lrw_failed]
    jmp 6f
5:  call err_text
6:  mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov [rip + chk_err], rax
8:  call build_rewind
9:  EPILOGUE
.Lan_export:
    call ex_clear_text
    test r15d, r15d
    jz 2f
    mov rdi, r12
    lea rsi, [rip + .Lk_response]
    call json_get
    mov r13, rax
    mov rdi, r13
    lea rsi, [rip + .Lk_text]
    call json_get
    mov r14, rax
    mov rdi, rax
    call json_type
    cmp eax, JT_STR
    jne 1f
    mov rdi, r14
    call json_str
    mov [rip + ex_len], rdx
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov [rip + ex_text], rax
    mov rdi, r13
    lea rsi, [rip + .Lk_filename]
    call json_get
    mov rdi, rax
    call json_str
    test rdx, rdx
    jz 1f
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov [rip + ex_name], rax
    cmp qword ptr [rip + ex_want], 0    # /export NAME: straight into the editor
    je 11f
    call export_direct
    EPILOGUE
11: call build_export
    EPILOGUE
1:  lea rax, [rip + .Le_none]   # (no text: the extension's "No export was returned")
    mov rdi, rax
    call strlen
    mov rdx, rax
    lea rax, [rip + .Le_none]
    jmp 3f
2:  call err_text
3:  mov r13, rax
    mov r14, rdx
    lea rdi, [rip + fsb]
    call sb_clear
    lea rdi, [rip + fsb]
    lea rsi, [rip + .Le_failed]
    call sb_push_cstr
    lea rdi, [rip + fsb]
    mov rsi, r13
    mov rdx, r14
    call sb_push
    mov rdi, [rip + fsb + SB_ptr]
    mov rsi, [rip + fsb + SB_len]
    call agentdlg_fail
    EPILOGUE
.Lan_rewind:                    # the rewind itself: its meta line, then the fork that waits for it
    mov r13, [rip + rw_as]
    test r15d, r15d
    jz 3f
    mov rdi, r12
    lea rsi, [rip + .Lk_response]
    call json_get
    mov r14, rax
    mov rdi, r14
    lea rsi, [rip + .Lk_can]
    call json_get
    mov rdi, rax
    call json_type
    cmp eax, JT_TRUE
    jne 2f
    mov rdi, r14
    lea rsi, [rip + .Lk_skipped]
    call json_get
    mov rdi, rax
    call json_int
    mov r14, rax
    lea rdi, [rip + fsb]        # "Code rewind successful", or what was skipped (OA)
    call sb_clear
    test r14, r14
    jnz 1f
    lea rdi, [rip + fsb]
    lea rsi, [rip + .Lrw_done]
    call sb_push_cstr
    jmp 11f
1:  lea rdi, [rip + fsb]
    lea rsi, [rip + .Lrw_some]
    call sb_push_cstr
    lea rdi, [rip + fsb]
    mov rsi, r14
    call sb_push_u64
    lea rdi, [rip + fsb]
    lea rsi, [rip + .Lrw_was]
    cmp r14, 1
    je 12f
    lea rsi, [rip + .Lrw_were]
12: call sb_push_cstr
11: mov rdi, [rbx + AL_as]
    mov esi, R_META
    mov rdx, [rip + fsb + SB_ptr]
    mov rcx, [rip + fsb + SB_len]
    xor r8d, r8d
    call agents_msg_add
    mov dword ptr [rip + g_dirty], 1
    cmp qword ptr [rip + rw_after], 0
    je 8f
    mov qword ptr [rip + rw_after], 0
    mov rbx, [rbx + AL_as]
    call fork_kept
    EPILOGUE
2:  mov rdi, r14                # canRewind false: its error
    lea rsi, [rip + .Lk_error]
    call json_get
    mov rdi, rax
    call json_str
    jmp 4f
3:  call err_text
4:  mov r13, rax
    mov r14, rdx
    lea rdi, [rip + fsb]
    call sb_clear
    lea rdi, [rip + fsb]
    lea rsi, [rip + .Lrw_failed]
    call sb_push_cstr
    test r14, r14
    jz 5f
    lea rdi, [rip + fsb]
    lea rsi, [rip + .Lcolon]
    call sb_push_cstr
    lea rdi, [rip + fsb]
    mov rsi, r13
    mov rdx, r14
    call sb_push
5:  lea rdi, [rip + fsb]
    xor esi, esi
    call sb_push_byte
    mov rdi, [rip + fsb + SB_ptr]
    call app_toast
8:  mov qword ptr [rip + rw_after], 0
    mov qword ptr [rip + rw_as], 0
    EPILOGUE

# err_text() -> rax ptr, rdx len: an error answer's text (r12: the response), or a word when it has none
err_text:
    PROLOGUE
    mov rdi, r12
    lea rsi, [rip + .Lk_error]
    call json_get
    mov rdi, rax
    call json_str
    test rdx, rdx
    jnz 9f
    lea rdi, [rip + .Lrw_failed]
    call strlen
    mov rdx, rax
    lea rax, [rip + .Lrw_failed]
9:  EPILOGUE

# ---------------- export ----------------

# ex_clear_text(), ex_clear(): the export's text and name forgotten (and the wanted name)
ex_clear:
    PROLOGUE
    mov rdi, [rip + ex_want]
    call mem_free
    mov qword ptr [rip + ex_want], 0
    call ex_clear_text
    EPILOGUE
ex_clear_text:
    PROLOGUE
    mov rdi, [rip + ex_text]
    call mem_free
    mov rdi, [rip + ex_name]
    call mem_free
    mov qword ptr [rip + ex_text], 0
    mov qword ptr [rip + ex_name], 0
    mov qword ptr [rip + ex_len], 0
    EPILOGUE

# open_export(AL*, name ptr, len): Export conversation (hPt @5612766); /export NAME goes straight to the editor
#   under that name (openExportForSaving's rule: its last path part, no ':', ".txt" when it has no extension)
open_export:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, [rbx + AL_as]
    mov rdi, r14
    lea rsi, [rip + .Ln_export]
    lea rdx, [rip + .Lt_export]
    lea rcx, [rip + fd_ops]
    call agentdlg_open
    call fd_reset
    call ex_clear
    mov [rip + fd_as], r14
    mov qword ptr [rip + fd_flow], FL_EXPORT
    mov qword ptr [rip + fd_open], 1
    mov rdi, r12
    mov rsi, r13
    call want_name
    lea rdi, [rip + .Le_preparing]
    call agentdlg_loading
    mov edi, RQ_EXPORT
    call ask
    EPILOGUE

# want_name(ptr, len): ex_want from /export's argument, or 0
want_name:
    PROLOGUE
    test rdi, rdi
    jz 9f
    call trim
    test rdx, rdx
    jz 9f
    mov rbx, rax
    mov r12, rdx
    mov rcx, r12                # its last part
1:  test rcx, rcx
    jz 2f
    cmp byte ptr [rbx + rcx - 1], '/'
    je 2f
    cmp byte ptr [rbx + rcx - 1], '\\'
    je 2f
    dec rcx
    jmp 1b
2:  lea r14, [rbx + rcx]        # the part and its length
    mov r15, r12
    sub r15, rcx
    lea rdi, [rip + fsb2]
    call sb_clear
    xor ebx, ebx                # without ':'
3:  cmp rbx, r15
    jae 4f
    movzx esi, byte ptr [r14 + rbx]
    inc rbx
    cmp esi, ':'
    je 3b
    lea rdi, [rip + fsb2]
    call sb_push_byte
    jmp 3b
4:  mov rdx, [rip + fsb2 + SB_len]
    test rdx, rdx
    jz 9f
    mov rax, [rip + fsb2 + SB_ptr]
    cmp rdx, 1
    jne 41f
    cmp byte ptr [rax], '.'
    je 9f
41: cmp rdx, 2
    jne 42f
    cmp word ptr [rax], 0x2e2e  # ".."
    je 9f
42: mov rdi, rax                # no extension: ".txt" (path.extname's rule)
    mov rsi, rdx
    call has_ext
    test eax, eax
    jnz 44f
    lea rdi, [rip + fsb2]
    lea rsi, [rip + .Ltxt]
    call sb_push_cstr
44: mov rdi, [rip + fsb2 + SB_ptr]
    mov rsi, [rip + fsb2 + SB_len]
    call mem_dup
    mov [rip + ex_want], rax
9:  EPILOGUE

# has_ext(ptr, len) -> eax 1 when the name has an extension (a '.' after its first character, not its last)
has_ext:
    xor eax, eax
    mov rcx, rsi
1:  dec rcx
    jle 9f
    cmp byte ptr [rdi + rcx], '.'
    jne 1b
    lea rdx, [rcx + 1]
    cmp rdx, rsi
    je 9f
    mov eax, 1
9:  ret

# build_export(): the export dialog's rows: its length, the name Save offers, the status, the buttons
build_export:
    PROLOGUE
    call agentdlg_begin
    lea rdi, [rip + fsb]
    call sb_clear
    lea rdi, [rip + fsb]
    lea rsi, [rip + .Le_whole]
    call sb_push_cstr
    mov rdi, [rip + ex_text]
    mov rsi, [rip + ex_len]
    call utf16_len
    mov rdi, rax
    call push_grouped
    lea rdi, [rip + fsb]
    lea rsi, [rip + .Le_chars]
    call sb_push_cstr
    mov edi, DGK_TEXT
    xor esi, esi
    xor edx, edx
    call agentdlg_row
    mov rdi, rax
    xor esi, esi
    mov rdx, [rip + fsb + SB_ptr]
    mov rcx, [rip + fsb + SB_len]
    call agentdlg_text
    lea rdi, [rip + fsb]
    call sb_clear
    lea rdi, [rip + fsb]
    lea rsi, [rip + .Le_offers]
    call sb_push_cstr
    lea rdi, [rip + fsb]
    mov rsi, [rip + ex_name]
    call sb_push_cstr
    mov edi, DGK_TEXT
    mov esi, DGF_MUTED
    xor edx, edx
    call agentdlg_row
    mov rdi, rax
    xor esi, esi
    mov rdx, [rip + fsb + SB_ptr]
    mov rcx, [rip + fsb + SB_len]
    call agentdlg_text
    mov rsi, [rip + ex_status]
    test rsi, rsi
    jz 1f
    call text_row_muted
1:  lea rdi, [rip + .Lb_copy]
    mov esi, CA_COPY
    mov edx, DBF_PRIMARY
    call agentdlg_button
    lea rdi, [rip + .Lb_save]
    mov esi, CA_SAVE
    xor edx, edx
    call agentdlg_button
    lea rdi, [rip + .Lb_close]
    mov esi, CA_CLOSE
    xor edx, edx
    call agentdlg_button
    EPILOGUE

# utf16_len(ptr, len) -> rax the text's length in UTF-16 units (JavaScript's .length): a lead byte counts one,
#   one of four bytes two
utf16_len:
    xor eax, eax
    xor ecx, ecx
1:  cmp rcx, rsi
    jae 9f
    movzx edx, byte ptr [rdi + rcx]
    inc rcx
    mov r8d, edx
    and r8d, 0xc0
    cmp r8d, 0x80
    je 1b
    inc rax
    cmp edx, 0xf0
    jb 1b
    inc rax
    jmp 1b
9:  ret

# push_grouped(n): n onto fsb with a comma between thousands ("12,345", toLocaleString's)
push_grouped:
    PROLOGUE 32
    mov rbx, rdi
    lea r12, [rsp + 31]         # the digits, from the end
    mov byte ptr [r12], 0
    xor r13d, r13d              # digits written
1:  mov rax, rbx
    xor edx, edx
    mov ecx, 10
    div rcx
    mov rbx, rax
    cmp r13d, 0
    je 2f
    mov eax, r13d
    xor r8d, r8d
    push rdx
    xor edx, edx
    mov ecx, 3
    div ecx
    mov r8d, edx
    pop rdx
    test r8d, r8d
    jnz 2f
    dec r12
    mov byte ptr [r12], ','
2:  add edx, '0'
    dec r12
    mov [r12], dl
    inc r13d
    test rbx, rbx
    jnz 1b
    lea rdi, [rip + fsb]
    mov rsi, r12
    call sb_push_cstr
    EPILOGUE

# export_direct(): /export NAME: the text into the editor under that name, a meta line saying so, the dialog shut
export_direct:
    PROLOGUE
    mov rdi, [rip + ex_want]
    call save_export
    mov rax, [rip + fd_as]
    mov rbx, rax
    call agentdlg_close
    lea rdi, [rip + .Le_opened]
    call strlen
    mov rdi, rbx
    mov esi, R_META
    lea rdx, [rip + .Le_opened]
    mov rcx, rax
    xor r8d, r8d
    call agents_msg_add
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# save_export(name cstr): the export's text in a new editor tab, not yet saved, named name (Save asks where)
save_export:
    PROLOGUE
    mov r12, rdi
    call doc_new
    mov rbx, rax
    mov rdi, rbx
    mov rsi, [rip + ex_text]
    mov rdx, [rip + ex_len]
    call doc_set_text
    mov rdi, r12
    call strlen
    mov rdi, r12
    mov rsi, rax
    call mem_dup                # (the document's name: kept as long as rhun runs)
    mov [rbx + DOC_name], rax
    mov rdi, rbx
    mov esi, TAB_DOC
    call app_add_tab
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# ---------------- a turn cut off by quitting ----------------

# cut_path() -> rax the state file's path (static), or 0 without a project
cut_path:
    lea rdi, [rip + .Lcut_suffix]
    jmp session_project_file

# cut_load(): the list read from the state file (an empty list without one); entries older than an hour dropped
cut_load:
    PROLOGUE 48
    mov qword ptr [rip + cuts + VEC_len], 0
    call cut_path
    test rax, rax
    jz 9f
    mov rdi, rax
    mov esi, CUT_FILE_MAX
    call vfs_read_limited
    test rax, rax
    jz 9f
    mov r12, rax
    mov r13, rdx
    call agtime_now
    mov [rsp + 40], rax
    xor r14d, r14d
1:  cmp r14, r13                # a line: ID TAB MS TAB N
    jae 8f
    mov r15, r14
2:  cmp r15, r13
    jae 3f
    cmp byte ptr [r12 + r15], 10
    je 3f
    inc r15
    jmp 2b
3:  mov [rsp], r15
    lea rdi, [r12 + r14]        # the id
    mov rsi, r15
    sub rsi, r14
    mov rdx, rsi
    mov rcx, 0
31: cmp rcx, rdx
    jae 7f
    cmp byte ptr [rdi + rcx], 9
    je 32f
    inc rcx
    jmp 31b
32: test rcx, rcx
    jz 7f
    cmp rcx, ID_MAX
    ja 7f
    mov [rsp + 8], rdi
    mov [rsp + 16], rcx
    lea rdi, [rdi + rcx + 1]    # its time
    sub rdx, rcx
    dec rdx
    mov [rsp + 24], rdi
    mov [rsp + 32], rdx
    mov rsi, rdx
    call parse_u64
    mov rbx, rax
    mov rcx, [rsp + 24]         # its re-runs, after the second tab
    mov rsi, [rsp + 32]
    xor r8d, r8d
33: cmp r8, rsi
    jae 7f
    cmp byte ptr [rcx + r8], 9
    je 34f
    inc r8
    jmp 33b
34: lea rdi, [rcx + r8 + 1]
    sub rsi, r8
    dec rsi
    call parse_u64
    mov [rsp + 32], rax
    mov rax, [rsp + 40]         # an hour old: gone
    sub rax, rbx
    cmp rax, CUT_MAX_AGE
    ja 7f
    lea rdi, [rip + cuts]
    mov esi, CUT_SIZE
    call vec_push
    mov [rax + CUT_t], rbx
    mov rcx, [rsp + 32]
    mov [rax + CUT_n], rcx
    mov rdi, rax
    mov rsi, [rsp + 8]
    mov rdx, [rsp + 16]
    mov byte ptr [rdi + rdx], 0
    call memcpy
7:  mov r14, [rsp]
    inc r14
    jmp 1b
8:  mov rdi, r12
    call mem_free
9:  EPILOGUE

# cut_save(): the list written (the file removed when it is empty)
cut_save:
    PROLOGUE
    call cut_path
    test rax, rax
    jz 9f
    mov r12, rax
    cmp qword ptr [rip + cuts + VEC_len], 0
    jne 1f
    mov rdi, r12
    call vfs_unlink
    EPILOGUE
1:  lea rdi, [rip + csb]
    call sb_clear
    xor ebx, ebx
2:  cmp rbx, [rip + cuts + VEC_len]
    jae 3f
    imul r13, rbx, CUT_SIZE
    add r13, [rip + cuts + VEC_ptr]
    lea rdi, [rip + csb]
    lea rsi, [r13 + CUT_sid]
    call sb_push_cstr
    lea rdi, [rip + csb]
    mov esi, 9
    call sb_push_byte
    lea rdi, [rip + csb]
    mov rsi, [r13 + CUT_t]
    call sb_push_u64
    lea rdi, [rip + csb]
    mov esi, 9
    call sb_push_byte
    lea rdi, [rip + csb]
    mov rsi, [r13 + CUT_n]
    call sb_push_u64
    lea rdi, [rip + csb]
    mov esi, 10
    call sb_push_byte
    inc rbx
    jmp 2b
3:  mov rdi, r12
    call vfs_mkdir_parent
    mov rdi, r12
    mov rsi, [rip + csb + SB_ptr]
    mov rdx, [rip + csb + SB_len]
    call file_write_all
9:  EPILOGUE

# cut_find(id cstr) -> rax its CUT, or 0
cut_find:
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12, [rip + cuts + VEC_len]
    jae 8f
    imul r13, r12, CUT_SIZE
    add r13, [rip + cuts + VEC_ptr]
    inc r12
    lea rdi, [r13 + CUT_sid]
    mov rsi, rbx
    call strcmp_eq
    test eax, eax
    jz 1b
    mov rax, r13
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# cut_drop(CUT*): it leaves the list
cut_drop:
    mov rax, [rip + cuts + VEC_len]
    imul rax, rax, CUT_SIZE
    add rax, [rip + cuts + VEC_ptr]
    lea rsi, [rdi + CUT_SIZE]
    mov rdx, rax
    sub rdx, rsi
    dec qword ptr [rip + cuts + VEC_len]
    jmp memmove

# cut_note(AL*): its turn is cut off by quitting: its id and now go in the list (re-runs kept)
cut_note:
    PROLOGUE
    mov rbx, rdi
    cmp byte ptr [rbx + AL_sid], 0
    je 9f
    call cut_load
    lea rdi, [rbx + AL_sid]
    call cut_find
    test rax, rax
    jnz 1f
    lea rdi, [rip + cuts]
    mov esi, CUT_SIZE
    call vec_push
    mov qword ptr [rax + CUT_n], 0
    mov r12, rax
    lea rdi, [rax + CUT_sid]
    lea rsi, [rbx + AL_sid]
    call cstr_copy
    mov rax, r12
1:  mov r12, rax
    call agtime_now
    mov [r12 + CUT_t], rax
    call cut_save
9:  EPILOGUE

# opened(AS*): a conversation opened: when its turn was cut off by quitting less than an hour ago, fewer than
#   RERUNS_MAX re-runs of it begun, and [agents] continue_after_restart, its program starts now to run it again
opened:
    PROLOGUE 48
    mov rbx, rdi
    cmp dword ptr [rip + cfg_agents_continue], 0
    je 9f
    call cut_path               # (no state file: nothing was cut)
    test rax, rax
    jz 9f
    mov rdi, rbx
    lea rsi, [rsp]
    call as_sid
    test eax, eax
    jz 9f
    call cut_load
    lea rdi, [rsp]
    call cut_find
    test rax, rax
    jz 9f
    mov r12, rax
    cmp qword ptr [r12 + CUT_n], RERUNS_MAX
    jb 1f
    mov rdi, r12                # re-run twice and never done: given up
    call cut_drop
    call cut_save
    jmp 9f
1:  mov rdi, rbx
    call agent_live
    test rax, rax
    jz 9f
    mov r13, rax
    cmp dword ptr [r13 + AL_state], ALS_OFF
    jne 9f
    inc qword ptr [r12 + CUT_n]
    call cut_save
    or dword ptr [r13 + AL_flags], ALF_RERUN
    mov rdi, rbx
    call agent_run
9:  EPILOGUE

# FN claude_fork_rerun(AL*) -> eax 1 when this start re-runs a cut turn (its environment gets Claude Code's two
#   variables); the record is remembered for claude_fork_record and the flag goes (one start only)
FN claude_fork_rerun
    xor eax, eax
    test dword ptr [rdi + AL_flags], ALF_RERUN
    jz 1f
    and dword ptr [rdi + AL_flags], ~ALF_RERUN
    mov [rip + claude_rerun_al], rdi
    mov eax, 1
1:  ret

# FN claude_fork_record(AL*, record jv): a record while a start re-runs a cut turn: the first one with resume_reason
#   begins the turn (ev_turn_begin) under the line saying so; the result ends the re-run and takes the
#   conversation off the list
FN claude_fork_record
    PROLOGUE 48
    mov rbx, rdi
    mov r12, rsi
    cmp rbx, [rip + claude_rerun_al]
    jne 9f
    mov rdi, r12
    lea rsi, [rip + .Lk_resume_reason]
    call json_get
    mov rdi, rax
    call json_type
    cmp eax, JT_STR
    jne 9f
    mov rdi, r12
    lea rsi, [rip + .Lk_type]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lv_result]
    call json_is
    test eax, eax
    jnz 5f
    cmp qword ptr [rbx + AL_turns], 0
    jne 9f
    lea rdi, [rip + .Lr_continuing]
    call strlen
    mov rdi, [rbx + AL_as]
    mov esi, R_META
    lea rdx, [rip + .Lr_continuing]
    mov rcx, rax
    xor r8d, r8d
    call agents_msg_add
    mov rdi, rbx
    call ev_turn_begin
    EPILOGUE
5:  mov qword ptr [rip + claude_rerun_al], 0
    call cut_load               # (the parse arena is the record's: nothing of it is used after this)
    lea rdi, [rbx + AL_sid]
    call cut_find
    test rax, rax
    jz 9f
    mov rdi, rax
    call cut_drop
    call cut_save
9:  EPILOGUE

# ---------------- headless ----------------

# FN claude_fork_c_print(out, rest, len): print-agent-fork: "fork=SRC at=ENTRY rerun=0|1" of the open conversation's
#   live record, then the prompts of its file as matched ("prompt ROW UUID PARENT TEXT", the newest last)
FN claude_fork_c_print
    PROLOGUE
    mov rbx, rdi
    call agents_open_driven
    test rax, rax
    jz 8f
    mov r12, rax
    mov r13, [r12 + AS_live]
    mov rdi, rbx
    lea rsi, [rip + .Lp_fork]
    call sb_push_cstr
    test r13, r13
    jz 1f
    mov rdi, rbx
    lea rsi, [r13 + AL_fork]
    call sb_push_cstr
1:  mov rdi, rbx
    lea rsi, [rip + .Lp_at]
    call sb_push_cstr
    test r13, r13
    jz 2f
    mov rdi, rbx
    lea rsi, [r13 + AL_forkat]
    call sb_push_cstr
2:  mov rdi, rbx
    lea rsi, [rip + .Lp_rerun]
    call sb_push_cstr
    xor esi, esi
    test r13, r13
    jz 3f
    cmp r13, [rip + claude_rerun_al]
    sete sil
3:  mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    mov rdi, r12
    call pl_load
    xor r14d, r14d
4:  cmp r14, [rip + pes + VEC_len]
    jae 7f
    imul r15, r14, PE_SIZE
    add r15, [rip + pes + VEC_ptr]
    inc r14
    mov rdi, rbx
    lea rsi, [rip + .Lp_prompt]
    call sb_push_cstr
    mov rsi, [r15 + PE_row]
    test rsi, rsi
    jns 5f
    mov rdi, rbx
    mov esi, '-'
    call sb_push_byte
    jmp 6f
5:  mov rdi, rbx
    call sb_push_u64
6:  mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rdi, rbx
    lea rsi, [r15 + PE_uuid]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rdi, rbx
    lea rsi, [r15 + PE_parent]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rdi, rbx
    mov rsi, [r15 + PE_text]
    mov rdx, [r15 + PE_len]
    call sb_push
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    jmp 4b
7:  xor eax, eax
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

.section .rodata
.p2align 3
fd_ops: .quad fd_act, fd_free
skip_keys: .quad .Lk_is_meta, .Lk_sidechain, .Lk_compact_summary, .Lk_transcript_only, 0
skip_heads: .quad .Lh_cmd_name, .Lh_cmd_msg, .Lh_local, .Lh_bash_in, .Lh_bash_out, .Lh_interrupted, .Lh_task, 0
choices:                        # label, description (sPn)
    .quad .Lc_both, .Ld_both, .Lc_conv, .Ld_conv, .Lc_code, .Ld_code
.globl claude_fork_n_print
claude_fork_n_print: .asciz "print-agent-fork"
.Lq_user: .asciz "\"user\""
.Lk_type: .asciz "type"
.Lv_user: .asciz "user"
.Lv_result: .asciz "result"
.Lk_is_meta: .asciz "isMeta"
.Lk_sidechain: .asciz "isSidechain"
.Lk_compact_summary: .asciz "isCompactSummary"
.Lk_transcript_only: .asciz "isVisibleInTranscriptOnly"
.Lk_message: .asciz "message"
.Lk_content: .asciz "content"
.Lv_tool_result: .asciz "tool_result"
.Lv_text: .asciz "text"
.Lk_text: .asciz "text"
.Lk_uuid: .asciz "uuid"
.Lk_parent: .asciz "parentUuid"
.Lk_timestamp: .asciz "timestamp"
.Lk_subtype: .asciz "subtype"
.Lv_success: .asciz "success"
.Lk_response: .asciz "response"
.Lk_error: .asciz "error"
.Lk_can: .asciz "canRewind"
.Lk_insertions: .asciz "insertions"
.Lk_deletions: .asciz "deletions"
.Lk_files: .asciz "filesChanged"
.Lk_skipped: .asciz "skippedLinks"
.Lk_filename: .asciz "default_filename"
.Lk_user_message_id: .asciz "user_message_id"
.Lk_dry_run: .asciz "dry_run"
.Lk_resume_reason: .asciz "resume_reason"
.Lv_rewind_files: .asciz "rewind_files"
.Lv_export: .asciz "export_conversation"
.Lh_cmd_name: .asciz "<command-name>"
.Lh_cmd_msg: .asciz "<command-message>"
.Lh_local: .asciz "<local-command-"
.Lh_bash_in: .asciz "<bash-input>"
.Lh_bash_out: .asciz "<bash-stdout>"
.Lh_interrupted: .asciz "[Request interrupted"
.Lh_task: .asciz "<task-notification>"
.Ljsonl: .asciz ".jsonl"
.Ltxt: .asciz ".txt"
.Lcolon: .asciz ": "
.Ln_rewind: .asciz "rewind"
.Ln_export: .asciz "export"
.Lt_pick: .asciz "Rewind to\xe2\x80\xa6"
.Lt_rewind: .asciz "Rewind"
.Lt_code: .asciz "Rewind code"
.Lt_both: .asciz "Fork and rewind"
.Lt_export: .asciz "Export conversation"
.Lp_empty: .asciz "No messages to rewind to yet."
.Lp_hint: .asciz "Select a message to restore the code and/or conversation from that point."
.Lp_keys: .asciz "\xe2\x86\x91 \xe2\x86\x93 to navigate \xc2\xb7 Enter to select \xc2\xb7 Esc to close"
.Lr_now: .asciz "just now"
.Lr_m: .asciz "m ago"
.Lr_h: .asciz "h ago"
.Lr_d: .asciz "d ago"
.Lc_both: .asciz "Restore code and conversation"
.Ld_both: .asciz "The conversation will be forked."
.Lc_conv: .asciz "Restore conversation"
.Ld_conv: .asciz "The conversation will be forked. The code will be unchanged."
.Lc_code: .asciz "Restore code"
.Ld_code: .asciz "The conversation will be unchanged."
.Lw_fork_note: .asciz "A new forked conversation will be created after rewinding."
.Lw_checking: .asciz "Checking code changes\xe2\x80\xa6"
.Lw_unchanged: .asciz "The code has not changed, so no code will be restored."
.Lw_warning: .asciz "Restored files go back whole, losing later changes by anyone. Bash changes to other files are not undone."
.Lw_line: .asciz " line"
.Lw_removed: .asciz " will be removed and "
.Lw_added: .asciz " will be added across "
.Lw_file: .asciz " file"
.Lb_restore: .asciz "Restore"
.Lb_rewind: .asciz "Rewind"
.Lb_continue: .asciz "Continue"
.Lb_never: .asciz "Never mind"
.Lb_copy: .asciz "Copy to clipboard"
.Lb_save: .asciz "Save to file"
.Lb_close: .asciz "Close"
.Le_preparing: .asciz "Preparing the conversation\xe2\x80\xa6"
.Le_whole: .asciz "The whole conversation as plain text, "
.Le_chars: .asciz " characters."
.Le_offers: .asciz "Save to file offers the name "
.Le_copied: .asciz "Copied to clipboard"
.Le_failed: .asciz "Could not prepare the conversation: "
.Le_none: .asciz "No export was returned"
.Le_opened: .asciz "Conversation opened in the editor; choose where to save it"
.Lrw_done: .asciz "Code rewind successful"
.Lrw_some: .asciz "Code rewind completed, but "
.Lrw_was: .asciz " file was skipped: the tracked path is (or became) a link or other non-regular file, its directory changed since the checkpoint, it is behind a link in a folder that sandboxed commands can write, or its backup could not be safely read"
.Lrw_were: .asciz " files were skipped: the tracked path is (or became) a link or other non-regular file, its directory changed since the checkpoint, it is behind a link in a folder that sandboxed commands can write, or its backup could not be safely read"
.Lrw_failed: .asciz "Failed to rewind code"
.Lrw_not_running: .asciz "Failed to rewind code: Claude Code is not running"
.Lnot_found: .asciz "Failed to fork conversation: Message not found"
.Lno_checkpoint: .asciz "Failed to rewind code: No file checkpoint found"
.Lfork_failed: .asciz "Failed to fork conversation"
.Lno_start: .asciz "Claude Code could not be started."
.Lnot_sent: .asciz "The request could not be sent to Claude Code."
.Lr_continuing: .asciz "Continuing the step that was interrupted when rhun quit."
.Lcut_suffix: .asciz ".agents-cut"
.Lp_fork: .asciz "fork="
.Lp_at: .asciz " at="
.Lp_rerun: .asciz " rerun="
.Lp_prompt: .asciz "prompt "

.bss
rw_uuid: .zero 40
