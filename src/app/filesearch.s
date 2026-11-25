# Files and search for extensions (feature files, docs/extensions/v1.1.md): find-files lists the
# workspace folders' files by glob (glob.s), search-text searches their text, the editor's text
# where a file is open. In a repository git may run in, git ls-files says which files there are
# (.gitignore and the rest of git's rules); elsewhere, or when the extension asks for ignored files
# too, rhun walks the folder itself and leaves out the names of the exclude setting. Results go to
# the extension in batches ("0 found ID LEN") as they come, then one reply. The runs share a few
# milliseconds of each frame, so typing never waits for them, and a run waits while its extension
# has more than 256 KiB to read. Files are read through vfs.s, git runs through git.s.
#
#   filesearch_body(ptr, len)          the request's body, for filesearch_start
#   filesearch_start(ext, id, kind, folder, max, flags) -> rax 0 when the run is queued, else the
#     error to answer ("CODE text" cstr)
#   filesearch_cancel(ext, id) -> eax 1 when it ended a run (answered "error ID cancelled")
#   filesearch_ext_gone(ext)           its program is gone: its runs end without an answer
#   filesearch_pending(ext) -> eax 1 while a run of it runs or waits (it is not idle)
#   filesearch_tick(), filesearch_timeout() -> eax ms or -1
#   filesearch_native(folder id or 0, max, flags FSF_*, cb, ctx) -> rax the run's serial, or 0 (phase 4 task 7:
#     rhun's own list of the project's files, filelist.s): no extension; cb(ctx, path, len, is_dir, folder id)
#     gets each path (relative to its folder, "/" separators, a folder's without its "/"), then cb(ctx, 0,
#     1 when it stopped at max else 0, 0, 0) once at the end. It shares the runs' slots and slice.
#     filesearch_native_cancel(serial): the run ends without its callback's end
.include "rhun.inc"

.equ FSR_SLOTS, 20              # 4 run at a time, 16 wait
.equ FSR_RUNNING, 4
.equ FSR_FIND_MAX, 100000
.equ FSR_SEARCH_MAX, 20000
.equ FSR_BATCH_RECS, 2000
.equ FSR_BATCH_BYTES, 262144
.equ FSR_GROUP_BYTES, 196608    # a file's matches past this go out as a group of their own
.equ FSR_PAUSE, 262144          # the extension has more to read: the run waits
.equ FSR_FILE_MAX, 8388608
.equ FSR_BINARY_HEAD, 8192
.equ FSR_PREVIEW, 512
.equ FSR_BEFORE, 128
.equ FSR_LITERAL_MAX, 4096
.equ FSR_PROGRAM_MAX, 262144
.equ FSR_GIT_CAP, 67108864
.equ FSR_SLICE_US, 4000         # all runs together, each frame
.equ FSR_DEPTH, 64
.equ FSR_RX_WORK, 1000000       # regex work for one line
.equ FSK_FIND, 1
.equ FSK_SEARCH, 2
.equ FSF_IGNORED, 1             # ignored files too: a walk without the exclude setting
.equ FSF_HIDDEN, 2              # skip names starting with .
.equ FSF_LINKS, 4               # follow links to folders
.equ FSF_DIRS, 8                # folders too, with a trailing /
.equ FSF_ICASE, 16
.equ FSF_WORD, 32
.equ FSF_REGEX, 64
.equ FSF_WALK, 128              # (phase 4 task 7) no git listing: the walk, with the exclude setting, without .git
.equ FSF_FIND_ALL, 15
.equ FSF_SEARCH_ALL, 0x77
.equ FSS_WAITING, 1
.equ FSS_RUNNING, 2

STRUCT
F FSR_ext, 8
F FSR_id, 8
F FSR_serial, 8
F FSR_state, 4          # 0 free, FSS_*
F FSR_kind, 4
F FSR_flags, 4
F FSR_git, 4            # 1 while git lists the folder
F FSR_gitlist, 4        # 1 when the list came from git (its paths are checked as they are taken)
F FSR_single, 4         # 1: only the folder asked for; 2: it was listed
F FSR_partial, 4
F FSR_limit, 4
F FSR_max, 8
F FSR_folder, 8         # the folder id asked for, 0 for all
F FSR_fidx, 8           # the next folder to list (all folders)
F FSR_fid, 8            # the folder being listed
F FSR_root, 8           # its path (owned)
F FSR_globs, 8          # fglob set or 0
F FSR_pat, 8            # the literal or the RNRX program (owned)
F FSR_plen, 8
F FSR_rx, 8             # regex context
F FSR_job, 8            # git job
F FSR_list, SB_SIZE     # paths to take, each with a NUL (a folder's with its /)
F FSR_lpos, 8
F FSR_walk, VEC_SIZE    # folders still to read: owned relative paths, "" the root
F FSR_chain, 16*(FSR_DEPTH+1)   # with FSF_LINKS: inode and device of the folders on the way
F FSR_dir, 8            # the folder a walk reads (relative, borrowed during vfs_dir_each)
F FSR_count, 8          # paths listed, or matches
F FSR_files, 8
F FSR_skipped, 8
F FSR_nrec, 8           # records in the batch
F FSR_batch, SB_SIZE
F FSR_text, 8           # the file being searched (owned), 0 between files
F FSR_tlen, 8
F FSR_tpos, 8           # where the scan goes on
F FSR_tline, 8          # the line at FSR_lstart
F FSR_lstart, 8
F FSR_lscan, 8          # lines before this are counted
F FSR_lend, 8           # the current line's end (regex)
F FSR_frel, 8           # its relative path (owned)
F FSR_fdoc, 8           # its document and version, 0 0 for text from disk
F FSR_fver, 8
F FSR_fcounted, 8       # it is counted in FSR_files
F FSR_fm, SB_SIZE       # its matches not yet in the batch
F FSR_fmn, 8
F FSR_dnames, SB_SIZE   # FSF_DIRS with a git list: the folders listed, each with a NUL
F FSR_dtab, 8           # their table (open addressing: offset + 1 into FSR_dnames, 0 free)
F FSR_dcap, 8
F FSR_dn, 8
F FSR_cb, 8             # (phase 4 task 7) a native run's callback and its context; FSR_ext is 0
F FSR_ctx, 8
ENDSTRUCT FSR_SIZE

.bss
.p2align 3
fsr_slots: .zero FSR_SIZE * FSR_SLOTS
fsr_serial: .quad 0
fsr_body: .quad 0
fsr_blen: .quad 0
fsr_deadline: .quad 0
fsr_rr: .quad 0
fsr_msg: .zero SB_SIZE
fsr_rel: .zero 4200
fsr_seg: .zero 264

.text

# FN filesearch_body(ptr, len)
FN filesearch_body
    mov [rip + fsr_body], rdi
    mov [rip + fsr_blen], rsi
    ret

# FN filesearch_start(ext, id, kind, folder, max, flags) -> rax 0 or the error
FN filesearch_start
    PROLOGUE 64
    mov [rsp], rdi
    mov [rsp + 8], rsi
    mov r12d, edx
    mov r13, rcx
    mov r14, r8
    mov r15d, r9d
    mov eax, FSF_FIND_ALL
    mov ecx, FSR_FIND_MAX
    cmp r12d, FSK_FIND
    je 1f
    mov eax, FSF_SEARCH_ALL
    mov ecx, FSR_SEARCH_MAX
1:  not eax
    test r15d, eax
    jnz .Lst_syntax
    test r14, r14
    jz .Lst_syntax
    lea rax, [rip + .Le_max_find]
    cmp r12d, FSK_FIND
    je 11f
    lea rax, [rip + .Le_max_search]
11: cmp r14, rcx
    ja .Lst_err
    test r13, r13
    jz 2f
    mov rdi, r13
    call wfold_index
    test rax, rax
    js .Lst_nofile
2:  # one run for each extension, FSR_SLOTS in all
    lea rbx, [rip + fsr_slots]
    xor ecx, ecx
    xor edx, edx                # a free slot
3:  cmp ecx, FSR_SLOTS
    jae 5f
    cmp dword ptr [rbx + FSR_state], 0
    jne 4f
    test rdx, rdx
    jnz 41f
    mov rdx, rbx
    jmp 41f
4:  mov rax, [rsp]
    cmp [rbx + FSR_ext], rax
    je .Lst_busy_ext
41: add rbx, FSR_SIZE
    inc ecx
    jmp 3b
5:  test rdx, rdx
    jz .Lst_busy_all
    mov [rsp + 16], rdx
    # the body: globs, after a search's pattern
    mov rax, [rip + fsr_body]
    mov [rsp + 24], rax         # globs
    mov rax, [rip + fsr_blen]
    mov [rsp + 32], rax
    mov qword ptr [rsp + 40], 0 # pattern
    mov qword ptr [rsp + 48], 0
    cmp r12d, FSK_SEARCH
    jne 6f
    call fsr_parse_search
    test rax, rax
    jnz .Lst_err
6:  xor ebx, ebx                # the glob set
    cmp qword ptr [rsp + 32], 0
    je 7f
    mov rdi, [rsp + 24]
    mov rsi, [rsp + 32]
    call fglob_set
    test rax, rax
    jns 61f
    lea rcx, [rip + .Le_globs]
    cmp rax, -27
    jne 60f
    lea rcx, [rip + .Le_globs_big]
60: mov rax, rcx
    jmp .Lst_err
61: mov rbx, rax
7:  # the run
    mov rdi, [rsp + 16]
    xor eax, eax
    mov ecx, FSR_SIZE
    rep stosb
    mov rdi, [rsp + 16]
    mov rax, [rsp]
    mov [rdi + FSR_ext], rax
    mov rax, [rsp + 8]
    mov [rdi + FSR_id], rax
    inc qword ptr [rip + fsr_serial]
    mov rax, [rip + fsr_serial]
    mov [rdi + FSR_serial], rax
    mov [rdi + FSR_kind], r12d
    mov [rdi + FSR_flags], r15d
    mov [rdi + FSR_max], r14
    mov [rdi + FSR_folder], r13
    mov [rdi + FSR_globs], rbx
    test r13, r13
    jz 8f
    mov dword ptr [rdi + FSR_single], 1
8:  cmp qword ptr [rsp + 48], 0
    je 9f
    mov rdi, [rsp + 40]
    mov rsi, [rsp + 48]
    call mem_dup
    mov rdi, [rsp + 16]
    mov [rdi + FSR_pat], rax
    mov rax, [rsp + 48]
    mov [rdi + FSR_plen], rax
    test r15d, FSF_REGEX
    jz 9f
    mov edi, FSR_RX_WORK
    xor esi, esi
    call snippet_regex_new
    mov rdi, [rsp + 16]
    mov [rdi + FSR_rx], rax
    test rax, rax
    jnz 9f
    call fsr_free
    lea rax, [rip + .Le_memory]
    jmp .Lst_err
9:  mov rdi, [rsp + 16]
    mov dword ptr [rdi + FSR_state], FSS_WAITING
    mov dword ptr [rip + g_dirty], 1
    xor eax, eax
    EPILOGUE
.Lst_syntax:
    lea rax, [rip + .Le_syntax]
    jmp .Lst_err
.Lst_nofile:
    lea rax, [rip + .Le_nofile]
    jmp .Lst_err
.Lst_busy_ext:
    lea rax, [rip + .Le_busy_ext]
    jmp .Lst_err
.Lst_busy_all:
    lea rax, [rip + .Le_busy_all]
.Lst_err:
    EPILOGUE

# fsr_parse_search() with filesearch_start's frame: "PATTERN_LEN GLOBS_LEN" LF, the pattern, the
# globs -> rax 0 with the pattern at [rsp + 40 + 8] and the globs at [rsp + 24 + 8] (this call's
# return address shifts them), or the error
fsr_parse_search:
    mov r8, [rip + fsr_body]
    mov r9, [rip + fsr_blen]
    xor r10d, r10d              # position
    xor eax, eax                # PATTERN_LEN
1:  cmp r10, r9
    jae 8f
    movzx ecx, byte ptr [r8 + r10]
    inc r10
    cmp ecx, ' '
    je 2f
    sub ecx, '0'
    cmp ecx, 9
    ja 8f
    cmp rax, 100000000
    ja 8f
    imul rax, rax, 10
    add rax, rcx
    jmp 1b
2:  mov r11, rax
    xor eax, eax                # GLOBS_LEN
3:  cmp r10, r9
    jae 8f
    movzx ecx, byte ptr [r8 + r10]
    inc r10
    cmp ecx, 10
    je 4f
    sub ecx, '0'
    cmp ecx, 9
    ja 8f
    cmp rax, 100000000
    ja 8f
    imul rax, rax, 10
    add rax, rcx
    jmp 3b
4:  # the pattern and the globs fill the rest exactly
    test r11, r11
    jz 8f
    mov rcx, r9
    sub rcx, r10
    mov rdx, r11
    add rdx, rax
    cmp rdx, rcx
    jne 8f
    lea rdx, [r8 + r10]
    mov [rsp + 48], rdx         # the pattern
    mov [rsp + 56], r11
    add rdx, r11
    mov [rsp + 32], rdx         # the globs
    mov [rsp + 40], rax
    test r15d, FSF_REGEX
    jnz 6f
    cmp r11, FSR_LITERAL_MAX
    ja 7f
    mov rdi, [rsp + 48]
    xor ecx, ecx
5:  cmp rcx, r11
    jae 9f
    cmp byte ptr [rdi + rcx], 10
    je 8f
    inc rcx
    jmp 5b
6:  cmp r11, FSR_PROGRAM_MAX
    ja 71f
    push r11
    mov rdi, [rsp + 56]
    mov rsi, r11
    call snippet_regex_validate
    pop r11
    test eax, eax
    jz 81f
9:  xor eax, eax
    ret
7:  lea rax, [rip + .Le_literal_big]
    ret
71: lea rax, [rip + .Le_program_big]
    ret
81: lea rax, [rip + .Le_program]
    ret
8:  lea rax, [rip + .Le_syntax]
    ret

# fsr_free(run): everything it holds goes, the slot is free
fsr_free:
    PROLOGUE
    mov rbx, rdi
    mov rdi, [rbx + FSR_job]
    test rdi, rdi
    jz 1f
    call git_job_kill           # its answer finds the slot changed and is dropped
1:  mov rdi, [rbx + FSR_root]
    call mem_free
    mov rdi, [rbx + FSR_globs]
    call mem_free
    mov rdi, [rbx + FSR_pat]
    call mem_free
    mov rdi, [rbx + FSR_rx]
    test rdi, rdi
    jz 2f
    call snippet_regex_free
2:  lea rdi, [rbx + FSR_list]
    call sb_free
    lea rdi, [rbx + FSR_batch]
    call sb_free
    lea rdi, [rbx + FSR_fm]
    call sb_free
    lea rdi, [rbx + FSR_dnames]
    call sb_free
    mov rdi, [rbx + FSR_dtab]
    call mem_free
    mov rdi, [rbx + FSR_text]
    call mem_free
    mov rdi, [rbx + FSR_frel]
    call mem_free
    call fsr_walk_clear
    mov rax, [rbx + FSR_serial]
    mov rdi, rbx
    mov r12, rax
    xor eax, eax
    mov ecx, FSR_SIZE
    rep stosb
    mov [rbx + FSR_serial], r12 # a late git answer still finds an older serial
    EPILOGUE

# fsr_walk_clear() with rbx the run: the folders still to read go
fsr_walk_clear:
    push r12
1:  mov rax, [rbx + FSR_walk + VEC_len]
    test rax, rax
    jz 2f
    dec rax
    mov [rbx + FSR_walk + VEC_len], rax
    mov rcx, [rbx + FSR_walk + VEC_ptr]
    mov rdi, [rcx + rax*8]
    call mem_free
    jmp 1b
2:  lea rdi, [rbx + FSR_walk]
    call vec_free
    pop r12
    ret

# FN filesearch_cancel(ext, id) -> eax 1 when a run of the extension had that id
FN filesearch_cancel
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    lea rbx, [rip + fsr_slots]
    xor r14d, r14d
1:  cmp r14d, FSR_SLOTS
    jae 8f
    cmp dword ptr [rbx + FSR_state], 0
    je 2f
    cmp [rbx + FSR_ext], r12
    jne 2f
    cmp [rbx + FSR_id], r13
    jne 2f
    lea rdi, [rip + fsr_msg]
    call sb_clear
    lea rdi, [rip + fsr_msg]
    lea rsi, [rip + .Lw_error]
    call sb_push_cstr
    lea rdi, [rip + fsr_msg]
    mov rsi, r13
    call sb_push_u64
    lea rdi, [rip + fsr_msg]
    lea rsi, [rip + .Lw_cancelled]
    call sb_push_cstr
    call fsr_send_msg
    mov rdi, rbx
    call fsr_free
    mov eax, 1
    EPILOGUE
2:  add rbx, FSR_SIZE
    inc r14d
    jmp 1b
8:  xor eax, eax
    EPILOGUE

# fsr_send_msg() with rbx the run: fsr_msg to its extension
fsr_send_msg:
    mov rdi, [rbx + FSR_ext]
    mov rsi, [rip + fsr_msg + SB_ptr]
    mov rdx, [rip + fsr_msg + SB_len]
    jmp ext_send_checked

# FN filesearch_ext_gone(ext)
FN filesearch_ext_gone
    PROLOGUE
    mov r12, rdi
    lea rbx, [rip + fsr_slots]
    xor r13d, r13d
1:  cmp r13d, FSR_SLOTS
    jae 9f
    cmp dword ptr [rbx + FSR_state], 0
    je 2f
    cmp [rbx + FSR_ext], r12
    jne 2f
    mov rdi, rbx
    call fsr_free
2:  add rbx, FSR_SIZE
    inc r13d
    jmp 1b
9:  EPILOGUE

# FN filesearch_timeout() -> eax 0 while a run can work, 10 while runs wait for their extension to
# read, -1 when none runs (or git is still listing)
FN filesearch_timeout
    push rbx
    push r12
    mov r12d, -1
    lea rbx, [rip + fsr_slots]
    xor ecx, ecx
1:  cmp ecx, FSR_SLOTS
    jae 9f
    cmp dword ptr [rbx + FSR_state], FSS_WAITING
    je 8f
    cmp dword ptr [rbx + FSR_state], FSS_RUNNING
    jne 2f
    cmp dword ptr [rbx + FSR_git], 0
    jne 2f
    mov rax, [rbx + FSR_ext]
    test rax, rax               # a native run (filesearch_native) has nobody to wait for
    jz 8f
    mov rdx, [rax + EXT_wq + SB_len]
    sub rdx, [rax + EXT_wq_off]
    cmp rdx, FSR_PAUSE
    jbe 8f
    mov r12d, 10
2:  add rbx, FSR_SIZE
    inc ecx
    jmp 1b
8:  xor r12d, r12d
9:  mov eax, r12d
    pop r12
    pop rbx
    ret

# FN filesearch_tick(): waiting runs start (FSR_RUNNING at a time); the running ones work for
# FSR_SLICE_US in all
FN filesearch_tick
    PROLOGUE
    lea rbx, [rip + fsr_slots]
    xor r12d, r12d              # running
    xor ecx, ecx
1:  cmp ecx, FSR_SLOTS
    jae 2f
    cmp dword ptr [rbx + FSR_state], FSS_RUNNING
    jne 11f
    inc r12d
11: add rbx, FSR_SIZE
    inc ecx
    jmp 1b
2:  lea rbx, [rip + fsr_slots]
    xor ecx, ecx
3:  cmp ecx, FSR_SLOTS
    jae 4f
    cmp r12d, FSR_RUNNING
    jae 4f
    cmp dword ptr [rbx + FSR_state], FSS_WAITING
    jne 31f
    mov dword ptr [rbx + FSR_state], FSS_RUNNING
    inc r12d
31: add rbx, FSR_SIZE
    inc ecx
    jmp 3b
4:  test r12d, r12d
    jz 9f
    call time_us
    add rax, FSR_SLICE_US
    mov [rip + fsr_deadline], rax
    # each running run in turn, starting with a different one each frame
    inc qword ptr [rip + fsr_rr]
    xor r13d, r13d
5:  cmp r13d, FSR_SLOTS
    jae 9f
    mov rax, [rip + fsr_rr]
    add rax, r13
    xor edx, edx
    mov ecx, FSR_SLOTS
    div rcx
    imul rbx, rdx, FSR_SIZE
    lea rax, [rip + fsr_slots]
    add rbx, rax
    cmp dword ptr [rbx + FSR_state], FSS_RUNNING
    jne 6f
    mov rdi, rbx
    call fsr_work
6:  inc r13d
    jmp 5b
9:  EPILOGUE

# fsr_work(run): steps until the slice is over, the run waits (git, its extension) or ends
fsr_work:
    PROLOGUE
    mov rbx, rdi
.Lwk_loop:
    call time_us
    cmp rax, [rip + fsr_deadline]
    jae .Lwk_out
    cmp dword ptr [rbx + FSR_state], FSS_RUNNING
    jne .Lwk_out
    mov rax, [rbx + FSR_ext]
    test rax, rax               # a native run: no extension to wait for
    jz 0f
    mov rdx, [rax + EXT_wq + SB_len]
    sub rdx, [rax + EXT_wq_off]
    cmp rdx, FSR_PAUSE
    ja .Lwk_out
0:
    # a file being searched
    cmp qword ptr [rbx + FSR_text], 0
    je 1f
    call fsr_scan
    test eax, eax
    jz .Lwk_out                 # the slice ended in it
    cmp eax, 2
    je .Lwk_out                 # the run ended
    call fsr_file_end
    jmp .Lwk_loop
1:  # paths to take
    mov rax, [rbx + FSR_lpos]
    cmp rax, [rbx + FSR_list + SB_len]
    jae 2f
    call fsr_entry
    cmp eax, 2
    je .Lwk_out
    jmp .Lwk_loop
2:  mov qword ptr [rbx + FSR_lpos], 0
    lea rdi, [rbx + FSR_list]
    call sb_clear
    cmp dword ptr [rbx + FSR_git], 0
    jne .Lwk_out                # git is listing the folder
    # a folder to read
    cmp qword ptr [rbx + FSR_walk + VEC_len], 0
    je 3f
    call fsr_walk_one
    jmp .Lwk_loop
3:  call fsr_next_folder
    test eax, eax
    jz .Lwk_loop
    cmp eax, 1
    je .Lwk_out
    call fsr_finish
.Lwk_out:
    EPILOGUE

# fsr_next_folder() with rbx the run -> eax 0 when a walk starts, 1 when git lists the folder, 2
# when no folder is left
fsr_next_folder:
    PROLOGUE
    cmp dword ptr [rbx + FSR_single], 0
    je 1f
    cmp dword ptr [rbx + FSR_single], 2
    je 8f
    mov dword ptr [rbx + FSR_single], 2
    mov rdi, [rbx + FSR_folder]
    call wfold_index
    test rax, rax
    js 8f                       # the folder went
    mov r12, rax
    jmp 2f
1:  call wfold_count
    mov r12, [rbx + FSR_fidx]
    cmp r12, rax
    jae 8f
    inc qword ptr [rbx + FSR_fidx]
2:  mov rdi, r12
    call wfold_id
    mov [rbx + FSR_fid], rax
    mov rdi, [rbx + FSR_root]
    call mem_free
    mov rdi, r12
    call wfold_path
    mov rdi, rax
    call strlen
    mov rsi, rax
    mov rdi, r12
    call wfold_path
    mov rdi, rax
    call mem_dup
    mov [rbx + FSR_root], rax
    mov dword ptr [rbx + FSR_gitlist], 0
    test dword ptr [rbx + FSR_flags], FSF_IGNORED | FSF_WALK
    jnz 4f
    call fsr_git_list
    test eax, eax
    jz 4f
    mov eax, 1
    EPILOGUE
4:  # a walk from the root
    lea rdi, [rip + .Lempty]
    xor esi, esi
    call mem_dup
    mov r12, rax
    lea rdi, [rbx + FSR_walk]
    mov esi, 8
    call vec_push
    mov [rax], r12
    xor eax, eax
    EPILOGUE
8:  mov eax, 2
    EPILOGUE

# fsr_git_list() with rbx the run -> eax 1 when git ls-files was started for the folder: git is on
# for the primary folder's repository and not paused
fsr_git_list:
    PROLOGUE 80
    cmp dword ptr [rip + g_git_on], 0
    je 8f
    cmp dword ptr [rip + g_git_paused], 0
    jne 8f
    lea rax, [rip + .Lg_dash_C]  # git -C FOLDER: another folder's repository too (a folder in none:
                                # git fails, and a walk lists it)
    mov [rsp], rax
    mov rax, [rbx + FSR_root]
    mov [rsp + 8], rax
    lea rax, [rip + .Lg_ls_files]
    mov [rsp + 16], rax
    lea rax, [rip + .Lg_z]
    mov [rsp + 24], rax
    lea rax, [rip + .Lg_cached]
    mov [rsp + 32], rax
    lea rax, [rip + .Lg_others]
    mov [rsp + 40], rax
    lea rax, [rip + .Lg_exclude]
    mov [rsp + 48], rax
    mov qword ptr [rsp + 56], 0
    mov edi, 16
    call mem_alloc
    mov [rax], rbx
    mov rcx, [rbx + FSR_serial]
    mov [rax + 8], rcx
    mov rdi, rsp
    lea rsi, [rip + fsr_git_done]
    mov rdx, rax
    xor ecx, ecx
    xor r8d, r8d
    mov r9d, FSR_GIT_CAP
    call git_start
    test rax, rax
    jz 8f
    mov [rbx + FSR_job], rax
    mov dword ptr [rbx + FSR_git], 1
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# fsr_git_done(ctx, output, len, status): git's list of the folder (NUL after each path); a git
# that failed leaves the folder to a walk
fsr_git_done:
    PROLOGUE
    mov rbx, [rdi]
    mov rax, [rdi + 8]
    cmp [rbx + FSR_serial], rax
    jne 9f
    cmp dword ptr [rbx + FSR_state], FSS_RUNNING
    jne 9f
    cmp dword ptr [rbx + FSR_git], 0
    je 9f
    mov dword ptr [rbx + FSR_git], 0
    mov qword ptr [rbx + FSR_job], 0
    mov r12, rsi
    mov r13, rdx
    test ecx, ecx
    jnz 5f
    lea rdi, [rbx + FSR_list]
    call sb_clear
    mov qword ptr [rbx + FSR_lpos], 0
    lea rdi, [rbx + FSR_list]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    test r13, r13
    jz 1f
    cmp byte ptr [r12 + r13 - 1], 0
    je 1f
    lea rdi, [rbx + FSR_list]
    xor esi, esi
    call sb_push_byte
1:  mov dword ptr [rbx + FSR_gitlist], 1
    jmp 8f
5:  # a walk instead
    lea rdi, [rip + .Lempty]
    xor esi, esi
    call mem_dup
    mov r12, rax
    lea rdi, [rbx + FSR_walk]
    mov esi, 8
    call vec_push
    mov [rax], r12
8:  mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# fsr_depth(rel) -> rax the folders above a relative path ("" 0, "a" 1, "a/b" 2)
fsr_depth:
    xor eax, eax
    cmp byte ptr [rdi], 0
    je 9f
    inc eax
1:  movzx ecx, byte ptr [rdi]
    test ecx, ecx
    jz 9f
    inc rdi
    cmp ecx, '/'
    jne 1b
    inc eax
    jmp 1b
9:  ret

# fsr_cycle(path, depth) with rbx the run -> eax 1 when the folder a link leads to is one of the
# folders on the way to it (FSR_chain up to depth): reading it would never end
fsr_cycle:
    PROLOGUE
    mov r12, rsi
    call vfs_id
    lea rcx, [rbx + FSR_chain]
    xor r8d, r8d
1:  cmp r8, r12
    ja 8f
    mov r9, r8
    shl r9, 4
    cmp [rcx + r9], rax
    jne 2f
    cmp [rcx + r9 + 8], rdx
    je 9f
2:  inc r8
    jmp 1b
8:  xor eax, eax
    EPILOGUE
9:  mov eax, 1
    EPILOGUE

# fsr_walk_one() with rbx the run: the last folder found is read; its folders join the walk, its
# files (and with FSF_DIRS its folders) the list
fsr_walk_one:
    PROLOGUE
    mov rax, [rbx + FSR_walk + VEC_len]
    dec rax
    mov [rbx + FSR_walk + VEC_len], rax
    mov rcx, [rbx + FSR_walk + VEC_ptr]
    mov r12, [rcx + rax*8]      # the folder (relative)
    mov [rbx + FSR_dir], r12
    mov rdi, [rbx + FSR_root]
    cmp byte ptr [r12], 0
    jne 1f
    call strlen
    mov rsi, rax
    mov rdi, [rbx + FSR_root]
    call mem_dup
    jmp 2f
1:  mov rsi, r12
    call path_join
2:  mov r13, rax
    test dword ptr [rbx + FSR_flags], FSF_LINKS
    jz 21f
    mov rdi, r12                # the folder's place on the way
    call fsr_depth
    cmp rax, FSR_DEPTH
    ja 21f
    mov r14, rax
    mov rdi, r13
    call vfs_id
    shl r14, 4
    mov [rbx + FSR_chain + r14], rax
    mov [rbx + FSR_chain + r14 + 8], rdx
21: mov rdi, r13
    lea rsi, [rip + fsr_dir_cb]
    mov rdx, rbx
    call vfs_dir_each
    test rax, rax
    jns 3f
    mov dword ptr [rbx + FSR_partial], 1
3:  mov rdi, r13
    call mem_free
    mov rdi, r12
    call mem_free
    mov qword ptr [rbx + FSR_dir], 0
    EPILOGUE

# fsr_dir_cb(run, name, is_dir): one entry of the folder a walk reads
fsr_dir_cb:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov rdi, r12
    lea rsi, [rip + .Ldot_git]
    call strcmp_eq
    test eax, eax
    jnz 9f
    test dword ptr [rbx + FSR_flags], FSF_HIDDEN
    jz 1f
    cmp byte ptr [r12], '.'
    je 9f
1:  test dword ptr [rbx + FSR_flags], FSF_IGNORED
    jnz 2f
    mov rdi, r12
    call explorer_excluded
    test eax, eax
    jnz 9f
2:  # its relative path in fsr_rel
    mov rdi, [rbx + FSR_dir]
    call strlen
    mov r14, rax
    mov rdi, r12
    call strlen
    lea rcx, [r14 + rax + 2]
    cmp rcx, 4096
    ja 9f
    lea rdi, [rip + fsr_rel]
    mov rsi, [rbx + FSR_dir]
    mov rcx, r14
    rep movsb
    test r14, r14
    jz 3f
    mov byte ptr [rdi], '/'
    inc rdi
3:  mov rsi, r12
    call cstr_copy
    lea rcx, [rip + fsr_rel]
    sub rax, rcx
    mov r14, rax                # its length
    test r13d, r13d
    jz .Ldc_file
    # a folder: not through a link unless asked, not twice, not too deep, not excluded
    lea rdi, [rip + fsr_rel]
    xor ecx, ecx
    xor edx, edx
4:  cmp rcx, r14
    jae 5f
    cmp byte ptr [rdi + rcx], '/'
    jne 41f
    inc edx
41: inc rcx
    jmp 4b
5:  cmp edx, FSR_DEPTH
    jae 9f
    mov rdi, [rbx + FSR_root]
    lea rsi, [rip + fsr_rel]
    call path_join
    mov r15, rax
    mov rdi, r15
    call vfs_lstat
    test rax, rax
    js 7f
    mov eax, [rip + vfs_statbuf + 24]
    and eax, 0xf000
    cmp eax, 0xa000             # S_IFLNK
    jne 7f
    test dword ptr [rbx + FSR_flags], FSF_LINKS
    jz 6f
    mov rdi, [rbx + FSR_dir]
    call fsr_depth
    mov rdi, r15
    mov rsi, rax
    call fsr_cycle
    test eax, eax
    jz 7f
6:  mov rdi, r15
    call mem_free
    jmp 9f
7:  mov rdi, r15
    call mem_free
    mov rdi, [rbx + FSR_globs]
    lea rsi, [rip + fsr_rel]
    mov rdx, r14
    call fglob_pruned
    test eax, eax
    jnz 9f
    lea rdi, [rip + fsr_rel]
    mov rsi, r14
    call mem_dup
    mov r15, rax
    lea rdi, [rbx + FSR_walk]
    mov esi, 8
    call vec_push
    mov [rax], r15
    test dword ptr [rbx + FSR_flags], FSF_DIRS
    jz 9f
    lea rdi, [rbx + FSR_list]
    lea rsi, [rip + fsr_rel]
    mov rdx, r14
    call sb_push
    lea rdi, [rbx + FSR_list]
    mov esi, '/'
    call sb_push_byte
    jmp 8f
.Ldc_file:
    lea rdi, [rbx + FSR_list]
    lea rsi, [rip + fsr_rel]
    mov rdx, r14
    call sb_push
8:  lea rdi, [rbx + FSR_list]
    xor esi, esi
    call sb_push_byte
9:  xor eax, eax
    EPILOGUE

# fsr_entry() with rbx the run -> eax 2 when the run ended: the next path of the list is listed,
# or its file opened for the search
fsr_entry:
    PROLOGUE
    mov r12, [rbx + FSR_list + SB_ptr]
    add r12, [rbx + FSR_lpos]
    mov rdi, r12
    call strlen
    mov r13, rax
    lea rcx, [rax + 1]
    add [rbx + FSR_lpos], rcx
    test r13, r13
    jz 8f
    xor r14d, r14d              # 1 for a folder
    mov r15, r13                # the length without its /
    cmp byte ptr [r12 + r13 - 1], '/'
    jne 1f
    mov r14d, 1
    dec r15
    jz 8f
1:  cmp dword ptr [rbx + FSR_gitlist], 0
    je 2f
    mov rdi, r12
    mov rsi, r15
    call fsr_segments_ok
    test eax, eax
    jz 8f
2:  mov rdi, [rbx + FSR_globs]
    mov rsi, r12
    mov rdx, r15
    call fglob_listed
    test eax, eax
    jz 8f
    cmp dword ptr [rbx + FSR_kind], FSK_SEARCH
    je 5f
    # find-files: git's paths must be files that are there (not gitlinks, not deleted ones)
    cmp dword ptr [rbx + FSR_gitlist], 0
    je 3f
    mov rdi, [rbx + FSR_root]
    mov rsi, r12
    call path_join
    push rax
    push rax
    mov rdi, rax
    call vfs_stat
    pop rdi
    pop rdi
    push rax
    push rax
    call mem_free
    pop rax
    pop rax
    test rax, rax
    js 8f
    mov eax, [rip + vfs_statbuf + 24]
    and eax, 0xf000
    cmp eax, 0x4000             # S_IFDIR
    je 8f
    test dword ptr [rbx + FSR_flags], FSF_DIRS
    jz 3f
    mov rdi, r12
    mov rsi, r15
    call fsr_git_dirs
    test eax, eax
    jnz .Len_ended
3:  # FOLDER PATH_LEN LF PATH
    mov rdi, r12
    mov rsi, r13
    call fsr_record
    test eax, eax
    jz 8f
.Len_ended:
    mov eax, 2
    EPILOGUE
5:  test r14d, r14d
    jnz 8f
    mov rdi, r12
    mov rsi, r15
    call fsr_open
8:  xor eax, eax
    EPILOGUE

# fsr_record(path, len) with rbx the run -> eax 1 when the run ended (MAX): FOLDER PATH_LEN LF
# PATH into the batch
fsr_record:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    cmp qword ptr [rbx + FSR_cb], 0
    jne .Lrc_native
    lea rdi, [r13 + 32]
    call fsr_room
    lea rdi, [rbx + FSR_batch]
    mov rsi, [rbx + FSR_fid]
    call sb_push_u64
    lea rdi, [rbx + FSR_batch]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rbx + FSR_batch]
    mov rsi, r13
    call sb_push_u64
    lea rdi, [rbx + FSR_batch]
    mov esi, 10
    call sb_push_byte
    lea rdi, [rbx + FSR_batch]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    inc qword ptr [rbx + FSR_nrec]
    inc qword ptr [rbx + FSR_count]
    mov rax, [rbx + FSR_count]
    cmp rax, [rbx + FSR_max]
    jb 8f
    mov dword ptr [rbx + FSR_limit], 1
    call fsr_finish
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE
.Lrc_native:                    # (phase 4 task 7) to the callback: the path, a folder's without its "/"
    xor ecx, ecx
    test r13, r13
    jz 1f
    cmp byte ptr [r12 + r13 - 1], '/'
    jne 1f
    dec r13
    mov ecx, 1
1:  mov rdi, [rbx + FSR_ctx]
    mov rsi, r12
    mov rdx, r13
    mov r8, [rbx + FSR_fid]
    call [rbx + FSR_cb]
    inc qword ptr [rbx + FSR_count]
    mov rax, [rbx + FSR_count]
    cmp rax, [rbx + FSR_max]
    jb 8b
    mov dword ptr [rbx + FSR_limit], 1
    call fsr_finish
    mov eax, 1
    EPILOGUE

# fsr_git_dirs(path, len) with rbx the run -> eax 1 when the run ended: the folders on the way to a
# path git listed, each the first time (git lists files only)
fsr_git_dirs:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    xor r14d, r14d
1:  cmp r14, r13
    jae 8f
    cmp byte ptr [r12 + r14], '/'
    jne 2f
    mov rdi, r12
    mov rsi, r14
    call fsr_dir_new
    test eax, eax
    jz 2f
    mov rdi, [rbx + FSR_globs]
    mov rsi, r12
    mov rdx, r14
    call fglob_listed
    test eax, eax
    jz 2f
    mov rdi, r12
    lea rsi, [r14 + 1]          # with its /
    call fsr_record
    test eax, eax
    jnz 9f
2:  inc r14
    jmp 1b
8:  xor eax, eax
9:  EPILOGUE

# fsr_dir_new(path, len) with rbx the run -> eax 1 when the folder was not listed before (it is
# now)
fsr_dir_new:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov rax, [rbx + FSR_dn]
    add rax, rax
    cmp rax, [rbx + FSR_dcap]
    jb 1f
    call fsr_dir_grow
1:  mov rdi, r12
    mov rsi, r13
    call fsr_hash
    mov r14, [rbx + FSR_dcap]
    dec r14                     # the mask
    and rax, r14
    mov r15, rax
2:  mov rcx, [rbx + FSR_dtab]
    mov rax, [rcx + r15*8]
    test rax, rax
    jz 5f
    # the same path?
    mov rdi, [rbx + FSR_dnames + SB_ptr]
    lea rdi, [rdi + rax - 1]
    xor ecx, ecx
3:  cmp rcx, r13
    jae 4f
    movzx edx, byte ptr [rdi + rcx]
    cmp dl, [r12 + rcx]
    jne 41f
    inc rcx
    jmp 3b
4:  cmp byte ptr [rdi + rcx], 0
    jne 41f
    xor eax, eax
    EPILOGUE
41: inc r15
    and r15, r14
    jmp 2b
5:  mov rax, [rbx + FSR_dnames + SB_len]
    inc rax
    mov rcx, [rbx + FSR_dtab]
    mov [rcx + r15*8], rax
    inc qword ptr [rbx + FSR_dn]
    lea rdi, [rbx + FSR_dnames]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    lea rdi, [rbx + FSR_dnames]
    xor esi, esi
    call sb_push_byte
    mov eax, 1
    EPILOGUE

# fsr_dir_grow() with rbx the run: the table doubles (1024 slots at first), its entries placed again
fsr_dir_grow:
    PROLOGUE
    mov r12, [rbx + FSR_dtab]
    mov r13, [rbx + FSR_dcap]
    lea r14, [r13 + r13]
    cmp r14, 1024
    jae 1f
    mov r14d, 1024
1:  mov rdi, r14
    shl rdi, 3
    call mem_alloc
    mov [rbx + FSR_dtab], rax
    mov rdi, rax
    xor eax, eax
    mov rcx, r14
    shl rcx, 3
    rep stosb
    mov [rbx + FSR_dcap], r14
    xor r15d, r15d
2:  cmp r15, r13
    jae 5f
    mov rax, [r12 + r15*8]
    test rax, rax
    jz 4f
    push rax
    push rax
    mov rdi, [rbx + FSR_dnames + SB_ptr]
    lea rdi, [rdi + rax - 1]
    push rdi
    push rdi
    call strlen
    pop rdi
    pop rdi
    mov rsi, rax
    call fsr_hash
    pop rdx
    pop rdx
    mov rcx, [rbx + FSR_dcap]
    dec rcx
    and rax, rcx
    mov rdi, [rbx + FSR_dtab]
3:  cmp qword ptr [rdi + rax*8], 0
    je 31f
    inc rax
    and rax, rcx
    jmp 3b
31: mov [rdi + rax*8], rdx
4:  inc r15
    jmp 2b
5:  mov rdi, r12
    call mem_free
    EPILOGUE

# fsr_hash(ptr, len) -> rax FNV-1a of the bytes
fsr_hash:
    mov rax, 0xcbf29ce484222325
    mov r8, 0x100000001b3
    xor ecx, ecx
1:  cmp rcx, rsi
    jae 2f
    movzx edx, byte ptr [rdi + rcx]
    xor rax, rdx
    imul rax, r8
    inc rcx
    jmp 1b
2:  ret

# fsr_segments_ok(path, len) with rbx the run -> eax 1 when no segment of a path git listed is
# hidden (FSF_HIDDEN) or a name of the exclude setting (unless FSF_IGNORED)
fsr_segments_ok:
    PROLOGUE
    mov r12, rdi
    lea r13, [rdi + rsi]
1:  cmp r12, r13
    jae 7f
    mov r14, r12                # the segment's end
2:  cmp r14, r13
    jae 3f
    cmp byte ptr [r14], '/'
    je 3f
    inc r14
    jmp 2b
3:  test dword ptr [rbx + FSR_flags], FSF_HIDDEN
    jz 4f
    cmp byte ptr [r12], '.'
    je 8f
4:  test dword ptr [rbx + FSR_flags], FSF_IGNORED
    jnz 5f
    mov rcx, r14
    sub rcx, r12
    cmp rcx, 255
    ja 5f
    lea rdi, [rip + fsr_seg]
    mov rsi, r12
    rep movsb
    mov byte ptr [rdi], 0
    lea rdi, [rip + fsr_seg]
    call explorer_excluded
    test eax, eax
    jnz 8f
5:  lea r12, [r14 + 1]
    jmp 1b
7:  mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# fsr_room(bytes) with rbx the run: the batch goes first when this record would not fit
fsr_room:
    mov rax, [rbx + FSR_nrec]
    test rax, rax
    jz 9f
    cmp rax, FSR_BATCH_RECS
    jae fsr_flush
    add rdi, [rbx + FSR_batch + SB_len]
    cmp rdi, FSR_BATCH_BYTES
    ja fsr_flush
9:  ret

# fsr_flush() with rbx the run: "0 found ID LEN" and the batch: N LF and its records
fsr_flush:
    PROLOGUE
    mov rax, [rbx + FSR_nrec]
    test rax, rax
    jz 9f
    mov rdi, rax
    call fsr_digits
    lea r12, [rax + 1]
    add r12, [rbx + FSR_batch + SB_len]
    lea rdi, [rip + fsr_msg]
    call sb_clear
    lea rdi, [rip + fsr_msg]
    lea rsi, [rip + .Lw_found]
    call sb_push_cstr
    lea rdi, [rip + fsr_msg]
    mov rsi, [rbx + FSR_id]
    call sb_push_u64
    lea rdi, [rip + fsr_msg]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + fsr_msg]
    mov rsi, r12
    call sb_push_u64
    lea rdi, [rip + fsr_msg]
    mov esi, 10
    call sb_push_byte
    lea rdi, [rip + fsr_msg]
    mov rsi, [rbx + FSR_nrec]
    call sb_push_u64
    lea rdi, [rip + fsr_msg]
    mov esi, 10
    call sb_push_byte
    lea rdi, [rip + fsr_msg]
    mov rsi, [rbx + FSR_batch + SB_ptr]
    mov rdx, [rbx + FSR_batch + SB_len]
    call sb_push
    call fsr_send_msg
    lea rdi, [rbx + FSR_batch]
    call sb_clear
    mov qword ptr [rbx + FSR_nrec], 0
9:  EPILOGUE

# fsr_digits(n) -> rax the digits of n in decimal
fsr_digits:
    mov rax, rdi
    mov ecx, 1
    mov r8d, 10
1:  cmp rax, 10
    jb 2f
    xor edx, edx
    div r8
    inc ecx
    jmp 1b
2:  mov eax, ecx
    ret

# fsr_finish() with rbx the run: the last batch, the answer, the slot free
fsr_finish:
    PROLOGUE
    cmp qword ptr [rbx + FSR_cb], 0     # (phase 4 task 7) a native run: its callback's end
    je 0f
    mov rdi, [rbx + FSR_ctx]
    xor esi, esi
    mov edx, [rbx + FSR_limit]
    xor ecx, ecx
    xor r8d, r8d
    call [rbx + FSR_cb]
    mov rdi, rbx
    call fsr_free
    EPILOGUE
0:  cmp qword ptr [rbx + FSR_text], 0
    je 1f
    call fsr_file_end
1:  call fsr_flush
    lea rdi, [rip + fsr_msg]
    call sb_clear
    lea rdi, [rip + fsr_msg]
    lea rsi, [rip + .Lw_ok]
    call sb_push_cstr
    lea rdi, [rip + fsr_msg]
    mov rsi, [rbx + FSR_id]
    call sb_push_u64
    lea rdi, [rip + fsr_msg]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + fsr_msg]
    mov rsi, [rbx + FSR_count]
    call sb_push_u64
    cmp dword ptr [rbx + FSR_kind], FSK_SEARCH
    jne 2f
    lea rdi, [rip + fsr_msg]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + fsr_msg]
    mov rsi, [rbx + FSR_files]
    call sb_push_u64
    lea rdi, [rip + fsr_msg]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + fsr_msg]
    mov rsi, [rbx + FSR_skipped]
    call sb_push_u64
2:  lea rsi, [rip + .Lw_complete]
    cmp dword ptr [rbx + FSR_partial], 0
    je 3f
    lea rsi, [rip + .Lw_partial]
3:  cmp dword ptr [rbx + FSR_limit], 0
    je 4f
    lea rsi, [rip + .Lw_limit]
4:  lea rdi, [rip + fsr_msg]
    call sb_push_cstr
    call fsr_send_msg
    mov rdi, rbx
    call fsr_free
    EPILOGUE

# ---------------- searching a file ----------------

# fsr_open(rel, len) with rbx the run: the file's text (an open document's, else the file's)
# becomes the one searched; too big or binary files are counted as skipped
fsr_open:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov rdi, [rbx + FSR_root]
    mov rsi, r12
    call path_join
    mov r14, rax
    mov rdi, rax
    call app_find_tab
    test rax, rax
    js 3f
    mov rdi, rax
    call tab_at
    mov r15, [rax + TAB_doc]
    test r15, r15
    jz 3f
    cmp qword ptr [r15 + DOC_uri], 0
    jne 3f
    mov rdi, r15
    call doc_len
    cmp rax, FSR_FILE_MAX
    ja .Lop_skip
    mov [rbx + FSR_tlen], rax
    lea rdi, [rax + 1]
    call mem_alloc
    mov [rbx + FSR_text], rax
    mov rcx, rax
    mov rdi, r15
    xor esi, esi
    mov rdx, [rbx + FSR_tlen]
    call doc_copy
    mov rax, [rbx + FSR_text]
    add rax, [rbx + FSR_tlen]
    mov byte ptr [rax], 0
    mov rax, [r15 + DOC_id]
    mov [rbx + FSR_fdoc], rax
    mov rax, [r15 + DOC_version]
    mov [rbx + FSR_fver], rax
    jmp 6f
3:  mov rdi, r14
    call vfs_stat
    test rax, rax
    js .Lop_done
    mov eax, [rip + vfs_statbuf + 24]
    and eax, 0xf000
    cmp eax, 0x8000             # S_IFREG
    jne .Lop_done
    cmp qword ptr [rip + vfs_statbuf + 48], FSR_FILE_MAX
    ja .Lop_skip
    mov rdi, r14
    mov esi, FSR_FILE_MAX
    call vfs_read_limited
    test rax, rax
    jz 4f
    mov [rbx + FSR_text], rax
    mov [rbx + FSR_tlen], rdx
    mov qword ptr [rbx + FSR_fdoc], 0
    mov qword ptr [rbx + FSR_fver], 0
    # binary: a NUL in its first 8 KiB
    mov rcx, rdx
    cmp rcx, FSR_BINARY_HEAD
    jbe 5f
    mov ecx, FSR_BINARY_HEAD
5:  xor edx, edx
51: cmp rdx, rcx
    jae 6f
    cmp byte ptr [rax + rdx], 0
    je 52f
    inc rdx
    jmp 51b
52: mov rdi, rax
    call mem_free
    mov qword ptr [rbx + FSR_text], 0
    jmp .Lop_skip
4:  cmp rdx, -27                # EFBIG: it grew past the limit
    je .Lop_skip
    mov dword ptr [rbx + FSR_partial], 1
    jmp .Lop_done
6:  mov qword ptr [rbx + FSR_tpos], 0
    mov qword ptr [rbx + FSR_tline], 1
    mov qword ptr [rbx + FSR_lstart], 0
    mov qword ptr [rbx + FSR_lscan], 0
    mov qword ptr [rbx + FSR_fcounted], 0
    mov qword ptr [rbx + FSR_fmn], 0
    lea rdi, [rbx + FSR_fm]
    call sb_clear
    mov rdi, r12
    mov rsi, r13
    call mem_dup
    mov [rbx + FSR_frel], rax
    jmp .Lop_done
.Lop_skip:
    inc qword ptr [rbx + FSR_skipped]
.Lop_done:
    mov rdi, r14
    call mem_free
    EPILOGUE

# fsr_file_end() with rbx the run: its matches go to the batch, its text goes
fsr_file_end:
    PROLOGUE
    call fsr_group
    mov rdi, [rbx + FSR_text]
    call mem_free
    mov qword ptr [rbx + FSR_text], 0
    mov rdi, [rbx + FSR_frel]
    call mem_free
    mov qword ptr [rbx + FSR_frel], 0
    EPILOGUE

# fsr_group() with rbx the run: the file's matches so far as a group of the batch:
# FOLDER DOC VERSION PATH_LEN M LF PATH, then the matches
fsr_group:
    PROLOGUE
    cmp qword ptr [rbx + FSR_fmn], 0
    je 9f
    mov rdi, [rbx + FSR_frel]
    call strlen
    mov r12, rax
    lea rdi, [rax + 80]
    add rdi, [rbx + FSR_fm + SB_len]
    call fsr_room
    lea r13, [rbx + FSR_batch]
    mov rdi, r13
    mov rsi, [rbx + FSR_fid]
    call sb_push_u64
    mov rdi, r13
    mov esi, ' '
    call sb_push_byte
    mov rdi, r13
    mov rsi, [rbx + FSR_fdoc]
    call sb_push_u64
    mov rdi, r13
    mov esi, ' '
    call sb_push_byte
    mov rdi, r13
    mov rsi, [rbx + FSR_fver]
    call sb_push_u64
    mov rdi, r13
    mov esi, ' '
    call sb_push_byte
    mov rdi, r13
    mov rsi, r12
    call sb_push_u64
    mov rdi, r13
    mov esi, ' '
    call sb_push_byte
    mov rdi, r13
    mov rsi, [rbx + FSR_fmn]
    call sb_push_u64
    mov rdi, r13
    mov esi, 10
    call sb_push_byte
    mov rdi, r13
    mov rsi, [rbx + FSR_frel]
    mov rdx, r12
    call sb_push
    mov rdi, r13
    mov rsi, [rbx + FSR_fm + SB_ptr]
    mov rdx, [rbx + FSR_fm + SB_len]
    call sb_push
    inc qword ptr [rbx + FSR_nrec]
    cmp qword ptr [rbx + FSR_fcounted], 0
    jne 1f
    mov qword ptr [rbx + FSR_fcounted], 1
    inc qword ptr [rbx + FSR_files]
1:  lea rdi, [rbx + FSR_fm]
    call sb_clear
    mov qword ptr [rbx + FSR_fmn], 0
9:  EPILOGUE

# fsr_scan() with rbx the run -> eax 0 when the slice ended inside the file, 1 when the file is
# done, 2 when the run ended (MAX matches)
fsr_scan:
    PROLOGUE
    test dword ptr [rbx + FSR_flags], FSF_REGEX
    jnz .Lsc_regex
.Lsc_literal:
    call time_us
    cmp rax, [rip + fsr_deadline]
    jae .Lsc_later
    mov r12, [rbx + FSR_tpos]
    mov rdi, [rbx + FSR_text]
    add rdi, r12
    mov rsi, [rbx + FSR_tlen]
    sub rsi, r12
    jbe .Lsc_done
    mov rdx, [rbx + FSR_pat]
    mov rcx, [rbx + FSR_plen]
    test dword ptr [rbx + FSR_flags], FSF_ICASE
    jnz 1f
    call str_find
    jmp 2f
1:  call str_ifind
2:  test rax, rax
    js .Lsc_done
    add r12, rax                # the match
    mov r13, r12
    add r13, [rbx + FSR_plen]
    test dword ptr [rbx + FSR_flags], FSF_WORD
    jz 4f
    test r12, r12
    jz 3f
    mov rax, [rbx + FSR_text]
    movzx edi, byte ptr [rax + r12 - 1]
    call is_ident
    test eax, eax
    jnz 31f
3:  cmp r13, [rbx + FSR_tlen]
    jae 4f
    mov rax, [rbx + FSR_text]
    movzx edi, byte ptr [rax + r13]
    call is_ident
    test eax, eax
    jz 4f
31: lea rax, [r12 + 1]          # not a whole word: on from the next byte
    mov [rbx + FSR_tpos], rax
    jmp .Lsc_literal
4:  mov [rbx + FSR_tpos], r13
    mov rdi, r12
    call fsr_line_of
    mov rdi, r12
    mov rsi, r13
    call fsr_match
    test eax, eax
    jnz .Lsc_end
    jmp .Lsc_literal
.Lsc_regex:
    call time_us
    cmp rax, [rip + fsr_deadline]
    jae .Lsc_later
    mov r12, [rbx + FSR_tpos]
    cmp r12, [rbx + FSR_tlen]
    jae .Lsc_done
    # the line [r12, r13), the next one at r14
    mov rdi, [rbx + FSR_text]
    add rdi, r12
    mov rsi, [rbx + FSR_tlen]
    sub rsi, r12
    lea rdx, [rip + .Llf]
    mov ecx, 1
    call str_find
    mov r13, [rbx + FSR_tlen]
    lea r14, [r13]
    test rax, rax
    js 1f
    lea r13, [r12 + rax]
    lea r14, [r13 + 1]
1:  mov [rbx + FSR_lstart], r12
    cmp r13, r12
    jbe 2f
    mov rax, [rbx + FSR_text]
    cmp byte ptr [rax + r13 - 1], 13
    jne 2f
    dec r13
2:  mov [rbx + FSR_lend], r13
    mov rdi, r12
    mov rsi, r13
    call fsr_regex_line
    test eax, eax
    jnz .Lsc_end
    mov [rbx + FSR_tpos], r14
    inc qword ptr [rbx + FSR_tline]
    jmp .Lsc_regex
.Lsc_later:
    xor eax, eax
    EPILOGUE
.Lsc_done:
    mov eax, 1
    EPILOGUE
.Lsc_end:
    mov eax, 2
    EPILOGUE

# fsr_line_of(pos) with rbx the run: FSR_tline, FSR_lstart and FSR_lend become pos's line's
# (lines are counted from FSR_lscan on)
fsr_line_of:
    PROLOGUE
    mov r12, rdi
1:  mov r13, [rbx + FSR_lscan]
    cmp r13, r12
    jae 2f
    mov rdi, [rbx + FSR_text]
    add rdi, r13
    mov rsi, r12
    sub rsi, r13
    lea rdx, [rip + .Llf]
    mov ecx, 1
    call str_find
    test rax, rax
    js 2f
    lea rax, [r13 + rax + 1]
    mov [rbx + FSR_lstart], rax
    mov [rbx + FSR_lscan], rax
    inc qword ptr [rbx + FSR_tline]
    jmp 1b
2:  mov [rbx + FSR_lscan], r12
    # the line's end
    mov rdi, [rbx + FSR_text]
    add rdi, r12
    mov rsi, [rbx + FSR_tlen]
    sub rsi, r12
    lea rdx, [rip + .Llf]
    mov ecx, 1
    call str_find
    mov rcx, [rbx + FSR_tlen]
    test rax, rax
    js 3f
    lea rcx, [r12 + rax]
3:  cmp rcx, [rbx + FSR_lstart]
    jbe 4f
    mov rax, [rbx + FSR_text]
    cmp byte ptr [rax + rcx - 1], 13
    jne 4f
    cmp rcx, r12
    jbe 4f
    dec rcx
4:  mov [rbx + FSR_lend], rcx
    EPILOGUE

# fsr_regex_line(start, end) with rbx the run -> eax 1 when the run ended: every match of the
# program on the line
fsr_regex_line:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov r15, [rbx + FSR_rx]
    # a fresh budget for the line
    mov qword ptr [r15 + RX_error], 0
    mov qword ptr [r15 + RX_errpc], -1
    mov qword ptr [r15 + RX_work], FSR_RX_WORK
    mov qword ptr [r15 + RX_clockat], FSR_RX_WORK - 1024
    mov qword ptr [r15 + RX_deadline], 0
    mov rdi, r15
    mov rsi, [rbx + FSR_pat]
    mov rdx, [rbx + FSR_plen]
    mov rcx, [rbx + FSR_text]
    add rcx, r12
    mov r8, r13
    sub r8, r12
    call snippet_regex_open
    test eax, eax
    jz 8f
    xor r14d, r14d              # where the next match may start (in the line)
1:  mov rdi, r15
    mov rsi, r14
    call snippet_regex_find
    test rax, rax
    jle 8f
    mov rdi, [r15 + RX_start]
    mov rsi, [r15 + RX_end]
    mov r14, rsi
    add rdi, r12
    add rsi, r12
    push rdi
    push rsi
    call fsr_match
    pop rsi
    pop rdi
    test eax, eax
    jnz 9f
    cmp rsi, rdi
    jne 1b
    # an empty match: on past one character
    mov rax, r12
    add rax, r14
    cmp rax, r13
    jae 8f
    mov rdi, [rbx + FSR_text]
    add rdi, rax
    mov rsi, r13
    sub rsi, rax
    call utf8_decode
    add r14, rdx
    jmp 1b
8:  xor eax, eax
9:  EPILOGUE

# fsr_match(start, end) with rbx the run -> eax 1 when the run ended (MAX): a match on the line
# FSR_tline (FSR_lstart to FSR_lend): LINE COL END PRE TEXT_LEN LF TEXT, TEXT the line or 512
# bytes of it from at most 128 before the match
fsr_match:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov r14, [rbx + FSR_lstart]
    mov r15, [rbx + FSR_lend]
    cmp r13, r15
    jbe 1f
    mov r15, r13                # a match past a CR at the line's end
1:  mov rax, r15
    sub rax, r14
    mov rcx, r14                # the preview's start
    cmp rax, FSR_PREVIEW
    jbe 3f
    mov rcx, r12
    sub rcx, FSR_BEFORE
    cmp rcx, r14
    jge 2f
    mov rcx, r14
2:  mov rdx, [rbx + FSR_text]   # not inside a character
21: cmp rcx, r12
    jae 3f
    movzx eax, byte ptr [rdx + rcx]
    and eax, 0xc0
    cmp eax, 0x80
    jne 3f
    inc rcx
    jmp 21b
3:  push rcx
    push rcx
    mov rdi, r15
    sub rdi, rcx
    mov rsi, [rbx + FSR_text]
    add rsi, rcx
    mov edx, FSR_PREVIEW
    call utf8_cut
    pop rcx
    pop rcx
    push rax                    # the preview's length
    push rcx
    lea rdi, [rbx + FSR_fm]
    mov rsi, [rbx + FSR_tline]
    call sb_push_u64
    lea rdi, [rbx + FSR_fm]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rbx + FSR_fm]
    lea rsi, [r12 + 1]
    sub rsi, r14
    call sb_push_u64
    lea rdi, [rbx + FSR_fm]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rbx + FSR_fm]
    lea rsi, [r13 + 1]
    sub rsi, r14
    call sb_push_u64
    lea rdi, [rbx + FSR_fm]
    mov esi, ' '
    call sb_push_byte
    mov rsi, [rsp]
    lea rdi, [rbx + FSR_fm]
    add rsi, 1
    sub rsi, r14
    call sb_push_u64
    lea rdi, [rbx + FSR_fm]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rbx + FSR_fm]
    mov rsi, [rsp + 8]
    call sb_push_u64
    lea rdi, [rbx + FSR_fm]
    mov esi, 10
    call sb_push_byte
    pop rsi
    pop rdx
    add rsi, [rbx + FSR_text]
    lea rdi, [rbx + FSR_fm]
    call sb_push
    inc qword ptr [rbx + FSR_fmn]
    inc qword ptr [rbx + FSR_count]
    cmp qword ptr [rbx + FSR_fm + SB_len], FSR_GROUP_BYTES
    jb 4f
    call fsr_group
4:  mov rax, [rbx + FSR_count]
    cmp rax, [rbx + FSR_max]
    jb 8f
    mov dword ptr [rbx + FSR_limit], 1
    call fsr_finish
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN filesearch_dump(out sb): "runs=N" and each run's id, state and counts (print-file-runs)
FN filesearch_dump
    PROLOGUE
    mov r12, rdi
    lea rbx, [rip + fsr_slots]
    xor r13d, r13d
    xor r14d, r14d
1:  cmp r13d, FSR_SLOTS
    jae 2f
    cmp dword ptr [rbx + FSR_state], 0
    je 11f
    inc r14d
11: add rbx, FSR_SIZE
    inc r13d
    jmp 1b
2:  mov rdi, r12
    lea rsi, [rip + .Lp_runs]
    call sb_push_cstr
    mov rdi, r12
    mov rsi, r14
    call sb_push_u64
    mov rdi, r12
    mov esi, 10
    call sb_push_byte
    EPILOGUE

# c_print_file_runs(out, args, len): print-file-runs
FN c_print_file_runs
    push rbx
    call filesearch_dump
    xor eax, eax
    pop rbx
    ret

# ---- phase 4 task 7: rhun's own runs (filelist.s) ----

# FN filesearch_native(folder id or 0, max, flags, cb, ctx) -> rax the run's serial, or 0 when every slot is
#   taken: see the top
FN filesearch_native
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov r14d, edx
    mov r15, rcx
    lea rbx, [rip + fsr_slots]
    xor ecx, ecx
1:  cmp ecx, FSR_SLOTS
    jae 8f
    cmp dword ptr [rbx + FSR_state], 0
    je 2f
    add rbx, FSR_SIZE
    inc ecx
    jmp 1b
2:  push r8
    push r8
    mov rdi, rbx
    xor eax, eax
    mov ecx, FSR_SIZE
    rep stosb
    pop r8
    pop r8
    inc qword ptr [rip + fsr_serial]
    mov rax, [rip + fsr_serial]
    mov [rbx + FSR_serial], rax
    mov dword ptr [rbx + FSR_kind], FSK_FIND
    mov [rbx + FSR_flags], r14d
    mov [rbx + FSR_max], r13
    mov [rbx + FSR_folder], r12
    mov [rbx + FSR_cb], r15
    mov [rbx + FSR_ctx], r8
    test r12, r12
    jz 3f
    mov dword ptr [rbx + FSR_single], 1
3:  mov dword ptr [rbx + FSR_state], FSS_WAITING
    mov dword ptr [rip + g_dirty], 1
    mov rax, [rbx + FSR_serial]
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN filesearch_native_cancel(serial): that native run ends, its callback not told
FN filesearch_native_cancel
    PROLOGUE
    mov r12, rdi
    lea rbx, [rip + fsr_slots]
    xor r13d, r13d
1:  cmp r13d, FSR_SLOTS
    jae 9f
    cmp dword ptr [rbx + FSR_state], 0
    je 2f
    cmp qword ptr [rbx + FSR_cb], 0
    je 2f
    cmp [rbx + FSR_serial], r12
    jne 2f
    mov rdi, rbx
    call fsr_free
    jmp 9f
2:  add rbx, FSR_SIZE
    inc r13d
    jmp 1b
9:  EPILOGUE

# FN filesearch_pending(ext) -> eax 1 while a find or search of the extension runs or waits
FN filesearch_pending
    lea rax, [rip + fsr_slots]
    xor ecx, ecx
1:  cmp ecx, FSR_SLOTS
    jae 8f
    cmp dword ptr [rax + FSR_state], 0
    je 2f
    cmp [rax + FSR_ext], rdi
    je 9f
2:  add rax, FSR_SIZE
    inc ecx
    jmp 1b
8:  xor eax, eax
    ret
9:  mov eax, 1
    ret

.section .rodata
.Lempty: .asciz ""
.Llf: .asciz "\n"
.Ldot_git: .asciz ".git"
.Lg_dash_C: .asciz "-C"
.Lg_ls_files: .asciz "ls-files"
.Lg_z: .asciz "-z"
.Lg_cached: .asciz "--cached"
.Lg_others: .asciz "--others"
.Lg_exclude: .asciz "--exclude-standard"
.Lw_found: .asciz "0 found "
.Lw_ok: .asciz "ok "
.Lw_error: .asciz "error "
.Lw_cancelled: .asciz " cancelled\n"
.Lw_complete: .asciz " complete\n"
.Lw_limit: .asciz " limit\n"
.Lw_partial: .asciz " partial\n"
.Lp_runs: .asciz "runs="
.Le_syntax: .asciz "syntax cannot parse the request"
.Le_nofile: .asciz "nofile no such folder"
.Le_max_find: .asciz "toobig MAX is at most 100000"
.Le_max_search: .asciz "toobig MAX is at most 20000"
.Le_globs: .asciz "syntax a glob line is not +GLOB or -GLOB, or the glob does not parse"
.Le_globs_big: .asciz "toobig 64 glob lines of 1024 bytes, 32 alternatives each"
.Le_literal_big: .asciz "toobig a literal pattern is at most 4096 bytes"
.Le_program_big: .asciz "toobig an RNRX program is at most 262144 bytes"
.Le_program: .asciz "syntax the pattern is not a valid RNRX program"
.Le_busy_ext: .asciz "busy a find or search of this extension is running"
.Le_busy_all: .asciz "busy 20 finds and searches are running or waiting"
.Le_memory: .asciz "toobig no memory for the regex"
