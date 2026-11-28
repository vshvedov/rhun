# where an installed extension came from and its previous version (extension management): the
# install record .rhun-install that rhun writes into each folder it installs, a linked development
# folder, one previous version kept in ROOT/.previous/OWNER/NAME for Roll back, the automatic roll
# back of a new version that fails its first start, and what an update adds to [needs].
#   .rhun-install   source = github|archive|folder, repository, tag, path, link = yes, sha256,
#                   reviewed = yes|no, installed = UTC time, started = yes after the first hello
.include "rhun.inc"

.equ REC_MAX, 8192              # bytes of an install record

.bss
.p2align 3
rc_sb: .zero SB_SIZE            # scratch: paths, the record
rc_words: .zero SB_SIZE         # what a version asks for in addition
rc_msg: .zero 640               # the automatic roll back's toast
rc_word: .zero 128
rc_title: .zero 256             # the roll-back dialog's question
rc_text: .zero 1100             # and its line
rc_pv: .zero EXT_SIZE           # the previous version's manifest (title, version, needs)
rc_ext: .quad 0                 # the extension a roll-back dialog asks about
rc_auto: .long 0                # that dialog is the automatic roll back's

.text

# ---------------- the record ----------------

# extrec_load(ext): ext_load calls it before reading the manifest. The record, when the folder has
# one, is kept in EXT_rec; a linked install loads from its folder (EXT_dir becomes the link's path,
# EXT_inst the stub in the extensions folder); a version without started = yes that has a previous
# version to go back to is fresh (extrec_tick watches its first start). EXT_prev: the previous
# version's version, for the Roll back button
FN extrec_load
    PROLOGUE
    mov rbx, rdi
    mov rdi, [rbx + EXT_dir]
    lea rsi, [rip + .Lrec_name]
    call path_join
    mov r12, rax
    mov rdi, rax
    mov esi, REC_MAX
    call file_read_limited
    mov r13, rax
    mov r14, rdx
    mov rdi, r12
    call mem_free
    test r13, r13
    jz 5f
    mov rdi, r13
    mov rsi, r14
    call mem_dup
    mov [rbx + EXT_rec], rax
    mov rdi, r13
    call mem_free
    # a link: the manifest and the program are in its folder (an absolute path)
    mov rdi, rbx
    lea rsi, [rip + .Lk_link]
    call rec_is_yes
    test eax, eax
    jz 2f
    mov rdi, rbx
    lea rsi, [rip + .Lk_path]
    call extrec_get
    test rax, rax
    jz 2f
    PATH_ABSOLUTE rax, 1f
    jmp 2f
1:  mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov rcx, [rbx + EXT_dir]
    mov [rbx + EXT_inst], rcx
    mov [rbx + EXT_dir], rax
2:  mov rdi, rbx
    lea rsi, [rip + .Lk_started]
    call rec_is_yes
    test eax, eax
    jnz 5f
    mov rdi, rbx
    lea rsi, [rip + .Lk_kept]
    call rec_is_yes
    test eax, eax
    jnz 5f                      # a version rolled back to stays
    mov rdi, rbx
    call prev_dir
    mov rdi, rax
    call file_is_dir
    test eax, eax
    jz 5f
    mov dword ptr [rbx + EXT_fresh], 1
5:  mov rdi, rbx
    call extrec_prev_refresh
    EPILOGUE

# extrec_prev_refresh(ext): EXT_prev, the version of the previous version kept, or 0
FN extrec_prev_refresh
    PROLOGUE
    mov rbx, rdi
    mov rdi, [rbx + EXT_prev]
    call mem_free
    mov qword ptr [rbx + EXT_prev], 0
    mov rdi, rbx
    call prev_dir
    mov rdi, rax
    lea rsi, [rip + rc_pv]
    call extrec_preview
    test eax, eax
    jz 9f
    mov rdi, [rip + rc_pv + EXT_version]
    call dup_cstr
    mov [rbx + EXT_prev], rax
9:  lea rdi, [rip + rc_pv]
    call extrec_pv_free
    EPILOGUE

# extrec_preview(dir, pv) -> 1 when dir (an installed folder, or a link's stub) holds a manifest
# that names title, version, owner and name: those, the description and [needs] into pv
FN extrec_preview
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov rdi, r12
    xor esi, esi
    mov edx, EXT_SIZE
    call memset
    mov qword ptr [rsp], 0      # a link's folder, owned
    # a stub: its record names the folder
    mov rdi, rbx
    lea rsi, [rip + .Lrec_name]
    call path_join
    mov r13, rax
    mov rdi, rax
    mov esi, REC_MAX
    call file_read_limited
    mov r14, rax
    mov r15, rdx
    mov rdi, r13
    call mem_free
    test r14, r14
    jz 3f
    mov rdi, r14
    mov rsi, r15
    lea rdx, [rip + .Lk_link]
    call ini_top_value
    test rax, rax
    jz 2f
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + .Lyes]
    call str_eq_cstr
    test eax, eax
    jz 2f
    mov rdi, r14
    mov rsi, r15
    lea rdx, [rip + .Lk_path]
    call ini_top_value
    test rax, rax
    jz 2f
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov [rsp], rax
    mov rbx, rax
2:  mov rdi, r14
    call mem_free
3:  mov rdi, rbx
    lea rsi, [rip + .Lmanifest]
    call path_join
    mov r13, rax
    mov rdi, rax
    mov esi, EXT_MANIFEST_MAX
    call file_read_limited
    mov r14, rax
    mov r15, rdx
    mov rdi, r13
    call mem_free
    xor ebx, ebx
    test r14, r14
    jz 8f
    mov rdi, r14
    mov rsi, r15
    mov rdx, r12
    call ext_preview
    mov ebx, eax
    mov rdi, r14
    call mem_free
8:  mov rdi, [rsp]
    call mem_free
    mov eax, ebx
    EPILOGUE

# extrec_pv_free(pv): the strings ext_preview kept, and the record cleared
FN extrec_pv_free
    PROLOGUE
    mov rbx, rdi
    mov rdi, [rbx + EXT_title]
    call mem_free
    mov rdi, [rbx + EXT_version]
    call mem_free
    mov rdi, [rbx + EXT_desc]
    call mem_free
    mov rdi, [rbx + EXT_mname]
    call mem_free
    mov rdi, [rbx + EXT_mowner]
    call mem_free
    mov rdi, [rbx + EXT_runs]
    call mem_free
    mov rdi, [rbx + EXT_pack]
    call mem_free
    mov rdi, [rbx + EXT_tests_progs]
    call mem_free
    mov rdi, [rbx + EXT_debuggers]
    call mem_free
    mov rdi, [rbx + EXT_nb_kernels]
    call mem_free
    mov rdi, rbx
    xor esi, esi
    mov edx, EXT_SIZE
    call memset
    EPILOGUE

# ini_top_value(ptr, len, key cstr) -> rax, rdx the value of a key before any [section], or rax 0
FN ini_top_value
    PROLOGUE INI_SIZE
    mov r12, rdx
    mov rdx, rsi
    mov rsi, rdi
    lea rdi, [rsp]
    call ini_init
1:  lea rdi, [rsp]
    call ini_next
    test eax, eax
    jz 8f
    cmp qword ptr [rsp + INI_seclen], 0
    jne 1b
    lea rdi, [rsp]
    mov rsi, r12
    call ini_key_is
    test eax, eax
    jz 1b
    mov rax, [rsp + INI_val]
    mov rdx, [rsp + INI_vallen]
    EPILOGUE
8:  xor eax, eax
    xor edx, edx
    EPILOGUE

# extrec_get(ext, key cstr) -> rax, rdx the record's value for key, or rax 0
FN extrec_get
    PROLOGUE
    mov rbx, [rdi + EXT_rec]
    test rbx, rbx
    jz 8f
    mov r12, rsi
    mov rdi, rbx
    call strlen
    mov rdi, rbx
    mov rsi, rax
    mov rdx, r12
    call ini_top_value
    EPILOGUE
8:  xor eax, eax
    xor edx, edx
    EPILOGUE

# rec_is_yes(ext, key) -> 1 when the record says key = yes
rec_is_yes:
    PROLOGUE
    call extrec_get
    test rax, rax
    jz 8f
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + .Lyes]
    call str_eq_cstr
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# ext_home(ext) -> the folder rhun installed it in: a link's stub, or EXT_dir
FN ext_home
    mov rax, [rdi + EXT_inst]
    test rax, rax
    jnz 1f
    mov rax, [rdi + EXT_dir]
1:  ret

# ext_prev_dir(ext) -> ROOT/.previous/OWNER/NAME in rc_sb (until rc_sb is used again)
FN ext_prev_dir
prev_dir:
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rip + rc_sb]
    call sb_clear
    call ext_root_dir
    lea rdi, [rip + rc_sb]
    mov rsi, rax
    call sb_push_cstr
    lea rdi, [rip + rc_sb]
    lea rsi, [rip + .Lprevious]
    call sb_push_cstr
    lea rdi, [rip + rc_sb]
    mov rsi, [rbx + EXT_owner]
    call sb_push_cstr
    lea rdi, [rip + rc_sb]
    mov esi, '/'
    call sb_push_byte
    lea rdi, [rip + rc_sb]
    mov rsi, [rbx + EXT_name]
    call sb_push_cstr
    lea rdi, [rip + rc_sb]
    xor esi, esi
    call sb_push_byte
    mov rax, [rip + rc_sb + SB_ptr]
    EPILOGUE

# extrec_started(ext): its first hello came: the record says so, and it is no longer fresh
FN extrec_started
    lea rsi, [rip + .Lline_started]
    jmp extrec_mark

# extrec_kept(ext): a version rolled back to is never rolled back by itself (unless it said hello)
FN extrec_kept
    push rdi
    lea rsi, [rip + .Lk_started]
    call rec_is_yes
    pop rdi
    mov dword ptr [rdi + EXT_fresh], 0
    test eax, eax
    jnz 1f
    lea rsi, [rip + .Lline_kept]
    jmp extrec_mark
1:  ret

# extrec_mark(ext, line): the line added to its record (in memory and on disk); not fresh any more
extrec_mark:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov dword ptr [rbx + EXT_fresh], 0
    lea rdi, [rip + rc_sb]
    call sb_clear
    mov rsi, [rbx + EXT_rec]
    test rsi, rsi
    jz 1f
    lea rdi, [rip + rc_sb]
    call sb_push_cstr
1:  lea rdi, [rip + rc_sb]
    mov rsi, r12
    call sb_push_cstr
    lea rdi, [rip + rc_sb]
    xor esi, esi
    call sb_push_byte
    mov rdi, [rbx + EXT_rec]
    call mem_free
    mov rdi, [rip + rc_sb + SB_ptr]
    call dup_cstr
    mov [rbx + EXT_rec], rax
    mov rdi, rbx
    call ext_home
    mov rdi, rax
    lea rsi, [rip + .Lrec_name]
    call path_join
    mov r12, rax
    mov rdi, [rbx + EXT_rec]
    call strlen
    mov rdi, r12
    mov rsi, [rbx + EXT_rec]
    mov rdx, rax
    call file_write_all
    mov rdi, r12
    call mem_free
    EPILOGUE

# extrec_tick(): once per frame: a fresh version that said hello is recorded as started; one whose
# first start failed (it could not start, gave no hello within 5 s, or exited before hello) goes
# back to the previous version
FN extrec_tick
    PROLOGUE
    xor r12d, r12d
1:  cmp r12, [rip + g_exts + VEC_len]
    jae 9f
    imul rbx, r12, EXT_SIZE
    add rbx, [rip + g_exts + VEC_ptr]
    inc r12
    cmp dword ptr [rbx + EXT_fresh], 0
    je 1b
    mov eax, [rbx + EXT_status]
    cmp eax, ES_REMOVED
    je 3f
    cmp dword ptr [rbx + EXT_hello], 1
    jne 2f
    mov rdi, rbx
    call extrec_started
    jmp 1b
2:  cmp eax, ES_FAILED
    je 4f
    cmp eax, ES_CRASHED
    je 4f
    cmp eax, ES_STOPPED
    jne 1b
    mov rdi, [rbx + EXT_reason]
    test rdi, rdi
    jz 1b
    lea rsi, [rip + .Lno_hello]
    call strcmp_eq
    test eax, eax
    jz 1b                       # stopped by the user: not a failed start
4:  mov rdi, rbx
    call auto_rollback
    jmp 9f                      # the table changed: the next frame looks again
3:  mov dword ptr [rbx + EXT_fresh], 0
    jmp 1b
9:  EPILOGUE

# auto_rollback(ext): its first start failed: back to the previous version, saying why (asking first
# when the previous version may do more)
auto_rollback:
    PROLOGUE
    mov rbx, rdi
    mov dword ptr [rbx + EXT_fresh], 0
    # "Showcase 0.1.2 did not start (no hello within 5 s); back to 0.1.0"
    lea rdi, [rip + rc_msg]
    mov rsi, rbx
    call title_of
    mov rsi, rax
    call ext_copy_title
    mov byte ptr [rax], ' '
    lea rdi, [rax + 1]
    mov rsi, [rbx + EXT_version]
    lea rdx, [rip + rc_msg + 200]
    call cstr_copy_max
    mov rdi, rax
    lea rsi, [rip + .Lt_not_started]
    call cstr_copy
    mov rdi, rax
    mov rsi, [rbx + EXT_reason]
    test rsi, rsi
    jnz 1f
    lea rsi, [rip + .Lt_failed]
1:  lea rdx, [rip + rc_msg + 480]
    call cstr_copy_max
    mov rdi, rax
    lea rsi, [rip + .Lt_back_to]
    call cstr_copy
    mov rdi, rax
    mov rsi, [rbx + EXT_prev]
    test rsi, rsi
    jnz 2f
    lea rsi, [rip + .Lt_previous]
2:  lea rdx, [rip + rc_msg + 630]
    call cstr_copy_max
    mov dword ptr [rip + rc_auto], 1
    mov rdi, rbx
    call ext_rollback_ask
    EPILOGUE

# cstr_copy_max(dst, src, limit): src, stopping before limit -> rax the end (its NUL)
cstr_copy_max:
1:  cmp rdi, rdx
    jae 2f
    mov al, [rsi]
    test al, al
    jz 2f
    mov [rdi], al
    inc rdi
    inc rsi
    jmp 1b
2:  mov byte ptr [rdi], 0
    mov rax, rdi
    ret

# title_of(ext in rsi) -> its title, or its name (rdi kept)
title_of:
    mov rax, [rsi + EXT_title]
    test rax, rax
    jnz 1f
    mov rax, [rsi + EXT_name]
1:  ret

# ---------------- roll back ----------------

# ext_rollback_ask(ext): Roll back: the previous version comes back at once, unless it asks for more
# than this one, which a dialog says first. rc_auto: the automatic roll back (rc_msg says why)
FN ext_rollback_ask
    PROLOGUE
    mov rbx, rdi
    mov rdi, rbx
    call prev_dir
    mov rdi, rax
    lea rsi, [rip + rc_pv]
    call extrec_preview
    test eax, eax
    jz .Lra_none
    lea rdi, [rip + rc_words]
    call sb_clear
    mov rdi, rbx
    lea rsi, [rip + rc_pv]
    lea rdx, [rip + rc_words]
    call ext_needs_wider
    test eax, eax
    jnz .Lra_ask
    lea rdi, [rip + rc_pv]
    call extrec_pv_free
    mov dword ptr [rip + rc_auto], 0
    mov rdi, rbx
    call ext_rollback
    EPILOGUE
.Lra_ask:
    # "Roll back “Showcase” to 0.1.0?" / "It then also asks to: use the internet."
    mov [rip + rc_ext], rbx
    lea rdi, [rip + rc_title]
    lea rsi, [rip + .Lq_rollback]
    call cstr_copy
    mov rdi, rax
    mov rsi, rbx
    call title_of
    mov rsi, rax
    call ext_copy_title
    mov rdi, rax
    lea rsi, [rip + .Lq_close_to]
    call cstr_copy
    mov rdi, rax
    mov rsi, [rip + rc_pv + EXT_version]
    lea rdx, [rip + rc_title + 250]
    call cstr_copy_max
    mov byte ptr [rax], '?'
    mov byte ptr [rax + 1], 0
    lea rdi, [rip + rc_text]
    cmp dword ptr [rip + rc_auto], 0
    je 1f
    lea rsi, [rip + rc_msg]
    call cstr_copy
    mov rdi, rax
    lea rsi, [rip + .Lt_dot_nl]
    call cstr_copy
    mov rdi, rax
1:  lea rsi, [rip + .Lt_also]
    call cstr_copy
    mov r12, rax
    lea rdi, [rip + rc_words]
    xor esi, esi
    call sb_push_byte
    mov rdi, r12
    mov rsi, [rip + rc_words + SB_ptr]
    lea rdx, [rip + rc_text + 1090]
    call cstr_copy_max
    mov byte ptr [rax], '.'
    mov byte ptr [rax + 1], 0
    lea rdi, [rip + rc_pv]
    call extrec_pv_free
    mov dword ptr [rip + rc_auto], 0
    mov byte ptr [rip + rc_msg], 0
    lea rdi, [rip + rc_title]
    lea rsi, [rip + rc_text]
    lea rdx, [rip + .Lb_rollback]
    lea rcx, [rip + rollback_confirmed]
    call app_confirm
    EPILOGUE
.Lra_none:
    lea rdi, [rip + rc_pv]
    call extrec_pv_free
    mov dword ptr [rip + rc_auto], 0
    mov byte ptr [rip + rc_msg], 0
    lea rdi, [rip + .Le_no_previous]
    call app_toast
    EPILOGUE

# extrec_slot_forget(ext): a Roll back dialog for that record is answered by nobody
FN extrec_slot_forget
    cmp [rip + rc_ext], rdi
    jne 1f
    mov qword ptr [rip + rc_ext], 0
1:  ret

# rollback_confirmed(): the dialog's Roll back
rollback_confirmed:
    PROLOGUE
    mov rdi, [rip + rc_ext]
    mov qword ptr [rip + rc_ext], 0
    test rdi, rdi
    jz 9f
    cmp dword ptr [rdi + EXT_status], ES_REMOVED
    je 9f
    call ext_rollback
9:  EPILOGUE

# ext_rollback(ext) -> rax the restored version's record, or 0: it stops, the installed folder and
# the previous version swap places (three renames, undone on a failure), and the restored one starts.
# Automatic updates then leave the tag it replaced alone (skip). rc_msg, when set, is the toast
FN ext_rollback
    PROLOGUE 48
    mov rbx, rdi
    # what is needed after the record retires: names, folders, the tag it replaced
    mov rdi, [rbx + EXT_owner]
    call dup_cstr
    mov [rsp], rax              # owner
    mov rdi, [rbx + EXT_name]
    call dup_cstr
    mov [rsp + 8], rax          # name
    mov rdi, rbx
    call ext_home
    mov rdi, rax
    call dup_cstr
    mov r12, rax                # ROOT/OWNER/NAME
    mov rdi, rbx
    call prev_dir
    mov rdi, rax
    call dup_cstr
    mov r13, rax                # ROOT/.previous/OWNER/NAME
    lea rdi, [rip + rc_sb]
    call sb_clear
    mov rdi, r13
    call strlen
    mov rdi, r13
    mov rsi, rax
    call path_dirlen
    lea rdi, [rip + rc_sb]
    mov rsi, r13
    mov rdx, rax
    call sb_push
    lea rdi, [rip + rc_sb]
    lea rsi, [rip + .Lswap]
    call sb_push_cstr
    lea rdi, [rip + rc_sb]
    mov rsi, [rbx + EXT_name]
    call sb_push_cstr
    lea rdi, [rip + rc_sb]
    xor esi, esi
    call sb_push_byte
    mov rdi, [rip + rc_sb + SB_ptr]
    call dup_cstr
    mov r14, rax                # ROOT/.previous/OWNER/.swap-NAME
    mov rdi, rbx
    call ext_tag_of
    mov rdi, rax
    call dup_cstr
    mov [rsp + 16], rax         # the tag it replaced
    xor eax, eax
    cmp [rip + g_xp_detail], rbx
    sete al
    mov [rsp + 24], eax         # its details were shown
    mov qword ptr [rsp + 32], 0 # the restored record
    mov rdi, r13
    call file_is_dir
    test eax, eax
    jz .Lrb_none
    mov rdi, rbx
    call ext_retire             # ended and reaped: its folder can be renamed (Windows too)
    mov rdi, r14
    call file_remove_tree
    mov rdi, r12
    mov rsi, r14
    SYS SYS_rename
    test rax, rax
    js .Lrb_fail
    mov rdi, r13
    mov rsi, r12
    SYS SYS_rename
    test rax, rax
    js .Lrb_undo1
    mov rdi, r14
    mov rsi, r13
    SYS SYS_rename
    test rax, rax
    js .Lrb_undo2
    mov rdi, rbx
    call ext_slot_reuse         # the restored version takes the retired record's place
    mov rdi, r12
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    call ext_install_load
    mov [rsp + 32], rax
    test rax, rax
    jz .Lrb_full
    mov r15, rax
    mov rdi, rax
    call extrec_kept            # chosen: it does not roll back by itself
    cmp dword ptr [rsp + 24], 0
    je 1f
    mov [rip + g_xp_detail], r15
1:  # automatic updates leave the tag it replaced alone
    mov rdi, r15
    call ext_full_name
    mov rdi, rax
    mov rsi, [rsp + 16]
    call extupdate_skip
    # "Rolled back Showcase to 0.1.0", or the automatic roll back's reason
    cmp byte ptr [rip + rc_msg], 0
    jne 2f
    lea rdi, [rip + rc_msg]
    lea rsi, [rip + .Lt_rolled]
    call cstr_copy
    mov rdi, rax
    mov rsi, r15
    call title_of
    mov rsi, rax
    call ext_copy_title
    mov rdi, rax
    lea rsi, [rip + .Lq_to]
    call cstr_copy
    mov rdi, rax
    mov rsi, [r15 + EXT_version]
    lea rdx, [rip + rc_msg + 630]
    call cstr_copy_max
2:  lea rdi, [rip + rc_msg]
    call app_toast
    jmp .Lrb_done
.Lrb_undo2:
    mov rdi, r12
    mov rsi, r13
    SYS SYS_rename
.Lrb_undo1:
    mov rdi, r14
    mov rsi, r12
    SYS SYS_rename
.Lrb_fail:
    mov rdi, rbx
    call ext_slot_reuse
    mov rdi, r12
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    call ext_install_load       # the installed version runs again
    lea rdi, [rip + .Le_swap]
    call app_toast
    jmp .Lrb_done
.Lrb_full:
    lea rdi, [rip + .Le_full]
    call app_toast
    jmp .Lrb_done
.Lrb_none:
    lea rdi, [rip + .Le_no_previous]
    call app_toast
.Lrb_done:
    mov byte ptr [rip + rc_msg], 0
    mov rdi, [rsp]
    call mem_free
    mov rdi, [rsp + 8]
    call mem_free
    mov rdi, [rsp + 16]
    call mem_free
    mov rdi, r12
    call mem_free
    mov rdi, r13
    call mem_free
    mov rdi, r14
    call mem_free
    mov dword ptr [rip + g_dirty], 1
    mov rax, [rsp + 32]
    EPILOGUE

# ext_tag_of(ext) -> its release tag: the record's tag, else "v" and the manifest's version (in
# rc_word until it is used again)
FN ext_tag_of
    PROLOGUE
    mov rbx, rdi
    lea rsi, [rip + .Lk_tag]
    call extrec_get
    test rax, rax
    jz 1f
    test rdx, rdx
    jz 1f
    cmp rdx, 100
    ja 1f
    lea rdi, [rip + rc_word]
    mov rsi, rax
    push rdx
    push rdx
    call memcpy
    pop rdx
    pop rdx
    lea rax, [rip + rc_word]
    mov byte ptr [rax + rdx], 0
    EPILOGUE
1:  lea rdi, [rip + rc_word]
    mov byte ptr [rdi], 'v'
    inc rdi
    mov rsi, [rbx + EXT_version]
    test rsi, rsi
    jnz 2f
    lea rsi, [rip + .Lempty]
2:  lea rdx, [rip + rc_word + 100]
    call cstr_copy_max
    lea rax, [rip + rc_word]
    EPILOGUE

# ---------------- permissions ----------------

# ext_needs_wider(old, new, sb) -> eax 1 when new may do something old may not: what, in words
# joined by ", ", onto sb. A level above the old one (none < read < write) for documents or the
# project, any other [needs] bit the old version lacks (home, network, the terminal ladder, Git,
# debug adapters, secrets, and any bit a later design adds: those say "use more of your system"),
# or a program in run, tests or kernels that the old list lacks (names of any length)
FN ext_needs_wider
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    xor r14d, r14d              # items
    mov eax, [rbx + EXT_needs]
    not eax
    and eax, [r12 + EXT_needs]
    mov r15d, eax               # the new bits (write comes with read)
    lea rsi, [rip + .Ln_docs_write]
    test r15d, NEEDS_DOC_WRITE
    jnz 1f
    lea rsi, [rip + .Ln_docs_read]
    test r15d, NEEDS_DOC_READ
    jz 2f
1:  call wider_item
2:  lea rsi, [rip + .Ln_proj_write]
    test r15d, NEEDS_PROJECT_WRITE
    jnz 3f
    lea rsi, [rip + .Ln_proj_read]
    test r15d, NEEDS_PROJECT_READ
    jz 4f
3:  call wider_item
4:  lea rcx, [rip + wider_bits]
5:  mov eax, [rcx]
    test eax, eax
    jz 6f
    test r15d, eax
    jz 51f
    push rcx
    push rcx
    mov rsi, [rcx + 8]
    call wider_item
    pop rcx
    pop rcx
51: add rcx, 16
    jmp 5b
6:  # a bit no phrase names: wider all the same
    mov eax, r15d
    and eax, ~(NEEDS_DOC_READ | NEEDS_DOC_WRITE | NEEDS_PROJECT_READ | NEEDS_PROJECT_WRITE | NEEDS_HOME_READ | NEEDS_NETWORK | NEEDS_TERMINAL | NEEDS_TERM_RUN | NEEDS_TERM_INPUT | NEEDS_TERM_OUTPUT | NEEDS_GIT_READ | NEEDS_DEBUG | NEEDS_SECRETS | NEEDS_AUDIO)
    jz 7f
    lea rsi, [rip + .Ln_more]
    call wider_item
7:  # programs in run, tests (testing) and kernels (notebooks) that the old lists lack
    mov rdi, [r12 + EXT_runs]
    mov rsi, [rbx + EXT_runs]
    lea rdx, [rip + .Lempty]
    mov rcx, r13
    mov r8d, r14d
    call wider_list
    mov r14d, eax
    mov rdi, [r12 + EXT_tests_progs]
    mov rsi, [rbx + EXT_tests_progs]
    lea rdx, [rip + .Ln_when_tests]
    mov rcx, r13
    mov r8d, r14d
    call wider_list
    mov r14d, eax
    mov rdi, [r12 + EXT_debuggers]  # other extensions' debuggers it starts
    mov rsi, [rbx + EXT_debuggers]
    lea rdx, [rip + .Ln_when_debuggers]
    mov rcx, r13
    mov r8d, r14d
    call wider_list
    mov r14d, eax
    mov rdi, [r12 + EXT_nb_kernels]
    mov rsi, [rbx + EXT_nb_kernels]
    lea rdx, [rip + .Ln_as_kernels]
    mov rcx, r13
    mov r8d, r14d
    call wider_list
    mov r14d, eax
    xor eax, eax
    test r14d, r14d
    setnz al
    EPILOGUE

# wider_list(new list, old list, suffix, sb, items) -> eax items: "run A B" + suffix onto sb (after
# ", " when items) for the names of new that old lacks; names are compared whole, whatever their
# length
wider_list:
    PROLOGUE 16
    mov r12, rdi
    mov rbx, rsi
    mov [rsp], rdx
    mov r13, rcx
    mov r14d, r8d
    xor r15d, r15d              # names so far
    test r12, r12
    jz 8f
1:  mov rdi, r12
    call strlen
    mov rdi, r12
    mov rsi, rax
    call next_word
    add r12, rcx
    test rdx, rdx
    jz 7f
    mov [rsp + 8], rax          # the name
    push rdx
    push rdx
    mov rdi, rax
    mov rsi, rdx
    mov rdx, rbx
    call span_in_list
    pop rdx
    pop rdx
    test eax, eax
    jnz 1b
    push rdx
    push rdx
    test r15d, r15d
    jnz 2f
    lea rsi, [rip + .Ln_run]
    call wider_item
    jmp 3f
2:  mov rdi, r13
    mov esi, ' '
    call sb_push_byte
3:  pop rdx
    pop rdx
    inc r15d
    mov rdi, r13
    mov rsi, [rsp + 8]
    call sb_push
    jmp 1b
7:  test r15d, r15d
    jz 8f
    mov rdi, r13
    mov rsi, [rsp]
    call sb_push_cstr
8:  mov eax, r14d
    EPILOGUE

# span_in_list(ptr, len, list cstr or 0) -> eax 1 when the space separated list has that word
span_in_list:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov rbx, rdx
    test rbx, rbx
    jz 8f
1:  mov rdi, rbx
    call strlen
    mov rdi, rbx
    mov rsi, rax
    call next_word
    add rbx, rcx
    test rdx, rdx
    jz 8f
    cmp rdx, r13
    jne 1b
    xor ecx, ecx
2:  cmp rcx, r13
    jae 9f
    mov r8b, [rax + rcx]
    cmp r8b, [r12 + rcx]
    jne 1b
    inc rcx
    jmp 2b
8:  xor eax, eax
    EPILOGUE
9:  mov eax, 1
    EPILOGUE

# wider_item(cstr in rsi): onto r13, after ", " when not the first (r14 counts)
wider_item:
    push rsi
    push rsi
    test r14d, r14d
    jz 1f
    mov rdi, r13
    lea rsi, [rip + .Ln_sep]
    call sb_push_cstr
1:  pop rsi
    pop rsi
    inc r14d
    mov rdi, r13
    jmp sb_push_cstr

# ---------------- settings across versions ----------------

# xset_keep(ext, it): the iterator's "setting.KEY = VALUE" from extensions.ini names a setting this version does
# not declare: kept (EXT_xset) and written back, so a roll back and forward keeps it (at most 16 KB)
FN xset_keep
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea rdi, [rip + rc_sb]
    call sb_clear
    mov rsi, [rbx + EXT_xset]
    test rsi, rsi
    jz 1f
    lea rdi, [rip + rc_sb]
    call sb_push_cstr
1:  mov rax, [rip + rc_sb + SB_len]
    add rax, [r12 + INI_keylen]
    add rax, [r12 + INI_vallen]
    cmp rax, 16384
    ja 9f
    lea rdi, [rip + rc_sb]
    mov rsi, [r12 + INI_key]
    mov rdx, [r12 + INI_keylen]
    call sb_push
    lea rdi, [rip + rc_sb]
    lea rsi, [rip + .Leq]
    call sb_push_cstr
    lea rdi, [rip + rc_sb]
    mov rsi, [r12 + INI_val]
    mov rdx, [r12 + INI_vallen]
    call sb_push
    lea rdi, [rip + rc_sb]
    mov esi, 10
    call sb_push_byte
    lea rdi, [rip + rc_sb]
    xor esi, esi
    call sb_push_byte
    mov rdi, [rbx + EXT_xset]
    call mem_free
    mov rdi, [rip + rc_sb + SB_ptr]
    call dup_cstr
    mov [rbx + EXT_xset], rax
9:  EPILOGUE

# ---------------- packs ----------------

# pack_check(ext) -> rax why its pack list is wrong (a cstr), or 0 when it has none or it is right:
# at most 16 names, each OWNER/NAME of [A-Za-z0-9._-], none of them the pack itself
FN pack_check
    PROLOGUE 16
    mov rbx, rdi
    mov r12, [rbx + EXT_pack]
    test r12, r12
    jz 8f
    xor r15d, r15d              # names
1:  mov rdi, r12
    call strlen
    mov rdi, r12
    mov rsi, rax
    call next_word
    add r12, rcx
    test rdx, rdx
    jz 8f
    inc r15d
    cmp r15d, 16
    ja 9f
    mov r13, rax
    mov r14, rdx
    # OWNER/NAME: one slash, a folder name on each side
    xor ecx, ecx
    mov qword ptr [rsp], -1
2:  cmp rcx, r14
    jae 4f
    movzx edx, byte ptr [r13 + rcx]
    cmp edx, '/'
    jne 3f
    cmp qword ptr [rsp], -1
    jne 9f
    mov [rsp], rcx
    inc rcx
    jmp 2b
3:  call pack_char
    test eax, eax
    jz 9f
    inc rcx
    jmp 2b
4:  mov rcx, [rsp]
    test rcx, rcx
    jle 9f                      # no slash, or nothing before it
    lea rax, [rcx + 1]
    cmp rax, r14
    jae 9f                      # nothing after it
    cmp byte ptr [r13], '.'
    je 9f
    cmp byte ptr [r13 + rcx + 1], '.'
    je 9f
    # not itself
    mov rdi, r13
    mov rsi, rcx
    mov rdx, [rbx + EXT_owner]
    call str_eq_cstr
    test eax, eax
    jz 1b
    mov rcx, [rsp]
    lea rdi, [r13 + rcx + 1]
    mov rsi, r14
    sub rsi, rcx
    dec rsi
    mov rdx, [rbx + EXT_name]
    call str_eq_cstr
    test eax, eax
    jz 1b
9:  lea rax, [rip + .Lr_pack]
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# pack_char(edx) -> eax 1 for [A-Za-z0-9._-]
pack_char:
    mov eax, 1
    cmp edx, '.'
    je 1f
    cmp edx, '_'
    je 1f
    cmp edx, '-'
    je 1f
    lea r8d, [rdx - '0']
    cmp r8d, 9
    jbe 1f
    mov r8d, edx
    or r8d, 0x20
    sub r8d, 'a'
    cmp r8d, 25
    jbe 1f
    xor eax, eax
1:  ret

# ---------------- time ----------------

# fmt_utc(dst, unix seconds) -> rax the end (its NUL): "2026-10-19T16:05:00Z"
FN fmt_utc
    PROLOGUE 16
    mov rbx, rdi
    mov rax, rsi
    xor edx, edx
    mov ecx, 86400
    div rcx
    mov r12, rdx                # seconds of the day
    # days since 1970-01-01 to a civil date (H. Hinnant's civil_from_days)
    add rax, 719468
    xor edx, edx
    mov ecx, 146097
    div rcx
    mov r13, rax                # era
    mov r14, rdx                # day of the era
    # year of the era: (doe - doe/1460 + doe/36524 - doe/146096) / 365
    mov rax, r14
    xor edx, edx
    mov ecx, 1460
    div rcx
    mov r15, r14
    sub r15, rax
    mov rax, r14
    xor edx, edx
    mov ecx, 36524
    div rcx
    add r15, rax
    mov rax, r14
    xor edx, edx
    mov ecx, 146096
    div rcx
    sub r15, rax
    mov rax, r15
    xor edx, edx
    mov ecx, 365
    div rcx
    mov r15, rax                # yoe
    imul rax, r13, 400
    add rax, r15
    mov [rsp], rax              # the year, counted from March
    # day of the year from March: doe - (365*yoe + yoe/4 - yoe/100)
    imul rcx, r15, 365
    mov rax, r15
    shr rax, 2
    add rcx, rax
    mov rax, r15
    xor edx, edx
    mov r8d, 100
    div r8
    sub rcx, rax
    mov rax, r14
    sub rax, rcx
    mov r14, rax                # doy
    imul rax, r14, 5
    add rax, 2
    xor edx, edx
    mov r8d, 153
    div r8
    mov r13, rax                # mp
    imul rax, r13, 153
    add rax, 2
    xor edx, edx
    mov r8d, 5
    div r8
    sub r14, rax
    inc r14                     # the day
    lea rax, [r13 + 3]
    cmp r13, 10
    jb 1f
    lea rax, [r13 - 9]
1:  mov r13, rax                # the month
    mov rax, [rsp]
    cmp r13, 2
    ja 2f
    inc rax
2:  mov rdi, rbx
    mov esi, eax
    mov edx, 4
    call put_num
    mov byte ptr [rax], '-'
    lea rdi, [rax + 1]
    mov esi, r13d
    mov edx, 2
    call put_num
    mov byte ptr [rax], '-'
    lea rdi, [rax + 1]
    mov esi, r14d
    mov edx, 2
    call put_num
    mov byte ptr [rax], 'T'
    lea rbx, [rax + 1]
    mov rax, r12
    xor edx, edx
    mov ecx, 3600
    div rcx
    mov r13, rdx
    mov rdi, rbx
    mov esi, eax
    mov edx, 2
    call put_num
    mov byte ptr [rax], ':'
    lea rbx, [rax + 1]
    mov rax, r13
    xor edx, edx
    mov ecx, 60
    div rcx
    mov r13, rdx
    mov rdi, rbx
    mov esi, eax
    mov edx, 2
    call put_num
    mov byte ptr [rax], ':'
    lea rdi, [rax + 1]
    mov esi, r13d
    mov edx, 2
    call put_num
    mov byte ptr [rax], 'Z'
    mov byte ptr [rax + 1], 0
    inc rax
    EPILOGUE

# put_num(dst, n, digits) -> rax after it: n with leading zeros to digits
put_num:
    mov eax, esi
    lea r8, [rdi + rdx]
    mov r9, r8
    mov ecx, 10
1:  dec r9
    xor edx, edx
    div ecx
    add dl, '0'
    mov [r9], dl
    cmp r9, rdi
    ja 1b
    mov rax, r8
    ret

.section .rodata
.Lrec_name: .asciz ".rhun-install"
.Lmanifest: .asciz "extension.ini"
.Lprevious: .asciz "/.previous/"
.Lswap: .asciz "/.swap-"
.Lk_link: .asciz "link"
.Lk_path: .asciz "path"
.Lk_started: .asciz "started"
.Lk_tag: .asciz "tag"
.Lyes: .asciz "yes"
.Lempty: .asciz ""
.Lline_started: .asciz "started = yes\n"
.Lline_kept: .asciz "kept = yes\n"
.Lk_kept: .asciz "kept"
.Lno_hello: .asciz "no hello within 5 s"
.Lt_not_started: .asciz " did not start ("
.Lt_failed: .asciz "it failed"
.Lt_back_to: .asciz "); back to "
.Lt_previous: .asciz "the previous version"
.Lt_rolled: .asciz "Rolled back "
.Lt_dot_nl: .asciz ".\n"
.Lt_also: .asciz "It then also asks to: "
.Lq_rollback: .asciz "Roll back \342\200\234"
.Lq_close_to: .asciz "\342\200\235 to "
.Lq_to: .asciz " to "
.Lb_rollback: .asciz "Roll back"
.Le_no_previous: .asciz "There is no previous version to go back to"
.Le_swap: .asciz "Could not swap the two versions' folders"
.Le_full: .asciz "Too many extensions are installed"
.Ln_docs_read: .asciz "read the files you have open"
.Ln_docs_write: .asciz "read and change the files you have open"
.Ln_proj_read: .asciz "read the files in your project"
.Ln_proj_write: .asciz "read and change the files in your project"
.Ln_home: .asciz "read the files in your home folder"
.Ln_net: .asciz "use the internet"
.Ln_terminal: .asciz "suggest terminal commands for you to run"
.Ln_run: .asciz "run "
.Ln_when_tests: .asciz " with your access when you run tests"
.Ln_when_debuggers: .asciz " in the debuggers other extensions provide"
.Ln_as_kernels: .asciz " as you for notebooks"
.Ln_term_run: .asciz "run programs as you in terminal tabs once you allow it in a project"
.Ln_term_input: .asciz "type into the terminals it started"
.Ln_term_output: .asciz "read what they show and what you type there"
.Ln_git: .asciz "read the project's Git history"
.Ln_debug: .asciz "start debug adapters that run as you"
.Ln_audio: .asciz "access local audio devices and services"
.Ln_secrets: .asciz "store passwords and tokens in your keychain"
.Ln_more: .asciz "use more of your system"
.p2align 3
# the [needs] bits beyond documents and the project, and how each is said
wider_bits:
    .quad NEEDS_HOME_READ, .Ln_home, NEEDS_NETWORK, .Ln_net, NEEDS_TERMINAL, .Ln_terminal
    .quad NEEDS_TERM_RUN, .Ln_term_run, NEEDS_TERM_INPUT, .Ln_term_input, NEEDS_TERM_OUTPUT, .Ln_term_output
    .quad NEEDS_GIT_READ, .Ln_git, NEEDS_DEBUG, .Ln_debug, NEEDS_SECRETS, .Ln_secrets, NEEDS_AUDIO, .Ln_audio, 0, 0
.Ln_when_kernels: .asciz " with your access as notebook kernels"
.Ln_sep: .asciz ", "
.Leq: .asciz " = "
.Lr_pack: .asciz "pack in extension.ini must list at most 16 other extensions as owner/name"
