# source control: the history's work tree row, as VS Code's Source Control view. A commit message with
# Commit (or Sync Changes, Publish Branch when there is nothing to commit), Pull, Push and Fetch, and the
# changes by group: merge conflicts, staged, not staged, each file to stage, unstage or discard
.include "rhun.inc"

.equ ID_SCM, 0x100000
.equ ID_SCM_MSG, ID_SCM
.equ ID_SCM_MAIN, ID_SCM + 1            # the button under the message
.equ ID_SCM_PULL, ID_SCM + 2            # Pull, Push, Fetch
.equ ID_SCM_SCROLL, ID_SCM + 5
.equ ID_SCM_AI, ID_SCM + 6
.equ ID_SCM_GROUP, ID_SCM + 0x10        # + group * 4 + button
.equ ID_SCM_FILE, ID_SCM + 0x100        # + file * 4 + button
.equ MAX_LINES, 10                      # of the message shown at once
.equ MAX_MSG, 60000                     # the message fits the pipe to git: rhun never waits to write it
.equ ENABLED, 0x100                     # with the UB_* bits of a button that takes clicks

# steps of an operation: what git runs (seq_*: steps, then 0)
.equ S_ADD_ALL, 1
.equ S_COMMIT, 2
.equ S_AMEND, 3
.equ S_PULL_CFG, 4                      # is pull.rebase or pull.ff set
.equ S_PULL, 5
.equ S_PUSH, 6
.equ S_REMOTES, 7
.equ S_PUBLISH, 8
.equ S_FETCH, 9
.equ S_ADD, 10                          # the ones on op_path
.equ S_RESET, 11
.equ S_RESET_ALL, 12
.equ S_CHECKOUT, 13
.equ S_CHECKOUT_ALL, 14
.equ S_CLEAN, 15
.equ S_CLEAN_ALL, 16

# operations, one at a time
.equ OP_NONE, 0
.equ OP_COMMIT, 1
.equ OP_PULL, 2
.equ OP_PUSH, 3
.equ OP_SYNC, 4
.equ OP_FETCH, 5
.equ OP_PUBLISH, 6
.equ OP_INDEX, 7                        # stage, unstage, discard

# the button under the message
.equ MB_NONE, 0                         # Commit, with nothing to commit
.equ MB_COMMIT, 1
.equ MB_COMMIT_ALL, 2                   # nothing staged: everything is staged first
.equ MB_SYNC, 3
.equ MB_PUBLISH, 4

.bss
.p2align 3
ai_draft: .zero SB_SIZE
tf_msg: .zero TF_SIZE                   # the commit message
list: .zero VEC_SIZE                    # GF of the status by group
seq: .quad 0                            # the running operation's step
confirm_seq: .quad 0                    # what a confirmed discard runs
lbl: .zero SB_SIZE
tmp: .zero SB_SIZE
argv: .zero 8 * 12
counts: .zero 4 * 4                     # files per group
pan: .zero 16                           # the panel: x, y, w, h
in_x: .long 0                           # its content
in_w: .long 0
op: .long 0                             # OP_*
pull_merge: .long 0                     # neither pull.rebase nor pull.ff is set: pull merges
scroll: .long 0
content_h: .long 0
merge_seen: .long 0                     # the merge's message went into the message box
rm_running: .long 0
has_remote: .long 0
remote: .zero 256                       # to publish to
err: .zero 256                          # what went wrong last
op_path: .zero 4096
question: .zero 4200
.data
list_ver: .long -1                      # g_git_ver of the list

.text

# ---------------- commands ----------------

FN cmd_git_commit
    xor edi, edi
    jmp commit
FN cmd_git_commit_amend
    mov edi, 1
# commit(amend): the message commits what is staged, or every change when nothing is (as VS Code's smart
#   commit); amending keeps the last commit's message when the box is empty
commit:
    PROLOGUE
    mov ebx, edi
    call ready
    test eax, eax
    jz 9f
    lea rdi, [rip + .Llong]
    cmp qword ptr [rip + tf_msg + TF_sb + SB_len], MAX_MSG
    ja 8f
    call sync_list
    lea rsi, [rip + seq_amend]
    test ebx, ebx
    jnz 3f
    lea rdi, [rip + .Lconflicts]
    cmp dword ptr [rip + counts + 4*GG_MERGE], 0
    jne 8f
    lea rdi, [rip + .Lnothing]
    mov eax, [rip + counts + 4*GG_STAGED]
    add eax, [rip + counts + 4*GG_CHANGES]
    jz 8f
    call msg_blank
    test eax, eax
    jz 1f
    lea rdi, [rip + .Lno_message]
    call app_toast
    call scm_focus
    jmp 9f
1:  lea rsi, [rip + seq_commit]
    cmp dword ptr [rip + counts + 4*GG_STAGED], 0
    jne 3f
    lea rsi, [rip + seq_commit_all]
3:  mov edi, OP_COMMIT
    call op_begin
    jmp 9f
8:  call app_toast
9:  EPILOGUE

FN cmd_git_pull
    mov edi, OP_PULL
    lea rsi, [rip + seq_pull]
    jmp start

FN cmd_git_fetch
    mov edi, OP_FETCH
    lea rsi, [rip + seq_fetch]
    jmp start

# pushing a branch without an upstream publishes it, to its remote
FN cmd_git_push
    mov edi, OP_PUSH
    lea rsi, [rip + seq_push]
    jmp 1f
FN cmd_git_sync
    mov edi, OP_SYNC
    lea rsi, [rip + seq_sync]
1:  push rsi
    push rdi
    call unpublished
    pop rdi
    pop rsi
    test eax, eax
    jz start
    mov edi, OP_PUBLISH
    lea rsi, [rip + seq_publish]
    jmp start

FN cmd_git_stage_all
    mov edi, OP_INDEX
    lea rsi, [rip + seq_stage_all]
    jmp start

FN cmd_git_unstage_all
    mov edi, OP_INDEX
    lea rsi, [rip + seq_unstage_all]
    jmp start

FN cmd_git_discard_all
    PROLOGUE
    call ready
    test eax, eax
    jz 9f
    call sync_list
    cmp dword ptr [rip + counts + 4*GG_CHANGES], 0
    jne 1f
    lea rdi, [rip + .Lnothing_discard]
    call app_toast
    jmp 9f
1:  # tracked files go back only when some changed (checkout fails with none to restore)
    lea rax, [rip + seq_clean_all]
    xor ecx, ecx
2:  cmp rcx, [rip + list + VEC_len]
    jae 4f
    imul rdx, rcx, GF_SIZE
    add rdx, [rip + list + VEC_ptr]
    inc rcx
    cmp dword ptr [rdx + GF_group], GG_CHANGES
    jne 2b
    cmp dword ptr [rdx + GF_code], 'U'
    je 2b
    lea rax, [rip + seq_discard_all]
4:  mov [rip + confirm_seq], rax
    lea rdi, [rip + .Lq_all]
    lea rsi, [rip + .Lq_all_text]
    lea rdx, [rip + .Lb_discard_all]
    lea rcx, [rip + confirmed]
    call app_confirm
9:  EPILOGUE

# start(op, seq): an operation when none runs
start:
    PROLOGUE
    mov r12d, edi
    mov r13, rsi
    call ready
    test eax, eax
    jz 9f
    mov edi, r12d
    mov rsi, r13
    call op_begin
9:  EPILOGUE

# confirmed(): the discard the dialog asked about
confirmed:
    mov edi, OP_INDEX
    mov rsi, [rip + confirm_seq]
    jmp op_begin

# ready() -> 1 when an operation can start, else says why not
ready:
    push rbx
    lea rdi, [rip + .Lno_repo]
    cmp dword ptr [rip + g_git_on], 0
    je 1f
    lea rdi, [rip + .Lbusy]
    cmp dword ptr [rip + op], OP_NONE
    jne 1f
    mov eax, 1
    pop rbx
    ret
1:  call app_toast
    xor eax, eax
    pop rbx
    ret

# unpublished() -> 1 when HEAD is a branch without an upstream
unpublished:
    xor eax, eax
    cmp dword ptr [rip + g_git_head], HD_BRANCH
    jne 1f
    cmp byte ptr [rip + g_git_upstream], 0
    jne 1f
    mov eax, 1
1:  ret

# msg_blank() -> 1 when the message has nothing but blanks
msg_blank:
    push rbx
    lea rdi, [rip + tf_msg]
    call tf_text
    pop rbx
    xor ecx, ecx
1:  cmp rcx, rdx
    jae 2f
    cmp byte ptr [rax + rcx], ' '
    ja 3f
    inc rcx
    jmp 1b
2:  mov eax, 1
    ret
3:  xor eax, eax
    ret

# scm_focus(): the history with the work tree selected, typing in the commit message
FN scm_focus
    push rbx
    cmp dword ptr [rip + g_git_on], 0
    jne 1f
    lea rdi, [rip + .Lno_repo]
    call app_toast
    pop rbx
    ret
1:  call gitview_show_wip
    mov dword ptr [rip + g_focus], FOCUS_SCM
    mov dword ptr [rip + scroll], 0
    mov dword ptr [rip + g_dirty], 1
    pop rbx
    ret

# scm_key(keysym, cp, mods) -> 1 if used: the commit message has the keys; Ctrl+Enter commits, Esc leaves
FN scm_key
    PROLOGUE
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    # only while the history shows it
    mov rdi, [rip + g_tab_cur]
    test rdi, rdi
    js 8f
    call tab_at
    cmp qword ptr [rax + TAB_kind], TAB_GIT
    jne 8f
    cmp r12d, KEY_ESCAPE
    jne 1f
    mov dword ptr [rip + g_focus], FOCUS_EDITOR
    jmp .Lsk_yes
1:  cmp r12d, KEY_RETURN
    je 2f
    cmp r12d, KEY_KP_ENTER
    jne 3f
2:  test r14d, MOD_CTRL
    jz 3f
    call cmd_git_commit
    jmp .Lsk_yes
3:  lea rdi, [rip + tf_msg]
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    call ta_key
    test eax, eax
    jz 9f
    mov dword ptr [rip + scroll], 0
.Lsk_yes:
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE
8:  mov dword ptr [rip + g_focus], FOCUS_EDITOR
9:  xor eax, eax
    EPILOGUE

# scm_paste(ptr, len): into the commit message
FN scm_paste
    mov rdx, rsi
    mov rsi, rdi
    lea rdi, [rip + tf_msg]
    jmp ta_insert

# scm_reset(): another repository
FN scm_reset
    push rbx
    call ai_cancel_generation
    mov dword ptr [rip + op], OP_NONE
    mov dword ptr [rip + list_ver], -1
    mov qword ptr [rip + list + VEC_len], 0
    lea rdi, [rip + counts]
    xor eax, eax
    mov ecx, 16
    rep stosb
    mov byte ptr [rip + err], 0
    mov byte ptr [rip + remote], 0
    mov dword ptr [rip + has_remote], 0
    mov dword ptr [rip + rm_running], 0
    mov dword ptr [rip + merge_seen], 0
    mov dword ptr [rip + scroll], 0
    lea rdi, [rip + tf_msg]
    call tf_clear
    cmp dword ptr [rip + g_focus], FOCUS_SCM
    jne 1f
    mov dword ptr [rip + g_focus], FOCUS_EDITOR
1:  pop rbx
    ret

# Capture the user's draft before starting. Result insertion requires exact equality.
FN cmd_git_generate_message
    PROLOGUE
    cmp dword ptr [rip + g_ai_kind], 3
    jne 1f
    call ai_cancel_generation
    jmp 9f
1:  cmp dword ptr [rip + cfg_commit_ai], 0
    jne 2f
    lea rdi, [rip + .Lai_off]
    call app_toast
    jmp 9f
2:  call ready
    test eax, eax
    jz 9f
    lea rdi, [rip + ai_draft]
    call sb_clear
    lea rdi, [rip + tf_msg]
    call tf_text
    lea rdi, [rip + ai_draft]
    mov rsi, rax
    call sb_push
    call ai_generate
9:  EPILOGUE

FN scm_ai_result
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    lea rdi, [rip + tf_msg]
    call tf_text
    mov rdi, rax
    mov rsi, rdx
    mov rdx, [rip + ai_draft + SB_ptr]
    mov rcx, [rip + ai_draft + SB_len]
    call str_eq
    test eax, eax
    jz 1f
    lea rdi, [rip + tf_msg]
    mov rsi, r12
    mov rdx, r13
    call tf_set
    mov dword ptr [rip + g_dirty], 1
    jmp 9f
1:  lea rdi, [rip + .Lai_edited]
    call app_toast
9:  EPILOGUE

# draw_ai(y): a compact button beside the message, with a stable width while running.
draw_ai:
    PROLOGUE
    mov r13d, edi
    lea rdi, [rip + lbl]
    call sb_clear
    lea rsi, [rip + .Lai_label]
    cmp dword ptr [rip + g_ai_kind], 3
    jne 1f
    lea rsi, [rip + .Lai_cancel]
1:  lea rdi, [rip + lbl]
    call sb_push_cstr
    mov edi, ID_SCM_AI
    mov esi, [rip + in_x]
    mov edx, r13d
    add esi, [rip + in_w]
    M ecx, MI_64
    add ecx, [rip + g_mt + 4*MI_16]
    sub esi, ecx
    M r8d, MI_32
    mov r9d, IC_SPARK
    cmp dword ptr [rip + g_ai_kind], 3
    jne 2f
    mov r9d, IC_CLOSE
2:  call draw_button
    test eax, eax
    jz 9f
    call cmd_git_generate_message
9:  EPILOGUE

# ---------------- the changes ----------------

# sync_list(): the changes by group, made again when the status changed
sync_list:
    PROLOGUE
    mov eax, [rip + g_git_ver]
    cmp eax, [rip + list_ver]
    je 9f
    mov [rip + list_ver], eax
    lea rdi, [rip + list]
    call git_scm_list
    lea rdi, [rip + counts]
    xor eax, eax
    mov ecx, 16
    rep stosb
    xor ebx, ebx
1:  cmp rbx, [rip + list + VEC_len]
    jae 2f
    imul rax, rbx, GF_SIZE
    add rax, [rip + list + VEC_ptr]
    mov ecx, [rax + GF_group]
    lea rdx, [rip + counts]
    inc dword ptr [rdx + rcx*4]
    inc rbx
    jmp 1b
2:  # a branch without an upstream: is there a remote to publish it to
    call unpublished
    test eax, eax
    jz 3f
    call remotes_check
3:  call merge_message
9:  EPILOGUE

# remotes_check(): the remotes, for Publish Branch
remotes_check:
    cmp dword ptr [rip + rm_running], 0
    jne 9f
    push rbx
    lea rdi, [rip + args_remote]
    lea rsi, [rip + on_remotes]
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    call git_run
    mov [rip + rm_running], eax
    pop rbx
9:  ret

# on_remotes(ctx, ptr, len, status): a remote per line
on_remotes:
    push rbx
    mov dword ptr [rip + rm_running], 0
    test ecx, ecx
    jnz 1f
    mov rdi, rsi
    mov rsi, rdx
    call pick_remote
    mov dword ptr [rip + g_dirty], 1
1:  pop rbx
    ret

# pick_remote(ptr, len): origin when there is one, else the first remote, into remote
pick_remote:
    PROLOGUE
    mov r12, rdi
    lea r14, [rdi + rsi]
    mov byte ptr [rip + remote], 0
    mov rbx, r12
1:  cmp rbx, r14
    jae 8f
    mov r15, rbx
2:  cmp r15, r14
    jae 3f
    cmp byte ptr [r15], 10
    je 3f
    inc r15
    jmp 2b
3:  mov r13, r15
    sub r13, rbx                # its length
    jz 6f
    cmp r13, 255
    jae 6f
    cmp byte ptr [rip + remote], 0
    je 4f
    cmp r13, 6
    jne 6f
    mov rdi, rbx
    lea rsi, [rip + .Lorigin]
    mov edx, 6
    call memeq
    test eax, eax
    jz 6f
4:  lea rdi, [rip + remote]
    mov rsi, rbx
    mov rcx, r13
    rep movsb
    mov byte ptr [rdi], 0
6:  lea rbx, [r15 + 1]
    jmp 1b
8:  xor eax, eax
    cmp byte ptr [rip + remote], 0
    setne al
    mov [rip + has_remote], eax
    EPILOGUE

# merge_message(): during a merge its message goes into an empty message box, once
merge_message:
    PROLOGUE
    call git_merge_msg
    test rax, rax
    jnz 1f
    mov dword ptr [rip + merge_seen], 0
    EPILOGUE
1:  mov r12, rax
    mov r13, rdx
    cmp dword ptr [rip + merge_seen], 0
    jne 8f
    mov dword ptr [rip + merge_seen], 1
    cmp qword ptr [rip + tf_msg + TF_sb + SB_len], 0
    jne 8f
    # its lines but the comments
    lea rdi, [rip + tmp]
    call sb_clear
    lea rdi, [rip + tmp]
    lea rsi, [rip + empty_str]
    xor edx, edx
    call sb_push
    mov rbx, r12
    lea r14, [r12 + r13]
2:  cmp rbx, r14
    jae 5f
    mov r15, rbx
3:  cmp r15, r14
    jae 4f
    cmp byte ptr [r15], 10
    je 4f
    inc r15
    jmp 3b
4:  cmp byte ptr [rbx], '#'
    je 41f
    lea rdi, [rip + tmp]
    mov rsi, rbx
    mov rdx, r15
    sub rdx, rbx
    call sb_push
    lea rdi, [rip + tmp]
    mov esi, 10
    call sb_push_byte
41: lea rbx, [r15 + 1]
    jmp 2b
5:  # no blank lines at the end
    mov rax, [rip + tmp + SB_len]
    mov rcx, [rip + tmp + SB_ptr]
51: test rax, rax
    jz 52f
    cmp byte ptr [rcx + rax - 1], ' '
    ja 52f
    dec rax
    jmp 51b
52: lea rdi, [rip + tf_msg]
    mov rsi, rcx
    mov rdx, rax
    call tf_set
8:  mov rdi, r12
    call mem_free
    EPILOGUE

# ---------------- operations ----------------

# op_begin(op, seq): runs the steps of seq one after another
op_begin:
    PROLOGUE
    push rdi
    push rsi
    call ai_cancel_generation
    pop rsi
    pop rdi
    cmp dword ptr [rip + op], OP_NONE
    jne 9f
    cmp dword ptr [rip + g_git_on], 0
    je 9f
    mov [rip + op], edi
    mov [rip + seq], rsi
    mov byte ptr [rip + err], 0
    xor edi, edi
    xor esi, esi
    call run_step
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# run_step(ptr, len): the next step; after the last the operation is done (ptr, len: that step's output)
run_step:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov rax, [rip + seq]
    movzx ebx, byte ptr [rax]
    test ebx, ebx
    jnz 1f
    mov rdi, r12
    mov rsi, r13
    call op_done
    EPILOGUE
1:  # its arguments, then what the step adds; a merge as configuration, so branch.<name>.rebase wins
    lea rax, [rip + step_args]
    mov rsi, [rax + rbx*8]
    cmp ebx, S_PULL
    jne 11f
    cmp dword ptr [rip + pull_merge], 0
    je 11f
    lea rsi, [rip + args_pull_merge]
11: lea r13, [rip + argv]
2:  mov rax, [rsi]
    test rax, rax
    jz 3f
    mov [r13], rax
    add rsi, 8
    add r13, 8
    jmp 2b
3:  xor r14d, r14d              # input
    xor r15d, r15d
    cmp ebx, S_COMMIT
    je 4f
    cmp ebx, S_AMEND
    jne 5f
    call msg_blank
    test eax, eax
    jz 41f
    lea rax, [rip + .Lno_edit]
    mov [r13], rax
    add r13, 8
    jmp 8f
41: lea rax, [rip + .Ldash_f]
    mov [r13], rax
    lea rax, [rip + .Ldash]
    mov [r13 + 8], rax
    add r13, 16
4:  lea rdi, [rip + tf_msg]
    call tf_text
    mov r14, rax
    mov r15, rdx
    jmp 8f
5:  cmp ebx, S_PUBLISH
    jne 7f
    lea rax, [rip + remote]
    mov [r13], rax
    lea rax, [rip + .Lhead]
    mov [r13 + 8], rax
    add r13, 16
    jmp 8f
7:  cmp ebx, S_ADD
    je 71f
    cmp ebx, S_RESET
    je 71f
    cmp ebx, S_CHECKOUT
    je 71f
    cmp ebx, S_CLEAN
    jne 8f
71: lea rax, [rip + .Ldashdash]
    mov [r13], rax
    lea rax, [rip + op_path]
    mov [r13 + 8], rax
    add r13, 16
8:  mov qword ptr [r13], 0
    lea rdi, [rip + argv]
    lea rsi, [rip + on_step]
    xor edx, edx
    mov rcx, r14
    mov r8, r15
    # the steps whose output is read take it without git's messages
    cmp ebx, S_REMOTES
    je 81f
    cmp ebx, S_PULL_CFG
    je 81f
    call git_run_all
    jmp 82f
81: call git_run
82: test eax, eax
    jnz 9f
    lea rdi, [rip + .Le_failed]
    call fail_with
9:  EPILOGUE

# on_step(ctx, ptr, len, status): a step ended
on_step:
    PROLOGUE
    mov r12, rsi
    mov r13, rdx
    mov r14d, ecx
    cmp dword ptr [rip + op], OP_NONE
    je 9f
    mov rax, [rip + seq]
    movzx ebx, byte ptr [rax]
    cmp ebx, S_PULL_CFG
    jne 1f
    # neither pull.rebase nor pull.ff: a merge, as git did before it asked
    xor eax, eax
    test r14d, r14d
    setnz al
    mov [rip + pull_merge], eax
    xor r14d, r14d
    jmp 5f
1:  cmp ebx, S_REMOTES
    jne 5f
    test r14d, r14d
    jnz 5f
    mov rdi, r12
    mov rsi, r13
    call pick_remote
    cmp byte ptr [rip + remote], 0
    jne 5f
    lea rdi, [rip + .Lno_remote]
    call fail_with
    jmp 9f
5:  test r14d, r14d
    jz 6f
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + err]
    call pick_error
    call failed
    jmp 9f
6:  inc qword ptr [rip + seq]
    mov rdi, r12
    mov rsi, r13
    call run_step
9:  EPILOGUE

# op_done(ptr, len): the operation went through (ptr, len: the last step's output)
op_done:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov ebx, [rip + op]
    cmp ebx, OP_COMMIT
    jne 1f
    lea rdi, [rip + tf_msg]
    call tf_clear
    jmp 8f
1:  lea rax, [rip + done_toasts]
    mov r14, [rax + rbx*8]
    test r14, r14
    jz 8f
    lea rdx, [rip + .Lpull_same]
    mov ecx, 18
    cmp ebx, OP_PULL
    je 2f
    lea rdx, [rip + .Lpush_same]
    mov ecx, 21
    cmp ebx, OP_PUSH
    jne 3f
2:  mov rdi, r12
    mov rsi, r13
    call str_find
    test rax, rax
    js 3f
    lea r14, [rip + .Lt_same]
3:  mov rdi, r14
    call app_toast
8:  call op_finish
    EPILOGUE

# fail_with(cstr): the operation stops with that message
fail_with:
    push rbx
    mov rsi, rdi
    lea rdi, [rip + err]
    call cstr_copy
    call failed
    pop rbx
    ret

# failed(): the operation stopped; err says why
failed:
    push rbx
    lea rdi, [rip + err]
    call app_toast
    call op_finish
    pop rbx
    ret

# op_finish(): no operation runs; the status, and HEAD unless only the index changed
op_finish:
    push rbx
    mov ebx, [rip + op]
    mov dword ptr [rip + op], OP_NONE
    mov edi, 1
    cmp ebx, OP_INDEX
    je 1f
    mov edi, 3
1:  call git_refresh
    mov dword ptr [rip + g_dirty], 1
    pop rbx
    ret

# pick_error(ptr, len, dest): what git's output says went wrong, as a line in dest
pick_error:
    PROLOGUE 32
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    # what it means, for the common ones
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lk_rejected]
    mov ecx, 10
    call str_find
    lea rbx, [rip + .Le_rejected]
    test rax, rax
    jns .Lpe_cstr
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lk_conflict]
    mov ecx, 8
    call str_find
    test rax, rax
    js 1f
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lk_rebase]
    mov ecx, 15
    call str_find
    lea rbx, [rip + .Le_conflict]
    test rax, rax
    js .Lpe_cstr
    lea rbx, [rip + .Le_rebase]
    jmp .Lpe_cstr
1:  # the first fatal or error line, else the last line that is not a hint
    xor r15d, r15d              # start of the last line kept
    lea rax, [r12 + r13]
    mov [rsp + 8], rax          # end of the output
    mov rbx, r12
.Lpe_line:
    cmp rbx, [rsp + 8]
    jae .Lpe_last
    mov rcx, rbx
2:  cmp rcx, [rsp + 8]
    jae 3f
    cmp byte ptr [rcx], 10
    je 3f
    inc rcx
    jmp 2b
3:  mov [rsp + 16], rcx         # end of the line
    mov rdi, rbx
    mov rsi, rcx
    sub rsi, rbx
    lea rdx, [rip + .Lk_fatal]
    mov ecx, 7
    call str_starts
    test eax, eax
    jnz 4f
    mov rdi, rbx
    mov rsi, [rsp + 16]
    sub rsi, rbx
    lea rdx, [rip + .Lk_error]
    mov ecx, 7
    call str_starts
    test eax, eax
    jz 5f
4:  lea rdi, [rbx + 7]
    mov rsi, [rsp + 16]
    jmp .Lpe_copy
5:  mov rdi, rbx
    mov rsi, [rsp + 16]
    sub rsi, rbx
    lea rdx, [rip + .Lk_hint]
    mov ecx, 5
    call str_starts
    test eax, eax
    jnz 6f
    mov rcx, rbx
51: cmp rcx, [rsp + 16]
    jae 6f
    cmp byte ptr [rcx], ' '
    ja 52f
    inc rcx
    jmp 51b
52: mov r15, rbx
    mov rax, [rsp + 16]
    mov [rsp], rax
6:  mov rbx, [rsp + 16]
    inc rbx
    jmp .Lpe_line
.Lpe_last:
    lea rbx, [rip + .Le_failed]
    test r15, r15
    jz .Lpe_cstr
    mov rdi, r15
    mov rsi, [rsp]
    jmp .Lpe_copy
.Lpe_cstr:
    mov rdi, rbx
    call strlen
    mov rdi, rbx
    lea rsi, [rbx + rax]
.Lpe_copy:
    # rdi..rsi, at most 250 bytes, no blanks at the end, a capital first
    mov rcx, rsi
    sub rcx, rdi
    cmp rcx, 250
    jbe 1f
    mov ecx, 250
1:  xor eax, eax
2:  cmp rax, rcx
    jae 3f
    mov dl, [rdi + rax]
    mov [r14 + rax], dl
    inc rax
    jmp 2b
3:  test rax, rax
    jz 4f
    cmp byte ptr [r14 + rax - 1], ' '
    ja 4f
    dec rax
    jmp 3b
4:  mov byte ptr [r14 + rax], 0
    movzx eax, byte ptr [r14]
    cmp eax, 'a'
    jb 9f
    cmp eax, 'z'
    ja 9f
    sub eax, 32
    mov [r14], al
9:  EPILOGUE

# file_action(gf, seq): stage or unstage a file
file_action:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call ready
    test eax, eax
    jz 9f
    mov rdi, rbx
    call take_path
    test eax, eax
    jz 9f
    mov edi, OP_INDEX
    mov rsi, r12
    call op_begin
9:  EPILOGUE

# ask_discard(gf): asks before its changes go (or before an untracked file is deleted)
ask_discard:
    PROLOGUE
    mov rbx, rdi
    call ready
    test eax, eax
    jz 9f
    mov rdi, rbx
    call take_path
    test eax, eax
    jz 9f
    lea rax, [rip + seq_discard]
    lea r12, [rip + .Lq_discard]
    lea r13, [rip + .Lq_discard_text]
    lea r14, [rip + .Lb_discard]
    cmp dword ptr [rbx + GF_code], 'U'
    jne 1f
    lea rax, [rip + seq_discard_new]
    lea r12, [rip + .Lq_delete]
    lea r13, [rip + .Lq_delete_text]
    lea r14, [rip + .Lb_delete]
1:  mov [rip + confirm_seq], rax
    lea rdi, [rip + question]
    mov rsi, r12
    call cstr_copy
    mov rdi, rax
    lea rsi, [rip + op_path]
    call cstr_copy
    mov byte ptr [rax], '?'
    mov byte ptr [rax + 1], 0
    lea rdi, [rip + question]
    mov rsi, r13
    mov rdx, r14
    lea rcx, [rip + confirmed]
    call app_confirm
9:  EPILOGUE

# take_path(gf) -> 1 when its path went into op_path
take_path:
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + GF_path]
    call strlen
    xor ecx, ecx
    cmp rax, 4000
    ja 1f
    lea rdi, [rip + op_path]
    mov rsi, [rbx + GF_path]
    call cstr_copy
    mov ecx, 1
1:  mov eax, ecx
    pop rbx
    ret

# ---------------- drawing ----------------

# scm_draw(x, y, w, h): the panel right of the history, for the work tree
FN scm_draw
    PROLOGUE 32
    mov [rip + pan], edi
    mov [rip + pan + 4], esi
    mov [rip + pan + 8], edx
    mov [rip + pan + 12], ecx
    call sync_list
    mov dword ptr [rip + tf_msg + TF_id], ID_SCM_MSG
    call pan_args
    COLOR r8d, T_PANEL
    call gfx_fill
    call pan_args
    call ui_in
    mov [rsp], eax              # the pointer is over the panel
    # else what scrolled out of it takes no clicks (the clip only cuts the drawing)
    mov ecx, [rip + g_block]
    mov [rsp + 4], ecx
    test eax, eax
    jnz 10f
    mov dword ptr [rip + g_block], 1
    jmp 1f
10: mov eax, [rip + g_scroll_y]
    add [rip + scroll], eax
1:  mov eax, [rip + content_h]
    sub eax, [rip + pan + 12]
    jns 11f
    xor eax, eax
11: cmp [rip + scroll], eax
    jle 12f
    mov [rip + scroll], eax
12: cmp dword ptr [rip + scroll], 0
    jge 13f
    mov dword ptr [rip + scroll], 0
13: call pan_args
    call gfx_clip_push
    M eax, MI_16
    mov ecx, [rip + pan]
    add ecx, eax
    mov [rip + in_x], ecx
    mov ecx, [rip + pan + 8]
    sub ecx, eax
    sub ecx, eax
    mov [rip + in_w], ecx
    mov r13d, [rip + pan + 4]
    add r13d, [rip + g_mt + 4*MI_8]
    sub r13d, [rip + scroll]
    # the branch
    mov edi, r13d
    call draw_branch
    add r13d, [rip + g_mt + 4*MI_32]
    # the message, up to MAX_LINES lines high
    lea rdi, [rip + tf_msg]
    call ta_lines
    mov ecx, MAX_LINES
    cmp eax, ecx
    cmova eax, ecx
    mov ebx, eax
    call ta_line_h
    imul ebx, eax
    add ebx, [rip + g_mt + 4*MI_12]
    call placeholder
    push rax
    push rax
    lea rdi, [rip + tf_msg]
    mov esi, [rip + in_x]
    mov edx, r13d
    mov ecx, [rip + in_w]
    cmp dword ptr [rip + cfg_commit_ai], 0
    je 21f
    sub ecx, [rip + g_mt + 4*MI_64]
    sub ecx, [rip + g_mt + 4*MI_16]
    sub ecx, [rip + g_mt + 4*MI_8]
21: mov r8d, ebx
    xor r9d, r9d
    cmp dword ptr [rip + g_focus], FOCUS_SCM
    jne 2f
    mov r9d, 1
2:  call ui_textarea
    add rsp, 16
    test eax, UB_PRESS
    jz 3f
    mov dword ptr [rip + g_focus], FOCUS_SCM
    mov dword ptr [rsp], 0
3:  # AI shares the message row and stays at its top as the draft grows.
    cmp dword ptr [rip + cfg_commit_ai], 0
    je 31f
    mov edi, r13d
    call draw_ai
    M eax, MI_32
    cmp ebx, eax
    cmovl ebx, eax
31: add r13d, ebx
    add r13d, [rip + g_mt + 4*MI_8]
    # Commit, Sync Changes or Publish Branch
    mov edi, r13d
    call draw_main
    add r13d, [rip + g_mt + 4*MI_32]
    add r13d, [rip + g_mt + 4*MI_8]
    # Pull, Push, Fetch
    mov edi, r13d
    call draw_remote
    add r13d, [rip + g_mt + 4*MI_28]
    add r13d, [rip + g_mt + 4*MI_8]
    # what went wrong last
    mov edi, r13d
    call draw_error
    mov r13d, eax
    add r13d, [rip + g_mt + 4*MI_4]
    # the changes by group
    mov r14d, GG_MERGE
5:  lea rax, [rip + counts]
    cmp dword ptr [rax + r14*4], 0
    je 6f
    mov edi, r14d
    mov esi, r13d
    call draw_group
    mov r13d, eax
6:  inc r14d
    cmp r14d, GG_CHANGES
    jbe 5b
    mov eax, r13d
    add eax, [rip + scroll]
    sub eax, [rip + pan + 4]
    add eax, [rip + g_mt + 4*MI_8]
    mov [rip + content_h], eax
    call gfx_clip_pop
    mov eax, [rsp + 4]
    mov [rip + g_block], eax
    mov eax, [rip + pan + 12]
    push rax
    mov eax, [rip + content_h]
    push rax
    M ecx, MI_12
    mov edi, ID_SCM_SCROLL
    mov esi, [rip + pan]
    add esi, [rip + pan + 8]
    sub esi, ecx
    mov edx, [rip + pan + 4]
    mov r8d, [rip + pan + 12]
    lea r9, [rip + scroll]
    call ui_scrollbar
    add rsp, 16
    # a press elsewhere in the panel takes the keyboard from the message
    cmp dword ptr [rsp], 0
    je 9f
    test dword ptr [rip + g_pressed], 1 << BTN_LEFT
    jz 9f
    cmp dword ptr [rip + g_focus], FOCUS_SCM
    jne 9f
    mov dword ptr [rip + g_focus], FOCUS_EDITOR
9:  EPILOGUE

# draw_error(y) -> eax y under it: err, broken into lines at spaces (at most 4)
draw_error:
    PROLOGUE 16
    mov r13d, edi
    lea rbx, [rip + err]
    mov rdi, rbx
    call strlen
    mov r12, rax
    xor r15d, r15d              # lines
1:  test r12, r12
    jz 8f
    cmp r15d, 4
    jae 8f
    # what fits, up to its last space when the rest goes on
    lea rdi, [rip + g_face_small]
    mov rsi, rbx
    mov rdx, r12
    mov ecx, [rip + in_w]
    call text_fit
    mov r14, rax
    cmp r14, r12
    jae 4f
    mov rcx, r14
2:  test rcx, rcx
    jz 4f
    cmp byte ptr [rbx + rcx], ' '
    je 3f
    dec rcx
    jmp 2b
3:  mov r14, rcx
4:  test r14, r14
    jnz 5f
    mov r14, r12
5:  COLOR eax, T_ERROR
    push rax
    push rax
    lea rdi, [rip + g_face_small]
    mov esi, [rip + in_x]
    mov edx, r13d
    M ecx, MI_20
    mov r8, rbx
    mov r9, r14
    call ui_text_v
    add rsp, 16
    add r13d, [rip + g_mt + 4*MI_20]
    inc r15d
    add rbx, r14
    sub r12, r14
6:  test r12, r12
    jz 1b
    cmp byte ptr [rbx], ' '
    jne 1b
    inc rbx
    dec r12
    jmp 6b
8:  test r15d, r15d
    jz 9f
    add r13d, [rip + g_mt + 4*MI_4]
9:  mov eax, r13d
    EPILOGUE

# pan_args() -> edi, esi, edx, ecx: the panel
pan_args:
    mov edi, [rip + pan]
    mov esi, [rip + pan + 4]
    mov edx, [rip + pan + 8]
    mov ecx, [rip + pan + 12]
    ret

# placeholder() -> the commit message's hint, with the branch
placeholder:
    push rbx
    lea rdi, [rip + lbl]
    call sb_clear
    lea rdi, [rip + lbl]
    lea rsi, [rip + .Lph]
    call sb_push_cstr
    cmp byte ptr [rip + g_branch], 0
    je 1f
    lea rdi, [rip + lbl]
    lea rsi, [rip + .Lph_on]
    call sb_push_cstr
    lea rdi, [rip + lbl]
    lea rsi, [rip + g_branch]
    call sb_push_cstr
1:  lea rdi, [rip + lbl]
    mov esi, ')'
    call sb_push_byte
    mov rax, [rip + lbl + SB_ptr]
    pop rbx
    ret

# draw_branch(y): the branch icon and name, and where it goes
draw_branch:
    PROLOGUE
    mov r13d, edi
    M r15d, MI_32
    mov edi, IC_BRANCH
    mov esi, [rip + in_x]
    mov edx, r13d
    M ecx, MI_ICON
    mov r8d, r15d
    COLOR r9d, T_UI_MUTED
    call ui_icon_center
    mov r12d, [rip + in_x]
    add r12d, [rip + g_mt + 4*MI_ICON]
    add r12d, [rip + g_mt + 4*MI_8]
    lea r8, [rip + g_branch]
    cmp byte ptr [r8], 0
    jne 1f
    lea r8, [rip + .Lhead]
1:  lea rdi, [rip + g_face_ui]
    mov esi, r12d
    mov edx, r13d
    mov ecx, r15d
    COLOR r9d, T_UI_FG
    call ui_text_c
    add eax, [rip + g_mt + 4*MI_8]
    mov r12d, eax
    # "→ origin/main", or what it is instead
    lea rdi, [rip + lbl]
    call sb_clear
    lea rsi, [rip + .Lh_unborn]
    cmp dword ptr [rip + g_git_head], HD_UNBORN
    je 2f
    lea rsi, [rip + .Lh_detached]
    cmp dword ptr [rip + g_git_head], HD_DETACHED
    je 2f
    lea rsi, [rip + .Lh_unpublished]
    cmp byte ptr [rip + g_git_upstream], 0
    je 2f
    lea rdi, [rip + lbl]
    lea rsi, [rip + .Lh_to]
    call sb_push_cstr
    lea rsi, [rip + g_git_upstream]
2:  lea rdi, [rip + lbl]
    call sb_push_cstr
    mov eax, [rip + in_x]
    add eax, [rip + in_w]
    sub eax, r12d
    jle 9f
    push rax
    COLOR eax, T_UI_MUTED
    push rax
    lea rdi, [rip + g_face_small]
    mov esi, r12d
    mov edx, r13d
    mov ecx, r15d
    mov r8, [rip + lbl + SB_ptr]
    mov r9, [rip + lbl + SB_len]
    call ui_text_v_fit
    add rsp, 16
9:  EPILOGUE

# main_button() -> MB_*: what the button under the message does
main_button:
    mov eax, MB_COMMIT
    cmp dword ptr [rip + counts + 4*GG_STAGED], 0
    jne 9f
    cmp dword ptr [rip + counts + 4*GG_MERGE], 0
    jne 9f
    mov eax, MB_COMMIT_ALL
    cmp dword ptr [rip + counts + 4*GG_CHANGES], 0
    jne 9f
    mov eax, MB_NONE
    cmp dword ptr [rip + g_git_head], HD_BRANCH
    jne 9f
    cmp byte ptr [rip + g_git_upstream], 0
    je 1f
    mov ecx, [rip + g_git_ahead]
    or ecx, [rip + g_git_behind]
    jz 9f
    mov eax, MB_SYNC
    ret
1:  cmp dword ptr [rip + has_remote], 0
    je 9f
    mov eax, MB_PUBLISH
9:  ret

# draw_main(y): the button under the message
draw_main:
    PROLOGUE 16
    mov r13d, edi
    M r15d, MI_32
    call main_button
    mov ebx, eax
    # its label: what runs, or what it does
    lea rdi, [rip + lbl]
    call sb_clear
    mov eax, [rip + op]
    cmp eax, OP_NONE
    je 1f
    cmp eax, OP_INDEX
    je 1f
    lea rcx, [rip + busy_labels]
    mov rsi, [rcx + rax*8]
    lea rdi, [rip + lbl]
    call sb_push_cstr
    jmp 3f
1:  lea rcx, [rip + main_labels]
    mov rsi, [rcx + rbx*8]
    lea rdi, [rip + lbl]
    call sb_push_cstr
    cmp ebx, MB_SYNC
    jne 3f
    # Sync Changes 2↓ 1↑
    lea rsi, [rip + .Ldown]
    mov edx, [rip + g_git_behind]
    call push_count
    lea rsi, [rip + .Lup]
    mov edx, [rip + g_git_ahead]
    call push_count
3:  # it takes clicks with nothing running and something to do
    xor eax, eax
    cmp dword ptr [rip + op], OP_NONE
    jne 4f
    cmp ebx, MB_NONE
    je 4f
    mov edi, ID_SCM_MAIN
    mov esi, [rip + in_x]
    mov edx, r13d
    mov ecx, [rip + in_w]
    mov r8d, r15d
    call ui_btn
    or eax, ENABLED
4:  mov [rsp], eax
    COLOR r12d, T_ACCENT
    COLOR r14d, T_ACCENT_FG
    test eax, ENABLED
    jnz 5f
    COLOR edi, T_PANEL
    mov esi, r12d
    mov edx, 110
    call color_mix
    mov r12d, eax
    COLOR edi, T_PANEL
    mov esi, r14d
    mov edx, 150
    call color_mix
    mov r14d, eax
    jmp 6f
5:  test dword ptr [rsp], UB_HOVER
    jz 6f
    mov edi, r12d
    mov esi, r14d
    mov edx, 36
    call color_mix
    mov r12d, eax
6:  mov edi, [rip + in_x]
    mov esi, r13d
    mov edx, [rip + in_w]
    mov ecx, r15d
    M r8d, MI_RADIUS
    mov r9d, r12d
    call gfx_round_rect
    mov r8d, -1
    cmp dword ptr [rip + op], OP_NONE
    jne 61f
    lea rax, [rip + main_icons]
    movzx r8d, byte ptr [rax + rbx]
61: mov edi, [rip + in_x]
    mov esi, r13d
    mov edx, [rip + in_w]
    mov ecx, r15d
    mov r9d, r14d
    call center_label
    test dword ptr [rsp], UB_CLICK
    jz 9f
    cmp ebx, MB_SYNC
    jne 7f
    call cmd_git_sync
    jmp 9f
7:  cmp ebx, MB_PUBLISH
    jne 8f
    call cmd_git_push
    jmp 9f
8:  call cmd_git_commit
9:  EPILOGUE

# push_count(arrow cstr, count): " 2↓" onto lbl when count is not 0
push_count:
    test edx, edx
    jz 9f
    push rbx
    push r12
    push r13
    mov r12, rsi
    mov r13d, edx
    lea rdi, [rip + lbl]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + lbl]
    mov esi, r13d
    call sb_push_u64
    lea rdi, [rip + lbl]
    mov rsi, r12
    call sb_push_cstr
    pop r13
    pop r12
    pop rbx
9:  ret

# draw_remote(y): Pull, Push and Fetch, side by side
draw_remote:
    PROLOGUE 16
    mov r13d, edi
    M r15d, MI_28
    M ecx, MI_8
    mov eax, [rip + in_w]
    sub eax, ecx
    sub eax, ecx
    xor edx, edx
    mov ecx, 3
    div ecx
    mov r14d, eax               # button w
    xor ebx, ebx
1:  cmp ebx, 3
    jae 9f
    lea rdi, [rip + lbl]
    call sb_clear
    lea rax, [rip + remote_labels]
    mov rsi, [rax + rbx*8]
    lea rdi, [rip + lbl]
    call sb_push_cstr
    # what there is to pull and to push
    xor edx, edx
    cmp ebx, 2
    je 2f
    mov edx, [rip + g_git_behind]
    test ebx, ebx
    jz 11f
    mov edx, [rip + g_git_ahead]
11: lea rsi, [rip + empty_str]
    call push_count
2:  mov eax, r14d
    add eax, [rip + g_mt + 4*MI_8]
    imul eax, ebx
    add eax, [rip + in_x]
    mov esi, eax
    lea edi, [rbx + ID_SCM_PULL]
    mov edx, r13d
    mov ecx, r14d
    mov r8d, r15d
    lea rax, [rip + remote_icons]
    movzx r9d, byte ptr [rax + rbx]
    call draw_button
    test eax, eax
    jz 5f
    test ebx, ebx
    jnz 3f
    call cmd_git_pull
    jmp 5f
3:  cmp ebx, 1
    jne 4f
    call cmd_git_push
    jmp 5f
4:  call cmd_git_fetch
5:  inc ebx
    jmp 1b
9:  EPILOGUE

# draw_button(id, x, y, w, h, icon) -> 1 when clicked: a button with the icon and the label in lbl, taking
#   clicks while no operation runs
draw_button:
    PROLOGUE 32
    mov [rsp], edi
    mov [rsp + 4], r9d
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    mov r15d, r8d
    xor eax, eax
    cmp dword ptr [rip + op], OP_NONE
    jne 1f
    mov edi, [rsp]
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    mov r8d, r15d
    call ui_btn
    or eax, ENABLED
1:  mov ebx, eax
    COLOR eax, T_PANEL
    test ebx, UB_HOVER
    jz 2f
    COLOR eax, T_HOVER
2:  push rax
    push rax
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    mov ecx, r15d
    M r8d, MI_RADIUS
    COLOR r9d, T_BORDER
    call gfx_frame
    add rsp, 16
    COLOR r9d, T_UI_FG
    test ebx, ENABLED
    jnz 3f
    COLOR r9d, T_UI_MUTED
3:  mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    mov ecx, r15d
    mov r8d, [rsp + 4]
    call center_label
    mov eax, ebx
    and eax, UB_CLICK
    shr eax, 2
    EPILOGUE

# center_label(x, y, w, h, icon or -1, argb): the icon and the text in lbl, centered in the box
center_label:
    PROLOGUE 32
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    mov [rsp + 16], r8d
    mov [rsp + 20], r9d
    lea rdi, [rip + g_face_ui]
    mov rsi, [rip + lbl + SB_ptr]
    mov rdx, [rip + lbl + SB_len]
    call text_width
    mov ebx, eax
    cmp dword ptr [rsp + 16], 0
    jl 1f
    add ebx, [rip + g_mt + 4*MI_ICON]
    add ebx, [rip + g_mt + 4*MI_6]
1:  mov r12d, [rsp + 8]
    sub r12d, ebx
    sar r12d, 1
    add r12d, [rsp]
    cmp dword ptr [rsp + 16], 0
    jl 2f
    mov edi, [rsp + 16]
    mov esi, r12d
    mov edx, [rsp + 4]
    M ecx, MI_ICON
    mov r8d, [rsp + 12]
    mov r9d, [rsp + 20]
    call ui_icon_center
    add r12d, [rip + g_mt + 4*MI_ICON]
    add r12d, [rip + g_mt + 4*MI_6]
2:  mov eax, [rsp + 20]
    push rax
    push rax
    lea rdi, [rip + g_face_ui]
    mov esi, r12d
    mov edx, [rsp + 16 + 4]
    mov ecx, [rsp + 16 + 12]
    mov r8, [rip + lbl + SB_ptr]
    mov r9, [rip + lbl + SB_len]
    call ui_text_v
    add rsp, 16
    EPILOGUE

# draw_group(group, y) -> eax y under it: its title, count and buttons, then its files
draw_group:
    PROLOGUE 48
    mov ebx, edi
    mov r13d, esi
    M r15d, MI_28
    lea rax, [rip + group_titles]
    mov r8, [rax + rbx*8]
    lea rdi, [rip + g_face_small]
    mov esi, [rip + in_x]
    mov edx, r13d
    mov ecx, r15d
    COLOR r9d, T_UI_MUTED
    call ui_text_c
    add eax, [rip + g_mt + 4*MI_8]
    mov r12d, eax
    # the count, in a pill
    lea rax, [rip + counts]
    mov esi, [rax + rbx*4]
    lea rdi, [rsp + 16]
    call fmt_u64
    mov byte ptr [rsp + 16 + rax], 0
    mov rdx, rax
    lea rdi, [rip + g_face_small]
    lea rsi, [rsp + 16]
    call text_width
    M ecx, MI_6
    lea eax, [rax + rcx*2]
    mov [rsp], eax
    M ecx, MI_6
    mov edi, r12d
    lea esi, [r13 + rcx]
    mov edx, eax
    mov r8d, r15d
    sub r8d, ecx
    sub r8d, ecx
    mov ecx, r8d
    shr r8d, 1
    COLOR r9d, T_HOVER
    call gfx_round_rect
    COLOR eax, T_UI_FG
    push rax
    push rax
    lea rdi, [rip + g_face_small]
    mov esi, r12d
    mov edx, r13d
    mov ecx, [rsp + 16]
    mov r8d, r15d
    lea r9, [rsp + 16 + 16]
    call ui_text_center
    add rsp, 16
    # its buttons, from the right
    mov r12d, [rip + in_x]
    add r12d, [rip + in_w]
    sub r12d, [rip + g_mt + 4*MI_24]
    cmp ebx, GG_STAGED
    jne 1f
    lea edi, [rbx*4 + ID_SCM_GROUP]
    mov esi, IC_MINUS
    call group_button
    test eax, eax
    jz 3f
    call cmd_git_unstage_all
    jmp 3f
1:  cmp ebx, GG_CHANGES
    jne 3f
    lea edi, [rbx*4 + ID_SCM_GROUP]
    mov esi, IC_PLUS
    call group_button
    test eax, eax
    jz 2f
    call cmd_git_stage_all
2:  sub r12d, [rip + g_mt + 4*MI_24]
    sub r12d, [rip + g_mt + 4*MI_2]
    lea edi, [rbx*4 + ID_SCM_GROUP + 1]
    mov esi, IC_DISCARD
    call group_button
    test eax, eax
    jz 3f
    call cmd_git_discard_all
3:  add r13d, r15d
    # its files; rows out of sight only take their height
    xor r14d, r14d
.Ldg_file:
    cmp r14, [rip + list + VEC_len]
    jae .Ldg_done
    imul r12, r14, GF_SIZE
    add r12, [rip + list + VEC_ptr]
    cmp [r12 + GF_group], ebx
    jne .Ldg_next
    mov eax, [rip + pan + 4]
    add eax, [rip + pan + 12]
    cmp r13d, eax
    jge .Ldg_row
    mov eax, r13d
    add eax, r15d
    cmp eax, [rip + pan + 4]
    jle .Ldg_row
    mov edi, r14d
    mov rsi, r12
    mov edx, r13d
    call draw_file
.Ldg_row:
    add r13d, r15d
.Ldg_next:
    inc r14
    jmp .Ldg_file
.Ldg_done:
    add r13d, [rip + g_mt + 4*MI_8]
    mov eax, r13d
    EPILOGUE
# group_button(id, icon) -> 1 when clicked: an icon button at r12d on the row at r13d
group_button:
    push rbx
    mov r9d, esi
    mov esi, r12d
    mov edx, r13d
    add edx, [rip + g_mt + 4*MI_2]
    M ecx, MI_24
    mov r8d, ecx
    call ui_icon_btn
    and eax, UB_CLICK
    shr eax, 2
    pop rbx
    ret

# draw_file(index, gf, y): a changed file: its letter and path, its buttons when hovered; a click shows
#   its changes
draw_file:
    PROLOGUE 32
    mov ebx, edi
    mov r12, rsi
    mov r13d, edx
    M r15d, MI_28
    lea edi, [rbx*4 + ID_SCM_FILE]
    mov esi, [rip + pan]
    mov edx, r13d
    mov ecx, [rip + pan + 8]
    sub ecx, [rip + g_mt + 4*MI_12]
    mov r8d, r15d
    call ui_btn
    mov r14d, eax
    test eax, UB_HOVER
    jz 1f
    M eax, MI_6
    mov edi, [rip + pan]
    add edi, eax
    mov esi, r13d
    mov edx, [rip + pan + 8]
    sub edx, eax
    sub edx, eax
    mov ecx, r15d
    M r8d, MI_RADIUS
    COLOR r9d, T_HOVER
    call gfx_round_rect
1:  # the letter
    mov eax, [r12 + GF_code]
    mov [rsp], eax
    mov edi, eax
    call git_code_color
    mov r9d, eax
    lea rdi, [rip + g_face_small]
    mov esi, [rip + in_x]
    mov edx, r13d
    mov ecx, r15d
    lea r8, [rsp]
    call ui_text_c
    # buttons, from the right: stage (or unstage), and discard for changes not staged
    mov eax, [rip + in_x]
    add eax, [rip + in_w]
    mov [rsp + 8], eax          # right of the path
    test r14d, UB_HOVER
    jz 5f
    mov eax, [rip + g_mt + 4*MI_24]
    sub [rsp + 8], eax
    lea edi, [rbx*4 + ID_SCM_FILE + 1]
    mov esi, [rsp + 8]
    cmp dword ptr [r12 + GF_group], GG_STAGED
    jne 2f
    mov r9d, IC_MINUS
    call file_button
    test eax, eax
    jz 4f
    mov rdi, r12
    lea rsi, [rip + seq_unstage]
    call file_action
    jmp 4f
2:  mov r9d, IC_PLUS
    call file_button
    test eax, eax
    jz 3f
    mov rdi, r12
    lea rsi, [rip + seq_stage]
    call file_action
3:  cmp dword ptr [r12 + GF_group], GG_CHANGES
    jne 4f
    mov eax, [rip + g_mt + 4*MI_24]
    add eax, [rip + g_mt + 4*MI_2]
    sub [rsp + 8], eax
    lea edi, [rbx*4 + ID_SCM_FILE + 2]
    mov esi, [rsp + 8]
    mov r9d, IC_DISCARD
    call file_button
    test eax, eax
    jz 4f
    mov rdi, r12
    call ask_discard
4:  mov eax, [rip + g_mt + 4*MI_4]
    sub [rsp + 8], eax
5:  # the path
    mov rdi, [r12 + GF_path]
    call strlen
    mov r9, rax
    mov eax, [rsp + 8]
    sub eax, [rip + in_x]
    sub eax, [rip + g_mt + 4*MI_20]
    jle 6f
    push rax
    COLOR eax, T_UI_FG
    push rax
    lea rdi, [rip + g_face_ui]
    mov esi, [rip + in_x]
    add esi, [rip + g_mt + 4*MI_20]
    mov edx, r13d
    mov ecx, r15d
    mov r8, [r12 + GF_path]
    call ui_text_v_fit
    add rsp, 16
6:  # a click on the row: the file's changes (not for untracked folders)
    test r14d, UB_CLICK
    jz 9f
    mov rdi, [r12 + GF_path]
    call strlen
    test rax, rax
    jz 9f
    mov rsi, [r12 + GF_path]
    cmp byte ptr [rsi + rax - 1], '/'
    je 9f
    mov rdx, rax
    xor edi, edi
    call git_open_diff
9:  EPILOGUE
# file_button(id, x, -, -, -, icon) -> 1 when clicked: an icon button on the row at r13d
file_button:
    push rbx
    mov edx, r13d
    add edx, [rip + g_mt + 4*MI_2]
    M ecx, MI_24
    mov r8d, ecx
    call ui_icon_btn
    and eax, UB_CLICK
    shr eax, 2
    pop rbx
    ret

# ---------------- scripts ----------------

# scm_dump(sb): "action=commit" (or what runs), the message (line breaks as |), the last error, the changes
FN scm_dump
    PROLOGUE
    mov rbx, rdi
    call sync_list
    mov rdi, rbx
    lea rsi, [rip + .Ld_action]
    call sb_push_cstr
    mov eax, [rip + op]
    lea rcx, [rip + op_names]
    test eax, eax
    jnz 1f
    call main_button
    lea rcx, [rip + mb_names]
1:  mov rsi, [rcx + rax*8]
    mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    lea rdi, [rip + tf_msg]
    call tf_text
    mov r12, rax
    mov r13, rdx
    test r13, r13
    jz 4f
    mov rdi, rbx
    lea rsi, [rip + .Ld_message]
    call sb_push_cstr
    xor r14d, r14d
2:  cmp r14, r13
    jae 3f
    movzx esi, byte ptr [r12 + r14]
    cmp esi, 10
    jne 21f
    mov esi, '|'
21: mov rdi, rbx
    call sb_push_byte
    inc r14
    jmp 2b
3:  mov rdi, rbx
    mov esi, 10
    call sb_push_byte
4:  cmp byte ptr [rip + err], 0
    je 5f
    mov rdi, rbx
    lea rsi, [rip + .Ld_error]
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + err]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
5:  mov rdi, rbx
    call scm_dump_files
    EPILOGUE

# scm_dump_files(sb): the changes, a group title then "    X path" per file
FN scm_dump_files
    PROLOGUE
    mov rbx, rdi
    call sync_list
    mov r12d, GG_MERGE
1:  lea rax, [rip + counts]
    cmp dword ptr [rax + r12*4], 0
    je 5f
    mov rdi, rbx
    lea rsi, [rip + .Lindent]
    call sb_push_cstr
    lea rax, [rip + group_titles]
    mov rsi, [rax + r12*8]
    mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    xor r13d, r13d
2:  cmp r13, [rip + list + VEC_len]
    jae 5f
    imul r14, r13, GF_SIZE
    add r14, [rip + list + VEC_ptr]
    cmp [r14 + GF_group], r12d
    jne 4f
    mov rdi, rbx
    lea rsi, [rip + .Lindent]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [r14 + GF_code]
    call sb_push_byte
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rdi, rbx
    mov rsi, [r14 + GF_path]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
4:  inc r13
    jmp 2b
5:  inc r12d
    cmp r12d, GG_CHANGES
    jbe 1b
    EPILOGUE

.section .rodata
.Lno_repo: .asciz "No git repository"
.Lbusy: .asciz "Wait for the git command that runs"
.Lconflicts: .asciz "Resolve the conflicts and stage the files first"
.Lnothing: .asciz "No changes to commit"
.Lnothing_discard: .asciz "No changes to discard"
.Lno_message: .asciz "Type a commit message first"
.Llong: .asciz "The commit message is too long"
.Lno_remote: .asciz "No remote to publish to: add one with git remote add"
.Le_rejected: .asciz "Push rejected: pull first to bring in the remote's changes"
.Le_conflict: .asciz "Merge conflicts: resolve them, stage the files, then commit"
.Le_rebase: .asciz "Rebase stopped on conflicts: resolve them, then git rebase --continue"
.Le_failed: .asciz "git failed"
.Lk_rejected: .ascii "[rejected]"
.Lk_conflict: .ascii "CONFLICT"
.Lk_rebase: .ascii "could not apply"
.Lk_fatal: .ascii "fatal: "
.Lk_error: .ascii "error: "
.Lk_hint: .ascii "hint:"
.Lpull_same: .ascii "Already up to date"
.Lpush_same: .ascii "Everything up-to-date"
.Lt_same: .asciz "Already up to date"
.Lt_pulled: .asciz "Pulled"
.Lt_pushed: .asciz "Pushed"
.Lt_synced: .asciz "Synced"
.Lt_fetched: .asciz "Fetched"
.Lt_published: .asciz "Branch published"
.Lq_discard: .asciz "Discard changes in "
.Lq_discard_text: .asciz "Its changes that are not staged will be lost."
.Lq_delete: .asciz "Delete "
.Lq_delete_text: .asciz "The file is not in git: it cannot be restored."
.Lq_all: .asciz "Discard all changes?"
.Lq_all_text: .asciz "Unstaged changes and new files will be lost."
.Lb_discard: .asciz "Discard"
.Lb_delete: .asciz "Delete"
.Lb_discard_all: .asciz "Discard All"
.ifdef MACOS
.Lph: .asciz "Message (\342\214\230Enter to commit"
.else
.Lph: .asciz "Message (Ctrl+Enter to commit"
.endif
.Lph_on: .asciz " on "
.Lh_unborn: .asciz "no commits yet"
.Lh_detached: .asciz "detached"
.Lh_unpublished: .asciz "not published"
.Lh_to: .asciz "\342\206\222 "
.Ldown: .asciz "\342\206\223"
.Lup: .asciz "\342\206\221"
.Lm_commit: .asciz "Commit"
.Lm_commit_all: .asciz "Commit All"
.Lm_sync: .asciz "Sync Changes"
.Lm_publish: .asciz "Publish Branch"
.Lw_commit: .asciz "Committing\342\200\246"
.Lw_pull: .asciz "Pulling\342\200\246"
.Lw_push: .asciz "Pushing\342\200\246"
.Lw_sync: .asciz "Syncing\342\200\246"
.Lw_fetch: .asciz "Fetching\342\200\246"
.Lw_publish: .asciz "Publishing\342\200\246"
.Lr_pull: .asciz "Pull"
.Lr_push: .asciz "Push"
.Lr_fetch: .asciz "Fetch"
.Lg_merge: .asciz "MERGE CHANGES"
.Lg_staged: .asciz "STAGED CHANGES"
.Lg_changes: .asciz "CHANGES"
.Ld_action: .asciz "action="
.Ld_message: .asciz "message="
.Ld_error: .asciz "error="
.Lindent: .asciz "    "
.Ln_none: .asciz "none"
.Ln_commit: .asciz "commit"
.Ln_commit_all: .asciz "commit-all"
.Ln_sync: .asciz "sync"
.Ln_publish: .asciz "publish"
.Ln_committing: .asciz "committing"
.Ln_pulling: .asciz "pulling"
.Ln_pushing: .asciz "pushing"
.Ln_syncing: .asciz "syncing"
.Ln_fetching: .asciz "fetching"
.Ln_publishing: .asciz "publishing"
.Ln_staging: .asciz "staging"
.Lorigin: .ascii "origin"
# git's arguments
.Ladd: .asciz "add"
.Ldash_a: .asciz "-A"
.Lcommit: .asciz "commit"
.Ldash_q: .asciz "-q"
.Ldash_f: .asciz "-F"
.Ldash: .asciz "-"
.Lamend: .asciz "--amend"
.Lno_edit: .asciz "--no-edit"
.Lconfig: .asciz "config"
.Lget_regexp: .asciz "--get-regexp"
.Lpull_keys: .asciz "^pull\\.(rebase|ff)$"
.Lpull: .asciz "pull"
.Lpull_merge: .asciz "pull.rebase=false"
.Ldash_c: .asciz "-c"
.Lpush: .asciz "push"
.Ldash_u: .asciz "-u"
.Lremote: .asciz "remote"
.Lfetch: .asciz "fetch"
.Lreset: .asciz "reset"
.Lcheckout: .asciz "checkout"
.Lclean: .asciz "clean"
.Ldash_d: .asciz "-d"
.Lforce: .asciz "-f"
.Ldashdash: .asciz "--"
.Ldot: .asciz "."
.Lhead: .asciz "HEAD"
.p2align 3
args_add_all: .quad .Ladd, .Ldash_a, 0
args_commit: .quad .Lcommit, .Ldash_q, .Ldash_f, .Ldash, 0
args_amend: .quad .Lcommit, .Ldash_q, .Lamend, 0
args_pull_cfg: .quad .Lconfig, .Lget_regexp, .Lpull_keys, 0
args_pull: .quad .Lpull, .Lno_edit, 0
args_pull_merge: .quad .Ldash_c, .Lpull_merge, .Lpull, .Lno_edit, 0
args_push: .quad .Lpush, 0
args_remote: .quad .Lremote, 0
args_publish: .quad .Lpush, .Ldash_u, 0
args_fetch: .quad .Lfetch, 0
args_add: .quad .Ladd, .Ldash_a, 0
args_reset: .quad .Lreset, .Ldash_q, 0
args_reset_all: .quad .Lreset, .Ldash_q, .Ldashdash, .Ldot, 0
args_checkout: .quad .Lcheckout, .Ldash_q, 0
args_checkout_all: .quad .Lcheckout, .Ldash_q, .Ldashdash, .Ldot, 0
args_clean: .quad .Lclean, .Lforce, .Ldash_d, .Ldash_q, 0
# by S_*
step_args:
    .quad 0, args_add_all, args_commit, args_amend, args_pull_cfg, args_pull, args_push, args_remote
    .quad args_publish, args_fetch, args_add, args_reset, args_reset_all, args_checkout, args_checkout_all
    .quad args_clean, args_clean
# by OP_*
done_toasts:
    .quad 0, 0, .Lt_pulled, .Lt_pushed, .Lt_synced, .Lt_fetched, .Lt_published, 0
busy_labels:
    .quad 0, .Lw_commit, .Lw_pull, .Lw_push, .Lw_sync, .Lw_fetch, .Lw_publish, 0
op_names:
    .quad .Ln_none, .Ln_committing, .Ln_pulling, .Ln_pushing, .Ln_syncing, .Ln_fetching, .Ln_publishing
    .quad .Ln_staging
# by MB_*
main_labels:
    .quad .Lm_commit, .Lm_commit, .Lm_commit_all, .Lm_sync, .Lm_publish
mb_names:
    .quad .Ln_none, .Ln_commit, .Ln_commit_all, .Ln_sync, .Ln_publish
# by GG_*
group_titles:
    .quad 0, .Lg_merge, .Lg_staged, .Lg_changes
remote_labels:
    .quad .Lr_pull, .Lr_push, .Lr_fetch
remote_icons:
    .byte IC_ARROW_DN, IC_ARROW_UP, IC_REFRESH
main_icons:
    .byte IC_CHECK, IC_CHECK, IC_CHECK, IC_REFRESH, IC_ARROW_UP
# steps
seq_commit: .byte S_COMMIT, 0
seq_commit_all: .byte S_ADD_ALL, S_COMMIT, 0
seq_amend: .byte S_AMEND, 0
seq_pull: .byte S_PULL_CFG, S_PULL, 0
seq_push: .byte S_PUSH, 0
seq_publish: .byte S_REMOTES, S_PUBLISH, 0
seq_sync: .byte S_PULL_CFG, S_PULL, S_PUSH, 0
seq_fetch: .byte S_FETCH, 0
seq_stage: .byte S_ADD, 0
seq_stage_all: .byte S_ADD_ALL, 0
seq_unstage: .byte S_RESET, 0
seq_unstage_all: .byte S_RESET_ALL, 0
seq_discard: .byte S_CHECKOUT, 0
seq_discard_new: .byte S_CLEAN, 0
seq_discard_all: .byte S_CHECKOUT_ALL, S_CLEAN_ALL, 0
seq_clean_all: .byte S_CLEAN_ALL, 0

.Lai_label: .asciz "AI"
.Lai_cancel: .asciz "Cancel"
.Lai_off: .asciz "Choose a commit message AI provider in Settings first."
.Lai_edited: .asciz "Your draft changed while generating, so it was kept."
