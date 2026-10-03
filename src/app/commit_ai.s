# Optional commit-message generation. Helpers own all discovery, I/O and setup.
# Rendering only reads cached state. No input pipe writes or blocking waits here.
.include "rhun.inc"

.bss
.p2align 3
out: .zero SB_SIZE
env_action: .zero SB_SIZE
env_provider: .zero SB_SIZE
env_model: .zero SB_SIZE
env_repo: .zero SB_SIZE
cached_model: .quad 0
confirm_model: .quad 0
confirm_text: .zero SB_SIZE
pid: .long 0
pending: .long 0
result_model: .long 0
.globl g_ai_model_ready
g_ai_model_ready: .long 0
cancelled: .long 0
exited: .long 0
exit_code: .long 0
.p2align 3
deadline: .quad 0
.globl g_ai_kind
g_ai_kind: .long 0                    # 1 detection, 2 setup, 3 generation, 4 delete
.data
fd: .long -1
cached_provider: .long -1
.globl g_ai_desc
g_ai_desc: .asciz "AI commit messages are off."
    .zero 230
.globl g_ai_provider_desc
g_ai_provider_desc: .zero 256
.globl g_ai_local_desc
g_ai_local_desc: .asciz "Select Local (Ollama) to manage model files."
    .zero 230

.text

# Called after either settings UI or external config changes.
FN ai_apply
    PROLOGUE
    mov eax, [rip + cfg_commit_ai]
    cmp eax, [rip + cached_provider]
    jne 1f
    mov rsi, [rip + cached_model]
    test rsi, rsi
    jz 1f
    mov rdi, [rip + cfg_commit_model]
    call strcmp_eq
    test eax, eax
    jnz 9f
1:  call ai_cancel
    mov dword ptr [rip + g_ai_model_ready], 0
    mov eax, [rip + cfg_commit_ai]
    mov [rip + cached_provider], eax
    mov rdi, [rip + cached_model]
    call mem_free
    mov rdi, [rip + cfg_commit_model]
    call strlen
    mov rsi, rax
    mov rdi, [rip + cfg_commit_model]
    call mem_dup
    mov [rip + cached_model], rax
    mov dword ptr [rip + pending], 0
    lea rdi, [rip + .Loff]
    cmp dword ptr [rip + cfg_commit_ai], 0
    je 2f
    mov dword ptr [rip + pending], 1
    lea rdi, [rip + .Lchecking]
2:  call describe
9:  EPILOGUE

FN cmd_ai_detect
    PROLOGUE
    cmp dword ptr [rip + cfg_commit_ai], 0
    je 1f
    cmp dword ptr [rip + g_ai_kind], 0
    jne 9f
    mov dword ptr [rip + pending], 1
    lea rdi, [rip + .Lchecking]
    call describe
    jmp 9f
1:  lea rdi, [rip + .Loff]
    call app_toast
9:  EPILOGUE

# One Settings action, selected from cached model state. Palette commands stay explicit.
FN cmd_ai_model_files
    cmp dword ptr [rip + cfg_commit_ai], 3
    je 2f
    lea rdi, [rip + .Lselect_local]
    jmp app_toast
2:  cmp dword ptr [rip + g_ai_kind], 2
    je cmd_ai_setup
    cmp dword ptr [rip + g_ai_kind], 0
    jne 1f
    cmp dword ptr [rip + pending], 0
    jne 1f
    cmp dword ptr [rip + g_ai_model_ready], 1
    je cmd_ai_delete
    jmp cmd_ai_setup
1:  lea rdi, [rip + .Lbusy]
    jmp app_toast

FN cmd_ai_setup
    PROLOGUE
    cmp dword ptr [rip + g_ai_kind], 0
    jne 2f
    cmp dword ptr [rip + cfg_commit_ai], 3
    jne 1f
    mov edi, 2
    call start
    jmp 9f
1:  lea rdi, [rip + .Lselect_local]
    call app_toast
    jmp 9f
2:  mov ebx, [rip + g_ai_kind]
    cmp ebx, 2
    jbe 3f
    lea rdi, [rip + .Lbusy]
    call app_toast
    jmp 9f
3:  call ai_cancel
    cmp ebx, 1
    jne 9f
    cmp dword ptr [rip + cfg_commit_ai], 3
    jne 9f
    mov dword ptr [rip + pending], 2
9:  EPILOGUE

# Confirmation owns its model name until replaced. Never delete a newly selected model.
FN cmd_ai_delete
    PROLOGUE
    cmp dword ptr [rip + cfg_commit_ai], 3
    jne 7f
    cmp dword ptr [rip + g_ai_kind], 0
    jne 8f
    cmp dword ptr [rip + pending], 0
    jne 8f
    mov rax, [rip + cfg_commit_model]
    cmp byte ptr [rax], 0
    jne 1f
    lea rdi, [rip + .Lmodel_required]
    call app_toast
    jmp 9f
1:  mov rdi, [rip + confirm_model]
    call mem_free
    mov rdi, [rip + cfg_commit_model]
    call strlen
    mov rsi, rax
    mov rdi, [rip + cfg_commit_model]
    call mem_dup
    mov [rip + confirm_model], rax
    lea rdi, [rip + confirm_text]
    call sb_clear
    lea rdi, [rip + confirm_text]
    mov rsi, [rip + confirm_model]
    call sb_push_cstr
    lea rdi, [rip + confirm_text]
    lea rsi, [rip + .Ldelete_warning]
    call sb_push_cstr
    lea rdi, [rip + confirm_text]
    xor esi, esi
    call sb_push_byte
    lea rdi, [rip + .Ldelete_question]
    mov rsi, [rip + confirm_text + SB_ptr]
    lea rdx, [rip + .Ldelete_button]
    lea rcx, [rip + delete_confirmed]
    call app_confirm
    jmp 9f
7:  lea rdi, [rip + .Lselect_local]
    call app_toast
    jmp 9f
8:  lea rdi, [rip + .Lbusy]
    call app_toast
9:  EPILOGUE

delete_confirmed:
    PROLOGUE
    cmp dword ptr [rip + cfg_commit_ai], 3
    jne 8f
    mov rdi, [rip + cfg_commit_model]
    mov rsi, [rip + confirm_model]
    call strcmp_eq
    test eax, eax
    jz 8f
    cmp dword ptr [rip + g_ai_kind], 0
    jne 8f
    cmp dword ptr [rip + pending], 0
    jne 8f
    mov edi, 4
    call start
    jmp 9f
8:  lea rdi, [rip + .Ldelete_changed]
    call app_toast
9:  EPILOGUE

# ai_generate(): caller has validated the repository and captured the draft.
FN ai_generate
    PROLOGUE
    cmp dword ptr [rip + g_ai_kind], 1
    jne 1f
    call ai_cancel
    mov dword ptr [rip + pending], 3
    jmp 9f
1:  mov edi, 3
    call start
9:  EPILOGUE

FN ai_cancel_generation
    cmp dword ptr [rip + pending], 3
    jne 1f
    mov dword ptr [rip + pending], 0
1:  cmp dword ptr [rip + g_ai_kind], 3
    je ai_cancel
    ret

FN cmd_ai_cancel
FN ai_cancel
    PROLOGUE
    mov dword ptr [rip + pending], 0
    cmp dword ptr [rip + pid], 0
    je 9f
    mov dword ptr [rip + cancelled], 1
    mov edi, [rip + pid]
    neg edi
    mov esi, 15
    SYS SYS_kill
    call time_ms
    add rax, 500
    mov [rip + deadline], rax
    lea rdi, [rip + .Lcancelled]
    cmp dword ptr [rip + g_ai_kind], 2
    jne 1f
    lea rdi, [rip + .Ldownload_cancelled]
1:  call describe
9:  EPILOGUE

# On app exit, terminate the owned job/group. No wait on the UI thread.
FN ai_shutdown
    mov edi, [rip + pid]
    test edi, edi
    jz 1f
    neg edi
    mov esi, 9
    SYS SYS_kill
1:  ret

FN ai_timeout
    mov eax, 50
    cmp dword ptr [rip + g_ai_kind], 0
    jne 1f
    cmp dword ptr [rip + pending], 0
    jne 1f
    mov eax, -1
1:  ret

FN ai_tick
    PROLOGUE
    cmp dword ptr [rip + g_ai_kind], 0
    jne 2f
    cmp dword ptr [rip + pending], 0
    je 9f
    mov edi, [rip + pending]
    call start
    jmp 9f
2:  cmp dword ptr [rip + exited], 0
    jne 4f
    mov edi, [rip + pid]
    mov esi, 1
    call proc_wait
    cmp eax, -1
    je 4f
    mov [rip + exit_code], eax
    mov dword ptr [rip + exited], 1
4:  cmp dword ptr [rip + fd], -1
    jne 5f
    cmp dword ptr [rip + exited], 0
    je 5f
    call finish
    jmp 9f
5:  call time_ms
    cmp rax, [rip + deadline]
    jb 9f
    mov edi, [rip + pid]
    neg edi
    mov esi, 9
    SYS SYS_kill
    cmp dword ptr [rip + cancelled], 0
    jne 6f
    mov dword ptr [rip + cancelled], 1
    lea rdi, [rip + .Ltimeout]
    call describe
    lea rdi, [rip + .Ltimeout]
    call app_toast
6:  # Descendants may hold stdout open; close it after terminating the group.
    call close_output
9:  EPILOGUE

# field(sb, prefix, value): one owned environment entry
field:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    call sb_clear
    mov rdi, rbx
    mov rsi, r12
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, r13
    test rsi, rsi
    jnz 1f
    lea rsi, [rip + .Lempty]
1:  call sb_push_cstr
    mov rdi, rbx
    xor esi, esi
    call sb_push_byte
    EPILOGUE

# start(kind): only fixed script text goes through an interpreter; all parameters
# are separate environment entries. errors=1 gives the helper an owned session.
start:
    PROLOGUE 128
    mov r15d, edi
    cmp dword ptr [rip + g_ai_kind], 0
    jne 9f
    cmp dword ptr [rip + cfg_commit_ai], 0
    je 9f
    mov dword ptr [rip + pending], 0
    lea rdi, [rip + env_action]
    lea rsi, [rip + .Le_action]
    lea rax, [rip + actions]
    mov rdx, [rax + r15*8]
    call field
    lea rdi, [rip + env_provider]
    lea rsi, [rip + .Le_provider]
    mov eax, [rip + cfg_commit_ai]
    cmp eax, 3
    ja 9f
    lea rcx, [rip + providers]
    mov rdx, [rcx + rax*8]
    call field
    lea rdi, [rip + env_model]
    lea rsi, [rip + .Le_model]
    mov rdx, [rip + cfg_commit_model]
    call field
    lea rdi, [rip + env_repo]
    lea rsi, [rip + .Le_repo]
    mov rdx, [rip + g_git_root]
    call field
    mov rax, [rip + env_action + SB_ptr]
    mov [rsp + 64], rax
    mov rax, [rip + env_provider + SB_ptr]
    mov [rsp + 72], rax
    mov rax, [rip + env_model + SB_ptr]
    mov [rsp + 80], rax
    mov rax, [rip + env_repo + SB_ptr]
    mov [rsp + 88], rax
    mov qword ptr [rsp + 96], 0
    lea rdi, [rsp + 64]
    call env_make
    mov r13, rax
.ifdef WINDOWS
    lea rdi, [rip + .Lshell]
    call proc_which
    mov r12, rax
    test rax, rax
    jz 8f
    mov [rsp], rax
    lea rax, [rip + .Lnoprofile]
    mov [rsp + 8], rax
    lea rax, [rip + .Lnoninteractive]
    mov [rsp + 16], rax
    lea rax, [rip + .Loutputformat]
    mov [rsp + 24], rax
    lea rax, [rip + .Ltext]
    mov [rsp + 32], rax
    lea rax, [rip + windows_helper_flag]
    mov [rsp + 40], rax
    lea rax, [rip + commit_ai_script]
    mov [rsp + 48], rax
    mov qword ptr [rsp + 56], 0
.else
    xor r12d, r12d
    lea rax, [rip + .Lshell]
    mov [rsp], rax
    lea rax, [rip + .Lcommand]
    mov [rsp + 8], rax
    lea rax, [rip + commit_ai_script]
    mov [rsp + 16], rax
    mov qword ptr [rsp + 24], 0
.endif
    lea rdi, [rsp]
    mov rsi, r13
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    mov r9d, 1
    call run_piped_input
    mov r14, rax
    mov [rsp + 104], edx
    mov rdi, r12
    call mem_free
    test r14, r14
    jle 8f
    mov [rip + pid], r14d
    mov eax, [rsp + 104]
    mov [rip + fd], eax
    mov [rip + g_ai_kind], r15d
    mov dword ptr [rip + cancelled], 0
    mov dword ptr [rip + result_model], -1
    mov dword ptr [rip + exited], 0
    lea rdi, [rip + out]
    call sb_clear
    call time_ms
    mov ecx, 20000
    cmp r15d, 2
    jne 1f
    mov ecx, 1800000
1:  cmp r15d, 3
    jne 2f
    mov ecx, 180000
2:  add rax, rcx
    mov [rip + deadline], rax
    mov edi, [rip + fd]
    mov esi, POLLIN
    lea rdx, [rip + on_output]
    xor ecx, ecx
    call watch_add
    lea rax, [rip + busy]
    mov rdi, [rax + r15*8]
    call describe
    jmp 7f
8:  lea rdi, [rip + .Lspawn_error]
    call describe
    lea rdi, [rip + .Lspawn_error]
    call app_toast
7:  mov rdi, r13
    call mem_free
9:  EPILOGUE

on_output:
    PROLOGUE
    lea rdi, [rip + out]
    mov esi, 4096
    call sb_reserve
    mov rsi, rax
    mov edi, [rip + fd]
    mov edx, 4096
    SYS SYS_read
    cmp rax, -EINTR
    je 9f
    cmp rax, -EAGAIN
    je 9f
    test rax, rax
    jle 7f
    cmp dword ptr [rip + cancelled], 0
    jne 9f
    add [rip + out + SB_len], rax
    cmp qword ptr [rip + out + SB_len], 16384
    ja 8f
    # Management helpers emit state/progress frames before their final status.
    cmp dword ptr [rip + g_ai_kind], 3
    je 9f
1:  mov rbx, [rip + out + SB_ptr]
    cmp byte ptr [rbx], '@'
    jne 9f
    xor r12d, r12d
2:  cmp r12, [rip + out + SB_len]
    jae 9f
    cmp byte ptr [rbx + r12], 10
    je 3f
    inc r12
    jmp 2b
3:  mov byte ptr [rbx + r12], 0
    mov rdi, rbx
    lea rsi, [rip + .Lmodel_present]
    call strcmp_eq
    test eax, eax
    jz 4f
    mov dword ptr [rip + result_model], 1
    jmp 6f
4:  mov rdi, rbx
    lea rsi, [rip + .Lmodel_absent]
    call strcmp_eq
    test eax, eax
    jz 5f
    mov dword ptr [rip + result_model], 0
    jmp 6f
5:  lea rdi, [rbx + 1]
    call describe
6:  inc r12
    sub [rip + out + SB_len], r12
    mov rdi, rbx
    lea rsi, [rbx + r12]
    mov rdx, [rip + out + SB_len]
    call memmove
    cmp qword ptr [rip + out + SB_len], 0
    jne 1b
    jmp 9f
7:  call close_output
    jmp 9f
8:  call ai_cancel
    lea rdi, [rip + .Linvalid]
    call describe
    lea rdi, [rip + .Linvalid]
    call app_toast
9:  EPILOGUE

close_output:
    push rbx
    mov edi, [rip + fd]
    test edi, edi
    js 1f
    call watch_remove
    mov edi, [rip + fd]
    SYS SYS_close
    mov dword ptr [rip + fd], -1
1:  pop rbx
    ret

finish:
    PROLOGUE
    mov ebx, [rip + g_ai_kind]
    mov dword ptr [rip + g_ai_kind], 0
    mov dword ptr [rip + pid], 0
    cmp dword ptr [rip + cancelled], 0
    jne 9f
    lea rdi, [rip + out]
    xor esi, esi
    call sb_push_byte
    mov rdi, [rip + out + SB_ptr]
    mov rsi, [rip + out + SB_len]
    dec rsi
    mov rax, rdi
    mov rdx, rsi
1:  test rdx, rdx
    jz 3f
    cmp byte ptr [rax], 32
    ja 2f
    inc rax
    dec rdx
    jmp 1b
2:  cmp byte ptr [rax + rdx - 1], 32
    ja 3f
    dec rdx
    jmp 1b
3:  mov byte ptr [rax + rdx], 0
    mov r12, rax
    mov r13, rdx
    test rdx, rdx
    jz 8f
    cmp dword ptr [rip + exit_code], 0
    jne 7f
    cmp dword ptr [rip + cfg_commit_ai], 3
    jne 4f
    mov eax, [rip + result_model]
    cmp eax, -1
    je 4f
    mov [rip + g_ai_model_ready], eax
4:  cmp ebx, 3
    jne 6f
    cmp r13, 8192
    ja 8f
    cmp dword ptr [rip + cfg_commit_ai], 3
    jne 5f
    mov dword ptr [rip + g_ai_model_ready], 1
5:  mov rdi, r12
    mov rsi, r13
    call scm_ai_result
    lea rdi, [rip + .Lready]
    call describe
    jmp 9f
6:  mov rdi, r12
    call describe
    jmp 9f
7:  mov rdi, r12
    call describe
    lea rdi, [rip + g_ai_desc]
    call app_toast
    jmp 9f
8:  lea rdi, [rip + .Linvalid]
    call describe
    lea rdi, [rip + .Linvalid]
    call app_toast
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# describe(cstr): bounded status, also safe for arbitrary helper errors.
describe:
    lea rsi, [rip + g_ai_desc]
    mov ecx, 250
1:  mov al, [rdi]
    test al, al
    jz 2f
    cmp al, 10
    je 2f
    cmp al, 13
    je 2f
    mov [rsi], al
    inc rsi
    inc rdi
    dec ecx
    jnz 1b
2:  mov byte ptr [rsi], 0
    lea rdi, [rip + .Lselect_local]
    cmp dword ptr [rip + cfg_commit_ai], 3
    jne 3f
    lea rdi, [rip + g_ai_desc]
3:  lea rsi, [rip + g_ai_local_desc]
4:  mov al, [rdi]
    mov [rsi], al
    inc rdi
    inc rsi
    test al, al
    jnz 4b
    lea rdi, [rip + g_ai_desc]
    cmp dword ptr [rip + cfg_commit_ai], 3
    jne 5f
    lea rdi, [rip + .Llocal_check]
5:  lea rsi, [rip + g_ai_provider_desc]
6:  mov al, [rdi]
    mov [rsi], al
    inc rdi
    inc rsi
    test al, al
    jnz 6b
    mov dword ptr [rip + g_dirty], 1
    ret

.section .rodata
.Lmodel_present: .asciz "@model=1"
.Lmodel_absent: .asciz "@model=0"
.Lempty: .asciz ""
.Loff: .asciz "AI commit messages are off."
.Llocal_check: .asciz "Local generation on this computer."
.Ldownload_cancelled: .asciz "Cancelled. Choose Download to retry."
.Lchecking: .asciz "Checking the selected provider..."
.Lsetup: .asciz "Setting up the local model..."
.Lgenerating: .asciz "Generating a commit message..."
.Lcancelled: .asciz "Cancelled. Your draft was kept."
.Ltimeout: .asciz "AI operation timed out. Your draft was kept; retry when ready."
.Linvalid: .asciz "The provider returned an empty or oversized response. Your draft was kept."
.Lready: .asciz "Ready. Review the generated message before committing."
.Lspawn_error: .asciz "Could not start the AI helper. Check that the system shell is available."
.Lselect_local: .asciz "Select Local (Ollama) to manage model files."
.Lbusy: .asciz "Wait for the current AI operation to finish."
.Lmodel_required: .asciz "Enter a local model name before deleting."
.Ldelete_question: .asciz "Delete installed model?"
.Ldelete_warning: .asciz " may also be used by other apps. Ollama stays installed."
.Ldelete_button: .asciz "Delete model"
.Ldelete_changed: .asciz "Model selection or operation changed. Choose Delete again."
.Ldeleting: .asciz "Deleting the selected model..."
.Ldelete: .asciz "delete"
.Le_action: .asciz "RHUN_AI_ACTION="
.Le_provider: .asciz "RHUN_AI_PROVIDER="
.Le_model: .asciz "RHUN_AI_MODEL="
.Le_repo: .asciz "RHUN_AI_REPO="
.Lprobe: .asciz "probe"
.Linstall: .asciz "setup"
.Lgenerate: .asciz "generate"
.Lnone: .asciz "off"
.Lclaude: .asciz "claude"
.Lcodex: .asciz "codex"
.Lollama: .asciz "ollama"
.ifdef WINDOWS
.Lshell: .asciz "powershell.exe"
.Loutputformat: .asciz "-OutputFormat"
.Ltext: .asciz "Text"
.Lnoprofile: .asciz "-NoProfile"
.Lnoninteractive: .asciz "-NonInteractive"
.else
.Lshell: .asciz "/bin/sh"
.Lcommand: .asciz "-c"
.endif
.p2align 3
actions: .quad .Lempty, .Lprobe, .Linstall, .Lgenerate, .Ldelete
providers: .quad .Lnone, .Lclaude, .Lcodex, .Lollama
busy: .quad .Loff, .Lchecking, .Lsetup, .Lgenerating, .Ldeleting
