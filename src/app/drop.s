# Files dropped on the window (generic; phase 4 task 5). A platform reports a drag with files as four events
# (app_on_drop: DROP_ENTER, DROP_MOVE, DROP_LEAVE, DROP_FILES with the point and the paths); rhun's own drags
# of paths (an explorer row, a file's tab) end the same way, marked as in-app. A part of the window claims a
# drop while it draws: drop_over says a drag with files is over its rectangle (its highlight), drop_take gives
# it the dropped paths, once. What nobody took by the frame's end opens: an OS drop's regular files in tabs
# (the first 20), an in-app drop nothing. Nothing is kept past that frame. Nothing here runs while no drag is
# under way: the state is a few words, and a move during a drag costs a frame, its highlight.
#
#   app_on_drop(DROP_*, x, y, list, len)   from the platform; list: paths, a NUL after each (DROP_FILES), copied
#                                       (at most DROP_PATHS_MAX paths and DROP_BYTES_MAX bytes: a toast says so)
#   drop_over(x, y, w, h) -> eax 1      a drag with files (or an in-app drag of paths) is over the rect now
#   drop_take(x, y, w, h) -> rax list or 0, rdx len, ecx 1 in-app (a mention)   the dropped paths, to the
#                                       first rect that asks and holds the point
#   drop_frame()                        the frame's end (app_render): an untaken drop opens or goes; an in-app
#                                       drag follows the pointer (its name beside it) and, let go, drops
#   drag_paths_begin(list, len)         an in-app drag of paths begins at the pointer (copied): it becomes one
#                                       once the pointer moved MI_4 with the left button held
#   drag_paths_active() -> eax 1        it moved: the paths follow the pointer
#   drag_tab_released()                 a file's tab that was dragged (tab_drag_step) was let go: an in-app
#                                       drop of its path where the pointer is
#   drop_dump(sb)                       print-drop: "over=0|1 at=X,Y files=N|none drag=0|1 opened=N"
#   clipdrop_ctl                        control commands: clip-set, clip-hold, clip-release, clip-request,
#                                       print-clip, drop, drag-paths, print-drop, print-agent-pastes,
#                                       print-agent-veil
.include "rhun.inc"

.equ OPEN_MAX, 20               # an untaken drop's files opened at most

.bss
.p2align 3
dp_list: .quad 0                # the dropped paths waiting for this frame (owned), their bytes and count
dp_len: .quad 0
dp_n: .quad 0
dp_over: .long 0                # a drag with files is over the window
dp_x: .long 0                   # where (window pixels)
dp_y: .long 0
dp_taken: .long 0               # the waiting list was taken this frame
dp_inapp: .long 0               # it came from rhun's own drag (a mention, never opened)
dp_pad: .long 0
dr_list: .quad 0                # an in-app drag: its paths (owned), their bytes, where it began
dr_len: .quad 0
dr_x0: .long 0
dr_y0: .long 0
dr_moved: .long 0
dr_pad: .long 0
dp_opened: .quad 0              # files an untaken drop opened since start (print-drop)
wsb: .zero SB_SIZE
.text

# count_paths(list, len) -> rax the paths (non-empty, NUL-ended)
count_paths:
    xor eax, eax
    xor ecx, ecx
    xor edx, edx                # the current path's bytes
1:  cmp rcx, rsi
    jae 9f
    cmp byte ptr [rdi + rcx], 0
    jne 2f
    test edx, edx
    jz 3f
    inc rax
    xor edx, edx
    jmp 3f
2:  inc edx
3:  inc rcx
    jmp 1b
9:  ret

# drop_clear(): the waiting list goes
drop_clear:
    sub rsp, 8
    mov rdi, [rip + dp_list]
    mov qword ptr [rip + dp_list], 0
    mov qword ptr [rip + dp_len], 0
    mov qword ptr [rip + dp_n], 0
    mov dword ptr [rip + dp_taken], 0
    mov dword ptr [rip + dp_inapp], 0
    call mem_free
    add rsp, 8
    ret

# take_list(list, len, inapp): a copy of the paths becomes the waiting list: at most DROP_PATHS_MAX paths and
#   DROP_BYTES_MAX bytes, a path cut by the byte cap left out; the rest counted (a toast)
take_list:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r15d, edx
    call drop_clear
    lea rdi, [rip + wsb]
    call sb_clear
    xor r13d, r13d              # paths taken
    xor r14d, r14d              # paths left out
    xor ecx, ecx
1:  cmp rcx, r12                # each path: its end
    jae 8f
    mov rdx, rcx
2:  cmp rdx, r12
    jae 3f
    cmp byte ptr [rbx + rdx], 0
    je 3f
    inc rdx
    jmp 2b
3:  mov rsi, rdx                # [rcx, rdx) the path
    sub rsi, rcx
    lea rax, [rdx + 1]
    push rax
    push rax
    test rsi, rsi
    jz 6f
    cmp r13, DROP_PATHS_MAX
    jae 5f
    mov rax, [rip + wsb + SB_len]
    add rax, rsi
    inc rax
    cmp rax, DROP_BYTES_MAX
    ja 5f
    lea rdi, [rip + wsb]
    lea rsi, [rbx + rcx]
    mov rdx, [rsp]
    dec rdx
    sub rdx, rcx
    call sb_push
    lea rdi, [rip + wsb]
    xor esi, esi
    call sb_push_byte
    inc r13
    jmp 6f
5:  inc r14
6:  pop rcx
    pop rcx
    jmp 1b
8:  test r13, r13
    jz 9f
    mov rdi, [rip + wsb + SB_ptr]
    mov rsi, [rip + wsb + SB_len]
    call mem_dup
    mov [rip + dp_list], rax
    mov rax, [rip + wsb + SB_len]
    mov [rip + dp_len], rax
    mov [rip + dp_n], r13
    mov [rip + dp_inapp], r15d
9:  test r14, r14
    jz 10f
    lea rdi, [rip + .Ltoo_many]
    call app_toast
10: EPILOGUE

# FN app_on_drop(DROP_*, x, y, list, len): see the top
FN app_on_drop
    PROLOGUE
    mov ebx, edi
    mov r12d, esi
    mov r13d, edx
    mov r14, rcx
    mov r15, r8
    mov dword ptr [rip + g_dirty], 1
    cmp ebx, DROP_LEAVE
    jne 1f
    mov dword ptr [rip + dp_over], 0
    EPILOGUE
1:  mov [rip + dp_x], r12d
    mov [rip + dp_y], r13d
    mov edi, r12d               # the pointer is where the drag is
    mov esi, r13d
    call ui_input_motion
    cmp ebx, DROP_FILES
    je 2f
    cmp ebx, DROP_ENTER
    je 11f
    cmp ebx, DROP_MOVE
    jne 9f
11: mov dword ptr [rip + dp_over], 1
    EPILOGUE
2:  mov dword ptr [rip + dp_over], 0
    test r14, r14
    jz 9f
    mov rdi, r14
    mov rsi, r15
    xor edx, edx
    call take_list
9:  EPILOGUE

# in_rect(x, y, w, h, px, py) -> eax 1 when the point is inside
in_rect:
    xor eax, eax
    cmp r8d, edi
    jl 9f
    add edi, edx
    cmp r8d, edi
    jge 9f
    cmp r9d, esi
    jl 9f
    add esi, ecx
    cmp r9d, esi
    jge 9f
    inc eax
9:  ret

# FN drop_over(x, y, w, h) -> eax 1: see the top
FN drop_over
    cmp dword ptr [rip + dp_over], 0
    je 1f
    mov r8d, [rip + dp_x]
    mov r9d, [rip + dp_y]
    jmp in_rect
1:  cmp qword ptr [rip + dr_list], 0
    je 2f
    cmp dword ptr [rip + dr_moved], 0
    je 2f
    test dword ptr [rip + g_mdown], 1 << BTN_LEFT
    jz 2f
    mov r8d, [rip + g_mx]
    mov r9d, [rip + g_my]
    jmp in_rect
2:  xor eax, eax
    ret

# FN drop_take(x, y, w, h) -> rax list or 0, rdx len, ecx in-app: see the top
FN drop_take
    cmp qword ptr [rip + dp_list], 0
    je 8f
    cmp dword ptr [rip + dp_taken], 0
    jne 8f
    mov r8d, [rip + dp_x]
    mov r9d, [rip + dp_y]
    sub rsp, 8
    call in_rect
    add rsp, 8
    test eax, eax
    jz 8f
    mov dword ptr [rip + dp_taken], 1
    mov rax, [rip + dp_list]
    mov rdx, [rip + dp_len]
    mov ecx, [rip + dp_inapp]
    ret
8:  xor eax, eax
    xor edx, edx
    xor ecx, ecx
    ret

# open_untaken(): an OS drop nobody took: its regular files in tabs (folders and the rest skipped)
open_untaken:
    PROLOGUE
    mov rbx, [rip + dp_list]
    mov r12, rbx
    add r12, [rip + dp_len]
    xor r13d, r13d
1:  cmp rbx, r12
    jae 9f
    cmp r13d, OPEN_MAX
    jae 9f
    mov rdi, rbx
    call strlen
    mov r14, rbx
    lea rbx, [rbx + rax + 1]
    test rax, rax
    jz 1b
    mov rdi, r14
    call vfs_type
    cmp eax, 0x8000
    jne 1b
    mov rdi, r14
    call app_open_file
    test rax, rax
    js 1b
    inc r13d
    inc qword ptr [rip + dp_opened]
    jmp 1b
9:  EPILOGUE

# FN drop_frame(): see the top
FN drop_frame
    PROLOGUE
    cmp qword ptr [rip + dp_list], 0
    je 2f
    cmp dword ptr [rip + dp_taken], 0
    jne 1f
    cmp dword ptr [rip + dp_inapp], 0
    jne 1f
    call open_untaken
1:  call drop_clear
    mov dword ptr [rip + g_dirty], 1
2:  cmp qword ptr [rip + dr_list], 0
    je 9f
    test dword ptr [rip + g_mdown], 1 << BTN_LEFT
    jz 5f
    cmp dword ptr [rip + dr_moved], 0
    jne 4f
    mov eax, [rip + g_mx]       # it becomes a drag once the pointer moved MI_4 away
    sub eax, [rip + dr_x0]
    cdq
    xor eax, edx
    sub eax, edx
    mov ecx, [rip + g_my]
    sub ecx, [rip + dr_y0]
    mov edx, ecx
    sar edx, 31
    xor ecx, edx
    sub ecx, edx
    add eax, ecx
    cmp eax, [rip + g_mt + 4*MI_4]
    jle 9f
    mov dword ptr [rip + dr_moved], 1
4:  call drag_label
    EPILOGUE
5:  cmp dword ptr [rip + dr_moved], 0       # let go: dropped where the pointer is, or nothing
    je 6f
    mov eax, [rip + g_mx]
    mov [rip + dp_x], eax
    mov eax, [rip + g_my]
    mov [rip + dp_y], eax
    mov rdi, [rip + dr_list]
    mov rsi, [rip + dr_len]
    mov edx, 1
    call take_list
    mov dword ptr [rip + g_dirty], 1
6:  call drag_end
9:  EPILOGUE

# drag_end(): the in-app drag goes
drag_end:
    sub rsp, 8
    mov rdi, [rip + dr_list]
    mov qword ptr [rip + dr_list], 0
    mov qword ptr [rip + dr_len], 0
    mov dword ptr [rip + dr_moved], 0
    call mem_free
    add rsp, 8
    ret

# drag_label(): the dragged path's name (and "+N" for more) in a small box beside the pointer
drag_label:
    PROLOGUE 16
    lea rdi, [rip + wsb]
    call sb_clear
    mov rdi, [rip + dr_list]
    call strlen
    mov rdi, [rip + dr_list]    # the first path's last part
    mov rsi, rax
1:  test rsi, rsi
    jz 2f
    cmp byte ptr [rdi + rsi - 1], '/'
    jne 11f
    dec rsi
    jmp 1b
11: mov rcx, rsi
12: test rcx, rcx
    jz 13f
    cmp byte ptr [rdi + rcx - 1], '/'
    je 13f
    dec rcx
    jmp 12b
13: lea rax, [rdi + rcx]
    sub rsi, rcx
    mov rdi, rax
2:  mov rdx, rsi
    mov rsi, rdi
    lea rdi, [rip + wsb]
    call sb_push
    mov rdi, [rip + dr_list]
    mov rsi, [rip + dr_len]
    call count_paths
    cmp rax, 1
    jbe 3f
    mov rbx, rax
    lea rdi, [rip + wsb]
    lea rsi, [rip + .Lplus]
    call sb_push_cstr
    lea rdi, [rip + wsb]
    lea rsi, [rbx - 1]
    call sb_push_u64
3:  lea rdi, [rip + g_face_small]
    mov rsi, [rip + wsb + SB_ptr]
    mov rdx, [rip + wsb + SB_len]
    call text_width
    M ecx, MI_16
    add eax, ecx
    mov [rsp], eax              # its box's width
    mov edi, [rip + g_mx]
    add edi, [rip + g_mt + 4*MI_12]
    mov esi, [rip + g_my]
    add esi, [rip + g_mt + 4*MI_12]
    mov [rsp + 4], edi
    mov [rsp + 8], esi
    mov edx, [rsp]
    M ecx, MI_24
    COLOR r8d, T_BORDER
    call gfx_fill
    mov edi, [rsp + 4]
    inc edi
    mov esi, [rsp + 8]
    inc esi
    mov edx, [rsp]
    sub edx, 2
    M ecx, MI_24
    sub ecx, 2
    COLOR r8d, T_PANEL
    call gfx_fill
    lea rdi, [rip + g_face_small]
    mov esi, [rsp + 4]
    add esi, [rip + g_mt + 4*MI_8]
    mov edx, [rsp + 8]
    M ecx, MI_24
    mov r8, [rip + wsb + SB_ptr]
    mov r9, [rip + wsb + SB_len]
    COLOR eax, T_FG
    push rax
    push rax
    call ui_text_v
    add rsp, 16
    EPILOGUE

# FN drag_paths_begin(list, len): see the top
FN drag_paths_begin
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call drag_end
    test r12, r12
    jz 9f
    mov rdi, rbx
    mov rsi, r12
    call mem_dup
    mov [rip + dr_list], rax
    mov [rip + dr_len], r12
    mov eax, [rip + g_mx]
    mov [rip + dr_x0], eax
    mov eax, [rip + g_my]
    mov [rip + dr_y0], eax
9:  EPILOGUE

# FN drag_paths_active() -> eax 1: see the top
FN drag_paths_active
    xor eax, eax
    cmp qword ptr [rip + dr_list], 0
    je 1f
    mov eax, [rip + dr_moved]
1:  ret

# FN drag_tab_released(): see the top. A tab is a file only when it is a document, an image or a notebook
#   whose DOC has a path and is no diff: a Review tab, a picture from memory, a conversation, Settings are none
FN drag_tab_released
    PROLOGUE
    mov rdi, [rip + g_tab_cur]
    test rdi, rdi
    js 9f
    cmp rdi, [rip + g_tabs + VEC_len]
    jae 9f
    call tab_at
    mov rcx, [rax + TAB_kind]
    cmp rcx, TAB_DOC
    je 1f
    cmp rcx, TAB_IMAGE
    je 1f
    cmp rcx, TAB_NOTEBOOK
    jne 9f
1:  mov rbx, [rax + TAB_doc]
    test rbx, rbx
    jz 9f
    cmp qword ptr [rbx + DOC_diff], 0
    jne 9f
    mov r12, [rbx + DOC_path]
    test r12, r12
    jz 9f
    mov rdi, r12                # an in-app drag let go: drop_frame drops it where the pointer is, and the
    call strlen                 #   next frame's parts claim it (this frame may have drawn them already)
    mov rdi, r12
    lea rsi, [rax + 1]
    call drag_paths_begin
    mov dword ptr [rip + dr_moved], 1
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# FN drop_dump(sb): see the top
FN drop_dump
    PROLOGUE
    mov rbx, rdi
    lea rsi, [rip + .Ld_over]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + dp_over]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_at]
    call sb_push_cstr
    mov rdi, rbx
    movsxd rsi, dword ptr [rip + dp_x]
    call sb_push_u64
    mov rdi, rbx
    mov esi, ','
    call sb_push_byte
    mov rdi, rbx
    movsxd rsi, dword ptr [rip + dp_y]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_files]
    call sb_push_cstr
    cmp qword ptr [rip + dp_list], 0
    jne 1f
    mov rdi, rbx
    lea rsi, [rip + .Ld_none]
    call sb_push_cstr
    jmp 2f
1:  mov rdi, rbx
    mov rsi, [rip + dp_n]
    call sb_push_u64
2:  mov rdi, rbx
    lea rsi, [rip + .Ld_drag]
    call sb_push_cstr
    call drag_paths_active
    mov rdi, rbx
    mov esi, eax
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_opened]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rip + dp_opened]
    call sb_push_u64
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    EPILOGUE

# ---- control commands (tests): the headless clipboard and drops ----

# next_word(ptr, len) -> rax the first word's length, rdx where the rest begins (after one space)
next_word:
    xor eax, eax
1:  cmp rax, rsi
    jae 2f
    cmp byte ptr [rdi + rax], ' '
    je 2f
    inc rax
    jmp 1b
2:  lea rdx, [rax + 1]
    cmp rdx, rsi
    jbe 3f
    mov rdx, rsi
3:  ret

# list_arg(ptr, len) -> rax owned list, rdx len: "A|B|C" as paths with a NUL after each; "@FILE": FILE's
#   lines as the paths
list_arg:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea rdi, [rip + wsb]
    call sb_clear
    test r12, r12
    jz 8f
    cmp byte ptr [rbx], '@'
    jne 3f
    lea rdi, [rbx + 1]
    lea rsi, [r12 - 1]
    call mem_dup
    mov r13, rax
    mov rdi, rax
    call file_read_all
    mov r14, rax
    mov r15, rdx
    mov rdi, r13
    call mem_free
    test r14, r14
    jz 8f
    xor ecx, ecx
1:  cmp rcx, r15
    jae 2f
    cmp byte ptr [r14 + rcx], 10
    jne 11f
    mov byte ptr [r14 + rcx], 0
11: inc rcx
    jmp 1b
2:  lea rdi, [rip + wsb]
    mov rsi, r14
    mov rdx, r15
    call sb_push
    mov rdi, r14
    call mem_free
    jmp 7f
3:  lea rdi, [rip + wsb]
    mov rsi, rbx
    mov rdx, r12
    call sb_push
    mov rax, [rip + wsb + SB_ptr]
    xor ecx, ecx
4:  cmp rcx, r12
    jae 7f
    cmp byte ptr [rax + rcx], '|'
    jne 41f
    mov byte ptr [rax + rcx], 0
41: inc rcx
    jmp 4b
7:  mov rax, [rip + wsb + SB_len]
    test rax, rax
    jz 8f
    mov rcx, [rip + wsb + SB_ptr]
    cmp byte ptr [rcx + rax - 1], 0
    je 8f
    lea rdi, [rip + wsb]
    xor esi, esi
    call sb_push_byte
8:  mov rdi, [rip + wsb + SB_ptr]
    mov rsi, [rip + wsb + SB_len]
    call mem_dup
    mov rdx, [rip + wsb + SB_len]
    EPILOGUE

# c_clip_set(out, rest, len): clip-set text TEXT (\n a line feed, \\ a backslash) | files A|B|@FILE |
#   image PATH | clear
c_clip_set:
    PROLOGUE
    mov rbx, rsi
    mov r12, rdx
    mov rdi, rbx
    mov rsi, r12
    call next_word
    mov r13, rax
    lea r14, [rbx + rdx]
    mov r15, r12
    sub r15, rdx
    mov rdi, rbx
    mov rsi, r13
    lea rdx, [rip + .Lw_text]
    call str_eq_cstr
    test eax, eax
    jnz .Lcs_text
    mov rdi, rbx
    mov rsi, r13
    lea rdx, [rip + .Lw_files]
    call str_eq_cstr
    test eax, eax
    jnz .Lcs_files
    mov rdi, rbx
    mov rsi, r13
    lea rdx, [rip + .Lw_image]
    call str_eq_cstr
    test eax, eax
    jnz .Lcs_image
    mov rdi, rbx
    mov rsi, r13
    lea rdx, [rip + .Lw_clear]
    call str_eq_cstr
    test eax, eax
    jz .Lcs_bad
    xor edi, edi
    xor esi, esi
    xor edx, edx
    call headless_clip_put
    xor eax, eax
    EPILOGUE
.Lcs_text:
    lea rdi, [rip + wsb]
    call sb_clear
    xor ebx, ebx
1:  cmp rbx, r15
    jae 3f
    movzx esi, byte ptr [r14 + rbx]
    inc rbx
    cmp esi, '\\'
    jne 2f
    cmp rbx, r15
    jae 2f
    movzx esi, byte ptr [r14 + rbx]
    inc rbx
    cmp esi, 'n'
    jne 2f
    mov esi, 10
2:  lea rdi, [rip + wsb]
    call sb_push_byte
    jmp 1b
3:  mov edi, CLIPK_TEXT
    mov rsi, [rip + wsb + SB_ptr]
    mov rdx, [rip + wsb + SB_len]
    call headless_clip_put
    xor eax, eax
    EPILOGUE
.Lcs_files:
    mov rdi, r14
    mov rsi, r15
    call list_arg
    mov rbx, rax
    mov edi, CLIPK_FILES
    mov rsi, rax
    call headless_clip_put
    mov rdi, rbx
    call mem_free
    xor eax, eax
    EPILOGUE
.Lcs_image:
    mov edi, CLIPK_IMAGE
    mov rsi, r14
    mov rdx, r15
    call headless_clip_put
    xor eax, eax
    EPILOGUE
.Lcs_bad:
    mov rax, -1
    EPILOGUE

# c_clip_hold(out, rest, len): the next request waits for clip-release
c_clip_hold:
    mov dword ptr [rip + hclip_hold], 1
    xor eax, eax
    ret

# c_clip_release(out, rest, len): the held request gets what the clipboard holds now
c_clip_release:
    sub rsp, 8
    call headless_clip_release
    mov dword ptr [rip + g_dirty], 1
    xor eax, eax
    add rsp, 8
    ret

# c_clip_request(out, rest, len): clip-request KINDS: a paste into the focused place that asks the platform for
#   those CLIPK_* kinds (a real system's TARGETS round, file lists and images, without the agents' box)
c_clip_request:
    PROLOGUE
    mov rdi, rsi
    mov rsi, rdx
    call parse_u64
    mov edi, eax
    call app_clip_request_kinds
    xor eax, eax
    EPILOGUE

# c_print_clip(out, rest, len)
c_print_clip:
    sub rsp, 8
    call headless_clip_dump
    xor eax, eax
    add rsp, 8
    ret

# c_drop(out, rest, len): drop enter|move|leave|files X Y [A|B|@FILE]
c_drop:
    PROLOGUE 16
    mov rbx, rsi
    mov r12, rdx
    mov rdi, rbx
    mov rsi, r12
    call next_word
    mov r13, rax                # the event's word
    lea r14, [rbx + rdx]
    mov r15, r12
    sub r15, rdx
    xor ecx, ecx
    lea rax, [rip + .Ldrop_words]
1:  mov rdx, [rax + rcx*8]
    test rdx, rdx
    jz .Ldr_bad
    push rax
    push rcx
    mov rdi, rbx
    mov rsi, r13
    call str_eq_cstr
    pop rcx
    pop rdx
    test eax, eax
    jnz 2f
    mov rax, rdx
    inc ecx
    jmp 1b
2:  inc ecx                     # DROP_ENTER 1 ..
    mov [rsp], ecx
    mov rdi, r14                # X
    mov rsi, r15
    call parse_u64
    mov [rsp + 4], eax
    add r14, rdx
    sub r15, rdx
    test r15, r15
    jz 3f
    inc r14
    dec r15
3:  mov rdi, r14                # Y
    mov rsi, r15
    call parse_u64
    mov [rsp + 8], eax
    add r14, rdx
    sub r15, rdx
    test r15, r15
    jz 4f
    inc r14
    dec r15
4:  xor ebx, ebx
    xor r12d, r12d
    cmp dword ptr [rsp], DROP_FILES
    jne 5f
    mov rdi, r14
    mov rsi, r15
    call list_arg
    mov rbx, rax
    mov r12, rdx
5:  mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov rcx, rbx
    mov r8, r12
    call app_on_drop
    mov rdi, rbx
    call mem_free
    xor eax, eax
    EPILOGUE
.Ldr_bad:
    mov rax, -1
    EPILOGUE

# c_drag_paths(out, rest, len): drag-paths A|B: an in-app drag of those paths begins at the pointer (the left
#   button is pressed there first by the test: down X Y)
c_drag_paths:
    PROLOGUE
    mov rdi, rsi
    mov rsi, rdx
    call list_arg
    mov rbx, rax
    mov rdi, rax
    mov rsi, rdx
    call drag_paths_begin
    mov rdi, rbx
    call mem_free
    xor eax, eax
    EPILOGUE

# c_print_agent_pastes(out, rest, len): the long pastes the box remembers (agentpaste.s)
c_print_agent_pastes:
    sub rsp, 8
    call agpaste_dump
    xor eax, eax
    add rsp, 8
    ret

# c_print_agent_veil(out, rest, len): the conversation's area and its veil as last drawn (agentpaste.s)
c_print_agent_veil:
    sub rsp, 8
    call agpaste_veil_dump
    xor eax, eax
    add rsp, 8
    ret

# c_print_drop(out, rest, len)
c_print_drop:
    sub rsp, 8
    call drop_dump
    xor eax, eax
    add rsp, 8
    ret

.section .rodata
.Ltoo_many: .asciz "Only the first 1,000 dropped files were taken."
.Lplus: .asciz " +"
.Ld_over: .asciz "over="
.Ld_at: .asciz " at="
.Ld_files: .asciz " files="
.Ld_none: .asciz "none"
.Ld_drag: .asciz " drag="
.Ld_opened: .asciz " opened="
.Lw_text: .asciz "text"
.Lw_files: .asciz "files"
.Lw_image: .asciz "image"
.Lw_clear: .asciz "clear"
.Lw_enter: .asciz "enter"
.Lw_move: .asciz "move"
.Lw_leave: .asciz "leave"
.Lw_dfiles: .asciz "files"
.Lc_clip_set: .asciz "clip-set"
.Lc_clip_hold: .asciz "clip-hold"
.Lc_clip_release: .asciz "clip-release"
.Lc_print_clip: .asciz "print-clip"
.Lc_clip_request: .asciz "clip-request"
.Lc_drop: .asciz "drop"
.Lc_drag_paths: .asciz "drag-paths"
.Lc_print_drop: .asciz "print-drop"
.Lc_print_agent_pastes: .asciz "print-agent-pastes"
.Lc_print_agent_veil: .asciz "print-agent-veil"
.p2align 3
.Ldrop_words: .quad .Lw_enter, .Lw_move, .Lw_leave, .Lw_dfiles, 0
.globl clipdrop_ctl
clipdrop_ctl:
    .quad .Lc_clip_set, c_clip_set, .Lc_clip_hold, c_clip_hold, .Lc_clip_release, c_clip_release
    .quad .Lc_print_clip, c_print_clip, .Lc_drop, c_drop, .Lc_drag_paths, c_drag_paths
    .quad .Lc_clip_request, c_clip_request
    .quad .Lc_print_drop, c_print_drop, .Lc_print_agent_pastes, c_print_agent_pastes
    .quad .Lc_print_agent_veil, c_print_agent_veil
    .quad 0, 0
