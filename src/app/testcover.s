# testing: the coverage of the last coverage run (test-coverage). Per file, a byte per line: bit 0
# "some range hit it", bit 1 "some range missed it"; both is partly covered (Go blocks that share a
# line). The first message of a new coverage run replaces what an older run left.
.include "rhun.inc"

# a file's coverage
STRUCT
F CF_path, 8            # owned cstr
F CF_lines, 8           # owned bytes, CF_n of them: line L at index L - 1
F CF_n, 8
F CF_ver, 8             # the version of the file's open document when its first range came, -1 none
ENDSTRUCT CF_SIZE
# a path of the message being checked, once
STRUCT
F CK_path, 8            # in the body
F CK_len, 8
F CK_max, 8             # its highest line in the message
F CK_hash, 8
ENDSTRUCT CK_SIZE
.equ COV_HIT, 1
.equ COV_MISS, 2
.equ COV_SPAN_MSG, 4194304      # lines one message may mark, all its ranges together
.equ TS_COVER_BYTES, 67108864   # line bytes all files of a run may hold (64 MiB)

.bss
.p2align 3
.globl g_cov_run, g_cov_on
files: .zero VEC_SIZE           # CF records
g_cov_run: .quad 0              # the run they are from, 0 for none
ranges: .quad 0                 # ranges taken from that run so far
cov_bytes: .quad 0              # line bytes the files hold
map: .quad 0                    # path index: u32 slots holding a file's index + 1, 0 empty
mapcap: .quad 0
apply: .long 0                  # 0 checking a body, 1 applying it
cnt: .zero 16
.p2align 3
ck_ents: .zero VEC_SIZE         # CK records of the message being checked
ck_tab: .quad 0                 # path hash -> u32 index + 1 into ck_ents, 0 empty
ck_cap: .quad 0

.data
.p2align 2
g_cov_on: .long 1               # tints show (Show Test Coverage toggles)

.text

# testcover_apply(run, body, len) -> rax 0 when applied, else the error text: "N" LF, then N files
#   "PATH_LEN M" LF PATH and M records "L1 L2 COUNT" LF (lines one-based, inclusive). The whole body
#   is checked first, the files and line bytes it would add counted against the caps
FN testcover_apply
    PROLOGUE 80
    mov rbx, rdi
    mov [rsp], rsi
    mov [rsp + 8], rdx
    mov dword ptr [rip + apply], 0
    xor eax, eax                # does it add to what the store holds (the same run)?
    mov rcx, [rbx + TSR_num]
    cmp rcx, [rip + g_cov_run]
    sete al
    mov [rsp + 56], rax
.Ltc_pass:
    mov rdi, [rsp]
    mov rsi, [rsp + 8]
    call tsb_begin
    call tsb_line
    test rax, rax
    jz .Ltc_syntax
    mov rdi, rax
    mov rsi, rdx
    call tsb_fields
    cmp eax, 1
    jne .Ltc_syntax
    xor edi, edi
    call tsb_num
    test edx, edx
    jz .Ltc_syntax
    cmp rax, TS_COVER_FILES
    ja .Ltc_toobig
    mov r12, rax                # files
    xor r15d, r15d              # lines marked
    mov qword ptr [rsp + 32], 0 # ranges in this message
    mov qword ptr [rsp + 64], 0 # files it adds
    mov qword ptr [rsp + 72], 0 # line bytes it adds
    cmp dword ptr [rip + apply], 0
    jne 11f
    mov rdi, r12                # checking: this message's paths, each once (a path may repeat)
    call ck_begin
    jmp 1f
11:
    cmp qword ptr [rsp + 56], 0
    jne 1f
    call testcover_clear        # a new run's data replaces the old
    mov rax, [rbx + TSR_num]
    mov [rip + g_cov_run], rax
1:  test r12, r12
    jz 6f
    dec r12
    call tsb_line
    test rax, rax
    jz .Ltc_syntax
    mov rdi, rax
    mov rsi, rdx
    call tsb_fields
    cmp eax, 2
    jne .Ltc_syntax
    xor edi, edi
    call tsb_num
    test edx, edx
    jz .Ltc_syntax
    test rax, rax
    jz .Ltc_syntax
    cmp rax, 4095
    ja .Ltc_syntax
    mov r13, rax                # path length
    mov edi, 1
    call tsb_num
    test edx, edx
    jz .Ltc_syntax
    cmp rax, TS_COVER_RANGES
    ja .Ltc_toobig
    mov r14, rax                # records
    mov rdi, r13
    call tsb_take
    test rax, rax
    jz .Ltc_syntax
    mov [rsp + 16], rax
    mov [rsp + 40], r13
    mov rdi, rax
    mov rsi, r13
    call tsb_oneline
    test eax, eax
    jz .Ltc_syntax
    mov rax, [rsp + 16]
    cmp byte ptr [rax], '/'
    je 2f
    cmp r13, 3                  # C:/ on Windows
    jb .Ltc_syntax
    cmp byte ptr [rax + 1], ':'
    jne .Ltc_syntax
2:  add [rsp + 32], r14
    mov qword ptr [rsp + 24], 0 # the file (applying), or its existing record (checking)
    mov qword ptr [rsp + 48], 0 # its highest line (checking)
    cmp qword ptr [rsp + 56], 0
    je 21f
    mov rdi, [rsp + 16]
    mov rsi, r13
    call file_find
    mov [rsp + 24], rax
21: cmp dword ptr [rip + apply], 0
    je 3f
    add [rip + ranges], r14
    mov rdi, [rsp + 16]
    mov rsi, r13
    call file_for
    test rax, rax
    jz .Ltc_toobig
    mov [rsp + 24], rax
3:  test r14, r14
    jz 5f
    dec r14
    call tsb_line
    test rax, rax
    jz .Ltc_syntax
    mov rdi, rax
    mov rsi, rdx
    call tsb_fields
    cmp eax, 3
    jne .Ltc_syntax
    xor edi, edi
    call tsb_num
    test edx, edx
    jz .Ltc_syntax
    test rax, rax
    jz .Ltc_syntax
    mov r13, rax                # L1
    mov edi, 1
    call tsb_num
    test edx, edx
    jz .Ltc_syntax
    cmp rax, r13
    jb .Ltc_syntax
    cmp rax, TS_COVER_LINES
    ja .Ltc_toobig
    mov rcx, rax
    sub rcx, r13
    lea r15, [r15 + rcx + 1]
    cmp r15, COV_SPAN_MSG
    ja .Ltc_toobig
    cmp rax, [rsp + 48]
    jbe 31f
    mov [rsp + 48], rax
31: push rax
    push rax
    mov edi, 2
    call tsb_num
    mov rcx, rax
    pop rax
    pop rsi
    test edx, edx
    jz .Ltc_syntax
    cmp dword ptr [rip + apply], 0
    je 3b
    mov edx, COV_MISS
    test rcx, rcx
    jz 4f
    mov edx, COV_HIT
4:  mov rdi, [rsp + 24]
    mov rsi, r13
    mov rcx, rax
    call mark
    jmp 3b
5:  # checking: the path's highest line in this message (its records are counted at the end)
    cmp dword ptr [rip + apply], 0
    jne 1b
    mov rdi, [rsp + 16]
    mov rsi, [rsp + 40]
    mov rdx, [rsp + 48]
    call ck_note
    jmp 1b
6:  call tsb_left
    test rax, rax
    jnz .Ltc_syntax
    cmp dword ptr [rip + apply], 0
    jne 7f
    # what the message's paths add: a new file, or more lines of one held (by the same run)
    xor r14d, r14d
62: cmp r14, [rip + ck_ents + VEC_len]
    jae 64f
    imul rax, r14, CK_SIZE
    add rax, [rip + ck_ents + VEC_ptr]
    mov r13, rax
    xor eax, eax
    cmp qword ptr [rsp + 56], 0
    je 63f
    mov rdi, [r13 + CK_path]
    mov rsi, [r13 + CK_len]
    call file_find
63: mov rcx, rax
    mov rax, [r13 + CK_max]
    call line_bytes
    inc r14
    test rcx, rcx
    jnz 631f
    inc qword ptr [rsp + 64]
    add [rsp + 72], rax
    jmp 62b
631: sub rax, [rcx + CF_n]
    jbe 62b
    add [rsp + 72], rax
    jmp 62b
64: call ck_end
    # the caps over what the run would hold
    mov rax, [rsp + 64]
    mov rcx, [rsp + 72]
    mov rdx, [rsp + 32]
    cmp qword ptr [rsp + 56], 0
    je 61f
    add rax, [rip + files + VEC_len]
    add rcx, [rip + cov_bytes]
    add rdx, [rip + ranges]
61: cmp rax, TS_COVER_FILES
    ja .Ltc_toobig
    cmp rcx, TS_COVER_BYTES
    ja .Ltc_toobig
    cmp rdx, TS_COVER_RANGES
    ja .Ltc_toobig
    mov dword ptr [rip + apply], 1
    jmp .Ltc_pass
7:  mov dword ptr [rip + g_dirty], 1
    mov dword ptr [rip + g_ts_dirty], 3
    call testgutter_cov_changed
    xor eax, eax
    EPILOGUE
.Ltc_syntax:
    call ck_end
    lea rax, [rip + .Le_syntax]
    EPILOGUE
.Ltc_toobig:
    call ck_end
    lea rax, [rip + .Le_toobig]
    EPILOGUE

# ck_begin(files): an empty table for that many paths of the message being checked
ck_begin:
    PROLOGUE
    mov qword ptr [rip + ck_ents + VEC_len], 0
    mov eax, 16
    lea rcx, [rdi + rdi]
1:  cmp rax, rcx
    jae 2f
    shl rax, 1
    jmp 1b
2:  mov [rip + ck_cap], rax
    lea rdi, [rax*4]
    call mem_alloc
    mov [rip + ck_tab], rax
    mov rdi, rax
    xor esi, esi
    mov rdx, [rip + ck_cap]
    shl rdx, 2
    call memset
    EPILOGUE

# ck_end(): the table goes (nothing when there is none)
ck_end:
    PROLOGUE
    mov rdi, [rip + ck_tab]
    call mem_free
    mov qword ptr [rip + ck_tab], 0
    EPILOGUE

# ck_note(path, len, line): the path's highest line in the message is at least line
ck_note:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    call hash_line
    mov r14, rax
    mov r15, [rip + ck_cap]
    dec r15                     # the mask
1:  and rax, r15
    mov rcx, [rip + ck_tab]
    mov edx, [rcx + rax*4]
    test edx, edx
    jz 3f
    dec edx
    imul rdx, rdx, CK_SIZE
    add rdx, [rip + ck_ents + VEC_ptr]
    cmp [rdx + CK_hash], r14
    jne 2f
    cmp [rdx + CK_len], r12
    jne 2f
    push rax
    push rdx
    mov rdi, [rdx + CK_path]
    mov rsi, rbx
    mov rdx, r12
    call memeq
    mov ecx, eax
    pop rdx
    pop rax
    test ecx, ecx
    jz 2f
    cmp r13, [rdx + CK_max]     # seen: the higher line
    jbe 9f
    mov [rdx + CK_max], r13
    jmp 9f
2:  inc rax
    jmp 1b
3:  push rax
    push rax
    lea rdi, [rip + ck_ents]
    mov esi, CK_SIZE
    call vec_push
    mov [rax + CK_path], rbx
    mov [rax + CK_len], r12
    mov [rax + CK_max], r13
    mov [rax + CK_hash], r14
    pop rax
    pop rax
    mov rdx, [rip + ck_ents + VEC_len]
    mov rcx, [rip + ck_tab]
    mov [rcx + rax*4], edx
9:  EPILOGUE

# line_bytes(rax lines) -> rax the bytes a file holding that many lines takes: whole 4 KiB steps
line_bytes:
    add rax, 4095
    and rax, -4096
    ret

# mark(CF*, l1, bit, l2): lines l1..l2 get the bit (the file's array grows to hold l2, in 4 KiB steps)
mark:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov r14, rcx
    cmp r14, [rbx + CF_n]
    jbe 2f
    mov rax, r14
    call line_bytes
    mov r15, rax
    mov rdi, [rbx + CF_lines]
    mov rsi, r15
    call mem_realloc
    mov [rbx + CF_lines], rax
    mov rdi, rax
    add rdi, [rbx + CF_n]
    xor esi, esi
    mov rdx, r15
    sub rdx, [rbx + CF_n]
    call memset
    mov rax, r15
    sub rax, [rbx + CF_n]
    add [rip + cov_bytes], rax
    mov [rbx + CF_n], r15
2:  mov rax, [rbx + CF_lines]
    lea rcx, [r12 - 1]
3:  cmp rcx, r14
    jae 9f
    or [rax + rcx], r13b
    inc rcx
    jmp 3b
9:  EPILOGUE

# file_find(path, len) -> CF* for that path, or 0 (the index: open addressing on hash_line)
file_find:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    cmp qword ptr [rip + mapcap], 0
    je 8f
    call hash_line
    mov r14, [rip + mapcap]
    dec r14
    and rax, r14
    mov r15, rax
1:  mov rcx, [rip + map]
    mov eax, [rcx + r15*4]
    test eax, eax
    jz 8f
    dec eax
    imul rbx, rax, CF_SIZE
    add rbx, [rip + files + VEC_ptr]
    mov rdi, r12
    mov rsi, r13
    mov rdx, [rbx + CF_path]
    call str_eq_cstr
    test eax, eax
    jnz 7f
    inc r15
    and r15, r14
    jmp 1b
7:  mov rax, rbx
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# map_put(index): the file at that index into the index (grown to twice the files when half full)
map_put:
    PROLOGUE
    mov rbx, rdi
    mov rax, [rip + files + VEC_len]
    add rax, rax
    cmp rax, [rip + mapcap]
    jbe 3f
    # grown: every file again
    mov r12, [rip + mapcap]
    add r12, r12
    mov eax, 64
    cmp r12, rax
    cmovb r12, rax
4:  cmp r12, [rip + files + VEC_len]
    ja 41f
    add r12, r12
    jmp 4b
41: add r12, r12
    mov rdi, [rip + map]
    call mem_free
    lea rdi, [r12*4]
    call mem_alloc
    mov [rip + map], rax
    mov rdi, rax
    xor esi, esi
    lea rdx, [r12*4]
    call memset
    mov [rip + mapcap], r12
    xor r13d, r13d
5:  cmp r13, [rip + files + VEC_len]
    jae 9f                      # the new one is among them
    mov rdi, r13
    call map_slot
    inc r13
    jmp 5b
3:  mov rdi, rbx
    call map_slot
9:  EPILOGUE

# map_slot(index): the file into the first free slot from its hash
map_slot:
    PROLOGUE
    mov rbx, rdi
    imul rax, rbx, CF_SIZE
    add rax, [rip + files + VEC_ptr]
    mov r12, [rax + CF_path]
    mov rdi, r12
    call strlen
    mov rsi, rax
    mov rdi, r12
    call hash_line
    mov rcx, [rip + mapcap]
    dec rcx
    and rax, rcx
    mov rdx, [rip + map]
1:  cmp dword ptr [rdx + rax*4], 0
    je 2f
    inc rax
    and rax, rcx
    jmp 1b
2:  lea esi, [rbx + 1]
    mov [rdx + rax*4], esi
    EPILOGUE

# file_for(path, len) -> CF* for that path, added when it has none (0 past 20000 files)
file_for:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    call file_find
    test rax, rax
    jnz 9f
    cmp qword ptr [rip + files + VEC_len], TS_COVER_FILES
    jae 8f
    lea rdi, [rip + files]
    mov esi, CF_SIZE
    call vec_push
    mov r14, rax
    mov rdi, r12
    mov rsi, r13
    call mem_dup
    mov [r14 + CF_path], rax
    mov rdi, rax
    call testgutter_doc_ver
    mov [r14 + CF_ver], rax
    mov rdi, [rip + files + VEC_len]
    dec rdi
    call map_put
    mov rax, [rip + files + VEC_len]
    dec rax
    imul rax, rax, CF_SIZE
    add rax, [rip + files + VEC_ptr]
9:  EPILOGUE
8:  xor eax, eax
    EPILOGUE

# testcover_clear(): no coverage
FN testcover_clear
    PROLOGUE
    xor ebx, ebx
1:  cmp rbx, [rip + files + VEC_len]
    jae 2f
    imul r12, rbx, CF_SIZE
    add r12, [rip + files + VEC_ptr]
    mov rdi, [r12 + CF_path]
    call mem_free
    mov rdi, [r12 + CF_lines]
    call mem_free
    inc rbx
    jmp 1b
2:  lea rdi, [rip + files]
    call vec_free
    mov rdi, [rip + map]
    call mem_free
    mov qword ptr [rip + map], 0
    mov qword ptr [rip + mapcap], 0
    mov qword ptr [rip + cov_bytes], 0
    mov qword ptr [rip + g_cov_run], 0
    mov qword ptr [rip + ranges], 0
    mov dword ptr [rip + g_dirty], 1
    call testgutter_cov_changed
    EPILOGUE

# testcover_file(path cstr) -> CF* or 0
FN testcover_file
    push rbx
    mov rbx, rdi
    call strlen
    mov rsi, rax
    mov rdi, rbx
    call file_find
    pop rbx
    ret

# testcover_ver(CF*) -> rax the version of the file's open document its coverage refers to, -1 none
FN testcover_ver
    mov rax, [rdi + CF_ver]
    ret

# testcover_set_ver(CF*, key): the document version its lines refer to (testgutter.s's key)
FN testcover_set_ver
    mov [rdi + CF_ver], rsi
    ret

# testcover_count(CF*) -> rax the lines it has a byte for
FN testcover_count
    mov rax, [rdi + CF_n]
    ret

# testcover_files() -> rax the files with coverage
FN testcover_files
    mov rax, [rip + files + VEC_len]
    ret

# testcover_file_at(i) -> rax CF*
FN testcover_file_at
    imul rax, rdi, CF_SIZE
    add rax, [rip + files + VEC_ptr]
    ret

# testcover_path(CF*) -> rax its path (cstr)
FN testcover_path
    mov rax, [rdi + CF_path]
    ret

# testcover_stats(CF*) -> eax its covered lines (partly covered ones too), edx the lines it has
#   coverage for
FN testcover_stats
    xor eax, eax
    xor edx, edx
    mov rsi, [rdi + CF_lines]
    mov r8, [rdi + CF_n]
    xor ecx, ecx
1:  cmp rcx, r8
    jae 9f
    movzx r9d, byte ptr [rsi + rcx]
    inc rcx
    test r9d, r9d
    jz 1b
    inc edx
    test r9d, COV_HIT
    jz 1b
    inc eax
    jmp 1b
9:  ret

# testcover_line(CF*, line one-based) -> eax 0 unknown, COV_HIT covered, COV_MISS missed, 3 partly
FN testcover_line
    xor eax, eax
    test rsi, rsi
    jz 9f
    cmp rsi, [rdi + CF_n]
    ja 9f
    mov rcx, [rdi + CF_lines]
    movzx eax, byte ptr [rcx + rsi - 1]
9:  ret

# testcover_dump(sb, path): print-coverage: "covered=N partial=N missed=N lines=L:C,L:P,L:M..."
FN testcover_dump
    PROLOGUE
    mov rbx, rdi
    mov rdi, rsi
    call testcover_file
    mov r12, rax
    lea rdi, [rip + cnt]
    xor esi, esi
    mov edx, 16
    call memset
    test r12, r12
    jz 3f
    xor r13d, r13d
1:  cmp r13, [r12 + CF_n]
    jae 3f
    mov rax, [r12 + CF_lines]
    movzx eax, byte ptr [rax + r13]
    inc r13
    lea rcx, [rip + cnt]
    inc dword ptr [rcx + rax*4]
    jmp 1b
3:  mov rdi, rbx
    lea rsi, [rip + .Lp_covered]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + cnt + 4]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lp_partial]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + cnt + 12]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lp_missed]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + cnt + 8]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lp_lines]
    call sb_push_cstr
    test r12, r12
    jz 9f
    xor r13d, r13d
    xor r14d, r14d              # 1 after the first
4:  cmp r13, [r12 + CF_n]
    jae 9f
    mov rax, [r12 + CF_lines]
    movzx r15d, byte ptr [rax + r13]
    inc r13
    test r15d, r15d
    jz 4b
    test r14d, r14d
    jz 5f
    mov rdi, rbx
    mov esi, ','
    call sb_push_byte
5:  mov r14d, 1
    mov rdi, rbx
    mov rsi, r13
    call sb_push_u64
    mov rdi, rbx
    mov esi, ':'
    call sb_push_byte
    lea rax, [rip + .Lcov_letters]
    movzx esi, byte ptr [rax + r15]
    mov rdi, rbx
    call sb_push_byte
    jmp 4b
9:  mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    EPILOGUE

.section .rodata
.Le_syntax: .asciz "syntax bad coverage body"
.Le_toobig: .asciz "toobig coverage: 20000 files, 1000000 ranges and 64 MiB of lines a run, 1048576 lines a file"
.Lp_covered: .asciz "covered="
.Lp_partial: .asciz " partial="
.Lp_missed: .asciz " missed="
.Lp_lines: .asciz " lines="
.Lcov_letters: .ascii "-CMP"
