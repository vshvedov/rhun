# palette overlay: fuzzy file finder, commands, themes, languages, go to line, find in files, one-line prompts,
# the path browser (Open File, Open Folder)
.include "rhun.inc"

.equ PM_NONE, 0
.equ PM_FILES, 1
.equ PM_COMMANDS, 2
.equ PM_THEMES, 3
.equ PM_LANGS, 4
.equ PM_GOTO, 5
.equ PM_PROMPT, 6
.equ PM_GREP, 7
.equ PM_BROWSE, 8

.equ ID_PAL_ROW, 0x3000
.equ ID_PAL_FIELD, 0x3fff
.equ MAXFILES, 200000
.equ GREP_MAX, 5000             # results
.equ GREP_FILE_MAX, 8 << 20     # bytes per file
.equ GREP_TOTAL_MAX, 256 << 20
.equ GREP_BLOCK, 32 << 20        # file texts are read into mappings this big, unmapped after
.equ BRW_MAX, 20000             # entries of a folder in the path browser
.equ BRW_DIR, 1                 # IT_data of the path browser: a folder
.equ BRW_HERE, 2                # the "Open <folder>" row

STRUCT
F IT_label, 8
F IT_len, 8
F IT_detail, 8          # cstr or 0
F IT_data, 8
ENDSTRUCT IT_SIZE

STRUCT
F GF_label, 8           # relative path (in strings)
F GF_text, 8
F GF_len, 8
ENDSTRUCT GF_SIZE

STRUCT
F RS_item, 4
F RS_score, 4
ENDSTRUCT RS_SIZE

.bss
.p2align 3
pal_mode: .long 0
pal_prompt: .long 0             # PROMPT_* when in PM_PROMPT
pal_sel: .long 0
pal_scroll: .long 0
pal_reveal: .long 0             # reveal selection after keyboard navigation/filtering only
pal_wheel: .long 0              # accumulate wheel pixels smaller than a row
.p2align 3
pal_tf: .zero TF_SIZE
items: .zero VEC_SIZE
results: .zero VEC_SIZE
strings: .zero SB_SIZE          # label storage for file items
pal_label: .quad 0              # prompt label
pal_theme_before: .quad 0
pal_path: .zero 4096
scan_depth: .long 0
scan_prefix: .zero 4096         # relative dir during scan
scan_plen: .long 0
tmp: .zero SB_SIZE
gfiles: .zero VEC_SIZE          # GF: project text files in memory while searching
ghit: .quad 0                   # per file: 0 when it has no match for the query in gprev
gblocks: .zero VEC_SIZE         # mappings holding the file texts (pointers)
gblock_ptr: .quad 0             # free space in the last one
gblock_end: .quad 0
gprev: .zero 256
gprev_len: .long 0
gstr: .zero SB_SIZE             # result labels and details
grep_case: .long 0
pal_mods: .long 0               # modifiers of the key that accepts
pal_nohl: .long 0               # the row being drawn shows no matched characters
brw_kind: .long 0               # the path browser picks: 0 a file, 1 a folder
brw_dir: .zero 4096             # the folder it lists
brw_next: .zero 4096
brw_label: .zero 4096

.text

FN palette_is_open
    xor eax, eax
    cmp dword ptr [rip + pal_mode], PM_NONE
    setne al
    ret

FN palette_field
    lea rax, [rip + pal_tf]
    ret

# palette_open(mode)
palette_open:
    PROLOGUE
    mov ebx, edi
    call grep_release
    mov [rip + pal_mode], ebx
    mov dword ptr [rip + pal_sel], 0
    mov dword ptr [rip + pal_scroll], 0
    mov dword ptr [rip + pal_tf + TF_id], ID_PAL_FIELD
    lea rdi, [rip + pal_tf]
    call tf_clear
    mov qword ptr [rip + items + VEC_len], 0
    mov dword ptr [rip + g_focus], FOCUS_PALETTE
    cmp ebx, PM_FILES
    jne 1f
    call load_files
    jmp 8f
1:  cmp ebx, PM_COMMANDS
    jne 2f
    call load_commands
    jmp 8f
2:  cmp ebx, PM_THEMES
    jne 3f
    call load_themes
    jmp 8f
3:  cmp ebx, PM_LANGS
    jne 8f
    call load_langs
8:  call palette_filter
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

FN palette_close
    push rbx
    # themes: Esc restores the previous theme
    cmp dword ptr [rip + pal_mode], PM_THEMES
    jne 1f
    mov rdi, [rip + pal_theme_before]
    cmp rdi, [rip + g_theme_cur]
    je 1f
    call theme_apply
1:  call grep_release
    mov dword ptr [rip + pal_mode], PM_NONE
    mov dword ptr [rip + g_focus], FOCUS_EDITOR
    mov dword ptr [rip + g_dirty], 1
    pop rbx
    ret

FN cmd_quick_open
    mov edi, PM_FILES
    jmp palette_open
FN cmd_command_palette
    mov edi, PM_COMMANDS
    jmp palette_open
FN cmd_select_theme
    mov rax, [rip + g_theme_cur]
    mov [rip + pal_theme_before], rax
    mov edi, PM_THEMES
    jmp palette_open
FN cmd_select_language
    cmp qword ptr [rip + g_doc], 0
    je 1f
    mov edi, PM_LANGS
    jmp palette_open
1:  ret
FN cmd_goto_line
    cmp qword ptr [rip + g_doc], 0
    je 1f
    mov edi, PM_GOTO
    jmp palette_open
1:  ret

FN cmd_open_file
    xor edi, edi
    jmp browse_open

FN cmd_open_folder
    mov edi, 1
    jmp browse_open

# find in files: the selection (one line) is the initial query
FN cmd_find_in_files
    PROLOGUE
    cmp qword ptr [rip + g_project], 0
    je 9f
    mov edi, PM_GREP
    call palette_open
    call grep_load
    mov rbx, [rip + g_doc]
    test rbx, rbx
    jz 8f
    mov rdi, rbx
    call ed_sel
    cmp rax, rdx
    je 8f
    mov r12, rax
    mov r13, rdx
    sub r13, rax
    cmp r13, 200
    ja 8f
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call doc_range
    mov r14, rax
    mov rdi, rax
    mov rsi, r13
    lea rdx, [rip + .Lnl]
    mov ecx, 1
    call str_find
    test rax, rax
    jns 8f
    lea rdi, [rip + pal_tf]
    mov rsi, r14
    mov rdx, r13
    call tf_set
    lea rdi, [rip + pal_tf]
    call tf_select_all
8:  call palette_filter
9:  EPILOGUE

# grep_load(): read the project's text files into memory
grep_load:
    PROLOGUE 16
    call load_files
    mov qword ptr [rsp], 0      # total bytes
    xor ebx, ebx
1:  cmp rbx, [rip + items + VEC_len]
    jae 8f
    cmp qword ptr [rsp], GREP_TOTAL_MAX
    jae 8f
    imul r12, rbx, IT_SIZE
    add r12, [rip + items + VEC_ptr]
    mov rdi, [rip + g_project]
    mov rsi, [r12 + IT_label]
    call path_join
    mov r13, rax
    mov rdi, rax
    call grep_read
    mov r14, rax
    mov r15, rdx
    mov rdi, r13
    call mem_free
    test r14, r14
    jz 7f
    add [rsp], r15
    lea rdi, [rip + gfiles]
    mov esi, GF_SIZE
    call vec_push
    mov rcx, [r12 + IT_label]
    mov [rax + GF_label], rcx
    mov [rax + GF_text], r14
    mov [rax + GF_len], r15
7:  inc rbx
    jmp 1b
8:  mov qword ptr [rip + items + VEC_len], 0
    call sort_gfiles
    EPILOGUE

# sort_gfiles(): by path, byte order (shell sort)
sort_gfiles:
    PROLOGUE 32
    mov r15, [rip + gfiles + VEC_len]
    mov rbx, r15
.Lsg_gap:
    shr rbx, 1
    jz .Lsg_done
    mov r12, rbx                # i
.Lsg_i:
    cmp r12, r15
    jae .Lsg_gap
    imul rax, r12, GF_SIZE
    add rax, [rip + gfiles + VEC_ptr]
    movups xmm0, [rax]
    movups [rsp], xmm0
    mov rcx, [rax + 16]
    mov [rsp + 16], rcx
    mov r13, r12                # j
.Lsg_j:
    cmp r13, rbx
    jb .Lsg_put
    mov r14, r13
    sub r14, rbx
    imul rax, r14, GF_SIZE
    add rax, [rip + gfiles + VEC_ptr]
    mov rdi, [rax + GF_label]
    mov rsi, [rsp + GF_label]
1:  movzx ecx, byte ptr [rdi]
    movzx edx, byte ptr [rsi]
    cmp ecx, edx
    jne 2f
    test ecx, ecx
    jz .Lsg_put
    inc rdi
    inc rsi
    jmp 1b
2:  jb .Lsg_put
    imul rdx, r13, GF_SIZE
    add rdx, [rip + gfiles + VEC_ptr]
    movups xmm0, [rax]
    movups [rdx], xmm0
    mov rcx, [rax + 16]
    mov [rdx + 16], rcx
    mov r13, r14
    jmp .Lsg_j
.Lsg_put:
    imul rdx, r13, GF_SIZE
    add rdx, [rip + gfiles + VEC_ptr]
    movups xmm0, [rsp]
    movups [rdx], xmm0
    mov rcx, [rsp + 16]
    mov [rdx + 16], rcx
    inc r12
    jmp .Lsg_i
.Lsg_done:
    EPILOGUE

# grep_read(path) -> rax text (NUL-terminated) or 0 for an empty, big or binary file, rdx length;
# the text goes into the current GREP_BLOCK mapping
grep_read:
    PROLOGUE
    call file_open_read
    test rax, rax
    js 8f
    mov ebx, eax
    mov edi, eax
    call file_size
    test rax, rax
    jle 7f
    cmp rax, GREP_FILE_MAX
    ja 7f
    mov r12, rax
    mov rax, [rip + gblock_ptr]
    lea rcx, [rax + r12 + 1]
    test rax, rax
    jz 1f
    cmp rcx, [rip + gblock_end]
    jbe 2f
1:  mov edi, GREP_BLOCK
    call os_map
    mov [rip + gblock_ptr], rax
    lea rcx, [rax + GREP_BLOCK]
    mov [rip + gblock_end], rcx
    mov r13, rax
    lea rdi, [rip + gblocks]
    mov esi, 8
    call vec_push
    mov [rax], r13
2:  mov r13, [rip + gblock_ptr]
    xor r14d, r14d
3:  cmp r14, r12
    jae 4f
    mov edi, ebx
    lea rsi, [r13 + r14]
    mov rdx, r12
    sub rdx, r14
    SYS SYS_read
    cmp rax, -EINTR
    je 3b
    test rax, rax
    jle 4f
    add r14, rax
    jmp 3b
4:  mov byte ptr [r13 + r14], 0
    mov edi, ebx
    SYS SYS_close
    # binary: a NUL in the first 8 KiB
    test r14, r14
    jz 8f
    mov rdi, r13
    mov rcx, r14
    cmp rcx, 8192
    jbe 5f
    mov ecx, 8192
5:  xor eax, eax
    repne scasb
    je 8f
    lea rax, [r13 + r14 + 1]
    mov [rip + gblock_ptr], rax
    mov rax, r13
    mov rdx, r14
    EPILOGUE
7:  mov edi, ebx
    SYS SYS_close
8:  xor eax, eax
    xor edx, edx
    EPILOGUE

grep_release:
    push rbx
    # the texts go back to the system with their mappings
    xor ebx, ebx
1:  cmp rbx, [rip + gblocks + VEC_len]
    jae 2f
    mov rax, [rip + gblocks + VEC_ptr]
    mov rdi, [rax + rbx*8]
    mov esi, GREP_BLOCK
    SYS SYS_munmap
    inc rbx
    jmp 1b
2:  mov qword ptr [rip + gblocks + VEC_len], 0
    mov qword ptr [rip + gblock_ptr], 0
    mov qword ptr [rip + gblock_end], 0
    mov qword ptr [rip + gfiles + VEC_len], 0
    mov rdi, [rip + ghit]
    call mem_free
    mov qword ptr [rip + ghit], 0
    mov dword ptr [rip + gprev_len], 0
    pop rbx
    ret

# grep_narrow() -> 1 when the query extends the previous one, so files without a match for that
# (ghit 0) can be skipped; otherwise every file is marked as a maybe. Remembers the query.
grep_narrow:
    PROLOGUE
    cmp qword ptr [rip + ghit], 0
    jne 1f
    mov rdi, [rip + gfiles + VEC_len]
    inc rdi
    call mem_alloc
    mov [rip + ghit], rax
    mov dword ptr [rip + gprev_len], 0
1:  lea rdi, [rip + pal_tf]
    call tf_text
    mov r12, rax
    mov r13, rdx
    xor ebx, ebx
    mov ecx, [rip + gprev_len]
    test ecx, ecx
    jz 3f
    cmp r13, rcx
    jb 3f
    xor edx, edx
    lea r8, [rip + gprev]
2:  cmp rdx, rcx
    jae 21f
    movzx eax, byte ptr [r12 + rdx]
    cmp al, [r8 + rdx]
    jne 3f
    inc rdx
    jmp 2b
21: mov ebx, 1
    jmp 4f
3:  mov rdi, [rip + ghit]
    mov esi, 1
    mov rdx, [rip + gfiles + VEC_len]
    call memset
4:  xor eax, eax
    cmp r13, 255
    ja 5f
    lea rdi, [rip + gprev]
    mov rsi, r12
    mov rcx, r13
    rep movsb
    mov eax, r13d
5:  mov [rip + gprev_len], eax
    mov eax, ebx
    EPILOGUE

# grep_run(): one result per line containing the query; an uppercase letter makes it case-sensitive
# IT_data = file index << 44 | line << 20 | column
grep_run:
    PROLOGUE 64
    mov qword ptr [rip + items + VEC_len], 0
    lea rdi, [rip + gstr]
    call sb_clear
    lea rdi, [rip + pal_tf]
    call tf_text
    mov [rsp], rax              # query
    mov [rsp + 8], rdx          # query length
    cmp rdx, 2
    jb .Lgr_fix
    mov dword ptr [rip + grep_case], 0
    xor ecx, ecx
1:  cmp rcx, rdx
    jae 2f
    movzx r8d, byte ptr [rax + rcx]
    sub r8d, 'A'
    cmp r8d, 25
    ja 11f
    mov dword ptr [rip + grep_case], 1
11: inc rcx
    jmp 1b
2:  call grep_narrow
    mov [rsp + 60], eax
    xor ebx, ebx                # file index
.Lgr_file:
    cmp rbx, [rip + gfiles + VEC_len]
    jae .Lgr_fix
    mov dword ptr [rsp + 56], 0 # a match in this file
    cmp dword ptr [rsp + 60], 0
    je 21f
    mov rax, [rip + ghit]
    cmp byte ptr [rax + rbx], 0
    je .Lgr_skip
21: imul r12, rbx, GF_SIZE
    add r12, [rip + gfiles + VEC_ptr]
    xor r13d, r13d              # scan position (lines counted up to here)
    xor r14d, r14d              # line
    xor r15d, r15d              # line start
.Lgr_match:
    cmp qword ptr [rip + items + VEC_len], GREP_MAX
    jae .Lgr_fix
    mov rdi, [r12 + GF_text]
    add rdi, r13
    mov rsi, [r12 + GF_len]
    sub rsi, r13
    jbe .Lgr_nextfile
    mov rdx, [rsp]
    mov rcx, [rsp + 8]
    cmp dword ptr [rip + grep_case], 0
    je 3f
    call str_find
    jmp 4f
3:  call str_ifind
4:  test rax, rax
    js .Lgr_nextfile
    add rax, r13
    mov [rsp + 16], rax         # match
    mov rdi, [r12 + GF_text]
5:  cmp r13, rax
    jae 6f
    cmp byte ptr [rdi + r13], 10
    jne 51f
    inc r14
    lea r15, [r13 + 1]
51: inc r13
    jmp 5b
6:  mov rcx, [r12 + GF_len]     # r13 = line end; the next search starts there
7:  cmp r13, rcx
    jae 8f
    cmp byte ptr [rdi + r13], 10
    je 8f
    inc r13
    jmp 7b
8:  # label: the line without its indent, starting near the match when it is far right
    mov rax, r15
9:  cmp rax, [rsp + 16]
    jae 10f
    movzx ecx, byte ptr [rdi + rax]
    cmp cl, ' '
    je 91f
    cmp cl, 9
    jne 10f
91: inc rax
    jmp 9b
10: mov rcx, [rsp + 16]
    sub rcx, rax
    cmp rcx, 60
    jbe 12f
    mov rax, [rsp + 16]
    sub rax, 40
101: movzx ecx, byte ptr [rdi + rax]
    and ecx, 0xc0
    cmp ecx, 0x80
    jne 12f
    inc rax
    jmp 101b
12: mov [rsp + 24], rax         # label start
    lea rcx, [rax + 240]
    cmp rcx, r13
    jbe 121f
    mov rcx, r13
    jmp 13f
121: movzx edx, byte ptr [rdi + rcx]
    and edx, 0xc0
    cmp edx, 0x80
    jne 13f
    inc rcx
    jmp 121b
13: sub rcx, rax
    mov [rsp + 32], rcx         # label length
    mov rax, [rip + gstr + SB_len]
    mov [rsp + 40], rax         # label offset
    lea rdi, [rip + gstr]
    mov rsi, [r12 + GF_text]
    add rsi, [rsp + 24]
    mov rdx, rcx
    call sb_push
    # tabs and other control bytes shown as spaces
    mov rdi, [rip + gstr + SB_ptr]
    mov rcx, [rsp + 40]
14: cmp rcx, [rip + gstr + SB_len]
    jae 15f
    cmp byte ptr [rdi + rcx], ' '
    jae 141f
    mov byte ptr [rdi + rcx], ' '
141: inc rcx
    jmp 14b
15: # detail "path:line"
    mov rax, [rip + gstr + SB_len]
    mov [rsp + 48], rax
    lea rdi, [rip + gstr]
    mov rsi, [r12 + GF_label]
    call sb_push_cstr
    lea rdi, [rip + gstr]
    mov esi, ':'
    call sb_push_byte
    lea rdi, [rip + gstr]
    lea rsi, [r14 + 1]
    call sb_push_u64
    lea rdi, [rip + gstr]
    xor esi, esi
    call sb_push_byte
    # data
    mov rax, [rsp + 16]
    sub rax, r15
    cmp rax, 0xfffff
    jbe 16f
    mov eax, 0xfffff
16: mov rcx, r14
    shl rcx, 20
    or rax, rcx
    mov rcx, rbx
    shl rcx, 44
    or rcx, rax
    mov rdi, [rsp + 40]
    mov rsi, [rsp + 32]
    mov rdx, [rsp + 48]
    call item_add
    mov dword ptr [rsp + 56], 1
    jmp .Lgr_match
.Lgr_nextfile:
    # searched to its end: whether it has the query
    mov rax, [rip + ghit]
    mov ecx, [rsp + 56]
    mov [rax + rbx], cl
.Lgr_skip:
    inc rbx
    jmp .Lgr_file
.Lgr_fix:
    # offsets -> pointers, results in file order
    mov qword ptr [rip + results + VEC_len], 0
    xor ebx, ebx
1:  cmp rbx, [rip + items + VEC_len]
    jae 9f
    imul r12, rbx, IT_SIZE
    add r12, [rip + items + VEC_ptr]
    mov rax, [rip + gstr + SB_ptr]
    add [r12 + IT_label], rax
    add [r12 + IT_detail], rax
    lea rdi, [rip + results]
    mov esi, RS_SIZE
    call vec_push
    mov [rax + RS_item], ebx
    mov dword ptr [rax + RS_score], 0
    inc rbx
    jmp 1b
9:  EPILOGUE

# prompt_open(label cstr, kind, [initial text in pal_path])
FN prompt_open
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12d, esi
    mov edi, PM_PROMPT
    call palette_open
    mov [rip + pal_label], rbx
    mov [rip + pal_prompt], r12d
    mov dword ptr [rip + g_focus], FOCUS_PROMPT
    # initial text: current path for save as / rename, project dir + / for new files
    lea rdi, [rip + tmp]
    call sb_clear
    call prompt_initial
    lea rdi, [rip + pal_tf]
    mov rsi, [rip + tmp + SB_ptr]
    mov rdx, [rip + tmp + SB_len]
    call tf_set
    pop r13
    pop r12
    pop rbx
    ret

prompt_initial:
    PROLOGUE
    mov eax, [rip + pal_prompt]
    cmp eax, PROMPT_SAVE_AS
    je 1f
    cmp eax, PROMPT_RENAME
    je 3f
    cmp eax, PROMPT_DELETE
    je 9f
    jmp 2f
1:  mov rax, [rip + g_doc]
    test rax, rax
    jz 2f
    mov rsi, [rax + DOC_path]
    test rsi, rsi
    jz 2f
    lea rdi, [rip + tmp]
    call sb_push_cstr
    jmp 9f
3:  lea rsi, [rip + g_explorer_target]
    cmp byte ptr [rsi], 0
    je 9f
    lea rdi, [rip + tmp]
    call sb_push_cstr
    jmp 9f
2:  # directory: explorer selection dir, else project
    lea rsi, [rip + g_explorer_dir]
    cmp byte ptr [rsi], 0
    jne 4f
    mov rsi, [rip + g_project]
    test rsi, rsi
    jnz 4f
    lea rdi, [rip + .Lhome]
    call getenv
    mov rsi, rax
    test rsi, rsi
    jz 9f
4:  lea rdi, [rip + tmp]
    call sb_push_cstr
    lea rdi, [rip + tmp]
    mov esi, '/'
    call sb_push_byte
9:  EPILOGUE

# ---- item sources ----

item_add:   # (label, len, detail, data)
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    lea rdi, [rip + items]
    mov esi, IT_SIZE
    call vec_push
    mov [rax + IT_label], rbx
    mov [rax + IT_len], r12
    mov [rax + IT_detail], r13
    mov [rax + IT_data], r14
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

load_commands:
    PROLOGUE
    lea rbx, [rip + g_commands]
1:  mov r12, [rbx + CMD_title]
    test r12, r12
    jz 9f
    cmp byte ptr [r12], 0
    je 2f
    mov rdi, r12
    call strlen
    mov r13, rax
    # shortcut label, formatted once per command
    mov rax, rbx
    lea rcx, [rip + g_commands]
    sub rax, rcx
    xor edx, edx
    mov ecx, CMD_SIZE
    div rcx
    mov r14, rax
    lea rcx, [rip + keys_cache]
    mov rax, [rcx + r14*8]
    test rax, rax
    jnz 3f
    mov rdi, rbx
    call keys_for
    test rax, rax
    jz 3f
    mov rdi, rax
    push rax
    call strlen
    pop rdi
    mov rsi, rax
    call mem_dup
    lea rcx, [rip + keys_cache]
    mov [rcx + r14*8], rax
3:  mov rdi, r12
    mov rsi, r13
    mov rdx, rax
    mov rcx, rbx
    call item_add
2:  add rbx, CMD_SIZE
    jmp 1b
9:  EPILOGUE

load_themes:
    PROLOGUE
    xor ebx, ebx
1:  cmp rbx, [rip + g_themes + VEC_len]
    jae 9f
    mov rdi, rbx
    call theme_entry
    mov r12, rax
    lea r13, [rip + .Ldark]
    cmp dword ptr [r12 + TH_dark], 0
    jne 2f
    lea r13, [rip + .Llight]
2:  cmp rbx, [rip + g_follow]
    jne 3f
    # "Follow Omarchy" shows the theme it stands for
    call omarchy_target
    mov rdi, rax
    call theme_entry
    mov r13, [rax + TH_name]
3:  mov rdi, [r12 + TH_name]
    call strlen
    mov rdi, [r12 + TH_name]
    mov rsi, rax
    mov rdx, r13
    mov rcx, rbx
    call item_add
    inc rbx
    jmp 1b
9:  # preselect the current theme
    mov rax, [rip + g_theme_cur]
    mov [rip + pal_sel], eax
    EPILOGUE

load_langs:
    PROLOGUE
    lea rdi, [rip + .Lplain]
    mov esi, 10
    xor edx, edx
    xor ecx, ecx
    call item_add
    xor ebx, ebx
1:  cmp rbx, [rip + g_grammars + VEC_len]
    jae 9f
    mov rax, [rip + g_grammars + VEC_ptr]
    mov r12, [rax + rbx*8]
    mov rdi, [r12 + GR_name]
    call strlen
    mov rdi, [r12 + GR_name]
    mov rsi, rax
    mov rdx, [r12 + GR_files]
    mov rcx, r12
    call item_add
    inc rbx
    jmp 1b
9:  EPILOGUE

# load_files(): walk the project, relative paths
load_files:
    PROLOGUE
    lea rdi, [rip + strings]
    call sb_clear
    mov rdi, [rip + g_project]
    test rdi, rdi
    jz 9f
    mov dword ptr [rip + scan_plen], 0
    mov dword ptr [rip + scan_depth], 0
    call scan_dir
    # labels point into strings (stable after the scan): offsets -> pointers
    xor ebx, ebx
1:  cmp rbx, [rip + items + VEC_len]
    jae 9f
    imul rax, rbx, IT_SIZE
    add rax, [rip + items + VEC_ptr]
    mov rcx, [rip + strings + SB_ptr]
    add [rax + IT_label], rcx
    inc rbx
    jmp 1b
9:  EPILOGUE

# scan_dir(abs dir): recursion via dir_each callback
scan_dir:
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rip + scan_depth], 16
    jae 9f
    inc dword ptr [rip + scan_depth]
    mov rdi, rbx
    lea rsi, [rip + scan_cb]
    mov rdx, rbx
    call dir_each
    dec dword ptr [rip + scan_depth]
9:  EPILOGUE

# scan_cb(dir, name, is_dir)
scan_cb:
    PROLOGUE 16
    mov r12, rdi                # abs dir
    mov r13, rsi                # name
    mov r14d, edx
    cmp qword ptr [rip + items + VEC_len], MAXFILES
    jae 9f
    mov rdi, r13
    call explorer_excluded
    test eax, eax
    jnz 9f
    # relative path = scan_prefix + name
    mov ebx, [rip + scan_plen]
    lea rdi, [rip + scan_prefix]
    add rdi, rbx
    mov rsi, r13
    call cstr_copy
    lea rcx, [rip + scan_prefix]
    sub rax, rcx
    mov r15, rax                # rel len
    test r14d, r14d
    jz 1f
    # directory: recurse
    cmp r15, 4000
    jae 9f
    lea rax, [rip + scan_prefix]
    mov byte ptr [rax + r15], '/'
    lea eax, [r15 + 1]
    mov [rip + scan_plen], eax
    mov rdi, r12
    mov rsi, r13
    call path_join
    mov [rsp], rax
    mov rdi, rax
    call scan_dir
    mov rdi, [rsp]
    call mem_free
    mov [rip + scan_plen], ebx
    jmp 9f
1:  # file: store offset now, pointer fixed up after the scan
    mov rax, [rip + strings + SB_len]
    mov [rsp], rax
    lea rdi, [rip + strings]
    lea rsi, [rip + scan_prefix]
    mov rdx, r15
    call sb_push
    lea rdi, [rip + strings]
    xor esi, esi
    call sb_push_byte
    mov rdi, [rsp]
    mov rsi, r15
    xor edx, edx
    xor ecx, ecx
    call item_add
9:  EPILOGUE

# ---- path browser ----

# browse_open(folder): Open File (0) or Open Folder (1), starting in the project folder
browse_open:
    PROLOGUE
    mov ebx, edi
    mov [rip + brw_kind], ebx
    mov byte ptr [rip + brw_dir], 0
    mov edi, PM_BROWSE
    call palette_open
    lea rax, [rip + .Lph_open_file]
    test ebx, ebx
    jz 1f
    lea rax, [rip + .Lph_open_folder]
1:  mov [rip + pal_label], rax
    # the field: the project folder, the home folder as ~, and a '/'
    mov rsi, [rip + g_project]
    test rsi, rsi
    jnz 2f
    lea rdi, [rip + .Lhome]
    call getenv
    mov rsi, rax
    test rsi, rsi
    jnz 2f
    lea rsi, [rip + .Lroot]
2:  lea rdi, [rip + brw_label]
    call path_tilde
    cmp byte ptr [rax - 1], '/'
    je 3f
    mov byte ptr [rax], '/'
    inc rax
3:  lea rsi, [rip + brw_label]
    sub rax, rsi
    lea rdi, [rip + pal_tf]
    mov rdx, rax
    call tf_set
    call palette_changed
    EPILOGUE

# browse_split() -> rax field text, rdx its length through the last '/' (0 without one), rcx its length
browse_split:
    push rbx
    lea rdi, [rip + pal_tf]
    call tf_text
.ifdef WINDOWS
    mov rdi, rax
    call win_slashes
.endif
    mov rcx, rdx
    mov rbx, rdx
1:  test rbx, rbx
    jz 2f
    cmp byte ptr [rax + rbx - 1], '/'
    je 2f
    dec rbx
    jmp 1b
2:  mov rdx, rbx
    pop rbx
    ret

# browse_expand(dst, ptr, len): the folder a path in the field names, absolute and normalized: ~ is
# the home folder, and a path without a leading / or ~ is in the project
browse_expand:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    cmp r13, 3000
    jbe 1f
    mov r13d, 3000
1:  test r13, r13
    jz 3f
    PATH_ABSOLUTE r12, 12f
    jmp 11f
12:
    mov rdi, rbx
    jmp 5f
11: cmp byte ptr [r12], '~'
    jne 3f
    cmp r13, 1
    je 2f
    cmp byte ptr [r12 + 1], '/'
    jne 3f
2:  # ~: the home folder
    inc r12
    dec r13
    lea rdi, [rip + .Lhome]
    call getenv
    mov rdi, rbx
    test rax, rax
    jz 5f
    mov rsi, rax
    call cstr_copy
    mov rdi, rax
    jmp 5f
3:  # in the project, or the home folder without one
    mov rsi, [rip + g_project]
    test rsi, rsi
    jnz 4f
    lea rdi, [rip + .Lhome]
    call getenv
    mov rsi, rax
    test rsi, rsi
    jnz 4f
    lea rsi, [rip + .Lempty]
4:  mov rdi, rbx
    call cstr_copy
    mov byte ptr [rax], '/'
    lea rdi, [rax + 1]
5:  mov rsi, r12
    mov rcx, r13
    rep movsb
    mov byte ptr [rdi], 0
    # a relative home: taken as from the root
    PATH_ABSOLUTE rbx, 6f
    lea rdi, [rip + brw_label]
    mov rsi, rbx
    call cstr_copy
    mov byte ptr [rbx], '/'
    lea rdi, [rbx + 1]
    lea rsi, [rip + brw_label]
    call cstr_copy
6:  mov rdi, rbx
    call path_normalize
    EPILOGUE

# browse_filter(): the folder the field names is listed (again when it changed); the rows are the
# entries matching what follows the last '/', best first. Hidden entries need a query starting
# with '.'. Picking a folder, "Open <folder>" always leads.
browse_filter:
    PROLOGUE 16
    call browse_split
    mov r12, rax
    mov r13, rdx
    mov r14, rcx
    lea rdi, [rip + brw_next]
    mov rsi, r12
    mov rdx, r13
    call browse_expand
    lea rdi, [rip + brw_next]
    lea rsi, [rip + brw_dir]
    call strcmp_eq
    test eax, eax
    jnz 1f
    lea rdi, [rip + brw_dir]
    lea rsi, [rip + brw_next]
    call cstr_copy
    call browse_load
1:  lea r15, [r12 + r13]        # query
    sub r14, r13
    xor ebx, ebx
    cmp qword ptr [rip + items + VEC_len], 0
    je 2f
    mov rax, [rip + items + VEC_ptr]
    test qword ptr [rax + IT_data], BRW_HERE
    jz 2f
    lea rdi, [rip + results]
    mov esi, RS_SIZE
    call vec_push
    mov dword ptr [rax + RS_item], 0
    mov dword ptr [rax + RS_score], 0
    mov ebx, 1
2:  mov [rsp], rbx              # leading rows
3:  cmp rbx, [rip + items + VEC_len]
    jae 5f
    imul r12, rbx, IT_SIZE
    add r12, [rip + items + VEC_ptr]
    mov rdi, [r12 + IT_label]
    cmp byte ptr [rdi], '.'
    jne 31f
    test r14, r14
    jz 4f
    cmp byte ptr [r15], '.'
    jne 4f
31: mov rsi, [r12 + IT_len]
    mov rdx, r15
    mov rcx, r14
    call fuzzy
    test eax, eax
    js 4f
    mov r13d, eax
    lea rdi, [rip + results]
    mov esi, RS_SIZE
    call vec_push
    mov [rax + RS_item], ebx
    mov [rax + RS_score], r13d
4:  inc rbx
    jmp 3b
5:  test r14, r14
    jz 6f
    mov rax, [rsp]
    mov rdi, [rip + results + VEC_ptr]
    lea rdi, [rdi + rax*8]
    mov rsi, [rip + results + VEC_len]
    sub rsi, rax
    mov [rsp + 8], rdi
    mov rbx, rsi
    call rs_flip
    mov rdi, [rsp + 8]
    mov rsi, rbx
    call sort_u64
    mov rdi, [rsp + 8]
    mov rsi, rbx
    call rs_flip
6:  # the selection: the leading row, or the best match of a query; a query that matches nothing
    # leaves no rows, so Enter can't open the folder above a typo
    xor eax, eax
    test r14, r14
    jz 7f
    mov rcx, [rsp]
    cmp [rip + results + VEC_len], rcx
    ja 61f
    mov qword ptr [rip + results + VEC_len], 0
    jmp 7f
61: mov eax, ecx
7:  mov [rip + pal_sel], eax
    EPILOGUE

# browse_load(): the entries of brw_dir, folders first ("name/"), then files (none when picking a
# folder), by name; picking a folder, the "Open <folder>" row first
browse_load:
    PROLOGUE
    mov qword ptr [rip + items + VEC_len], 0
    lea rdi, [rip + strings]
    call sb_clear
    lea rdi, [rip + brw_dir]
    call file_is_dir
    test eax, eax
    jz 9f
    xor ebx, ebx                # items before the sorted ones
    cmp dword ptr [rip + brw_kind], 0
    je 1f
    lea rdi, [rip + strings]
    lea rsi, [rip + .Lopen_here]
    call sb_push_cstr
    lea rdi, [rip + brw_label]
    lea rsi, [rip + brw_dir]
    call path_tilde
    lea rdi, [rip + strings]
    lea rsi, [rip + brw_label]
    call sb_push_cstr
    mov r12, [rip + strings + SB_len]
    lea rdi, [rip + strings]
    xor esi, esi
    call sb_push_byte
    xor edi, edi
    mov rsi, r12
    xor edx, edx
    mov ecx, BRW_HERE
    call item_add
    mov ebx, 1
1:  lea rdi, [rip + brw_dir]
    lea rsi, [rip + browse_cb]
    xor edx, edx
    call dir_each
    # labels point into strings (stable now): offsets -> pointers
    xor ecx, ecx
2:  cmp rcx, [rip + items + VEC_len]
    jae 3f
    imul rax, rcx, IT_SIZE
    add rax, [rip + items + VEC_ptr]
    mov rdx, [rip + strings + SB_ptr]
    add [rax + IT_label], rdx
    inc rcx
    jmp 2b
3:  mov rdi, rbx
    call browse_sort
9:  EPILOGUE

# browse_cb(ctx, name, is_dir)
browse_cb:
    PROLOGUE 16
    mov r12, rsi
    mov r13d, edx
    cmp qword ptr [rip + items + VEC_len], BRW_MAX
    jae 9f
    test r13d, r13d
    jnz 1f
    cmp dword ptr [rip + brw_kind], 0
    jne 9f
1:  mov rax, [rip + strings + SB_len]
    mov [rsp], rax
    lea rdi, [rip + strings]
    mov rsi, r12
    call sb_push_cstr
    test r13d, r13d
    jz 2f
    lea rdi, [rip + strings]
    mov esi, '/'
    call sb_push_byte
2:  mov rax, [rip + strings + SB_len]
    sub rax, [rsp]
    mov [rsp + 8], rax
    lea rdi, [rip + strings]
    xor esi, esi
    call sb_push_byte
    mov rdi, [rsp]
    mov rsi, [rsp + 8]
    xor edx, edx
    mov ecx, r13d
    call item_add
9:  EPILOGUE

# browse_sort(first): the items from first on, folders first, then by name ignoring case (shell sort)
browse_sort:
    PROLOGUE 48
    mov r15, [rip + items + VEC_len]
    cmp r15, rdi
    jbe 9f
    sub r15, rdi                # n
    imul rax, rdi, IT_SIZE
    add rax, [rip + items + VEC_ptr]
    mov [rsp + 32], rax         # a
    mov rbx, r15                # gap
.Lbs_gap:
    shr rbx, 1
    jz 9f
    mov r12, rbx                # i
.Lbs_i:
    cmp r12, r15
    jae .Lbs_gap
    imul rax, r12, IT_SIZE
    add rax, [rsp + 32]
    movups xmm0, [rax]
    movups xmm1, [rax + 16]
    movups [rsp], xmm0
    movups [rsp + 16], xmm1
    mov r13, r12                # j
.Lbs_j:
    cmp r13, rbx
    jb .Lbs_put
    mov r14, r13
    sub r14, rbx
    imul rsi, r14, IT_SIZE
    add rsi, [rsp + 32]
    lea rdi, [rsp]
    call it_less
    test eax, eax
    jz .Lbs_put
    imul rax, r14, IT_SIZE
    add rax, [rsp + 32]
    imul rdx, r13, IT_SIZE
    add rdx, [rsp + 32]
    movups xmm0, [rax]
    movups xmm1, [rax + 16]
    movups [rdx], xmm0
    movups [rdx + 16], xmm1
    mov r13, r14
    jmp .Lbs_j
.Lbs_put:
    imul rdx, r13, IT_SIZE
    add rdx, [rsp + 32]
    movups xmm0, [rsp]
    movups xmm1, [rsp + 16]
    movups [rdx], xmm0
    movups [rdx + 16], xmm1
    inc r12
    jmp .Lbs_i
9:  EPILOGUE

# it_less(a, b) -> 1 if item a sorts before item b: folders first, then by name ignoring case
it_less:
    mov eax, [rdi + IT_data]
    and eax, BRW_DIR
    mov ecx, [rsi + IT_data]
    and ecx, BRW_DIR
    cmp eax, ecx
    je 1f
    seta al
    movzx eax, al
    ret
1:  mov rdi, [rdi + IT_label]
    mov rsi, [rsi + IT_label]
2:  movzx eax, byte ptr [rdi]
    movzx ecx, byte ptr [rsi]
    lea edx, [rax - 'A']
    cmp edx, 25
    ja 3f
    or eax, 0x20
3:  lea edx, [rcx - 'A']
    cmp edx, 25
    ja 4f
    or ecx, 0x20
4:  cmp eax, ecx
    jne 5f
    test eax, eax
    jz 6f
    inc rdi
    inc rsi
    jmp 2b
5:  setb al
    movzx eax, al
    ret
6:  xor eax, eax
    ret

# browse_complete(item): the field becomes the listed folder (written plainly) and the item's name;
# for a folder that goes into it
browse_complete:
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rip + brw_label]
    lea rsi, [rip + brw_dir]
    call path_tilde
    cmp byte ptr [rax - 1], '/'
    je 1f
    mov byte ptr [rax], '/'
    mov byte ptr [rax + 1], 0
1:  lea rdi, [rip + tmp]
    call sb_clear
    lea rdi, [rip + tmp]
    lea rsi, [rip + brw_label]
    call sb_push_cstr
    lea rdi, [rip + tmp]
    mov rsi, [rbx + IT_label]
    mov rdx, [rbx + IT_len]
    call sb_push
    lea rdi, [rip + pal_tf]
    mov rsi, [rip + tmp + SB_ptr]
    mov rdx, [rip + tmp + SB_len]
    call tf_set
    call palette_changed
    EPILOGUE

# pal_query() -> rax, rdx: what the items are matched against (the path browser: after the last '/')
pal_query:
    cmp dword ptr [rip + pal_mode], PM_BROWSE
    je 1f
    lea rdi, [rip + pal_tf]
    jmp tf_text
1:  call browse_split
    add rax, rdx
    sub rcx, rdx
    mov rdx, rcx
    ret

# palette_print(sb): the field, then the rows ("> " marks the selected one), or "none"
FN palette_print
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rip + pal_mode], PM_NONE
    jne 1f
    lea rsi, [rip + .Lpp_none]
    call sb_push_cstr
    EPILOGUE
1:  lea rsi, [rip + .Lpp_field]
    call sb_push_cstr
    lea rdi, [rip + pal_tf]
    call tf_text
    mov rdi, rbx
    mov rsi, rax
    call sb_push
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    xor r12d, r12d
2:  cmp r12, [rip + results + VEC_len]
    jae 9f
    cmp r12, 20
    jae 9f
    lea rsi, [rip + .Lpp_row]
    cmp r12d, [rip + pal_sel]
    jne 3f
    lea rsi, [rip + .Lpp_sel]
3:  mov rdi, rbx
    call sb_push_cstr
    mov rax, [rip + results + VEC_ptr]
    mov eax, [rax + r12*8 + RS_item]
    imul rax, rax, IT_SIZE
    add rax, [rip + items + VEC_ptr]
    mov rdi, rbx
    mov rsi, [rax + IT_label]
    mov rdx, [rax + IT_len]
    call sb_push
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    inc r12
    jmp 2b
9:  EPILOGUE

# ---- fuzzy matching ----

# fuzzy(label, len, query, qlen) -> score (-1 when not a subsequence)
FN fuzzy
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    test r15, r15
    jz .Lfz_empty
    xor ebx, ebx                # score
    xor ecx, ecx                # label index
    xor edx, edx                # query index
    mov dword ptr [rsp], -2     # last match index
    # the basename part starts after the last '/'
    mov r8, r13
1:  test r8, r8
    jz 2f
    cmp byte ptr [r12 + r8 - 1], '/'
    je 2f
    dec r8
    jmp 1b
2:  mov [rsp + 8], r8
.Lfz_loop:
    cmp rdx, r15
    jae .Lfz_done
    cmp rcx, r13
    jae .Lfz_fail
    movzx eax, byte ptr [r12 + rcx]
    movzx r9d, byte ptr [r14 + rdx]
    lea r10d, [rax - 'A']
    cmp r10d, 25
    ja 3f
    or eax, 0x20
3:  lea r10d, [r9 - 'A']
    cmp r10d, 25
    ja 4f
    or r9d, 0x20
4:  cmp eax, r9d
    jne .Lfz_next
    add ebx, 10
    # consecutive
    mov eax, [rsp]
    inc eax
    cmp eax, ecx
    jne 5f
    add ebx, 15
5:  # word start
    test rcx, rcx
    jz 6f
    movzx eax, byte ptr [r12 + rcx - 1]
    cmp al, '/'
    je 6f
    cmp al, '_'
    je 6f
    cmp al, '-'
    je 6f
    cmp al, '.'
    je 6f
    cmp al, ' '
    je 6f
    # camelCase hump
    movzx r10d, byte ptr [r12 + rcx]
    sub r10d, 'A'
    cmp r10d, 25
    ja 7f
    sub eax, 'a'
    cmp eax, 25
    ja 7f
6:  add ebx, 12
7:  cmp rcx, [rsp + 8]
    jb 8f
    add ebx, 6                  # inside the file name
8:  mov [rsp], ecx
    inc rdx
.Lfz_next:
    inc rcx
    jmp .Lfz_loop
.Lfz_done:
    # prefer shorter labels
    mov eax, 200
    sub eax, r13d
    sar eax, 3
    add ebx, eax
    # the query is a prefix of the label (or all of it)
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    mov rcx, r15
    cmp rsi, rcx
    jb 1f
    mov rsi, rcx
    call str_ieq
    test eax, eax
    jz 1f
    add ebx, 40
    cmp r13, r15
    jne 1f
    add ebx, 100
1:  mov eax, ebx
    EPILOGUE
.Lfz_fail:
    mov eax, -1
    EPILOGUE
.Lfz_empty:
    xor eax, eax
    EPILOGUE

# palette_filter(): results = items matching the query, best first
FN palette_filter
    PROLOGUE 16
    mov dword ptr [rip + pal_reveal], 1
    mov dword ptr [rip + pal_wheel], 0
    mov qword ptr [rip + results + VEC_len], 0
    cmp dword ptr [rip + pal_mode], PM_BROWSE
    jne .Lpf_grep
    call browse_filter
    jmp 5f
.Lpf_grep:
    cmp dword ptr [rip + pal_mode], PM_GREP
    jne 0f
    call grep_run
    jmp 5f
0:  cmp dword ptr [rip + pal_mode], PM_GOTO
    je 9f
    cmp dword ptr [rip + pal_mode], PM_PROMPT
    je 9f
    lea rdi, [rip + pal_tf]
    call tf_text
    mov r14, rax
    mov r15, rdx
    xor ebx, ebx
1:  cmp rbx, [rip + items + VEC_len]
    jae 45f
    imul r12, rbx, IT_SIZE
    add r12, [rip + items + VEC_ptr]
    mov rdi, [r12 + IT_label]
    mov rsi, [r12 + IT_len]
    mov rdx, r14
    mov rcx, r15
    call fuzzy
    test eax, eax
    js 4f
    mov r13d, eax
    lea rdi, [rip + results]
    mov esi, RS_SIZE
    call vec_push
    mov [rax + RS_item], ebx
    mov [rax + RS_score], r13d
4:  inc rbx
    jmp 1b
45: # best score first, ties in item order: sort (~score << 32 | item) ascending
    test r15, r15
    jz 5f
    mov rdi, [rip + results + VEC_ptr]
    mov rsi, [rip + results + VEC_len]
    call rs_flip
    mov rdi, [rip + results + VEC_ptr]
    mov rsi, [rip + results + VEC_len]
    call sort_u64
    mov rdi, [rip + results + VEC_ptr]
    mov rsi, [rip + results + VEC_len]
    call rs_flip
5:  # keep selection in range
    mov eax, [rip + pal_sel]
    mov rcx, [rip + results + VEC_len]
    cmp rax, rcx
    jb 9f
    xor eax, eax
    mov [rip + pal_sel], eax
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# rs_flip(ptr, n): complement the scores of RS records (their high halves)
rs_flip:
    mov rax, 0xffffffff00000000
1:  test rsi, rsi
    jz 2f
    xor [rdi], rax
    add rdi, 8
    dec rsi
    jmp 1b
2:  ret

FN palette_changed
    cmp dword ptr [rip + pal_mode], PM_THEMES
    je 1f
    mov dword ptr [rip + pal_sel], 0
    mov dword ptr [rip + pal_scroll], 0
1:  # '>' switches files -> commands
    cmp dword ptr [rip + pal_mode], PM_FILES
    jne 2f
    mov rax, [rip + pal_tf + TF_sb + SB_ptr]
    test rax, rax
    jz 2f
    cmp byte ptr [rax], '>'
    jne 3f
    push rbx
    call cmd_command_palette
    pop rbx
    ret
3:  cmp byte ptr [rax], ':'
    jne 2f
    cmp qword ptr [rip + g_doc], 0
    je 2f
    mov dword ptr [rip + pal_mode], PM_GOTO
    lea rdi, [rip + pal_tf]
    lea rsi, [rax + 1]
    mov rdx, [rip + pal_tf + TF_sb + SB_len]
    dec rdx
    call tf_set
2:  jmp palette_filter

# selected item -> IT* or 0
selected_item:
    mov eax, [rip + pal_sel]
    cmp rax, [rip + results + VEC_len]
    jae 1f
    mov rcx, [rip + results + VEC_ptr]
    mov eax, [rcx + rax*8 + RS_item]
    imul rax, rax, IT_SIZE
    add rax, [rip + items + VEC_ptr]
    ret
1:  xor eax, eax
    ret

# preview selection (themes)
preview:
    cmp dword ptr [rip + pal_mode], PM_THEMES
    jne 1f
    call selected_item
    test rax, rax
    jz 1f
    mov rdi, [rax + IT_data]
    cmp rdi, [rip + g_theme_cur]
    je 1f
    jmp theme_apply
1:  ret

# palette_key(keysym, cp, mods) -> 1 if handled
FN palette_key
    PROLOGUE 16
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov [rip + pal_mods], edx
    cmp r12d, KEY_ESCAPE
    jne 1f
    call palette_close
    jmp .Lpk_yes
1:  cmp r12d, KEY_UP
    jne 2f
    mov dword ptr [rip + pal_reveal], 1
    mov dword ptr [rip + pal_wheel], 0
    mov eax, [rip + pal_sel]
    test eax, eax
    jz .Lpk_yes
    dec dword ptr [rip + pal_sel]
    call preview
    jmp .Lpk_yes
2:  cmp r12d, KEY_DOWN
    jne 3f
    mov dword ptr [rip + pal_reveal], 1
    mov dword ptr [rip + pal_wheel], 0
    mov eax, [rip + pal_sel]
    inc eax
    cmp rax, [rip + results + VEC_len]
    jae .Lpk_yes
    mov [rip + pal_sel], eax
    call preview
    jmp .Lpk_yes
3:  cmp r12d, KEY_PAGEDOWN
    jne 31f
    mov dword ptr [rip + pal_reveal], 1
    mov dword ptr [rip + pal_wheel], 0
    mov eax, [rip + pal_sel]
    add eax, 10
    mov rcx, [rip + results + VEC_len]
    dec ecx
    cmp eax, ecx
    cmovg eax, ecx
    test eax, eax
    jns 32f
    xor eax, eax
32: mov [rip + pal_sel], eax
    call preview
    jmp .Lpk_yes
31: cmp r12d, KEY_PAGEUP
    jne 33f
    mov dword ptr [rip + pal_reveal], 1
    mov dword ptr [rip + pal_wheel], 0
    mov eax, [rip + pal_sel]
    sub eax, 10
    jns 34f
    xor eax, eax
34: mov [rip + pal_sel], eax
    call preview
    jmp .Lpk_yes
33: cmp r12d, KEY_RETURN
    je 4f
    cmp r12d, KEY_KP_ENTER
    jne 5f
4:  call palette_accept
    jmp .Lpk_yes
5:  # text editing keys go to the field
    mov edi, r12d
    cmp edi, KEY_TAB
    jne 51f
    # the path browser: Tab takes the selected name
    cmp dword ptr [rip + pal_mode], PM_BROWSE
    jne .Lpk_no
    call selected_item
    test rax, rax
    jz .Lpk_yes
    test qword ptr [rax + IT_data], BRW_HERE
    jnz .Lpk_yes
    mov rdi, rax
    call browse_complete
    jmp .Lpk_yes
51:
    lea rdi, [rip + pal_tf]
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    call tf_key
    test eax, eax
    jz .Lpk_no
    # ctrl+c / ctrl+a etc. don't change text; filtering is cheap anyway
    call palette_changed
    jmp .Lpk_yes
.Lpk_no:
    xor eax, eax
    EPILOGUE
.Lpk_yes:
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE

# palette_accept(): act on the selection / input
palette_accept:
    PROLOGUE 16
    mov ebx, [rip + pal_mode]
    cmp ebx, PM_GOTO
    je .Lpa_goto
    cmp ebx, PM_PROMPT
    je .Lpa_prompt
    cmp ebx, PM_BROWSE
    je .Lpa_browse
    call selected_item
    test rax, rax
    jz .Lpa_close
    mov r12, rax
    cmp ebx, PM_GREP
    je .Lpa_grep
    cmp ebx, PM_FILES
    jne 1f
    mov rdi, [rip + g_project]
    mov rsi, [r12 + IT_label]
    call path_join
    mov r13, rax
    mov dword ptr [rip + pal_mode], PM_NONE
    mov dword ptr [rip + g_focus], FOCUS_EDITOR
    mov rdi, r13
    call app_open_file
    mov rdi, r13
    call mem_free
    jmp .Lpa_ret
1:  cmp ebx, PM_COMMANDS
    jne 2f
    mov dword ptr [rip + pal_mode], PM_NONE
    mov dword ptr [rip + g_focus], FOCUS_EDITOR
    mov rax, [r12 + IT_data]
    call [rax + CMD_fn]
    jmp .Lpa_ret
2:  cmp ebx, PM_THEMES
    jne 3f
    mov rdi, [r12 + IT_data]
    call theme_apply
    call theme_current_id
    mov [rip + cfg_theme], rax
    mov dword ptr [rip + g_settings_changed], 1
    mov rax, [rip + g_theme_cur]
    mov [rip + pal_theme_before], rax
    jmp .Lpa_close
3:  cmp ebx, PM_LANGS
    jne .Lpa_close
    cmp qword ptr [rip + g_doc], 0
    je .Lpa_close
    mov rdi, [r12 + IT_data]
    call syntax_ready
    mov rcx, [rip + g_doc]
    mov [rcx + DOC_lang], rax
    mov qword ptr [rcx + DOC_svalid], 0
    jmp .Lpa_close
.Lpa_goto:
    lea rdi, [rip + pal_tf]
    call tf_text
    mov rdi, rax
    mov rsi, rdx
    call parse_u64
    test rdx, rdx
    jz .Lpa_close
    mov rbx, [rip + g_doc]
    test rbx, rbx
    jz .Lpa_close
    dec rax
    jns 4f
    xor eax, eax
4:  cmp rax, [rbx + DOC_nlines]
    jb 5f
    mov rax, [rbx + DOC_nlines]
    dec rax
5:  mov rdi, rbx
    mov rsi, rax
    call doc_line_start
    mov rdi, rbx
    mov rsi, rax
    xor edx, edx
    call ed_set_cursor
    # center it
    mov rdi, rbx
    mov rsi, [rbx + DOC_cur]
    call doc_line_of
    mov ecx, [rip + g_ed_h_lines]
    shr ecx, 1
    sub rax, rcx
    jns 6f
    xor eax, eax
6:  shl rax, 8
    mov [rbx + DOC_scrolly], rax
    mov dword ptr [rip + g_reveal], 0
    jmp .Lpa_close
.Lpa_prompt:
    lea rdi, [rip + pal_tf]
    call tf_text
    test rdx, rdx
    jz .Lpa_close
    cmp dword ptr [rip + pal_prompt], PROMPT_DELETE
    jne 70f
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + .Lyes]
    call str_eq_cstr
    test eax, eax
    jz .Lpa_close
    mov dword ptr [rip + pal_mode], PM_NONE
    mov dword ptr [rip + g_focus], FOCUS_EDITOR
    call explorer_delete_target
    jmp .Lpa_ret
70:
    # absolute path: relative input is taken from the project root
.ifdef WINDOWS
    mov rdi, rax
    call win_slashes
.endif
    lea rdi, [rip + pal_path]
    PATH_ABSOLUTE rax, 7f
    cmp byte ptr [rax], '~'
    jne 71f
    push rax
    push rdx
    lea rdi, [rip + .Lhome]
    call getenv
    mov rsi, rax
    lea rdi, [rip + pal_path]
    call cstr_copy
    mov rdi, rax
    pop rdx
    pop rax
    inc rax
    dec rdx
    jmp 7f
71: mov rsi, [rip + g_project]
    test rsi, rsi
    jz 7f
    push rax
    push rdx
    call cstr_copy
    mov byte ptr [rax], '/'
    lea rdi, [rax + 1]
    pop rdx
    pop rax
7:  mov rsi, rax
    mov rcx, rdx
    cmp rcx, 3000
    jbe 72f
    mov ecx, 3000
72: rep movsb
    mov byte ptr [rdi], 0
.ifdef WINDOWS
    lea rdi, [rip + pal_path]
    call path_normalize
.endif
    mov ebx, [rip + pal_prompt]
    mov dword ptr [rip + pal_mode], PM_NONE
    mov dword ptr [rip + g_focus], FOCUS_EDITOR
    lea rdi, [rip + pal_path]
    mov esi, ebx
    call prompt_done
    jmp .Lpa_ret
.Lpa_grep:
    # open the file and select the match
    mov r13, [r12 + IT_data]
    mov rax, r13
    shr rax, 44
    imul rax, rax, GF_SIZE
    add rax, [rip + gfiles + VEC_ptr]
    mov rdi, [rip + g_project]
    mov rsi, [rax + GF_label]
    call path_join
    mov r14, rax
    call grep_release
    mov dword ptr [rip + pal_mode], PM_NONE
    mov dword ptr [rip + g_focus], FOCUS_EDITOR
    mov rdi, r14
    call app_open_file
    mov rdi, r14
    call mem_free
    mov rbx, [rip + g_doc]
    test rbx, rbx
    jz .Lpa_ret
    mov rsi, r13
    shr rsi, 20
    and esi, 0xffffff
    mov rax, [rbx + DOC_nlines]
    dec rax
    cmp rsi, rax
    cmova rsi, rax
    mov [rsp], rsi              # line
    mov rdi, rbx
    call doc_line_start
    mov r14, rax
    mov rdi, rbx
    mov rsi, [rsp]
    call doc_line_end
    mov r15, rax
    mov eax, r13d
    and eax, 0xfffff
    add rax, r14
    cmp rax, r15
    cmova rax, r15
    mov r14, rax
    mov rdi, rbx
    mov rsi, rax
    xor edx, edx
    call ed_set_cursor
    lea rdi, [rip + pal_tf]
    call tf_text
    lea rsi, [r14 + rdx]
    cmp rsi, r15
    cmova rsi, r15
    mov rdi, rbx
    mov edx, 1
    call ed_set_cursor
    mov rax, [rsp]
    mov ecx, [rip + g_ed_h_lines]
    shr ecx, 1
    sub rax, rcx
    jns 1f
    xor eax, eax
1:  shl rax, 8
    mov [rbx + DOC_scrolly], rax
    mov dword ptr [rip + g_reveal], 1
    jmp .Lpa_ret
.Lpa_browse:
    call selected_item
    test rax, rax
    jz .Lpa_ret
    mov r12, rax
    mov rax, [r12 + IT_data]
    test eax, BRW_HERE
    jnz .Lpa_here
    test eax, BRW_DIR
    jz .Lpa_file
    # a folder: the browser goes into it; picking a folder, Ctrl+Enter opens it
    cmp dword ptr [rip + brw_kind], 0
    je 1f
    test dword ptr [rip + pal_mods], MOD_CTRL
    jnz 2f
1:  mov rdi, r12
    call browse_complete
    jmp .Lpa_ret
2:  lea rdi, [rip + brw_dir]
    mov rsi, [r12 + IT_label]
    call path_join_tmp
    lea rdi, [rip + brw_next]
    mov rsi, rax
    call cstr_copy
    lea rdi, [rip + brw_next]
    call path_normalize
    jmp .Lpa_switch
.Lpa_here:
    lea rdi, [rip + brw_next]
    lea rsi, [rip + brw_dir]
    call cstr_copy
.Lpa_switch:
    call palette_close
    lea rdi, [rip + brw_next]
    call app_switch_project
    jmp .Lpa_ret
.Lpa_file:
    lea rdi, [rip + brw_dir]
    mov rsi, [r12 + IT_label]
    call path_join
    mov r13, rax
    call palette_close
    mov rdi, r13
    call app_open_path
    mov rdi, r13
    call mem_free
    jmp .Lpa_ret
.Lpa_close:
    call palette_close
.Lpa_ret:
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# prompt_done(path, kind)
prompt_done:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    cmp r12d, PROMPT_SAVE_AS
    jne 1f
    mov r13, [rip + g_doc]
    test r13, r13
    jz 9f
    mov rdi, r13
    mov rsi, rbx
    call doc_set_path
    mov rdi, rbx
    call mkdir_parent
    mov rdi, r13
    call doc_save
    test rax, rax
    js 8f
    mov rdi, r13
    call app_detect_lang
    mov rdi, r13
    call app_after_save
    call app_update_title
    jmp 9f
1:  cmp r12d, PROMPT_NEW_FILE
    jne 2f
    # create the file (and its folders) if missing, then open it
    mov rdi, rbx
    call file_mtime
    test rax, rax
    jnz 11f
    mov rdi, rbx
    call mkdir_parent
    mov rdi, rbx
    lea rsi, [rip + .Lempty]
    xor edx, edx
    call file_write_all
11: mov rdi, rbx
    call app_open_file
    call explorer_refresh
    jmp 9f
2:  cmp r12d, PROMPT_NEW_FOLDER
    jne 3f
    mov rdi, rbx
    call mkdir_p
    call explorer_refresh
    jmp 9f
3:  cmp r12d, PROMPT_RENAME
    jne 4f
    lea rdi, [rip + g_explorer_target]
    mov rsi, rbx
    SYS SYS_rename
    test rax, rax
    js 8f
    # retarget an open tab
    lea rdi, [rip + g_explorer_target]
    call app_find_tab
    test rax, rax
    js 31f
    mov rdi, rax
    call tab_at
    mov rdi, [rax + TAB_doc]
    mov rsi, rbx
    call doc_set_path
    call app_update_title
31: call explorer_refresh
    jmp 9f
4:  cmp r12d, PROMPT_DELETE
    jne 9f
    # the prompt text must be "yes"
    call explorer_delete_target
    jmp 9f
8:  lea rdi, [rip + .Lfailed]
    call app_toast
9:  EPILOGUE

# ---- drawing ----

FN palette_draw
    PROLOGUE 64
    cmp dword ptr [rip + pal_mode], PM_NONE
    je .Lpd_ret
    # scrim + card
    xor edi, edi
    xor esi, esi
    mov edx, [rip + g_cv + CV_w]
    mov ecx, [rip + g_cv + CV_h]
    mov r8d, 0x30000000
    call gfx_fill
    mov edi, 640
    cmp dword ptr [rip + pal_mode], PM_GREP
    jne 0f
    mov edi, 820
0:  call sc
    mov ecx, [rip + g_cv + CV_w]
    sub ecx, [rip + g_mt + 4*MI_64]
    cmp eax, ecx
    cmovg eax, ecx
    mov r12d, eax               # w
    mov eax, [rip + g_cv + CV_w]
    sub eax, r12d
    sar eax, 1
    mov r13d, eax               # x
    M r14d, MI_TITLE
    add r14d, [rip + g_mt + 4*MI_8]   # y
    M ebx, MI_32                # row height
    # visible rows
    mov rax, [rip + results + VEC_len]
    cmp rax, 12
    jbe 1f
    mov eax, 12
1:  mov [rsp], eax              # rows shown
    mov eax, [rsp]
    imul eax, ebx
    M ecx, MI_48
    add eax, ecx
    cmp dword ptr [rsp], 0
    je 2f
    add eax, [rip + g_mt + 4*MI_12]
2:  cmp dword ptr [rip + pal_mode], PM_PROMPT
    je 21f
    cmp dword ptr [rip + pal_mode], PM_GOTO
    je 21f
    cmp dword ptr [rip + pal_mode], PM_GREP
    je 20f
    cmp dword ptr [rip + pal_mode], PM_BROWSE
    jne 22f
20: cmp dword ptr [rsp], 0
    jne 22f
21: add eax, [rip + g_mt + 4*MI_20]
22: mov [rsp + 4], eax          # card h
    mov edi, r13d
    mov esi, r14d
    mov edx, r12d
    mov ecx, eax
    call ui_card
    # click outside closes
    test dword ptr [rip + g_pressed], 1 << BTN_LEFT
    jz 3f
    mov edi, r13d
    mov esi, r14d
    mov edx, r12d
    mov ecx, [rsp + 4]
    call ui_in
    test eax, eax
    jnz 3f
    call palette_close
    jmp .Lpd_ret
3:  # input field
    call placeholder_text
    mov r10, rax
    M eax, MI_8
    mov [rsp + 8], eax
    lea rdi, [rip + pal_tf]
    lea esi, [r13 + rax]
    lea edx, [r14 + rax]
    mov ecx, r12d
    sub ecx, eax
    sub ecx, eax
    M r8d, MI_32
    mov r9d, 1
    push r10
    push r10
    call ui_textfield
    add rsp, 16
    # hint under the field for prompts / goto
    M r15d, MI_48
    add r15d, r14d
    mov eax, [rip + pal_mode]
    cmp eax, PM_PROMPT
    je 4f
    cmp eax, PM_GOTO
    je 4f
    cmp eax, PM_GREP
    je 41f
    cmp eax, PM_BROWSE
    jne 5f
41: cmp qword ptr [rip + results + VEC_len], 0
    jne 5f
4:  lea rdi, [rip + g_face_small]
    mov esi, r13d
    add esi, [rip + g_mt + 4*MI_16]
    mov edx, r15d
    sub edx, [rip + g_mt + 4*MI_4]
    M ecx, MI_20
    call hint_text
    mov r8, rax
    COLOR r9d, T_UI_MUTED
    call ui_text_c
    jmp .Lpd_ret
5:  # Mouse scrolling owns the viewport until selection changes explicitly.
    cmp dword ptr [rip + pal_reveal], 0
    je .Lpd_wheel
    mov dword ptr [rip + pal_reveal], 0
    mov eax, [rip + pal_sel]
    cmp eax, [rip + pal_scroll]
    jge 6f
    mov [rip + pal_scroll], eax
6:  mov ecx, [rip + pal_scroll]
    add ecx, [rsp]
    cmp eax, ecx
    jl 7f
    sub eax, [rsp]
    inc eax
    mov [rip + pal_scroll], eax
7:
.Lpd_wheel:
    movsxd rax, dword ptr [rip + g_scroll_y]
    test rax, rax
    jz .Lpd_clamp
    movsxd rdx, dword ptr [rip + pal_wheel]
    add rax, rdx
    cqo
    idiv rbx
    mov [rip + pal_wheel], edx
    add [rip + pal_scroll], eax
.Lpd_clamp:
    # Clamp on every frame, including after filtering shrinks the result list.
    mov eax, [rip + pal_scroll]
    mov rcx, [rip + results + VEC_len]
    sub ecx, [rsp]
    cmp eax, ecx
    jle .Lpd_top
    mov eax, ecx
    mov dword ptr [rip + pal_wheel], 0
.Lpd_top:
    test eax, eax
    jns .Lpd_edge_remainder
    xor eax, eax
    mov dword ptr [rip + pal_wheel], 0
.Lpd_edge_remainder:
    # Do not retain outward wheel motion at an edge: reversing responds at once.
    test eax, eax
    jnz .Lpd_bottom_remainder
    cmp dword ptr [rip + pal_wheel], 0
    jge .Lpd_bottom_remainder
    mov dword ptr [rip + pal_wheel], 0
.Lpd_bottom_remainder:
    cmp eax, ecx
    jne .Lpd_scroll_ready
    cmp dword ptr [rip + pal_wheel], 0
    jle .Lpd_scroll_ready
    mov dword ptr [rip + pal_wheel], 0
.Lpd_scroll_ready:
    mov [rip + pal_scroll], eax
    xor ecx, ecx
    mov [rsp + 12], ecx         # row i
.Lpd_row:
    mov ecx, [rsp + 12]
    cmp ecx, [rsp]
    jae .Lpd_ret
    mov eax, [rip + pal_scroll]
    add eax, ecx
    mov [rsp + 16], eax         # result index
    mov rdx, [rip + results + VEC_ptr]
    mov eax, [rdx + rax*8 + RS_item]
    imul rax, rax, IT_SIZE
    add rax, [rip + items + VEC_ptr]
    mov [rsp + 24], rax         # item
    mov eax, ecx
    imul eax, ebx
    add eax, r15d
    mov [rsp + 20], eax         # row y
    lea edi, [rcx + ID_PAL_ROW]
    M eax, MI_6
    lea esi, [r13 + rax]
    mov edx, [rsp + 20]
    mov ecx, r12d
    sub ecx, eax
    sub ecx, eax
    mov r8d, ebx
    call ui_btn
    mov [rsp + 32], eax
    test eax, UB_HOVER
    jz 8f
    # mouse moved over a row selects it (only on real movement / press)
    test eax, UB_PRESS
    jz 8f
    mov eax, [rsp + 16]
    mov [rip + pal_sel], eax
    call preview
8:  mov eax, [rsp + 16]
    cmp eax, [rip + pal_sel]
    jne 9f
    M eax, MI_6
    lea edi, [r13 + rax]
    mov esi, [rsp + 20]
    mov edx, r12d
    sub edx, eax
    sub edx, eax
    mov ecx, ebx
    M r8d, MI_RADIUS
    COLOR r9d, T_ACTIVE
    call gfx_round_rect
    jmp 10f
9:  test dword ptr [rsp + 32], UB_HOVER
    jz 10f
    M eax, MI_6
    lea edi, [r13 + rax]
    mov esi, [rsp + 20]
    mov edx, r12d
    sub edx, eax
    sub edx, eax
    mov ecx, ebx
    M r8d, MI_RADIUS
    COLOR r9d, T_HOVER
    call gfx_round_rect
10: # detail width
    mov dword ptr [rsp + 56], 0
    mov rax, [rsp + 24]
    mov rdi, [rax + IT_detail]
    test rdi, rdi
    jz 101f
    mov [rsp + 40], rdi
    call strlen
    mov [rsp + 48], rax
    lea rdi, [rip + g_face_small]
    mov rsi, [rsp + 40]
    mov rdx, rax
    call text_width
    add eax, [rip + g_mt + 4*MI_16]
    mov [rsp + 56], eax
101: # label with matched characters highlighted, clipped before the detail; not the path
    # browser's "Open <folder>"
    mov rax, [rsp + 24]
    xor ecx, ecx
    cmp dword ptr [rip + pal_mode], PM_BROWSE
    jne 102f
    test qword ptr [rax + IT_data], BRW_HERE
    setnz cl
102:mov [rip + pal_nohl], ecx
    M eax, MI_16
    lea edi, [r13 + rax]
    mov esi, [rsp + 20]
    mov edx, r12d
    sub edx, eax
    sub edx, eax
    sub edx, [rsp + 56]
    mov ecx, ebx
    call gfx_clip_push
    mov rax, [rsp + 24]
    mov rdi, [rax + IT_label]
    mov rsi, [rax + IT_len]
    M edx, MI_16
    add edx, r13d
    mov ecx, [rsp + 20]
    mov r8d, ebx
    call draw_highlighted
    call gfx_clip_pop
    # detail on the right
    cmp dword ptr [rsp + 56], 0
    je 11f
    mov esi, r13d
    add esi, r12d
    sub esi, [rsp + 56]
    lea rdi, [rip + g_face_small]
    mov edx, [rsp + 20]
    mov ecx, ebx
    mov r8, [rsp + 40]
    mov r9, [rsp + 48]
    COLOR eax, T_UI_MUTED
    push rax
    push rax
    call ui_text_v
    add rsp, 16
11: test dword ptr [rsp + 32], UB_CLICK
    jz 12f
    mov eax, [rsp + 16]
    mov [rip + pal_sel], eax
    mov dword ptr [rip + pal_mods], 0
    call palette_accept
    jmp .Lpd_ret
12: inc dword ptr [rsp + 12]
    jmp .Lpd_row
.Lpd_ret:
    EPILOGUE

# draw_highlighted(label, len, x, y, h): label with query characters in accent
draw_highlighted:
    PROLOGUE 64
    mov r12, rdi
    mov r13, rsi
    mov r14d, edx               # x
    mov [rsp], ecx              # y
    mov [rsp + 4], r8d          # h
    call pal_query
    mov [rsp + 8], rax          # query
    mov [rsp + 16], rdx
    cmp dword ptr [rip + pal_nohl], 0
    je .Ldh_query
    mov qword ptr [rsp + 16], 0
.Ldh_query:
    lea rax, [rip + g_face_ui]
    mov [rsp + 48], rax         # face
    mov qword ptr [rsp + 40], -1
    cmp dword ptr [rip + pal_mode], PM_GREP
    jne 0f
    # find in files: code font, the literal match highlighted
    lea rax, [rip + g_face_code]
    mov [rsp + 48], rax
    mov rdi, r12
    mov rsi, r13
    mov rdx, [rsp + 8]
    mov rcx, [rsp + 16]
    cmp dword ptr [rip + grep_case], 0
    je 7f
    call str_find
    jmp 8f
7:  call str_ifind
8:  mov [rsp + 40], rax
0:  mov rcx, [rsp + 48]
    mov eax, [rsp + 4]
    sub eax, [rcx + FACE_ascent]
    sub eax, [rcx + FACE_descent]
    sar eax, 1
    add eax, [rsp]
    add eax, [rcx + FACE_ascent]
    mov [rsp + 24], eax         # baseline
    xor ebx, ebx                # label index
    xor r15d, r15d              # query index
1:  cmp rbx, r13
    jae 9f
    lea rdi, [r12 + rbx]
    mov rsi, r13
    sub rsi, rbx
    call utf8_decode
    mov [rsp + 32], edx
    COLOR r9d, T_UI_FG
    cmp dword ptr [rip + pal_mode], PM_GREP
    jne 3f
    mov rax, [rsp + 40]
    cmp rbx, rax
    jb 2f
    add rax, [rsp + 16]
    cmp rbx, rax
    jae 2f
    COLOR r9d, T_ACCENT
    jmp 2f
3:  cmp r15, [rsp + 16]
    jae 2f
    mov rcx, [rsp + 8]
    movzx ecx, byte ptr [rcx + r15]
    movzx edx, byte ptr [r12 + rbx]
    mov edi, ecx
    push rdx
    call to_lower
    pop rdi
    mov ecx, eax
    push rcx
    call to_lower
    pop rcx
    cmp eax, ecx
    jne 2f
    inc r15
    COLOR r9d, T_ACCENT
2:  mov rdi, [rsp + 48]
    mov esi, r14d
    mov edx, [rsp + 24]
    lea rcx, [r12 + rbx]
    mov r8d, [rsp + 32]
    call text_draw
    mov r14d, eax
    mov eax, [rsp + 32]
    add rbx, rax
    jmp 1b
9:  EPILOGUE

placeholder_text:
    mov eax, [rip + pal_mode]
    lea rcx, [rip + .Lph_files]
    cmp eax, PM_FILES
    je 1f
    lea rcx, [rip + .Lph_cmds]
    cmp eax, PM_COMMANDS
    je 1f
    lea rcx, [rip + .Lph_themes]
    cmp eax, PM_THEMES
    je 1f
    lea rcx, [rip + .Lph_langs]
    cmp eax, PM_LANGS
    je 1f
    lea rcx, [rip + .Lph_goto]
    cmp eax, PM_GOTO
    je 1f
    lea rcx, [rip + .Lph_grep]
    cmp eax, PM_GREP
    je 1f
    mov rcx, [rip + pal_label]
1:  mov rax, rcx
    ret

hint_text:
    lea rax, [rip + .Lhint_nomatch]
    cmp dword ptr [rip + pal_mode], PM_BROWSE
    je 1f
    cmp dword ptr [rip + pal_mode], PM_GREP
    jne 2f
    lea rax, [rip + .Lhint_grep]
    cmp qword ptr [rip + pal_tf + TF_sb + SB_len], 2
    jb 1f
    lea rax, [rip + .Lhint_nomatch]
    ret
2:  lea rax, [rip + .Lhint_goto]
    cmp dword ptr [rip + pal_mode], PM_GOTO
    je 1f
    lea rax, [rip + .Lhint_path]
    cmp dword ptr [rip + pal_prompt], PROMPT_DELETE
    jne 1f
    lea rax, [rip + .Lhint_delete]
1:  ret

.section .rodata
.Lhome: .asciz "HOME"
.Lyes: .asciz "yes"
.Ldark: .asciz "dark"
.Llight: .asciz "light"
.Lplain: .asciz "Plain Text"
.Lempty: .asciz ""
.Lfailed: .asciz "That didn't work"
.Lph_files: .asciz "Search files by name  (> commands, : line)"
.Lph_cmds: .asciz "Type a command"
.Lph_themes: .asciz "Select a color theme"
.Lph_langs: .asciz "Select a language"
.Lph_goto: .asciz "Line number"
.Lph_grep: .asciz "Search in files"
.Lhint_grep: .asciz "Case-insensitive unless the text has capitals"
.Lhint_nomatch: .asciz "No matches"
.Lnl: .ascii "\n"
.Lhint_goto: .asciz "Enter a line number and press Enter"
.Lhint_path: .asciz "Enter a path and press Enter, Esc to cancel"
.Lhint_delete: .asciz "Type yes and press Enter to delete"
.Lph_open_file: .asciz "Open a file"
.Lph_open_folder: .asciz "Open a folder"
.Lopen_here: .asciz "Open "
.Lroot: .asciz "/"
.Lpp_none: .asciz "none\n"
.Lpp_field: .asciz "field="
.Lpp_row: .asciz "  "
.Lpp_sel: .asciz "> "
.bss
.p2align 3
keys_cache: .zero 8 * 256
.globl g_ed_h_lines
g_ed_h_lines: .long 0
