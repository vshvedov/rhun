# headless platform: offscreen framebuffer, used by tests and scripted runs
.include "rhun.inc"

.bss
.p2align 3
hbuf: .quad 0
hw: .long 0
hh: .long 0
.p2align 3
.globl headless_clip_plain, headless_clip_native
headless_clip_plain:
hclip: .zero SB_SIZE
headless_clip_native:
hclip_wire: .zero SB_SIZE
hclip_files: .zero SB_SIZE      # clip-set files: paths, a NUL after each (phase 4 task 4)
hclip_image: .quad 0            # clip-set image: an image file's path (read when pasted, never past the limit)
hclip_held: .quad 0             # clip-hold: the request waiting for clip-release, its kinds and image limit
hclip_held_kinds: .long 0
hclip_held_max: .long 0
hclip_hold: .long 0
.globl hclip_hold
# window requests, recorded for tests; a move grabs the pointer like a compositor does
.globl g_hl_grab, g_hl_moves, g_hl_minimized, g_hl_frames
g_hl_grab: .long 0
g_hl_moves: .long 0
g_hl_minimized: .long 0
g_hl_frames: .long 0            # frames drawn, for tests

.text

FN headless_init
    PROLOGUE
    mov r12d, edi
    mov r13d, esi
    lea rax, [rip + hl_nop]
    lea rdi, [rip + g_plat]
    mov ecx, PLAT_SIZE / 8
1:  mov [rdi], rax
    add rdi, 8
    dec ecx
    jnz 1b
    lea rax, [rip + hl_timeout]
    mov [rip + g_plat + P_timeout], rax
    lea rax, [rip + hl_draw]
    mov [rip + g_plat + P_draw], rax
    lea rax, [rip + headless_clip_set]
    mov [rip + g_plat + P_clip_set], rax
    lea rax, [rip + headless_clip_get]
    mov [rip + g_plat + P_clip_get], rax
    lea rax, [rip + headless_clip_write]
    mov [rip + g_plat + P_clip_write], rax
    lea rax, [rip + hl_move]
    mov [rip + g_plat + P_move], rax
    lea rax, [rip + hl_minimize]
    mov [rip + g_plat + P_minimize], rax
    lea rax, [rip + hl_maximize]
    mov [rip + g_plat + P_maximize], rax
    mov dword ptr [rip + g_headless], 1
    mov dword ptr [rip + g_csd], 1
    mov edi, r12d
    mov esi, r13d
    call headless_resize
    EPILOGUE

FN headless_resize
    push rbx
    push r12
    push r13
    mov r12d, edi
    mov r13d, esi
    mov [rip + hw], edi
    mov [rip + hh], esi
    mov rdi, [rip + hbuf]
    call mem_free
    mov eax, r12d
    imul eax, r13d
    lea rdi, [rax*4]
    call mem_alloc
    mov [rip + hbuf], rax
    mov edi, r12d
    mov esi, r13d
    call app_on_resize
    mov dword ptr [rip + g_dirty], 1
    pop r13
    pop r12
    pop rbx
    ret

hl_nop:
    ret

hl_move:
    inc dword ptr [rip + g_hl_moves]
    mov dword ptr [rip + g_hl_grab], 1
    ret

hl_minimize:
    inc dword ptr [rip + g_hl_minimized]
    ret

hl_maximize:
    xor dword ptr [rip + g_win_states], 1
    mov dword ptr [rip + g_dirty], 1
    ret

# hl_timeout(): at once when the last frame asked for another, otherwise forever
hl_timeout:
    xor eax, eax
    cmp dword ptr [rip + g_dirty], 0
    jne 1f
    mov eax, -1
1:  ret

hl_draw:
    push rbx
    mov rdi, [rip + hbuf]
    mov esi, [rip + hw]
    mov edx, [rip + hh]
    mov ecx, esi
    call gfx_set_target
    mov dword ptr [rip + g_dirty], 0
    inc dword ptr [rip + g_hl_frames]
.ifndef WINDOWS
    call probe_init
    cmp qword ptr [rip + under_log], 0
    je 1f
    call under_fill
1:
.endif
    call app_render
.ifndef WINDOWS
    cmp qword ptr [rip + under_log], 0
    je 2f
    call under_check
2:  cmp qword ptr [rip + stale_log], 0
    je 3f
    cmp dword ptr [rip + g_dirty], 0
    jne 3f
    call stale_check
3:
.endif
    pop rbx
    ret

.ifndef WINDOWS
# ---- probes for missing frames (editor presentation, tests/stale-frames.py) ----
# RHUN_STALE=LOG: after a frame that asked for no other, the frame is drawn again into a second
# buffer; when it differs, the state changed during the frame without g_dirty, and the next real
# frame would only come with some unrelated event. The log gets the control command being run,
# the differing box and app_timeout() (a short one is an animation; -1 or the blink is a bug).
# RHUN_UNDERPAINT=LOG: the buffer is filled with magenta before each frame; a frame that leaves
# some of it never painted those pixels.
.equ PROBE_MAGENTA, 0xffff00ff

probe_init:
    cmp dword ptr [rip + probe_done], 0
    jne 9f
    mov dword ptr [rip + probe_done], 1
    lea rdi, [rip + .Lenv_stale]
    call getenv
    mov [rip + stale_log], rax
    lea rdi, [rip + .Lenv_under]
    call getenv
    mov [rip + under_log], rax
9:  ret

under_fill:
    mov rdi, [rip + hbuf]
    mov ecx, [rip + hw]
    imul ecx, [rip + hh]
    mov eax, PROBE_MAGENTA
    rep stosd
    ret

# under_check(): log the box of the pixels the frame left magenta
under_check:
    PROLOGUE
    cmp dword ptr [rip + g_probe_plant], 2
    jne 1f
    mov dword ptr [rip + g_probe_plant], 0  # the positive control: a pixel left unpainted
    mov rax, [rip + hbuf]
    mov dword ptr [rax], PROBE_MAGENTA
1:  mov rdi, [rip + hbuf]
    xor esi, esi
    call box_of
    test eax, eax
    jz 9f
    lea rdi, [rip + .Lw_under]
    mov rsi, [rip + under_log]
    call probe_log
9:  EPILOGUE

# stale_check(): draw again into hbuf2 and log what changed
stale_check:
    PROLOGUE
    mov eax, [rip + hw]
    imul eax, [rip + hh]
    shl eax, 2
    cmp rax, [rip + hbuf2_cap]
    jbe 1f
    mov rdi, [rip + hbuf2]
    call mem_free
    mov eax, [rip + hw]
    imul eax, [rip + hh]
    shl eax, 2
    mov [rip + hbuf2_cap], rax
    mov rdi, rax
    call mem_alloc
    mov [rip + hbuf2], rax
1:  mov rdi, [rip + hbuf2]
    mov esi, [rip + hw]
    mov edx, [rip + hh]
    mov ecx, esi
    call gfx_set_target
    call app_render
    mov rdi, [rip + hbuf]
    mov esi, [rip + hw]
    mov edx, [rip + hh]
    mov ecx, esi
    call gfx_set_target
    cmp dword ptr [rip + g_probe_plant], 1
    jne 2f
    mov dword ptr [rip + g_probe_plant], 0  # the positive control: the frame changed
    mov rax, [rip + hbuf2]
    xor dword ptr [rax], 1
2:  mov rdi, [rip + hbuf]
    mov rsi, [rip + hbuf2]
    call box_of
    test eax, eax
    jz 9f
    lea rdi, [rip + .Lw_stale]
    mov rsi, [rip + stale_log]
    call probe_log
    # what the screen shows is the newer frame
    mov rdi, [rip + hbuf]
    mov rsi, [rip + hbuf2]
    mov edx, [rip + hw]
    imul edx, [rip + hh]
    shl edx, 2
    call memcpy
9:  EPILOGUE

# box_of(a, b) -> eax 1 and pb_* the box of the pixels where a differs from b (b 0: where a is
# magenta), or 0
box_of:
    mov dword ptr [rip + pb_x0], 0x7fffffff
    mov dword ptr [rip + pb_y0], 0x7fffffff
    mov dword ptr [rip + pb_x1], -1
    mov dword ptr [rip + pb_y1], -1
    xor ecx, ecx                # y
1:  cmp ecx, [rip + hh]
    jae 8f
    xor edx, edx                # x
2:  cmp edx, [rip + hw]
    jae 7f
    mov eax, [rdi]
    test rsi, rsi
    jnz 3f
    cmp eax, PROBE_MAGENTA
    jne 6f
    jmp 4f
3:  cmp eax, [rsi]
    je 6f
4:  cmp edx, [rip + pb_x0]
    jge 41f
    mov [rip + pb_x0], edx
41: cmp ecx, [rip + pb_y0]
    jge 42f
    mov [rip + pb_y0], ecx
42: cmp edx, [rip + pb_x1]
    jle 43f
    mov [rip + pb_x1], edx
43: mov [rip + pb_y1], ecx
6:  add rdi, 4
    test rsi, rsi
    jz 62f
    add rsi, 4
62: inc edx
    jmp 2b
7:  inc ecx
    jmp 1b
8:  xor eax, eax
    cmp dword ptr [rip + pb_x1], 0
    setge al
    ret

# probe_log(word, path): "WORD COMMAND | x0,y0-x1,y1 | timeout T" appended to the log
probe_log:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea rdi, [rip + pl_buf]
    call sb_clear
    lea rdi, [rip + pl_buf]
    mov rsi, rbx
    call sb_push_cstr
    lea rdi, [rip + pl_buf]
    mov rsi, [rip + g_ctl_cur]
    mov rdx, [rip + g_ctl_cur_len]
    cmp rdx, 200
    jbe 1f
    mov edx, 200
1:  call sb_push
    lea rdi, [rip + pl_buf]
    lea rsi, [rip + .Lw_bar]
    call sb_push_cstr
    xor r13d, r13d
2:  lea rax, [rip + pb_x0]
    mov esi, [rax + r13*4]
    lea rdi, [rip + pl_buf]
    call sb_push_u64
    lea rax, [rip + .Lbox_seps]
    movzx esi, byte ptr [rax + r13]
    lea rdi, [rip + pl_buf]
    call sb_push_byte
    inc r13d
    cmp r13d, 4
    jb 2b
    lea rdi, [rip + pl_buf]
    lea rsi, [rip + .Lw_timeout]
    call sb_push_cstr
    call app_timeout
    cmp eax, -1
    jne 3f
    lea rdi, [rip + pl_buf]
    lea rsi, [rip + .Lw_never]
    call sb_push_cstr
    jmp 4f
3:  mov esi, eax
    lea rdi, [rip + pl_buf]
    call sb_push_u64
4:  lea rdi, [rip + pl_buf]
    mov esi, 10
    call sb_push_byte
    mov rdi, r12
    mov esi, O_WRONLY | O_CREAT | O_APPEND
    mov edx, 0644
    SYS SYS_open
    test eax, eax
    js 9f
    mov ebx, eax
    mov edi, eax
    mov rsi, [rip + pl_buf + SB_ptr]
    mov rdx, [rip + pl_buf + SB_len]
    call write_all
    mov edi, ebx
    SYS SYS_close
9:  EPILOGUE

.section .rodata
.Lenv_stale: .asciz "RHUN_STALE"
.Lenv_under: .asciz "RHUN_UNDERPAINT"
.Lw_stale: .asciz "stale "
.Lw_under: .asciz "underpaint "
.Lw_bar: .asciz " | "
.Lw_timeout: .asciz "| timeout "
.Lw_never: .asciz "never"
.Lbox_seps: .ascii ",-, "
.bss
.p2align 3
.globl g_probe_plant
g_probe_plant: .long 0          # probe-plant: 1 a stale frame, 2 an unpainted pixel, once
probe_done: .long 0
.p2align 3
stale_log: .quad 0
under_log: .quad 0
hbuf2: .quad 0
hbuf2_cap: .quad 0
pb_x0: .long 0
pb_y0: .long 0
pb_x1: .long 0
pb_y1: .long 0
.p2align 3
pl_buf: .zero SB_SIZE
.text
.endif

# Detach counted clipboard storage before a setter or a completion can replace it.
hl_clip_copy:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    cmp rsi, CLW_MAX
    ja 2f
    test rdi, rdi
    jnz 1f
    test rsi, rsi
    jnz 2f
1:  lea rdi, [rsi + 1]
    call mem_alloc_try
    test rax, rax
    jz 3f
    mov r13, rax
    mov rdi, rax
    mov rsi, rbx
    mov rdx, r12
    call memcpy
    mov rax, r13
    jmp 3f
2:  xor eax, eax
3:  EPILOGUE

FN headless_clip_reset
    PROLOGUE
    lea rdi, [rip + hclip]
    call sb_free
    lea rdi, [rip + hclip_wire]
    call sb_free
    lea rdi, [rip + hclip_files]
    call sb_free
    mov rdi, [rip + hclip_image]
    call mem_free
    mov qword ptr [rip + hclip_image], 0
    EPILOGUE

FN headless_clip_set
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    cmp rsi, DOC_MULTI_BYTES_MAX
    ja .Lhcs_bad
    test rdi, rdi
    jnz 1f
    test rsi, rsi
    jnz .Lhcs_bad
1:  call snippet_utf8_valid
    test eax, eax
    jz .Lhcs_bad
    mov rdi, rbx
    mov rsi, r12
    call hl_clip_copy
    test rax, rax
    jz .Lhcs_bad
    mov rbx, rax
    call headless_clip_reset
    mov [rip + hclip + SB_ptr], rbx
    mov [rip + hclip + SB_len], r12
    inc r12
    mov [rip + hclip + SB_cap], r12
    mov eax, 1
    EPILOGUE
.Lhcs_bad:
    xor eax, eax
    EPILOGUE

FN headless_clip_write
    PROLOGUE CWB_SIZE
    mov rbx, rdi
    mov r12, rsi
    mov rdx, rsp
    call clip_wire_decode
    test eax, eax
    jz .Lhcw_bad
    mov rdi, rbx
    mov rsi, r12
    call hl_clip_copy
    test rax, rax
    jz .Lhcw_bad
    mov r13, rax
    mov rdi, [rsp + CWB_text]
    mov rsi, [rsp + CWB_len]
    call hl_clip_copy
    test rax, rax
    jz .Lhcw_free
    mov r14, rax
    call headless_clip_reset
    mov [rip + hclip_wire + SB_ptr], r13
    mov [rip + hclip_wire + SB_len], r12
    inc r12
    mov [rip + hclip_wire + SB_cap], r12
    mov [rip + hclip + SB_ptr], r14
    mov rax, [rsp + CWB_len]
    mov [rip + hclip + SB_len], rax
    inc rax
    mov [rip + hclip + SB_cap], rax
    mov eax, 1
    EPILOGUE
.Lhcw_free:
    mov rdi, r13
    call mem_free
.Lhcw_bad:
    xor eax, eax
    EPILOGUE

# headless_clip_get(kinds CLIPK_*, an image's most bytes): files, else an image, else text, as the request
#   asks (phase 4 task 4); clip-hold keeps the request until clip-release delivers it
FN headless_clip_get
    PROLOGUE
    mov rbx, [rip + app_clip_active_token]
    cmp dword ptr [rip + hclip_hold], 0
    je 1f
    mov [rip + hclip_held], rbx
    mov [rip + hclip_held_kinds], edi
    mov [rip + hclip_held_max], esi
    EPILOGUE
1:  mov edx, esi
    mov esi, edi
    mov rdi, rbx
    call hl_clip_deliver
    EPILOGUE

# hl_clip_deliver(token, kinds, an image's most bytes): what the headless clipboard holds, of the best kind
hl_clip_deliver:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    test r12d, CLIPK_FILES
    jz 2f
    mov r14, [rip + hclip_files + SB_len]
    test r14, r14
    jz 2f
    mov rdi, [rip + hclip_files + SB_ptr]
    mov rsi, r14
    call mem_dup
    mov r15, rax
    mov rdi, rbx
    mov esi, CLIPK_FILES
    mov rdx, rax
    mov rcx, r14
    call app_clip_complete_kind
    mov rdi, r15
    call mem_free
    EPILOGUE
2:  test r12d, CLIPK_IMAGE
    jz 4f
    mov rdi, [rip + hclip_image]
    test rdi, rdi
    jz 4f
    lea esi, [r13 - 1]          # never more than the request takes: a larger file is not read
    call file_read_limited
    test rax, rax
    jnz 3f
    cmp rdx, -27
    jne 4f                      # unreadable: the text, as a system whose image failed
    mov qword ptr [rip + g_clip_read], 0
    mov rdi, rbx
    mov esi, CLIPK_IMAGE
    xor edx, edx
    mov rcx, CLIP_TOO_BIG
    call app_clip_complete_kind
    EPILOGUE
3:  mov r15, rax
    mov rdi, rbx
    mov esi, CLIPK_IMAGE
    mov rcx, rdx
    mov rdx, rax
    call app_clip_complete_kind
    mov rdi, r15
    call mem_free
    EPILOGUE
4:  mov rdi, rbx
    call hl_clip_text
    EPILOGUE

# headless_clip_release(): clip-release: the held request gets what the clipboard holds now
FN headless_clip_release
    PROLOGUE
    mov dword ptr [rip + hclip_hold], 0
    mov rdi, [rip + hclip_held]
    test rdi, rdi
    jz 9f
    mov qword ptr [rip + hclip_held], 0
    mov esi, [rip + hclip_held_kinds]
    mov edx, [rip + hclip_held_max]
    call hl_clip_deliver
9:  EPILOGUE

# headless_clip_put(kind CLIPK_*, ptr, len) -> eax 1: clip-set: text (as a copy from another program), a
#   file list (NUL after each path) or an image file's path; the other kinds stay. len 0 clears that kind;
#   kind 0 clears all
FN headless_clip_put
    PROLOGUE
    mov r12d, edi
    mov r13, rsi
    mov r14, rdx
    test r12d, r12d
    jnz 1f
    call headless_clip_reset
    jmp 8f
1:  cmp r12d, CLIPK_TEXT
    jne 2f
    lea rdi, [rip + hclip_wire]
    call sb_free
    lea rdi, [rip + hclip]
    call sb_free
    test r14, r14
    jz 8f
    lea rdi, [rip + hclip]
    mov rsi, r13
    mov rdx, r14
    call sb_push
    jmp 8f
2:  cmp r12d, CLIPK_FILES
    jne 3f
    lea rdi, [rip + hclip_files]
    call sb_free
    lea rdi, [rip + hclip_files]
    mov rsi, r13
    mov rdx, r14
    call sb_push
    jmp 8f
3:  mov rdi, [rip + hclip_image]
    call mem_free
    mov qword ptr [rip + hclip_image], 0
    test r14, r14
    jz 8f
    mov rdi, r13
    mov rsi, r14
    call mem_dup
    mov [rip + hclip_image], rax
8:  mov eax, 1
    EPILOGUE

# headless_clip_dump(sb): print-clip: "text=BYTES files=N image=BYTES|- read=BYTES kind=K asked=K held=0|1":
#   the clipboard, what the last answer brought and of which kind, what the last request asked for
FN headless_clip_dump
    PROLOGUE
    mov rbx, rdi
    lea rsi, [rip + .Lhc_text]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rip + hclip + SB_len]
    call sb_push_u64
    lea rsi, [rip + .Lhc_files]
    mov rdi, rbx
    call sb_push_cstr
    xor r12d, r12d              # the paths: a NUL after each
    xor ecx, ecx
    mov rax, [rip + hclip_files + SB_ptr]
1:  cmp rcx, [rip + hclip_files + SB_len]
    jae 2f
    cmp byte ptr [rax + rcx], 0
    jne 11f
    inc r12
11: inc rcx
    jmp 1b
2:  mov rdi, rbx
    mov rsi, r12
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lhc_image]
    call sb_push_cstr
    mov rdi, [rip + hclip_image]
    test rdi, rdi
    jz 3f
    call vfs_stat
    test rax, rax
    js 3f
    mov rdi, rbx
    mov rsi, [rip + vfs_statbuf + 48]
    call sb_push_u64
    jmp 4f
3:  mov rdi, rbx
    mov esi, '-'
    call sb_push_byte
4:  mov rdi, rbx
    lea rsi, [rip + .Lhc_read]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rip + g_clip_read]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lhc_kind]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rip + g_clip_last_kind]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lhc_asked]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rip + g_clip_asked]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lhc_held]
    call sb_push_cstr
    xor esi, esi
    cmp qword ptr [rip + hclip_held], 0
    setne sil
    mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    EPILOGUE

.section .rodata
.Lhc_text: .asciz "text="
.Lhc_files: .asciz " files="
.Lhc_image: .asciz " image="
.Lhc_read: .asciz " read="
.Lhc_kind: .asciz " kind="
.Lhc_held: .asciz " held="
.Lhc_asked: .asciz " asked="
.text

# hl_clip_text(token): the text the headless clipboard holds (rhun's own rich copy first)
hl_clip_text:
    PROLOGUE
    mov rbx, rdi
    mov rdi, [rip + hclip_wire + SB_ptr]
    test rdi, rdi
    jz .Lhcg_plain
    mov r13, [rip + hclip_wire + SB_len]
    mov rsi, r13
    call hl_clip_copy
    test rax, rax
    jz .Lhcg_plain
    mov r12, rax
    mov rdi, rbx
    mov rsi, rax
    mov rdx, r13
    call app_clip_complete_native
    mov r14d, eax
    mov rdi, r12
    call mem_free
    test r14d, r14d
    jnz .Lhcg_done
.Lhcg_plain:
    mov rdi, [rip + hclip + SB_ptr]
    test rdi, rdi
    jz .Lhcg_failure
    mov r13, [rip + hclip + SB_len]
    mov rsi, r13
    call hl_clip_copy
    test rax, rax
    jz .Lhcg_failure
    mov r12, rax
    mov rdi, rbx
    mov rsi, rax
    mov rdx, r13
    mov ecx, 1
    call app_clip_complete
    mov rdi, r12
    call mem_free
    jmp .Lhcg_done
.Lhcg_failure:
    mov rdi, rbx
    xor esi, esi
    xor edx, edx
    xor ecx, ecx
    call app_clip_complete
.Lhcg_done:
    EPILOGUE
