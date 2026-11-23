# Time for the agents panel's rows: a record's ISO 8601 time to unix milliseconds, the local zone, the
# labels the thread shows ("3:45 PM", the tip's "2026-11-23 15:45:07 MST", a day's "Mon, Nov 23"). Generic.
# The zone: a time's offset by its own date, from the zone file (TZ naming one, else /etc/localtime; read
# once) by its transitions and past the last one by its POSIX rule; no file: UTC; Windows asks the system
# for that time (win_tz_offset: the zone's rules for that year), with no abbreviation.
#
#   agtime_iso(ptr, len) -> rax unix ms, 0 when it is no time   "2026-11-22T10:00:00.000Z", with or without
#                                                               the fraction, "Z" or "+hh:mm" / "-hh:mm"
#   agtime_now() -> rax unix ms now (the wall clock)
#   agtime_offset(unix s) -> rax seconds east of UTC then, rdx the zone's abbreviation then (a cstr valid
#                           until the next call) or 0 (none, or only a number such as "+03")
#   agtime_days(unix s) -> rax the local day (days since 1970-01-01), rdx its second
#   agtime_civil(days) -> rax the year, edx the month (1-12), ecx the day
#   agtime_days_of(year, month, day) -> rax days since 1970-01-01
#   agtime_day(unix ms) -> rax its local day
#   agtime_clock(sb, unix ms)       "3:45 PM" (12-hour, local)
#   agtime_full(sb, unix ms)        "2026-11-23 15:45:07 MST" (24-hour; without an abbreviation "UTC-7",
#                                   "UTC+5:30", "UTC")
#   agtime_daylabel(sb, unix ms)    "Mon, Nov 23", with ", 2025" when its year is not this one
#   day_names, month_names          "Sun".."Sat", "Jan".."Dec", 4 bytes each
.include "rhun.inc"

.equ ABBR_MAX, 15
.equ LT_Y, 0                    # ltm's fields
.equ LT_M, 4
.equ LT_D, 8
.equ LT_H, 12
.equ LT_MIN, 16
.equ LT_S, 20
.equ LT_WD, 24
.equ LT_OFF, 28

.data
.globl day_names, month_names
day_names: .ascii "Sun\0Mon\0Tue\0Wed\0Thu\0Fri\0Sat\0"
month_names: .ascii "Jan\0Feb\0Mar\0Apr\0May\0Jun\0Jul\0Aug\0Sep\0Oct\0Nov\0Dec\0"

.bss
.p2align 3
now_ts: .zero 16
tz_tried: .long 0               # the zone file was looked for (tz_load)
tz_n: .zero 4 * 6               # a zone file header's counts
.p2align 3
tz_buf: .quad 0                 # the zone file (owned), or 0
tz_len: .quad 0
tz_p: .quad 0                   # the POSIX rule being read, and its end
tz_end: .quad 0
pz_ns: .quad 0                  # the last zone name pz_name read (without "<" ">") and its length
pz_nl: .quad 0
tz_path: .zero 256
tz_abbr: .zero ABBR_MAX + 1     # the abbreviation of the last offset asked
.p2align 2
ltm: .zero 4 * 10                # lt_fill's parts: year, month, day, hour, minute, second, weekday, offset
.p2align 3
lt_abbr: .quad 0                # its abbreviation or 0

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

# FN agtime_days(unix seconds) -> rax the local day (days since 1970-01-01), rdx its second
FN agtime_days
    PROLOGUE
    mov rbx, rdi
    call tz_offset
    add rax, rbx
    jns 1f
    xor eax, eax
1:  xor edx, edx
    mov ecx, 86400
    div rcx
    EPILOGUE

# FN agtime_civil(days since 1970-01-01, not before it) -> rax the year, edx the month (1-12), ecx the day (H. Hinnant's
#   civil_from_days)
FN agtime_civil
    lea rax, [rdi + 719468]
    xor edx, edx
    mov ecx, 146097
    div rcx
    mov r8, rax                 # the era
    mov r9, rdx                 # the day of the era
    mov rax, r9                 # the year of the era: (doe - doe/1460 + doe/36524 - doe/146096) / 365
    xor edx, edx
    mov ecx, 1460
    div rcx
    mov r10, r9
    sub r10, rax
    mov rax, r9
    xor edx, edx
    mov ecx, 36524
    div rcx
    add r10, rax
    mov rax, r9
    xor edx, edx
    mov ecx, 146096
    div rcx
    sub r10, rax
    mov rax, r10
    xor edx, edx
    mov ecx, 365
    div rcx
    mov r10, rax                # yoe
    imul rcx, r10, 365          # the day of the year from March: doe - (365 yoe + yoe/4 - yoe/100)
    mov rax, r10
    shr rax, 2
    add rcx, rax
    mov rax, r10
    xor edx, edx
    mov r11d, 100
    div r11
    sub rcx, rax
    sub r9, rcx                 # doy
    imul rax, r9, 5             # mp = (5 doy + 2) / 153
    add rax, 2
    xor edx, edx
    mov r11d, 153
    div r11
    mov r11, rax
    imul rax, r11, 153          # the day: doy - (153 mp + 2) / 5 + 1
    add rax, 2
    xor edx, edx
    mov ecx, 5
    div rcx
    mov rcx, r9
    sub rcx, rax
    inc rcx
    lea rdx, [r11 + 3]          # the month: mp < 10 ? mp + 3 : mp - 9
    cmp r11, 10
    jb 1f
    lea rdx, [r11 - 9]
1:  imul rax, r8, 400
    add rax, r10
    cmp edx, 2
    ja 2f
    inc rax
2:  ret

# FN agtime_days_of(year, month, day) -> rax days since 1970-01-01 (H. Hinnant's days_from_civil; years from 1)
FN agtime_days_of
    mov rax, rdi
    cmp esi, 2
    ja 1f
    dec rax
1:  xor r8d, r8d
    mov r9, rax
    test rax, rax
    js 9f
    push rdx
    xor edx, edx
    mov ecx, 400
    div rcx
    mov r8, rax                 # the era
    mov r9, rdx                 # yoe
    pop rdx
    lea eax, [rsi - 3]          # doy = (153 (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1
    cmp esi, 2
    ja 2f
    lea eax, [rsi + 9]
2:  mov r10d, edx
    imul eax, eax, 153
    add eax, 2
    xor edx, edx
    mov ecx, 5
    div ecx
    lea r10, [rax + r10 - 1]
    imul rax, r9, 365           # doe = 365 yoe + yoe/4 - yoe/100 + doy
    mov rcx, r9
    shr rcx, 2
    add rax, rcx
    push rax
    mov rax, r9
    xor edx, edx
    mov ecx, 100
    div rcx
    mov rcx, rax
    pop rax
    sub rax, rcx
    add rax, r10
    imul rcx, r8, 146097
    add rax, rcx
    sub rax, 719468
    ret
9:  xor eax, eax
    ret

# tz_offset(unix seconds) -> rax the local zone's offset east of UTC then, in seconds: the zone file (TZ
#   naming one, else /etc/localtime; read once, on a writer's notice: a rate limit) by its transitions, and
#   past the last one by its POSIX rule ("PST8PDT,M3.2.0,M11.1.0": the M forms; others keep standard
#   time). No file (Windows, a container without one): UTC
tz_offset:
    PROLOGUE 32
    mov rbx, rdi
    mov byte ptr [rip + tz_abbr], 0
    call tz_load
    test rax, rax
    jz .Ltz_zero
    mov r12, rax                # the file
    mov r13, rdx
    cmp r13, 44
    jb .Ltz_zero
    cmp dword ptr [r12], 0x66695a54     # "TZif"
    jne .Ltz_zero
    xor esi, esi
    call tz_counts
    mov r15d, 4                 # the size of a transition's time
    mov r14d, 44                # where the data starts
    cmp byte ptr [r12 + 4], '2'
    jb 1f
    mov eax, [rip + tz_n + 12]  # past the version 1 block: the 64-bit one
    imul eax, eax, 5
    mov ecx, [rip + tz_n + 16]
    imul ecx, ecx, 6
    add eax, ecx
    add eax, [rip + tz_n + 20]
    mov ecx, [rip + tz_n + 8]
    shl ecx, 3
    add eax, ecx
    add eax, [rip + tz_n + 4]
    add eax, [rip + tz_n]
    lea rsi, [rax + 44]
    lea rcx, [rsi + 44]
    cmp rcx, r13
    ja .Ltz_zero
    cmp dword ptr [r12 + rsi], 0x66695a54
    jne .Ltz_zero
    mov r14, rsi
    call tz_counts
    add r14, 44
    mov r15d, 8
1:  mov eax, [rip + tz_n + 12]  # the transitions, their types, the types, the names, leaps, flags: in the file
    imul rax, r15
    lea r8, [r14 + rax]         # the types of the transitions
    mov eax, [rip + tz_n + 12]
    lea r9, [r8 + rax]          # the types
    mov eax, [rip + tz_n + 16]
    imul eax, eax, 6
    lea r10, [r9 + rax]
    add r10d, [rip + tz_n + 20]
    lea rax, [r15 + 4]
    imul eax, [rip + tz_n + 8]
    add r10, rax
    add r10d, [rip + tz_n + 4]
    add r10d, [rip + tz_n]      # the end of the data: the footer's "\n" after it (version 2 on)
    cmp r10, r13
    ja .Ltz_zero
    mov [rsp], r9
    mov [rsp + 8], r10
    mov [rsp + 16], r8
    mov ecx, -1                 # the last transition at or before t
    xor edx, edx
2:  cmp edx, [rip + tz_n + 12]
    jae 4f
    mov eax, edx
    imul rax, r15
    add rax, r14
    cmp r15d, 8
    jne 3f
    mov rax, [r12 + rax]
    bswap rax
    jmp 31f
3:  mov eax, [r12 + rax]
    bswap eax
    movsxd rax, eax
31: cmp rax, rbx
    jg 4f
    mov ecx, edx
    inc edx
    jmp 2b
4:  mov eax, [rip + tz_n + 12]  # past the last transition (or none): the rule, when there is one
    dec eax
    cmp ecx, eax
    jne 5f
    cmp r15d, 8
    jne 5f
    mov rsi, [rsp + 8]
    lea rax, [rsi + 1]
    cmp rax, r13
    jae 5f
    cmp byte ptr [r12 + rsi], 10
    jne 5f
    mov [rsp + 24], ecx
    lea rdi, [r12 + rsi + 1]    # the rule's line
    mov rax, r13
    sub rax, rsi
    dec rax
    mov rsi, rax
    mov rdx, rbx
    call tz_rule
    test edx, edx
    jnz 9f
    mov ecx, [rsp + 24]
    mov r8, [rsp + 16]
5:  xor eax, eax                # the type of that transition (before the first: the first type)
    test ecx, ecx
    js 6f
    lea rax, [r8 + rcx]
    movzx eax, byte ptr [r12 + rax]
6:  cmp eax, [rip + tz_n + 16]
    jae .Ltz_zero
    imul eax, eax, 6
    add rax, [rsp]
    mov [rsp + 24], rax         # its type record: the offset, isdst, the name's index
    movzx ecx, byte ptr [r12 + rax + 5]
    mov eax, [rip + tz_n + 16]  # the names follow the types
    imul eax, eax, 6
    add rax, [rsp]
    mov edx, [rip + tz_n + 20]
    cmp ecx, edx
    jae 7f
    sub edx, ecx
    lea rdi, [r12 + rax]
    add rdi, rcx
    mov esi, edx
    call abbr_z
7:  mov rax, [rsp + 24]
    mov eax, [r12 + rax]
    bswap eax
    movsxd rax, eax
9:  EPILOGUE
.Ltz_zero:
    xor eax, eax
    EPILOGUE

# tz_counts(rsi the header's offset) (r12 the file): tz_n = its six counts (isut, isstd, leap, time, type,
#   char), each at most 100000
tz_counts:
    lea rdx, [r12 + rsi + 20]
    xor ecx, ecx
1:  mov eax, [rdx + rcx*4]
    bswap eax
    cmp eax, 100000
    jbe 2f
    mov eax, 100000
2:  lea r8, [rip + tz_n]
    mov [r8 + rcx*4], eax
    inc ecx
    cmp ecx, 6
    jb 1b
    ret

# tz_load() -> rax the zone file's bytes, rdx their length (0, 0 none): read once, at most 1 MiB
tz_load:
    PROLOGUE
    cmp dword ptr [rip + tz_tried], 0
    jne 8f
    mov dword ptr [rip + tz_tried], 1
    lea rdi, [rip + .Ltz_env]
    call getenv
    test rax, rax
    jz 3f
    mov rbx, rax
    cmp byte ptr [rbx], ':'
    jne 1f
    inc rbx
1:  cmp byte ptr [rbx], 0
    je 3f
    mov rdi, rbx
    cmp byte ptr [rbx], '/'
    je 2f
    mov rdi, rbx
    call strlen
    cmp rax, 200
    ja 3f
    lea rdi, [rip + tz_path]
    lea rsi, [rip + .Ltz_dir]
    call cstr_copy
    lea rdi, [rip + tz_path]
    call strlen
    lea rdi, [rip + tz_path]
    add rdi, rax
    mov rsi, rbx
    call cstr_copy
    lea rdi, [rip + tz_path]
2:  call file_read_all
    test rax, rax
    jnz 4f
3:  lea rdi, [rip + .Ltz_local]
    call file_read_all
    test rax, rax
    jz 8f
4:  cmp rdx, 1 << 20
    jbe 5f
    mov rdi, rax
    call mem_free
    jmp 8f
5:  mov [rip + tz_buf], rax
    mov [rip + tz_len], rdx
8:  mov rax, [rip + tz_buf]
    mov rdx, [rip + tz_len]
    EPILOGUE

# tz_rule(ptr, len of the footer's line, t) -> rax the offset east at t, edx 1 when the rule was read:
#   STD OFFSET [DST [OFFSET] ,Mm.w.d[/TIME],Mm.w.d[/TIME]]
tz_rule:
    PROLOGUE 80
    mov [rip + tz_p], rdi
    lea rax, [rdi + rsi]
    mov [rip + tz_end], rax
    mov rbx, rdx
    call pz_name
    test eax, eax
    jz 8f
    mov rax, [rip + pz_ns]      # standard time's name
    mov [rsp + 48], rax
    mov rax, [rip + pz_nl]
    mov [rsp + 56], rax
    call pz_off
    test edx, edx
    jz 8f
    neg rax
    mov r12, rax                # standard time, east
    call pz_name
    test eax, eax
    jz 7f                       # no daylight saving time
    mov rax, [rip + pz_ns]      # its name
    mov [rsp + 64], rax
    mov rax, [rip + pz_nl]
    mov [rsp + 72], rax
    lea r13, [r12 + 3600]
    call pz_peek
    cmp eax, ','
    je 1f
    cmp eax, 10
    je 7f
    test eax, eax
    js 7f
    call pz_off
    test edx, edx
    jz 7f
    neg rax
    mov r13, rax                # daylight saving time, east
1:  call pz_peek
    cmp eax, ','
    jne 7f                      # no rules given: standard time
    inc qword ptr [rip + tz_p]
    lea rdi, [rsp]
    call pz_rule
    test eax, eax
    jz 7f
    call pz_peek
    cmp eax, ','
    jne 7f
    inc qword ptr [rip + tz_p]
    lea rdi, [rsp + 24]
    call pz_rule
    test eax, eax
    jz 7f
    lea rax, [rbx + r12]        # this year, in standard time
    test rax, rax
    js 7f
    xor edx, edx
    mov ecx, 86400
    div rcx
    mov rdi, rax
    call agtime_civil
    mov r14, rax
    mov rdi, r14
    lea rsi, [rsp]
    call rule_at
    sub rax, r12
    mov r15, rax                # it starts (UTC)
    mov rdi, r14
    lea rsi, [rsp + 24]
    call rule_at
    sub rax, r13                # it ends (UTC)
    cmp r15, rax
    jge 3f
    cmp rbx, r15                # northern: from the start to the end
    jl 7f
    cmp rbx, rax
    jge 7f
    jmp 6f
3:  cmp rbx, rax                # southern: all but from the end to the start
    jl 6f
    cmp rbx, r15
    jl 7f
6:  mov rdi, [rsp + 64]
    mov rsi, [rsp + 72]
    call abbr_put
    mov rax, r13
    mov edx, 1
    EPILOGUE
7:  mov rdi, [rsp + 48]
    mov rsi, [rsp + 56]
    call abbr_put
    mov rax, r12
    mov edx, 1
    EPILOGUE
8:  xor eax, eax
    xor edx, edx
    EPILOGUE

# abbr_put(ptr, len): tz_abbr is that name (cut at ABBR_MAX)
abbr_put:
    cmp rsi, ABBR_MAX
    jbe 1f
    mov esi, ABBR_MAX
1:  xor ecx, ecx
2:  cmp rcx, rsi
    jae 3f
    movzx eax, byte ptr [rdi + rcx]
    lea rdx, [rip + tz_abbr]
    mov [rdx + rcx], al
    inc rcx
    jmp 2b
3:  lea rdx, [rip + tz_abbr]
    mov byte ptr [rdx + rcx], 0
    ret

# abbr_z(ptr, at most n bytes): tz_abbr is the name there, up to its NUL
abbr_z:
    xor ecx, ecx
1:  cmp ecx, esi
    jae 2f
    cmp byte ptr [rdi + rcx], 0
    je 2f
    inc ecx
    jmp 1b
2:  mov esi, ecx
    jmp abbr_put

# rule_at(year, rule {m 4, w 4, d 4, pad 4, time 8}) -> rax the local second it changes, from 1970
rule_at:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rbx                # the month's first day, and its weekday
    mov esi, [r12]
    mov edx, 1
    call agtime_days_of
    mov r13, rax
    add rax, 4
    xor edx, edx
    mov ecx, 7
    div rcx                     # rdx its weekday (0 Sunday)
    mov eax, [r12 + 8]
    sub eax, edx
    add eax, 7
    xor edx, edx
    mov ecx, 7
    div ecx
    mov r14d, edx               # the first such weekday: 0 + that many days
    mov eax, [r12 + 4]
    dec eax
    imul eax, eax, 7
    add r14d, eax               # its w-th (5: the last)
    mov rdi, rbx                # the days of the month: the next month's first day less this one's
    mov esi, [r12]
    inc esi
    mov rdx, rbx
    cmp esi, 12
    jbe 1f
    mov esi, 1
    inc rdi
1:  mov edx, 1
    call agtime_days_of
    sub rax, r13
2:  cmp r14, rax
    jb 3f
    sub r14d, 7
    jmp 2b
3:  lea rax, [r13 + r14]
    imul rax, rax, 86400
    add rax, [r12 + 8 + 8]
    EPILOGUE

# pz_peek() -> eax the rule's next character, -1 at its end
pz_peek:
    mov rcx, [rip + tz_p]
    mov eax, -1
    cmp rcx, [rip + tz_end]
    jae 1f
    movzx eax, byte ptr [rcx]
1:  ret

# pz_name() -> eax 1 when a zone's name was read ("<+03>" or letters); pz_ns, pz_nl: the name (without "<" ">")
pz_name:
    call pz_peek
    cmp eax, '<'
    jne 2f
    inc qword ptr [rip + tz_p]
    mov rax, [rip + tz_p]
    mov [rip + pz_ns], rax
1:  call pz_peek
    test eax, eax
    js 8f
    cmp eax, '>'
    je 11f
    inc qword ptr [rip + tz_p]
    jmp 1b
11: mov rax, [rip + tz_p]
    sub rax, [rip + pz_ns]
    mov [rip + pz_nl], rax
    inc qword ptr [rip + tz_p]
    mov eax, 1
    ret
2:  mov rax, [rip + tz_p]
    mov [rip + pz_ns], rax
    xor edx, edx
3:  call pz_peek
    or eax, 0x20
    sub eax, 'a'
    cmp eax, 25
    ja 4f
    inc qword ptr [rip + tz_p]
    inc edx
    jmp 3b
4:  mov [rip + pz_nl], rdx
    xor eax, eax
    test edx, edx
    setnz al
    ret
8:  xor eax, eax
    ret

# pz_num() -> rax a number's digits, edx 1 when there was one
pz_num:
    xor r8d, r8d
    xor r9d, r9d
1:  call pz_peek
    sub eax, '0'
    cmp eax, 9
    ja 2f
    inc qword ptr [rip + tz_p]
    cmp r8, 100000
    jae 1b
    imul r8, r8, 10
    add r8, rax
    mov r9d, 1
    jmp 1b
2:  mov rax, r8
    mov edx, r9d
    ret

# pz_off() -> rax [+-]hh[:mm[:ss]] in seconds, edx 1 when read
pz_off:
    push rbx
    push r12
    push r13
    xor ebx, ebx                # negative
    call pz_peek
    cmp eax, '+'
    je 1f
    cmp eax, '-'
    jne 2f
    mov ebx, 1
1:  inc qword ptr [rip + tz_p]
2:  call pz_num
    test edx, edx
    jz 8f
    imul r12, rax, 3600
    mov r13d, 60
3:  call pz_peek
    cmp eax, ':'
    jne 4f
    inc qword ptr [rip + tz_p]
    call pz_num
    imul rax, r13
    add r12, rax
    cmp r13d, 1
    je 4f
    mov r13d, 1
    jmp 3b
4:  mov rax, r12
    test ebx, ebx
    jz 5f
    neg rax
5:  mov edx, 1
    pop r13
    pop r12
    pop rbx
    ret
8:  xor eax, eax
    xor edx, edx
    pop r13
    pop r12
    pop rbx
    ret

# pz_rule(rdi out {m 4, w 4, d 4, pad 4, time 8}) -> eax 1 when an Mm.w.d[/TIME] rule was read
pz_rule:
    push rbx
    mov rbx, rdi
    mov qword ptr [rbx + 8 + 8], 7200   # 02:00 when no time is given
    call pz_peek
    cmp eax, 'M'
    jne 8f
    inc qword ptr [rip + tz_p]
    call pz_num
    test edx, edx
    jz 8f
    cmp rax, 1
    jb 8f
    cmp rax, 12
    ja 8f
    mov [rbx], eax
    call pz_peek
    cmp eax, '.'
    jne 8f
    inc qword ptr [rip + tz_p]
    call pz_num
    test edx, edx
    jz 8f
    cmp rax, 1
    jb 8f
    cmp rax, 5
    ja 8f
    mov [rbx + 4], eax
    call pz_peek
    cmp eax, '.'
    jne 8f
    inc qword ptr [rip + tz_p]
    call pz_num
    test edx, edx
    jz 8f
    cmp rax, 6
    ja 8f
    mov [rbx + 8], eax
    call pz_peek
    cmp eax, '/'
    jne 7f
    inc qword ptr [rip + tz_p]
    call pz_off
    test edx, edx
    jz 8f
    mov [rbx + 8 + 8], rax
7:  mov eax, 1
    pop rbx
    ret
8:  xor eax, eax
    pop rbx
    ret


# ---- the zone and the labels ----

# FN agtime_offset(unix seconds) -> rax the local zone's offset east of UTC then, in seconds; rdx its
#   abbreviation then ("MST"; valid until the next call) or 0: none, or only a number ("+03", "-00")
FN agtime_offset
    PROLOGUE
.ifdef WINDOWS
    call win_tz_offset          # the system's answer for that time: no abbreviation
    xor edx, edx
    EPILOGUE
.else
    call tz_offset
    xor edx, edx
    movzx ecx, byte ptr [rip + tz_abbr]
    or ecx, 0x20
    sub ecx, 'a'
    cmp ecx, 25
    ja 9f
    lea rdx, [rip + tz_abbr]
9:  EPILOGUE
.endif

# FN agtime_day(unix ms) -> rax its local day (days since 1970-01-01)
FN agtime_day
    PROLOGUE
    mov rax, rdi
    test rax, rax
    jns 1f
    xor eax, eax
1:  xor edx, edx
    mov ecx, 1000
    div rcx
    mov rdi, rax
    call agtime_days
    EPILOGUE

# lt_fill(unix ms): ltm is that time's local parts, lt_abbr its zone's abbreviation or 0
lt_fill:
    PROLOGUE
    mov rax, rdi
    test rax, rax
    jns 1f
    xor eax, eax
1:  xor edx, edx
    mov ecx, 1000
    div rcx
    mov rbx, rax
    mov rdi, rax
    call agtime_offset
    mov [rip + ltm + LT_OFF], eax
    mov [rip + lt_abbr], rdx
    add rax, rbx
    jns 2f
    xor eax, eax
2:  xor edx, edx
    mov ecx, 86400
    div rcx
    mov r12, rax                # the day
    mov r13, rdx                # its second
    lea rax, [r12 + 4]
    xor edx, edx
    mov ecx, 7
    div rcx
    mov [rip + ltm + LT_WD], edx
    mov rdi, r12
    call agtime_civil
    mov [rip + ltm + LT_Y], eax
    mov [rip + ltm + LT_M], edx
    mov [rip + ltm + LT_D], ecx
    mov rax, r13
    xor edx, edx
    mov ecx, 3600
    div rcx
    mov [rip + ltm + LT_H], eax
    mov rax, rdx
    xor edx, edx
    mov ecx, 60
    div rcx
    mov [rip + ltm + LT_MIN], eax
    mov [rip + ltm + LT_S], edx
    EPILOGUE

# push2(sb, n): two digits
push2:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    cmp r12d, 10
    jae 1f
    mov esi, '0'
    call sb_push_byte
1:  mov rdi, rbx
    mov esi, r12d
    call sb_push_u64
    EPILOGUE

# FN agtime_clock(sb, unix ms): "3:45 PM", local
FN agtime_clock
    PROLOGUE
    mov rbx, rdi
    mov rdi, rsi
    call lt_fill
    mov eax, [rip + ltm + LT_H]
    add eax, 11
    xor edx, edx
    mov ecx, 12
    div ecx
    lea esi, [rdx + 1]
    mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    mov esi, ':'
    call sb_push_byte
    mov rdi, rbx
    mov esi, [rip + ltm + LT_MIN]
    call push2
    lea rsi, [rip + .Lt_am]
    cmp dword ptr [rip + ltm + LT_H], 12
    jb 1f
    lea rsi, [rip + .Lt_pm]
1:  mov rdi, rbx
    call sb_push_cstr
    EPILOGUE

# FN agtime_full(sb, unix ms): "2026-11-23 15:45:07 MST", local; without an abbreviation the offset:
#   "UTC", "UTC-7", "UTC+5:30"
FN agtime_full
    PROLOGUE
    mov rbx, rdi
    mov rdi, rsi
    call lt_fill
    mov rdi, rbx
    mov esi, [rip + ltm + LT_Y]
    call sb_push_u64
    mov rdi, rbx
    mov esi, '-'
    call sb_push_byte
    mov rdi, rbx
    mov esi, [rip + ltm + LT_M]
    call push2
    mov rdi, rbx
    mov esi, '-'
    call sb_push_byte
    mov rdi, rbx
    mov esi, [rip + ltm + LT_D]
    call push2
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rdi, rbx
    mov esi, [rip + ltm + LT_H]
    call push2
    mov rdi, rbx
    mov esi, ':'
    call sb_push_byte
    mov rdi, rbx
    mov esi, [rip + ltm + LT_MIN]
    call push2
    mov rdi, rbx
    mov esi, ':'
    call sb_push_byte
    mov rdi, rbx
    mov esi, [rip + ltm + LT_S]
    call push2
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rsi, [rip + lt_abbr]
    test rsi, rsi
    jz 1f
    mov rdi, rbx
    call sb_push_cstr
    EPILOGUE
1:  mov rdi, rbx
    lea rsi, [rip + .Lt_utc]
    call sb_push_cstr
    mov r12d, [rip + ltm + LT_OFF]
    test r12d, r12d
    jz 9f
    mov esi, '+'
    jns 2f
    mov esi, '-'
    neg r12d
2:  mov rdi, rbx
    call sb_push_byte
    mov eax, r12d
    xor edx, edx
    mov ecx, 3600
    div ecx
    mov r13d, edx
    mov rdi, rbx
    mov esi, eax
    call sb_push_u64
    mov eax, r13d
    xor edx, edx
    mov ecx, 60
    div ecx
    test eax, eax
    jz 9f
    mov r13d, eax
    mov rdi, rbx
    mov esi, ':'
    call sb_push_byte
    mov rdi, rbx
    mov esi, r13d
    call push2
9:  EPILOGUE

# FN agtime_daylabel(sb, unix ms): "Mon, Nov 23", local, with ", 2025" when its year is not this one
FN agtime_daylabel
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call agtime_now             # this year, here
    mov rdi, rax
    call lt_fill
    mov r13d, [rip + ltm + LT_Y]
    mov rdi, r12
    call lt_fill
    mov eax, [rip + ltm + LT_WD]
    lea rcx, [rip + day_names]
    lea rsi, [rcx + rax*4]
    mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Lt_comma]
    call sb_push_cstr
    mov eax, [rip + ltm + LT_M]
    lea rcx, [rip + month_names]
    lea rsi, [rcx + rax*4 - 4]
    mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rdi, rbx
    mov esi, [rip + ltm + LT_D]
    call sb_push_u64
    cmp r13d, [rip + ltm + LT_Y]
    je 9f
    mov rdi, rbx
    lea rsi, [rip + .Lt_comma]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + ltm + LT_Y]
    call sb_push_u64
9:  EPILOGUE

.section .rodata
.Ltz_env: .asciz "TZ"
.Ltz_dir: .asciz "/usr/share/zoneinfo/"
.Ltz_local: .asciz "/etc/localtime"
.Lt_am: .asciz " AM"
.Lt_pm: .asciz " PM"
.Lt_comma: .asciz ", "
.Lt_utc: .asciz "UTC"
