# Owned clipboard destinations. Async delivery never follows a different focused target.
.include "rhun.inc"
.bss
.p2align 3
.globl app_clip_active_token
app_clip_active_token: .quad 0
clip_request_next: .quad 0
clip_requests: .zero 8 * CPR_COUNT
clip_request_count: .quad 0
clip_pumping: .quad 0
.globl g_clip_last_kind, g_clip_read, g_clip_asked
g_clip_asked: .quad 0           # the kinds the last request the platform got asked for (print-clip)
g_clip_last_kind: .quad 0       # the kind of the last completion that reached a request (print-clip)
g_clip_read: .quad 0            #   and the bytes it brought (a platform that stopped past a limit: what it read)
.globl clip_delivery_view
clip_delivery_view: .quad 0
.text

# A view applies only to the exact counted bytes of this delivery.
FN clip_delivery_get
    mov rax, [rip + clip_delivery_view]
    test rax, rax
    jz 1f
    cmp rdi, [rax + CWB_text]
    jne 2f
    cmp rsi, [rax + CWB_len]
    je 1f
2:  xor eax, eax
1:  ret

# Valid-format result, independent of whether the destination still accepts Paste.
# Invalid wire leaves the captured request available for the platform's plain fallback.
FN app_clip_complete_native
    PROLOGUE CWB_SIZE
    mov r12, rdi
    mov rdi, rsi
    mov rsi, rdx
    mov rdx, rsp
    call clip_wire_decode
    test eax, eax
    jz 1f
    mov r13, [rip + clip_delivery_view]
    mov [rip + clip_delivery_view], rsp
    mov rdi, r12
    mov rsi, [rsp + CWB_text]
    mov rdx, [rsp + CWB_len]
    mov ecx, 1
    call clip_complete
    mov [rip + clip_delivery_view], r13
    mov eax, 1
1:  EPILOGUE

# clip_context_capture(empty_context) -> bool. Caller owns the secondary snapshot.
FN clip_context_capture
    PROLOGUE
    mov rbx, rdi
    xor esi, esi
    mov edx, CPX_SIZE
    call memset
    mov eax, [rip + g_focus]
    mov [rbx + CPX_focus], rax
    cmp eax, FOCUS_TERMINAL
    je .Lcc_terminal
    cmp eax, FOCUS_VIEW         # a picture with the keyboard (views group, viewpic.s)
    jne 0f
    call views_paste_target
    test rax, rax
    jz 0f
    mov [rbx + CPX_identity], rax
    mov ecx, [rax + VW_id]      # and which view of whose: a slot taken again is another one
    mov [rbx + CPX_revision], rcx
    mov rcx, [rax + VW_ext]
    mov [rbx + CPX_owner], rcx
    mov qword ptr [rbx + CPX_kind], CPX_PICTURE
    jmp .Lcc_good
0:  call focused_field
    test rax, rax
    jnz .Lcc_field
    cmp dword ptr [rip + g_focus], FOCUS_EDITOR
    jne .Lcc_bad
    mov r12, [rip + g_doc]
    test r12, r12
    jz .Lcc_bad
    test dword ptr [r12 + DOC_flags], DF_READONLY
    jnz .Lcc_bad
    cmp qword ptr [r12 + DOC_selectionbatch], 0
    jne .Lcc_bad
    mov rax, [r12 + DOC_id]
    test rax, rax
    jz .Lcc_bad
    mov [rbx + CPX_identity], rax
    mov qword ptr [rbx + CPX_kind], CPX_DOCUMENT
    mov rax, [r12 + DOC_version]
    mov [rbx + CPX_revision], rax
    mov rax, [r12 + DOC_cur]
    mov [rbx + CPX_cur], rax
    mov rax, [r12 + DOC_anchor]
    mov [rbx + CPX_anchor], rax
    mov rdi, r12
    call doc_selections_snapshot
    mov [rbx + CPX_extras], rax
    jmp .Lcc_mode
.Lcc_field:
    mov r12, rax
    mov qword ptr [rbx + CPX_kind], CPX_FIELD
    mov [rbx + CPX_identity], rax
    mov rax, [r12 + TF_revision]
    mov [rbx + CPX_revision], rax
    mov rax, [r12 + TF_cur]
    mov [rbx + CPX_cur], rax
    mov rax, [r12 + TF_anchor]
    mov [rbx + CPX_anchor], rax
    mov eax, [r12 + TF_id]
    mov [rbx + CPX_flags], rax
    mov rax, [r12 + TF_sb + SB_len]
    mov [rbx + CPX_length], rax
    mov rax, [rip + g_doc]
    test rax, rax
    jz 1f
    mov rax, [rax + DOC_id]
    mov [rbx + CPX_owner], rax
1:  mov eax, [rip + g_vim_cmdline]
    mov [rbx + CPX_submode], rax
.Lcc_mode:
    mov eax, [rip + g_vim_mode]
    shl rax, 32
    mov ecx, [rip + cfg_vim]
    or rax, rcx
    mov [rbx + CPX_vim], rax
    cmp qword ptr [rbx + CPX_kind], CPX_DOCUMENT
    jne .Lcc_good
    mov rdi, rbx
    mov rsi, r12
    call vim_clip_context
    jmp .Lcc_good
.Lcc_terminal:
    call term_clip_identity
    test rax, rax
    jz .Lcc_bad
    mov [rbx + CPX_identity], rax
    mov qword ptr [rbx + CPX_kind], CPX_TERMINAL
.Lcc_good:
    mov eax, 1
    EPILOGUE
.Lcc_bad:
    xor eax, eax
    EPILOGUE

# Release only the owned selection snapshot. The context itself may be on the stack.
FN clip_context_clear
    mov rax, [rdi + CPX_extras]
    mov qword ptr [rdi + CPX_extras], 0
    mov rdi, rax
    jmp mem_free

# clone(empty_dest, trusted_source), with independent secondary selection ownership.
FN clip_context_clone
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov edx, CPX_SIZE
    call memcpy
    mov qword ptr [rbx + CPX_extras], 0
    mov rdi, [r12 + CPX_extras]
    test rdi, rdi
    jz 1f
    mov rsi, [rdi + DMS_count]
    shl rsi, 4
    add rsi, DMS_DATA
    call mem_dup
    mov [rbx + CPX_extras], rax
1:  EPILOGUE

# Contexts are trusted, bounded owned captures. Compare identities before any endpoints.
FN clip_context_equal
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov edx, CPX_extras
    call memeq
    test eax, eax
    jz .Lcce_done
    lea rdi, [rbx + CPX_owner]
    lea rsi, [r12 + CPX_owner]
    mov edx, CPX_SIZE - CPX_owner
    call memeq
    test eax, eax
    jz .Lcce_done
    mov rdi, [rbx + CPX_extras]
    mov rsi, [r12 + CPX_extras]
    cmp rdi, rsi
    je .Lcce_same
    test rdi, rdi
    jz .Lcce_no
    test rsi, rsi
    jz .Lcce_no
    mov rdx, [rdi + DMS_count]
    cmp rdx, [rsi + DMS_count]
    jne .Lcce_no
    shl rdx, 4
    add rdx, DMS_DATA
    call memeq
    jmp .Lcce_done
.Lcce_same:
    mov eax, 1
    jmp .Lcce_done
.Lcce_no:
    xor eax, eax
.Lcce_done:
    EPILOGUE

FN clip_context_matches
    PROLOGUE CPX_SIZE
    mov r12, rdi
    mov rdi, rsp
    call clip_context_capture
    test eax, eax
    jz 1f
    mov rdi, r12
    mov rsi, rsp
    call clip_context_equal
1:  mov r13d, eax
    mov rdi, rsp
    call clip_context_clear
    mov eax, r13d
    EPILOGUE

# Request wrappers capture destination now. Only the FIFO head touches the platform. A plain request takes
# what its destination takes (phase 4 task 4): the agents' box of a driver with parts also files and an image
# (agpaste_kinds), everything else text.
FN app_clip_request
    sub rsp, 8
    call agpaste_kinds
    add rsp, 8
    mov r9d, eax
    xor edi, edi
    xor esi, esi
    xor edx, edx
    xor r8d, r8d
    jmp clip_request_enqueue
FN app_clip_request_vim
    mov r8d, 1
    mov r9d, CLIPK_TEXT
clip_request_enqueue:
    PROLOGUE 48
    mov [rsp], rdi
    mov [rsp + 8], rsi
    mov [rsp + 16], rdx
    mov [rsp + 24], r8
    mov [rsp + 32], r9
    cmp qword ptr [rip + clip_request_count], CPR_COUNT
    jae .Lcre_full
    cmp qword ptr [rip + clip_request_next], -1
    je .Lcre_no
    test r8d, r8d
    jz 1f
    cmp edi, 'p'
    je 2f
    cmp edi, 'P'
    jne .Lcre_no
2:  test rsi, rsi
    jz .Lcre_no
    cmp rsi, 0x7fffffff
    ja .Lcre_no
    cmp edx, VM_INSERT
    je .Lcre_no
    cmp edx, VM_VLINE
    ja .Lcre_no
1:  mov edi, CPR_SIZE
    call mem_alloc
    mov rbx, rax
    mov rdi, rax
    call clip_context_capture
    test eax, eax
    jz .Lcre_free
    cmp qword ptr [rsp + 24], 0
    je 3f
    cmp qword ptr [rbx + CPX_kind], CPX_DOCUMENT
    jne .Lcre_free
    cmp dword ptr [rbx + CPX_vim], 0
    je .Lcre_free
    mov eax, [rbx + CPX_vim + 4]
    cmp eax, [rsp + 16]
    jne .Lcre_free
3:  inc qword ptr [rip + clip_request_next]
    mov rax, [rip + clip_request_next]
    mov [rbx + CPR_token], rax
    mov rax, [rsp + 24]
    mov [rbx + CPR_operation], rax
    mov rax, [rsp]
    mov [rbx + CPR_putkind], rax
    mov rax, [rsp + 8]
    mov [rbx + CPR_putcount], rax
    mov rax, [rsp + 16]
    mov [rbx + CPR_putmode], rax
    mov eax, [rsp + 32]
    mov [rbx + CPR_kinds], eax
    mov dword ptr [rbx + CPR_imgmax], MP_IMAGE_MAX + 1
    mov rax, [rip + clip_request_count]
    lea rdx, [rip + clip_requests]
    mov [rdx + rax*8], rbx
    inc qword ptr [rip + clip_request_count]
    cmp qword ptr [rbx + CPR_operation], 0
    je 4f
    mov edi, [rbx + CPR_putmode]
    call vim_clip_accepted
4:  call app_clip_pump
    mov eax, 1
    EPILOGUE
.Lcre_free:
    mov rdi, rbx
    call clip_context_clear
    mov rdi, rbx
    call mem_free
.Lcre_no:
    xor eax, eax
    EPILOGUE
.Lcre_full:
    lea rdi, [rip + .Lclip_pending_full]
    call app_toast
    jmp .Lcre_no

# Detach before releasing the old head. No callbacks or transport operations here.
clip_request_pop:
    PROLOGUE
    mov rbx, [rip + clip_requests]
    mov qword ptr [rip + app_clip_active_token], 0
    dec qword ptr [rip + clip_request_count]
    mov rcx, [rip + clip_request_count]
    shl rcx, 3
    lea rdi, [rip + clip_requests]
    lea rsi, [rdi + 8]
    rep movsb
    mov rax, [rip + clip_request_count]
    lea rdx, [rip + clip_requests]
    mov qword ptr [rdx + rax*8], 0
    mov rdi, rbx
    call clip_context_clear
    mov rdi, rbx
    call mem_free
    EPILOGUE

# At most16 stale discards and one platform submission per pump. Sync successors yield.
FN app_clip_pump
    PROLOGUE
    cmp qword ptr [rip + clip_pumping], 0
    jne .Lcpp_done
    mov qword ptr [rip + clip_pumping], 1
    mov r12d, CPR_COUNT
.Lcpp_next:
    cmp qword ptr [rip + clip_request_count], 0
    je .Lcpp_unlock
    mov rbx, [rip + clip_requests]
    cmp qword ptr [rbx + CPR_started], 0
    jne .Lcpp_unlock
    mov rdi, rbx
    call clip_context_matches
    test eax, eax
    jz .Lcpp_stale
    mov qword ptr [rbx + CPR_started], 1
    mov rax, [rbx + CPR_token]
    mov [rip + app_clip_active_token], rax
    mov edi, [rbx + CPR_kinds]
    mov [rip + g_clip_asked], rdi
    mov esi, [rbx + CPR_imgmax]
    PCALL P_clip_get
    jmp .Lcpp_unlock
.Lcpp_stale:
    call clip_request_pop
    dec r12d
    jnz .Lcpp_next
.Lcpp_unlock:
    mov qword ptr [rip + clip_pumping], 0
.Lcpp_done:
    EPILOGUE

FN app_clip_timeout
    mov eax, -1
    cmp qword ptr [rip + clip_request_count], 0
    je 1f
    mov rdx, [rip + clip_requests]
    cmp qword ptr [rdx + CPR_started], 0
    jne 1f
    xor eax, eax
1:  ret

FN app_clip_tick
    jmp app_clip_pump

# Shutdown/reset never attempts a new transport. Nonzero old tokens become stale.
FN app_clip_reset
    PROLOGUE
1:  cmp qword ptr [rip + clip_request_count], 0
    je 2f
    call clip_request_pop
    jmp 1b
2:  mov qword ptr [rip + app_clip_active_token], 0
    EPILOGUE

.section .rodata
.Lclip_pending_full: .asciz "Too many paste requests are pending"
.text

# Rebase only an unchanged original destination. Operation parameters stay per-request.
FN clip_request_rebase
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov rax, [r12 + CPX_kind]
    cmp rax, [r13 + CPX_kind]
    jne .Lcrr_done
    mov rax, [r12 + CPX_identity]
    cmp rax, [r13 + CPX_identity]
    jne .Lcrr_done
    mov rax, [r12 + CPX_owner]
    cmp rax, [r13 + CPX_owner]
    jne .Lcrr_done
    mov rax, [r12 + CPX_focus]
    cmp rax, [r13 + CPX_focus]
    jne .Lcrr_done
    cmp qword ptr [r12 + CPX_kind], CPX_FIELD
    jne 1f
    mov rax, [r12 + CPX_flags]
    cmp rax, [r13 + CPX_flags]
    jne .Lcrr_done
    mov rax, [r12 + CPX_submode]
    cmp rax, [r13 + CPX_submode]
    jne .Lcrr_done
1:  mov r14d, 1
.Lcrr_next:
    cmp r14, [rip + clip_request_count]
    jae .Lcrr_done
    lea rax, [rip + clip_requests]
    mov rbx, [rax + r14*8]
    cmp qword ptr [rbx + CPR_started], 0
    jne .Lcrr_skip
    cmp qword ptr [rbx + CPR_operation], 0
    je 2f
    mov eax, [r13 + CPX_vim + 4]
    cmp eax, [rbx + CPR_putmode]
    jne .Lcrr_skip
2:  mov rdi, r12
    mov rsi, rbx
    call clip_context_equal
    test eax, eax
    jz .Lcrr_skip
    mov rdi, rbx
    call clip_context_clear
    mov rdi, rbx
    mov rsi, r13
    call clip_context_clone
.Lcrr_skip:
    inc r14
    jmp .Lcrr_next
.Lcrr_done:
    EPILOGUE

# Normalize only a valid document delivery, after every rejection preflight.
clip_request_prepare:
    cmp qword ptr [rdi + CPX_kind], CPX_DOCUMENT
    jne .Lcrp_return
    cmp dword ptr [rip + cfg_vim], 0
    je .Lcrp_return
    PROLOGUE
    mov rbx, rdi
    mov rdi, [rip + g_doc]
    call vim_view
    cmp qword ptr [rbx + CPR_operation], 0
    jne 1f
    call vim_export
1:  EPILOGUE
.Lcrp_return:
    ret

# Platform owns bytes through this call. A nonzero stale token never routes text.
FN app_clip_complete
    PROLOGUE
    mov r12, [rip + clip_delivery_view]
    mov qword ptr [rip + clip_delivery_view], 0
    call clip_complete
    mov [rip + clip_delivery_view], r12
    EPILOGUE
clip_complete:
    test rdi, rdi
    jnz .Lclc_tagged
    cmp ecx, 1
    jne .Lclc_legacy_done
    mov rdi, rsi
    mov rsi, rdx
    jmp app_on_paste
.Lclc_legacy_done:
    ret
.Lclc_tagged:
    PROLOGUE CPX_SIZE
    mov r12, rsi
    mov r13, rdx
    cmp qword ptr [rip + clip_request_count], 0
    je .Lclc_done
    mov rbx, [rip + clip_requests]
    cmp rdi, [rbx + CPR_token]
    jne .Lclc_done
    cmp qword ptr [rbx + CPR_started], 1
    jne .Lclc_done
    mov qword ptr [rbx + CPR_started], 2
    mov qword ptr [rip + g_clip_last_kind], CLIPK_TEXT
    mov [rip + g_clip_read], r13
    cmp ecx, 1
    jne .Lclc_pop
    cmp r13, DOC_MULTI_BYTES_MAX
    ja .Lclc_pop
    test r13, r13
    jz .Lclc_pop
    test r12, r12
    jz .Lclc_pop
    mov rdi, r12
    mov rsi, r13
    call snippet_utf8_valid
    test eax, eax
    jz .Lclc_pop
    mov rdi, rbx
    call clip_context_matches
    test eax, eax
    jz .Lclc_pop
    cmp qword ptr [rbx + CPR_operation], 0
    je .Lclc_normal
    mov eax, DOC_MULTI_BYTES_MAX
    xor edx, edx
    div r13
    cmp [rbx + CPR_putcount], rax
    ja .Lclc_pop
    mov rax, [rbx + CPR_putcount]
    imul rax, r13
    cmp qword ptr [rbx + CPR_putmode], VM_VISUAL
    jb 1f
    inc rax                       # visual put may add a separating newline
1:  cmp rax, DOC_MULTI_BYTES_MAX
    ja .Lclc_pop
    mov rdi, rbx
    call clip_request_prepare
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call vim_clip_apply
    jmp .Lclc_post
.Lclc_normal:
    mov rdi, rbx
    call clip_request_prepare
    call vim_clip_clear_legacy
    mov rdi, r12
    mov rsi, r13
    call app_on_paste
.Lclc_post:
    mov rdi, rsp
    call clip_context_capture
    test eax, eax
    jz 2f
    mov rdi, rbx
    mov rsi, rsp
    call clip_request_rebase
2:  mov rdi, rsp
    call clip_context_clear
.Lclc_pop:
    call clip_request_pop
    call app_clip_pump
.Lclc_done:
    EPILOGUE

# ---- phase 4 task 4: files and an image beside text ----

# FN app_clip_request_kinds(kinds CLIPK_*) -> eax 1 queued: a request for the focused destination that takes
#   those kinds (app_clip_request asks for what the destination takes)
FN app_clip_request_kinds
    mov r9d, edi
    xor edi, edi
    xor esi, esi
    xor edx, edx
    xor r8d, r8d
    jmp clip_request_enqueue

# FN app_clip_complete_kind(token, kind CLIPK_*, ptr, len): a platform's answer of one kind. Text is
#   app_clip_complete's. Files (absolute paths, a NUL after each) or an image's bytes reach the destination
#   (agpaste_take) only for the head request that asked for that kind, while its destination is still the one
#   that asked (clip_context_matches); ptr 0 is a failure (len CLIP_TOO_BIG: the image was larger than the
#   request reads, which the destination says). The platform owns the bytes through this call.
FN app_clip_complete_kind
    cmp esi, CLIPK_TEXT
    jne 1f
    mov rsi, rdx                # text: (token, ptr, len, ok)
    mov rdx, rcx
    xor ecx, ecx
    test rsi, rsi
    setnz cl
    jmp app_clip_complete
1:  PROLOGUE 16
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    test rdi, rdi
    jz .Lcck_done
    cmp qword ptr [rip + clip_request_count], 0
    je .Lcck_done
    mov rbx, [rip + clip_requests]
    cmp rdi, [rbx + CPR_token]
    jne .Lcck_done
    cmp qword ptr [rbx + CPR_started], 1
    jne .Lcck_done
    mov qword ptr [rbx + CPR_started], 2
    mov [rip + g_clip_last_kind], r12
    test r13, r13
    jnz 3f
    cmp r14, CLIP_TOO_BIG       # (the platform set g_clip_read to what it read before it stopped)
    je 2f
    xor r14d, r14d
3:  mov [rip + g_clip_read], r14
2:  test [rbx + CPR_kinds], r12d
    jz .Lcck_pop
    mov rdi, rbx
    call clip_context_matches
    test eax, eax
    jz .Lcck_pop
    mov edi, r12d
    mov rsi, r13
    mov rdx, r14
    call agpaste_take
.Lcck_pop:
    call clip_request_pop
    call app_clip_pump
.Lcck_done:
    EPILOGUE
