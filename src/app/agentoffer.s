# A request's proposed change (phase 4 task 11): a driver offers the change an edit request would make
# (ev_offer, agent_drv.s); it shows in the Review tab as an offer (review.s), tied to the request's card in
# both directions. The tab's Accept is the card's Yes, its Reject or its closing the card's No, through
# agentcard_resolve with CD_why saying where the answer came from (the driver writes the answer, reading the
# text as it stands with agoffer_text). The card's own answer, a withdrawn request, a turn's end, a dead
# process, a closed conversation, a project switch and quit go through aq_free, which withdraws the offer
# (agoffer_drop): its tab closes and nothing is sent. Decisions in the tab obey the card's lock (offer_locked:
# the half second of agentcard_live), and a close waits it out before it answers.
#
# The offer's owner context is the request (AQ*): aq_free withdraws the offer before the request is freed, and
# review.s calls an owner only from review_tick while the offer is not withdrawn, so no callback ever sees a
# freed request. One offer a conversation: only the head request's card shows, and offering a change closes
# the offer of any other request of the conversation.
#
# Nothing here knows a driver: the path and the two texts come from it (ev_offer), the label is the driver's
# name and the file's name.
#
#   agoffer_open(AS*, AQ*, path cstr, OT*, flags OFF_*) -> eax 1 offered (or offered already)
#   agoffer_drop(AQ*)                          aq_free: its offer closes, nothing is sent
#   agoffer_text(AQ*) -> rax ptr, rdx len, ecx edited, r8d reverted    the proposed text as it stands (rax 0:
#                                              none)
#   agoffer_before(AQ*) -> rax ptr, rdx len    the text the change was made against
#   agoffer_show(AQ*)                          its tab the active one (the card's "Review the change")
#   agoffer_dump(sb, AS*)                      print-agent-offer: the head request's offer
.include "rhun.inc"

.bss
.p2align 3
lsb: .zero SB_SIZE              # a label

.section .rodata
.p2align 3
offer_ops: .quad offer_done, offer_locked_ms, 0, 0   # RVO: no name (the label has the driver's)
.Lcolon: .asciz ": "
.Lnoread: .asciz " (file not read)"
.Lpartial: .asciz " (edited text only)"
.Lnone: .asciz "offer=none"

.text

# FN agoffer_open(AS*, AQ*, path cstr, OT*, flags OFF_*) -> eax 1 when the request's change is offered (or was
#   already: a card shown again keeps its offer); 0 when there is nothing to show
FN agoffer_open
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov r15d, r8d
    mov rdi, [r12 + AQ_offer]
    test rdi, rdi
    jz 1f
    call review_offer_text
    test rax, rax
    jz 1f
    mov eax, 1
    EPILOGUE
1:  mov qword ptr [r12 + AQ_offer], 0
    mov rdi, [rbx + AS_live]    # the conversation's other offers go (one a conversation)
    test rdi, rdi
    jz 3f
    xor ecx, ecx
2:  cmp rcx, [rdi + AL_reqs + VEC_len]
    jae 3f
    mov rax, [rdi + AL_reqs + VEC_ptr]
    mov rax, [rax + rcx*8]
    inc rcx
    cmp rax, r12
    je 2b
    cmp qword ptr [rax + AQ_offer], 0
    je 2b
    push rdi
    push rcx
    mov rdi, rax
    call agoffer_drop
    pop rcx
    pop rdi
    jmp 2b
3:  # the label: the driver's name, a colon, the file's name, the suffix
    lea rdi, [rip + lsb]
    call sb_clear
    mov rax, [rbx + AS_live]
    test rax, rax
    jz 4f
    mov rax, [rax + AL_drv]
    mov rsi, [rax + DRV_name]
    test rsi, rsi
    jz 4f
    lea rdi, [rip + lsb]
    call sb_push_cstr
    lea rdi, [rip + lsb]
    lea rsi, [rip + .Lcolon]
    call sb_push_cstr
4:  mov rdi, r13
    call strlen
    mov rdi, r13
    mov rsi, rax
    call path_basename
    mov rsi, rax
    lea rdi, [rip + lsb]
    call sb_push
    lea rsi, [rip + .Lnoread]
    test r15d, OFF_NOREAD
    jnz 5f
    lea rsi, [rip + .Lpartial]
    test r15d, OFF_PARTIAL
    jz 6f
5:  lea rdi, [rip + lsb]
    call sb_push_cstr
6:  lea rdi, [rip + lsb]
    xor esi, esi
    call sb_push_byte
    lea rdi, [rip + offer_ops]
    mov rsi, r12
    mov rdx, [rip + lsb + SB_ptr]
    mov rcx, r13
    mov r8, r14
    mov r9d, 1                  # shown (a conversation in a tab's view: its card's link shows it, task 13)
    call review_offer
    mov [r12 + AQ_offer], rax
    xor ecx, ecx
    test rax, rax
    setnz cl
    mov eax, ecx
    EPILOGUE

# FN agoffer_drop(AQ*): its offer closes; its owner is not told, nothing is sent
FN agoffer_drop
    test rdi, rdi
    jz 1f
    mov rax, [rdi + AQ_offer]
    test rax, rax
    jz 1f
    mov qword ptr [rdi + AQ_offer], 0
    mov rdi, rax
    jmp review_offer_close
1:  ret

# FN agoffer_text(AQ*) -> rax ptr, rdx len of the proposed text as it stands, ecx 1 edited, r8d 1 reverted;
#   rax 0 without an offer
FN agoffer_text
    mov rdi, [rdi + AQ_offer]
    test rdi, rdi
    jz 1f
    jmp review_offer_text
1:  xor eax, eax
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    ret

# FN agoffer_before(AQ*) -> rax ptr, rdx len of the text the change was made against (rax 0: none)
FN agoffer_before
    mov rdi, [rdi + AQ_offer]
    test rdi, rdi
    jz 1f
    jmp review_offer_before
1:  xor eax, eax
    xor edx, edx
    ret

# FN agoffer_show(AQ*): its offer's tab the active one, the keyboard where it is
FN agoffer_show
    mov rdi, [rdi + AQ_offer]
    test rdi, rdi
    jz 1f
    jmp review_offer_show
1:  ret

# FN agoffer_dump(sb, AS*): print-agent-offer: the conversation's head request's offer, a line
FN agoffer_dump
    PROLOGUE
    mov rbx, rdi
    xor eax, eax
    test rsi, rsi
    jz 1f
    mov rcx, [rsi + AS_live]
    test rcx, rcx
    jz 1f
    cmp qword ptr [rcx + AL_reqs + VEC_len], 0
    je 1f
    mov rcx, [rcx + AL_reqs + VEC_ptr]
    mov rcx, [rcx]
    mov rax, [rcx + AQ_offer]
1:  test rax, rax
    jz 2f
    mov rdi, rax
    mov rsi, rbx
    call review_offer_dump
    jmp 3f
2:  mov rdi, rbx
    lea rsi, [rip + .Lnone]
    call sb_push_cstr
3:  mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    EPILOGUE

# head_of(AQ*) -> rax the live record whose head request it is, or 0
head_of:
    PROLOGUE
    mov r12, rdi
    xor ebx, ebx
1:  mov rdi, rbx
    call agent_live_at
    test rax, rax
    jz 9f
    inc rbx
    cmp qword ptr [rax + AL_reqs + VEC_len], 0
    je 1b
    mov rcx, [rax + AL_reqs + VEC_ptr]
    cmp [rcx], r12
    jne 1b
9:  EPILOGUE

# offer_locked_ms(ctx AQ*) -> eax ms its card's lock still lasts (0: decisions may be taken); a card not shown
#   yet is locked
offer_locked_ms:
    PROLOGUE
    mov rbx, [rdi + AQ_card]
    xor eax, eax
    test rbx, rbx
    jz 9f
    mov eax, [rip + g_card_lock_ms]
    test dword ptr [rbx + CD_flags], CDF_SHOWN
    jz 9f
    call time_ms
    sub rax, [rbx + CD_born]
    movsxd rcx, dword ptr [rip + g_card_lock_ms]
    sub rcx, rax
    xor eax, eax
    test rcx, rcx
    jle 9f
    mov eax, ecx
9:  EPILOGUE

# offer_done(ctx AQ*, outcome OFFER_*, text ptr, len, edited) -> eax 1 taken, 0 again later (the card's lock):
#   the outcome as the card's answer (accepted: its Yes; rejected, closed: its No), when the request is still
#   its conversation's head; otherwise the offer just closes
offer_done:
    PROLOGUE
    mov r12, rdi
    mov r13d, esi
    mov rdi, r12
    call offer_locked_ms
    test eax, eax
    jz 1f
    xor eax, eax
    EPILOGUE
1:  mov rdi, r12
    call head_of
    test rax, rax
    jz 8f
    mov rdi, [rax + AL_as]
    mov rsi, r12
    mov edx, CBA_YES
    mov ecx, CDW_TAB_ACCEPT
    cmp r13d, OFFER_ACCEPT
    je 2f
    mov ecx, CDW_REVERTED
    cmp r13d, OFFER_REVERTED
    je 2f
    mov edx, CBA_NO
    mov ecx, CDW_TAB_REJECT
    cmp r13d, OFFER_REJECT
    je 2f
    mov ecx, CDW_TAB_CLOSED
2:  call agentcard_resolve
    test eax, eax
    jnz 9f
8:  mov rdi, r12                # no card to answer: the offer only closes
    call agoffer_drop
9:  mov eax, 1
    EPILOGUE
