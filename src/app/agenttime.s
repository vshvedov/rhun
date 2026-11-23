# Time for the agents panel's rows: a record's ISO 8601 time to unix milliseconds, the clock. Generic.
# (Phase 3 task 5 adds the local zone, moved here from claude_session.s, and the labels: "3:45 PM", the
# tip's form, a day's label.)
#
#   agtime_iso(ptr, len) -> rax unix ms, 0 when it is no time   "2026-11-22T10:00:00.000Z", with or without
#                                                               the fraction, "Z" or "+hh:mm" / "-hh:mm"
#   agtime_now() -> rax unix ms now (the wall clock)
.include "rhun.inc"

.bss
.p2align 3
now_ts: .zero 16

.text

# FN agtime_now() -> rax the wall clock's unix milliseconds
FN agtime_now
    mov edi, CLOCK_REALTIME
    lea rsi, [rip + now_ts]
    SYS SYS_clock_gettime
    mov rax, [rip + now_ts]
    imul rax, rax, 1000
    mov rcx, rax
    mov rax, [rip + now_ts + 8]
    xor edx, edx
    mov r8d, 1000000
    div r8
    add rax, rcx
    ret

# digits(rdi ptr, esi n) -> eax the number of n ASCII digits, -1 when one is not a digit
digits:
    xor eax, eax
    xor ecx, ecx
1:  cmp ecx, esi
    jae 9f
    movzx edx, byte ptr [rdi + rcx]
    sub edx, '0'
    cmp edx, 9
    ja 8f
    imul eax, eax, 10
    add eax, edx
    inc ecx
    jmp 1b
8:  mov eax, -1
9:  ret

# FN agtime_iso(ptr, len) -> rax unix milliseconds of an ISO 8601 time ("YYYY-MM-DDTHH:MM:SS", then
#   ".fff" of any length, then "Z" or "+hh:mm" / "-hh:mm"); 0 when the text is no such time
FN agtime_iso
    PROLOGUE 48
    mov rbx, rdi
    mov r12, rsi
    cmp r12, 20
    jb 8f
    cmp byte ptr [rbx + 4], '-'
    jne 8f
    cmp byte ptr [rbx + 7], '-'
    jne 8f
    movzx eax, byte ptr [rbx + 10]
    cmp eax, 'T'
    je 1f
    cmp eax, 't'
    je 1f
    cmp eax, ' '
    jne 8f
1:  cmp byte ptr [rbx + 13], ':'
    jne 8f
    cmp byte ptr [rbx + 16], ':'
    jne 8f
    mov rdi, rbx                # year
    mov esi, 4
    call digits
    test eax, eax
    js 8f
    cmp eax, 1
    jl 8f
    mov [rsp], eax
    lea rdi, [rbx + 5]          # month
    mov esi, 2
    call digits
    dec eax
    cmp eax, 11
    ja 8f
    inc eax
    mov [rsp + 4], eax
    lea rdi, [rbx + 8]          # day
    mov esi, 2
    call digits
    dec eax
    cmp eax, 30
    ja 8f
    inc eax
    mov [rsp + 8], eax
    lea rdi, [rbx + 11]         # hour
    mov esi, 2
    call digits
    cmp eax, 23
    ja 8f
    mov [rsp + 12], eax
    lea rdi, [rbx + 14]         # minute
    mov esi, 2
    call digits
    cmp eax, 59
    ja 8f
    mov [rsp + 16], eax
    lea rdi, [rbx + 17]         # second (a leap second is the next one's start)
    mov esi, 2
    call digits
    cmp eax, 60
    ja 8f
    mov [rsp + 20], eax
    # the fraction: its first three digits are milliseconds
    mov r13d, 19                # p
    xor r14d, r14d              # ms
    cmp byte ptr [rbx + r13], '.'
    jne 3f
    inc r13d
    mov r15d, 100
2:  cmp r13, r12
    jae 8f
    movzx eax, byte ptr [rbx + r13]
    sub eax, '0'
    cmp eax, 9
    ja 3f
    imul eax, r15d
    add r14d, eax
    mov eax, r15d
    xor edx, edx
    mov ecx, 10
    div ecx
    mov r15d, eax
    inc r13d
    jmp 2b
3:  # the zone: Z, or +hh:mm / -hh:mm (east of UTC is ahead: subtracted)
    xor r15d, r15d              # its offset, seconds
    cmp r13, r12
    jae 8f
    movzx eax, byte ptr [rbx + r13]
    cmp eax, 'Z'
    je 4f
    cmp eax, 'z'
    je 4f
    cmp eax, '+'
    je 5f
    cmp eax, '-'
    jne 8f
5:  lea rax, [r13 + 6]
    cmp rax, r12
    ja 8f
    cmp byte ptr [rbx + r13 + 3], ':'
    jne 8f
    lea rdi, [rbx + r13 + 1]
    mov esi, 2
    call digits
    cmp eax, 23
    ja 8f
    imul r15d, eax, 3600
    lea rdi, [rbx + r13 + 4]
    mov esi, 2
    call digits
    cmp eax, 59
    ja 8f
    imul eax, eax, 60
    add r15d, eax
    cmp byte ptr [rbx + r13], '-'
    jne 51f
    neg r15d
51: add r13d, 5
4:  inc r13d
    cmp r13, r12
    jne 8f                      # something after the zone
    # days from 1970-01-01 (the civil calendar)
    mov eax, [rsp]              # y
    mov ecx, [rsp + 4]          # m
    cmp ecx, 2
    jg 6f
    dec eax
6:  cdq
    mov r8d, 400
    idiv r8d                    # eax era (years >= 1: no negative eras), edx yoe
    mov r9d, eax
    mov r10d, edx
    mov eax, [rsp + 4]
    lea ecx, [rax - 3]
    cmp eax, 2
    jg 7f
    lea ecx, [rax + 9]
7:  imul ecx, ecx, 153
    add ecx, 2
    mov eax, ecx
    cdq
    mov r8d, 5
    idiv r8d
    add eax, [rsp + 8]
    dec eax                     # doy
    mov r11d, eax
    imul eax, r10d, 365         # doe = yoe*365 + yoe/4 - yoe/100 + doy
    mov ecx, r10d
    shr ecx, 2
    add eax, ecx
    mov ecx, eax
    mov eax, r10d
    xor edx, edx
    mov r8d, 100
    div r8d
    sub ecx, eax
    add ecx, r11d
    movsxd rax, r9d
    imul rax, rax, 146097
    movsxd rcx, ecx
    add rax, rcx
    sub rax, 719468             # days
    imul rax, rax, 86400
    mov ecx, [rsp + 12]
    imul ecx, ecx, 3600
    movsxd rcx, ecx
    add rax, rcx
    mov ecx, [rsp + 16]
    imul ecx, ecx, 60
    add ecx, [rsp + 20]
    movsxd rcx, ecx
    add rax, rcx
    movsxd rcx, r15d
    sub rax, rcx
    imul rax, rax, 1000
    mov ecx, r14d
    add rax, rcx
    test rax, rax
    jle 8f
    EPILOGUE
8:  xor eax, eax
    EPILOGUE
