# The spinner line after the last row while the open conversation works (UI 3.23, the extension's MLe
# @5436400): a glyph of six vector frames stepping there and back (IC_SPIN0..5, 12 steps), a verb and "..."
# with the typewriter's sweep (YRn: 3 characters a tick, each passing the cursor and a scramble step on its
# way), a new verb after 2 s, 3 s more, then every 5 s; the driver's words in place of the verb while it
# says so (ev_spin: "Compacting", a start-up hook's). The verbs are the driver's (DRV_verbs, 0-ended); a
# session whose driver has none (an extension's, one whose driver is switched off) has no line. Generic:
# the words come from the driver.
#
# The one tick of 120 ms serves everything drawn that moves (this line, a running call's blinking dot):
# whatever draws something moving calls agspin_seen; agspin_tick (agents_tick) steps when the time has come
# and the mark is set, clears the mark and asks for a frame; agspin_timeout gives a time only while the mark
# is set, the panel shows and the open conversation is one rhun drives whose turn runs. So the frame after a
# tick that draws nothing moving (the list, a hidden panel, another side tab, the line scrolled away, the
# turn's end) ends the tick.
#
#   agspin_h(AS*) -> eax            its height (0: none); keeps the line's state for the session shown
#   agspin_draw(AS*, x, y, w)       drawn after the last row, before the task lines and the queued rows
#   agspin_seen()                   something drawn this frame moves: the tick goes on
#   agspin_phase() -> eax           the tick's count
#   agspin_blink(AS*) -> eax        a running dot of that session: 1 draw it, 0 not now (the blink: 4 ticks on,
#                                   4 off, only in a conversation rhun drives whose turn runs and where no
#                                   request waits for the user; else 1, still)
#   agspin_color(AS*) -> eax argb   the spinner's and a running dot's colour: the open mode's, the driver's
#                                   own in the default mode (DRV_brand), else the accent
#   agspin_timeout() -> eax ms|-1   the time to the next tick, -1 none
#   agspin_tick()                   the tick: a step and a frame when something moving was drawn
#   agspin_step()                   one step now, whatever the time (agent-spin-tick)
#   agspin_dump(sb)                 print-agent-spinner
#   agspin_set(AS*, cstr or 0, static)   the driver's words in place of a verb (ev_spin); 0 gives the verbs back
.include "rhun.inc"

.equ SPIN_TICK, 120             # ms a tick (the extension's interval)
.equ SPIN_FRAMES, 12            # · ✢ * ✶ ✻ ✽ ✽ ✻ ✶ * ✢ · (gNt)
.equ LABEL_MAX, 64              # characters of the label
.equ VERBS_MAX, 256             # verbs counted at most
.equ OV_MAX, 8                  # sessions with words of their driver's at once
.equ OV_TEXT, 48
.equ CURSOR_CP, 0x258c          # "▌"

.data
.globl g_spin_ms
g_spin_ms: .long SPIN_TICK      # the tick (agent-timing spin=; 0 holds it: steps by agent-spin-tick alone)
frames: .byte 0, 1, 2, 3, 4, 5, 5, 4, 3, 2, 1, 0
.p2align 2
delays: .long 2000, 3000, 5000  # the verb's changes: after 2 s, 3 s more, then every 5 s

.bss
.p2align 3
sp_last: .quad 0                # time_ms of the last tick
sp_as: .quad 0                  # the session whose turn the line's state is for
sp_verb: .quad 0                # its verb (cstr of the driver's list)
sp_seed: .quad 0                # the verbs' and the scramble's random state
sp_mark: .long 0                # something moving was drawn since the last tick
sp_phase: .long 0               # ticks so far (a running dot's blink)
sp_on: .long 0                  # the line shows for sp_as
sp_n: .long 0                   # its ticks since its turn began
sp_ms: .long 0                  # its time since then, ms (sp_n ticks)
sp_next: .long 0                # when its verb changes next
sp_chg: .long 0                 # how often it changed
sp_len: .long 0                 # the label's characters (the longest verb and "...", or the words')
sp_idx: .long 0                 # the typewriter's place
sp_static: .long 0              # the words are shown at once
sp_ser: .long 0                 # th_serial of the frame it was drawn in, and where
sp_y: .long 0
sp_bser: .long 0                # th_serial of the frame a blinking dot was drawn in, and whether it showed
sp_blink: .long 0
sp_nverbs: .long 0              # the verbs the line picks from
sp_word: .zero OV_TEXT          # the words shown ("Clauding", an override), without "..."
sp_cur: .zero 4 * LABEL_MAX     # the label as shown, a code point a character
sp_tgt: .zero 4 * LABEL_MAX     # what it sweeps to
ov_as: .zero 8 * OV_MAX         # the driver's words, by session
ov_static: .zero 4 * OV_MAX
ov_text: .zero OV_TEXT * OV_MAX
lab: .zero SB_SIZE              # the label as UTF-8

.text

# spin_drv(AS*) -> rax its driver's verb list (cstr*, at least one), or 0
spin_drv:
    PROLOGUE
    xor eax, eax
    test rdi, rdi
    jz 9f
    call agent_drv_of
    test rax, rax
    jz 9f
    mov rax, [rax + DRV_verbs]
    test rax, rax
    jz 9f
    cmp qword ptr [rax], 0
    jne 9f
    xor eax, eax
9:  EPILOGUE

# works(AS*) -> eax 1 when it is a conversation rhun drives whose turn runs (or whose program starts with a
#   prompt waiting)
works:
    xor eax, eax
    test rdi, rdi
    jz 9f
    mov rcx, [rdi + AS_live]
    test rcx, rcx
    jz 9f
    cmp qword ptr [rcx + AL_turns], 0
    jne 1f
    cmp dword ptr [rcx + AL_state], ALS_STARTING
    jne 9f
    cmp qword ptr [rcx + AL_queue + VEC_len], 0
    je 9f
1:  mov eax, 1
9:  ret

# moving(AS*) -> eax 1 when its turn runs and no request waits for the user: while a permission, question,
#   plan or dialog card waits nothing moves (the extension hides its spinner while a permission request is
#   pending, index.js @5944989 `visiblyBusy && !permissionRequests.length`; a card can wait for hours)
moving:
    PROLOGUE
    mov rbx, rdi
    call works
    test eax, eax
    jz 9f
    mov rcx, [rbx + AS_live]
    xor eax, eax
    cmp dword ptr [rcx + AL_state], ALS_WAITING
    je 9f
    cmp qword ptr [rcx + AL_reqs + VEC_len], 0
    jne 9f
    mov eax, 1
9:  EPILOGUE

# shown(AS*) -> eax 1 when the line shows for it: a driver with verbs, a turn that runs
shown:
    PROLOGUE
    mov rbx, rdi
    call works
    test eax, eax
    jz 9f
    mov rdi, rbx
    call spin_drv
    test rax, rax
    setnz al
    movzx eax, al
9:  EPILOGUE

# rnd(n) -> eax a number below n (xorshift; seeded from the clock)
rnd:
    PROLOGUE
    mov ebx, edi
    mov rax, [rip + sp_seed]
    test rax, rax
    jnz 1f
    call time_ms
    or rax, 1
1:  mov rcx, rax
    shl rcx, 13
    xor rax, rcx
    mov rcx, rax
    shr rcx, 7
    xor rax, rcx
    mov rcx, rax
    shl rcx, 17
    xor rax, rcx
    mov [rip + sp_seed], rax
    xor eax, eax
    test ebx, ebx
    jz 9f
    mov rax, [rip + sp_seed]
    shr rax, 1
    xor edx, edx
    mov ecx, ebx
    div rcx
    mov eax, edx
9:  EPILOGUE

# ov_find(AS*) -> eax its slot in the words' table, -1 none
ov_find:
    xor eax, eax
1:  cmp eax, OV_MAX
    jae 8f
    lea rcx, [rip + ov_as]
    cmp [rcx + rax*8], rdi
    je 9f
    inc eax
    jmp 1b
8:  mov eax, -1
9:  ret

# FN agspin_set(AS*, cstr or 0, static): the driver's words in place of a verb ("Compacting"), static 1: no
#   typewriter; 0 gives the verbs back
FN agspin_set
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    test rbx, rbx
    jz 9f
    call ov_find
    mov r14d, eax
    test r12, r12
    jnz 2f
    test r14d, r14d             # none: its slot goes
    js 8f
    lea rcx, [rip + ov_as]
    mov qword ptr [rcx + r14*8], 0
    jmp 8f
2:  test r14d, r14d
    jns 4f
    xor edi, edi                # a free slot (else the first's)
    call ov_find
    mov r14d, eax
    test eax, eax
    jns 4f
    xor r14d, r14d
4:  lea rcx, [rip + ov_as]
    mov [rcx + r14*8], rbx
    lea rcx, [rip + ov_static]
    mov [rcx + r14*4], r13d
    imul rdi, r14, OV_TEXT
    lea rcx, [rip + ov_text]
    add rdi, rcx
    mov rsi, r12
    mov edx, OV_TEXT - 1
    call cstr_copy_n
8:  mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# cstr_copy_n(dst, src, n): at most n bytes and a NUL
cstr_copy_n:
    xor ecx, ecx
1:  cmp ecx, edx
    jae 2f
    movzx eax, byte ptr [rsi + rcx]
    test eax, eax
    jz 2f
    mov [rdi + rcx], al
    inc ecx
    jmp 1b
2:  mov byte ptr [rdi + rcx], 0
    ret

# verbs_of(AS*) -> rax the list, edx how many, ecx the longest's length
verbs_of:
    PROLOGUE
    call spin_drv
    mov rbx, rax
    xor r12d, r12d
    xor r13d, r13d
    test rbx, rbx
    jz 9f
1:  cmp r12d, VERBS_MAX
    jae 9f
    mov rdi, [rbx + r12*8]
    test rdi, rdi
    jz 9f
    call strlen
    cmp eax, r13d
    cmovg r13d, eax
    inc r12d
    jmp 1b
9:  mov rax, rbx
    mov edx, r12d
    mov ecx, r13d
    EPILOGUE

# pick(AS*): a verb, another than the one shown when there is a choice
pick:
    PROLOGUE
    call verbs_of
    mov rbx, rax
    mov r12d, edx
    mov [rip + sp_nverbs], edx
    test rbx, rbx
    jz 9f
    test r12d, r12d
    jz 9f
1:  mov edi, r12d
    call rnd
    mov rax, [rbx + rax*8]
    cmp r12d, 1
    je 2f
    cmp rax, [rip + sp_verb]
    je 1b
2:  mov [rip + sp_verb], rax
9:  EPILOGUE

# words(AS*) -> rax the words the line shows now (its driver's, else its verb), edx 1 static
words:
    PROLOGUE
    call ov_find
    test eax, eax
    js 1f
    lea rcx, [rip + ov_static]
    mov edx, [rcx + rax*4]
    imul rax, rax, OV_TEXT
    lea rcx, [rip + ov_text]
    add rax, rcx
    EPILOGUE
1:  mov rax, [rip + sp_verb]
    xor edx, edx
    test rax, rax
    jnz 9f
    lea rax, [rip + .Lempty]
9:  EPILOGUE

# aim(AS*, first): the label sweeps to the words shown now (first: from blank), when they are not those yet
aim:
    PROLOGUE
    mov rbx, rdi
    mov r15d, esi
    call words
    mov r12, rax
    mov r13d, edx
    test r15d, r15d
    jnz 1f
    lea rdi, [rip + sp_word]
    mov rsi, r12
    call strcmp_eq
    test eax, eax
    jnz 9f
1:  lea rdi, [rip + sp_word]
    mov rsi, r12
    mov edx, OV_TEXT - 1
    call cstr_copy_n
    mov [rip + sp_static], r13d
    mov rdi, rbx                # the label's length: the longest verb and "...", or the words and "..."
    call verbs_of
    lea r14d, [rcx + 3]
    mov rdi, r12
    call strlen
    add eax, 3
    cmp eax, r14d
    cmovg r14d, eax
    cmp r14d, LABEL_MAX
    jbe 2f
    mov r14d, LABEL_MAX
2:  mov [rip + sp_len], r14d
    xor ecx, ecx                # the target: the words, "...", spaces
    xor edx, edx
3:  cmp ecx, r14d
    jae 6f
    mov eax, ' '
    movzx r8d, byte ptr [r12 + rdx]
    test r8d, r8d
    jz 4f
    mov eax, r8d
    inc edx
    jmp 5f
4:  mov r9d, ecx                # "..." right after the words
    sub r9d, edx
    cmp r9d, 3
    jae 5f
    mov eax, '.'
5:  lea r8, [rip + sp_tgt]
    mov [r8 + rcx*4], eax
    test r15d, r15d             # a new turn: from blank
    jz 51f
    lea r8, [rip + sp_cur]
    mov dword ptr [r8 + rcx*4], ' '
51: inc ecx
    jmp 3b
6:  mov dword ptr [rip + sp_idx], 0
    test r13d, r13d
    jz 9f
    xor ecx, ecx                # static: at once
7:  cmp ecx, r14d
    jae 71f
    lea r8, [rip + sp_tgt]
    mov eax, [r8 + rcx*4]
    lea r8, [rip + sp_cur]
    mov [r8 + rcx*4], eax
    inc ecx
    jmp 7b
71: lea eax, [r14 + 4]
    mov [rip + sp_idx], eax
9:  EPILOGUE

# sweep(): one step of the typewriter (the extension's 40 ms): the place moves on one character; the four
#   characters behind it are the cursor, two scramble steps and the target
sweep:
    PROLOGUE
    mov ebx, [rip + sp_idx]
    lea eax, [rbx - 3]
    cmp eax, [rip + sp_len]
    jge 9f
    inc dword ptr [rip + sp_idx]
    xor r12d, r12d              # f
1:  cmp r12d, 3
    ja 9f
    mov r13d, ebx
    sub r13d, r12d              # g
    js 8f
    cmp r13d, [rip + sp_len]
    jge 8f
    lea rcx, [rip + sp_tgt]
    mov r14d, [rcx + r13*4]
    cmp r14d, ' '
    je 7f
    cmp r12d, 3
    je 7f
    test r12d, r12d
    jnz 2f
    mov r14d, CURSOR_CP
    jmp 7f
2:  mov edi, 3                  # ".", "_" or the target
    call rnd
    cmp eax, 2
    je 7f
    mov r14d, '.'
    test eax, eax
    jz 7f
    mov r14d, '_'
7:  lea rcx, [rip + sp_cur]
    mov [rcx + r13*4], r14d
8:  inc r12d
    jmp 1b
9:  EPILOGUE

# state(AS*, shown): the line's state follows the session shown: a turn that begins starts it again, words
#   that change are swept to
state:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    test r12d, r12d
    jnz 2f
    cmp [rip + sp_as], rbx      # it went: its turn is over
    jne 1f
    mov dword ptr [rip + sp_on], 0
1:  mov rdi, rbx                # no program: its driver's words are stale
    mov rax, [rbx + AS_live]
    test rax, rax
    jz 11f
    mov eax, [rax + AL_state]
    cmp eax, ALS_OFF
    je 11f
    cmp eax, ALS_FAILED
    jne 9f
11: mov rdi, rbx
    xor esi, esi
    xor edx, edx
    call ov_find
    test eax, eax
    js 9f
    lea rcx, [rip + ov_as]
    mov qword ptr [rcx + rax*8], 0
    jmp 9f
2:  cmp [rip + sp_as], rbx
    jne 3f
    cmp dword ptr [rip + sp_on], 0
    jne 4f
3:  mov [rip + sp_as], rbx      # a turn begins
    mov dword ptr [rip + sp_on], 1
    mov dword ptr [rip + sp_n], 0
    mov dword ptr [rip + sp_ms], 0
    mov dword ptr [rip + sp_chg], 0
    mov eax, [rip + delays]
    mov [rip + sp_next], eax
    mov qword ptr [rip + sp_verb], 0
    mov rdi, rbx
    call pick
    mov rdi, rbx
    mov esi, 1
    call aim
    jmp 9f
4:  mov rdi, rbx                # the same turn: new words are swept to
    xor esi, esi
    call aim
9:  EPILOGUE

# FN agspin_h(AS*) -> eax the line's height: one line of the panel's face and MI_8; 0 when it does not show
FN agspin_h
    PROLOGUE
    mov rbx, rdi
    xor eax, eax
    test rbx, rbx
    jz 9f
    call shown
    mov r12d, eax
    mov rdi, rbx
    mov esi, eax
    call state
    xor eax, eax
    test r12d, r12d
    jz 9f
    call line_h
    add eax, [rip + g_pmt + 4*MI_8]
9:  EPILOGUE

# line_h() -> eax the line: the panel face's line or the glyph's size, the larger
line_h:
    mov rax, [rip + ag_fui]
    mov ecx, [rax + FACE_lineh]
    mov eax, [rax + FACE_px]
    cmp eax, ecx
    cmovl eax, ecx
    ret

# FN agspin_color(AS*) -> eax argb: the open mode's colour (the box's frame's, foot_ring), but in the modes
#   whose frame is the accent (the default ones) the driver's own colour; the accent without either
FN agspin_color
    PROLOGUE
    mov rbx, rdi
    call foot_ring
    test eax, eax
    jz 1f
    dec eax
    cmp eax, T_ACCENT
    je 1f
    lea rcx, [rip + g_theme]
    mov eax, [rcx + rax*4]
    EPILOGUE
1:  mov rdi, rbx
    call agent_drv_of
    test rax, rax
    jz 2f
    mov rax, [rax + DRV_brand]
    test eax, eax
    jnz 9f
2:  COLOR eax, T_ACCENT
9:  EPILOGUE

# FN agspin_draw(AS*, x, y, w): the line at y (when it shows): its glyph (1.5 times the text's size wide),
#   then the label; seen only when it is inside the clip
FN agspin_draw
    PROLOGUE 32
    mov rbx, rdi
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    call shown
    test eax, eax
    jz 9f
    mov rdi, rbx                # a request waits: the line keeps its room, blank (the extension's empty row)
    call moving
    test eax, eax
    jz 9f
    call line_h
    mov [rsp + 12], eax
    mov eax, [rsp + 4]          # in view?
    add eax, [rip + g_pmt + 4*MI_4]
    cmp eax, [rip + g_cv + CV_cy1]
    jge 9f
    add eax, [rsp + 12]
    cmp eax, [rip + g_cv + CV_cy0]
    jle 9f
    mov eax, [rip + th_serial]
    mov [rip + sp_ser], eax
    mov eax, [rsp + 4]
    mov [rip + sp_y], eax
    call agspin_seen
    mov rdi, rbx
    call agspin_color
    mov r15d, eax
    mov rax, [rip + ag_fui]     # the glyph: the text's size, centred in 1.5 of it
    mov r12d, [rax + FACE_px]
    mov eax, [rip + sp_n]
    xor edx, edx
    mov ecx, SPIN_FRAMES
    div ecx
    lea rax, [rip + frames]
    movzx edi, byte ptr [rax + rdx]
    add edi, IC_SPIN0
    mov esi, r12d               # x + size / 4
    shr esi, 2
    add esi, [rsp]
    mov edx, [rsp + 12]         # y: centred in the line
    sub edx, r12d
    sar edx, 1
    add edx, [rsp + 4]
    add edx, [rip + g_pmt + 4*MI_4]
    mov ecx, r12d
    mov r8d, r15d
    call icon_draw
    call label_text             # the label, in the text's colour, cut at the width
    mov eax, r12d
    imul eax, eax, 3
    shr eax, 1
    add eax, [rsp]
    mov [rsp + 16], eax
    mov r11d, [rsp]
    add r11d, [rsp + 8]
    sub r11d, eax
    cmp r11d, 1
    jl 9f
    mov rdi, [rip + ag_fui]
    mov esi, [rsp + 16]
    mov edx, [rsp + 4]
    add edx, [rip + g_pmt + 4*MI_4]
    mov ecx, [rsp + 12]
    mov r8, [rip + lab + SB_ptr]
    mov r9, [rip + lab + SB_len]
    COLOR r10d, T_FG
    push r11
    push r10
    call ui_text_v_fit
    add rsp, 16
9:  EPILOGUE

# label_text(): lab = the label as shown, UTF-8, its trailing spaces left out
label_text:
    PROLOGUE
    lea rdi, [rip + lab]
    call sb_clear
    mov r12d, [rip + sp_len]    # the last character that is not a space
1:  test r12d, r12d
    jz 9f
    lea rcx, [rip + sp_cur]
    cmp dword ptr [rcx + r12*4 - 4], ' '
    jne 2f
    dec r12d
    jmp 1b
2:  xor ebx, ebx
3:  cmp ebx, r12d
    jae 9f
    lea rcx, [rip + sp_cur]
    mov esi, [rcx + rbx*4]
    lea rdi, [rip + lab]
    call sb_push_utf8
    inc ebx
    jmp 3b
9:  EPILOGUE

# FN agspin_seen(): something drawn this frame moves: the tick goes on
FN agspin_seen
    mov dword ptr [rip + sp_mark], 1
    ret

# FN agspin_phase() -> eax the tick's count
FN agspin_phase
    mov eax, [rip + sp_phase]
    ret

# FN agspin_blink(AS*) -> eax 1 when a running dot of that session is drawn now: in a conversation rhun drives
#   whose turn runs it blinks (on 4 ticks, off 4: the extension's 1 s) and the tick goes on; in any other
#   it is still (a reader adds no wake-up)
FN agspin_blink
    PROLOGUE
    call moving
    test eax, eax
    jnz 1f
    mov eax, 1
    EPILOGUE
1:  call agspin_seen
    mov eax, [rip + sp_phase]
    shr eax, 2
    and eax, 1
    xor eax, 1
    mov [rip + sp_blink], eax
    mov ecx, [rip + th_serial]
    mov [rip + sp_bser], ecx
    EPILOGUE

# FN agspin_timeout() -> eax ms to the next tick, -1 none: only while something moving was drawn since the
#   last tick, the panel or a conversation tab shows the view and the open conversation is driven and works
FN agspin_timeout
    PROLOGUE
    cmp dword ptr [rip + g_spin_ms], 0
    je 8f
    cmp dword ptr [rip + sp_mark], 0
    je 8f
    cmp dword ptr [rip + g_show_agents], 0
    jne 1f
    call agtab_hosting          # (or a conversation tab draws the view)
    test eax, eax
    jz 8f
1:  call agents_viewed
    mov rdi, rax
    call moving
    test eax, eax
    jz 8f
    call time_ms
    mov rcx, [rip + sp_last]
    mov edx, [rip + g_spin_ms]
    add rcx, rdx
    sub rcx, rax
    xor eax, eax
    test rcx, rcx
    cmovg eax, ecx
    EPILOGUE
8:  mov eax, -1
    EPILOGUE

# FN agspin_tick(): when the tick's time has come and something moving was drawn: a step, the mark cleared,
#   a frame
FN agspin_tick
    PROLOGUE
    cmp dword ptr [rip + g_spin_ms], 0
    je 9f
    cmp dword ptr [rip + sp_mark], 0
    je 9f
    call time_ms
    mov rbx, rax
    sub rax, [rip + sp_last]
    mov ecx, [rip + g_spin_ms]
    cmp rax, rcx
    jl 9f
    mov [rip + sp_last], rbx
    mov dword ptr [rip + sp_mark], 0
    call agspin_step
9:  EPILOGUE

# FN agspin_step(): one step: the phase, the line's frame, its time, its verb when due, three characters of
#   the sweep; a frame
FN agspin_step
    PROLOGUE
    inc dword ptr [rip + sp_phase]
    mov dword ptr [rip + g_dirty], 1
    cmp dword ptr [rip + sp_on], 0
    je 9f
    inc dword ptr [rip + sp_n]
    add dword ptr [rip + sp_ms], SPIN_TICK
    mov eax, [rip + sp_ms]
    cmp eax, [rip + sp_next]
    jl 2f
    inc dword ptr [rip + sp_chg]
    mov eax, [rip + sp_chg]     # the next delay: 3 s, then 5 s
    cmp eax, 2
    jbe 1f
    mov eax, 2
1:  lea rcx, [rip + delays]
    mov eax, [rcx + rax*4]
    add [rip + sp_next], eax
    mov rdi, [rip + sp_as]
    call pick
    mov rdi, [rip + sp_as]
    xor esi, esi
    call aim
2:  call sweep
    call sweep
    call sweep
9:  EPILOGUE

# FN agspin_dump(sb): print-agent-spinner: "shown=0|1 frame=N verb=T label=T static=0|1 tick=MS color=RRGGBB
#   seen=0|1 timeout=MS|- verbs=N waiting=0|1 y=Y|- blink=on|off|-" for the open conversation (waiting: a
#   request waits for the user, the line is blank and nothing ticks) (spaces in verb and label as
#   "_"; label without its trailing spaces; y and blink: in the last frame of the thread drawn)
FN agspin_dump
    PROLOGUE
    mov r15, rdi
    call agents_viewed
    mov rbx, rax
    mov rdi, rax
    call shown
    mov r12d, eax
    mov rdi, r15
    lea rsi, [rip + .Ls_shown]
    call sb_push_cstr
    mov rdi, r15
    mov esi, r12d
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Ls_frame]
    call sb_push_cstr
    mov eax, [rip + sp_n]
    xor edx, edx
    mov ecx, SPIN_FRAMES
    div ecx
    lea rax, [rip + frames]
    movzx esi, byte ptr [rax + rdx]
    mov rdi, r15
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Ls_verb]
    call sb_push_cstr
    test r12d, r12d
    jz 1f
    mov rdi, rbx
    call words
    mov rsi, rax
    mov rdi, r15
    call push_under
1:  mov rdi, r15
    lea rsi, [rip + .Ls_label]
    call sb_push_cstr
    test r12d, r12d
    jz 2f
    call label_text
    mov rdi, r15
    mov rsi, [rip + lab + SB_ptr]
    mov rdx, [rip + lab + SB_len]
    call push_under_n
2:  mov rdi, r15
    lea rsi, [rip + .Ls_static]
    call sb_push_cstr
    mov rdi, r15
    mov esi, [rip + sp_static]
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Ls_tick]
    call sb_push_cstr
    mov rdi, r15
    mov esi, [rip + g_spin_ms]
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Ls_color]
    call sb_push_cstr
    mov rdi, rbx
    call agspin_color
    mov r13d, eax
    mov r14d, 20                # RRGGBB
3:  mov eax, r13d
    mov ecx, r14d
    shr eax, cl
    and eax, 15
    lea rcx, [rip + .Ls_hex]
    movzx esi, byte ptr [rcx + rax]
    mov rdi, r15
    call sb_push_byte
    sub r14d, 4
    jns 3b
    mov rdi, r15
    lea rsi, [rip + .Ls_seen]
    call sb_push_cstr
    mov rdi, r15
    mov esi, [rip + sp_mark]
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Ls_timeout]
    call sb_push_cstr
    call agspin_timeout
    mov rdi, r15
    mov esi, eax
    call push_num
    mov rdi, r15
    lea rsi, [rip + .Ls_verbs]
    call sb_push_cstr
    mov rdi, rbx
    call verbs_of
    mov rdi, r15
    mov esi, edx
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Ls_waiting]
    call sb_push_cstr
    xor esi, esi
    test r12d, r12d
    jz 31f
    mov rdi, rbx
    call moving
    xor eax, 1
    mov esi, eax
31: mov rdi, r15
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Ls_y]
    call sb_push_cstr
    mov esi, -1
    mov eax, [rip + th_serial]
    test r12d, r12d
    jz 4f
    cmp eax, [rip + sp_ser]
    jne 4f
    mov esi, [rip + sp_y]
4:  mov rdi, r15
    call push_num
    mov rdi, r15
    lea rsi, [rip + .Ls_blink]
    call sb_push_cstr
    lea rsi, [rip + .Ls_dash]
    mov eax, [rip + th_serial]
    cmp eax, [rip + sp_bser]
    jne 5f
    lea rsi, [rip + .Ls_off]
    cmp dword ptr [rip + sp_blink], 0
    je 5f
    lea rsi, [rip + .Ls_on]
5:  mov rdi, r15
    call sb_push_cstr
    mov rdi, r15
    mov esi, 10
    call sb_push_byte
    EPILOGUE

# push_num(sb, n): n, "-" when it is negative
push_num:
    test esi, esi
    js 1f
    jmp sb_push_u64
1:  mov esi, '-'
    jmp sb_push_byte

# push_under(sb, cstr), push_under_n(sb, ptr, len): the text with "_" for its spaces
push_under:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rsi
    call strlen
    mov rdi, rbx
    mov rsi, r12
    mov rdx, rax
    call push_under_n
    EPILOGUE
push_under_n:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    xor r14d, r14d
1:  cmp r14, r13
    jae 9f
    movzx esi, byte ptr [r12 + r14]
    cmp esi, ' '
    jne 2f
    mov esi, '_'
2:  mov rdi, rbx
    call sb_push_byte
    inc r14
    jmp 1b
9:  EPILOGUE

.section .rodata
.Lempty: .asciz ""
.Ls_shown: .asciz "shown="
.Ls_frame: .asciz " frame="
.Ls_verb: .asciz " verb="
.Ls_label: .asciz " label="
.Ls_static: .asciz " static="
.Ls_tick: .asciz " tick="
.Ls_color: .asciz " color="
.Ls_seen: .asciz " seen="
.Ls_timeout: .asciz " timeout="
.Ls_verbs: .asciz " verbs="
.Ls_waiting: .asciz " waiting="
.Ls_y: .asciz " y="
.Ls_blink: .asciz " blink="
.Ls_dash: .asciz "-"
.Ls_on: .asciz "on"
.Ls_off: .asciz "off"
.Ls_hex: .ascii "0123456789abcdef"
