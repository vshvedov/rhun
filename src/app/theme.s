# themes: parse "key = #rrggbb" files, derive missing colors, registry of built-in + user themes
.include "rhun.inc"


.bss
.p2align 3
.globl g_theme, g_theme_dark, g_themes, g_theme_cur
g_theme: .zero 4 * T_COUNT
g_theme_dark: .long 0
.p2align 3
defined: .zero 16                # bit per slot given by the theme
g_themes: .zero VEC_SIZE
g_theme_cur: .quad 0            # index into g_themes
it: .zero INI_SIZE

.text

# theme_load(text, len)
FN theme_load
    PROLOGUE 16
    mov qword ptr [rip + defined], 0
    mov qword ptr [rip + defined + 8], 0
    mov dword ptr [rip + g_theme_dark], 1
    mov rdx, rsi
    mov rsi, rdi
    lea rdi, [rip + it]
    call ini_init
.Ltl_next:
    lea rdi, [rip + it]
    call ini_next
    test eax, eax
    jz .Ltl_derive
    lea rdi, [rip + it]
    lea rsi, [rip + .Lkind]
    call ini_key_is
    test eax, eax
    jz 1f
    mov rdi, [rip + it + INI_val]
    mov rsi, [rip + it + INI_vallen]
    lea rdx, [rip + .Llight]
    call str_eq_cstr
    xor eax, 1
    mov [rip + g_theme_dark], eax
    jmp .Ltl_next
1:  # slot name lookup
    lea rbx, [rip + slot_names]
    xor r12d, r12d
2:  cmp r12d, T_COUNT
    jae .Ltl_next
    mov rdi, [rip + it + INI_key]
    mov rsi, [rip + it + INI_keylen]
    mov rdx, [rbx + r12*8]
    call str_eq_cstr
    test eax, eax
    jnz 3f
    inc r12d
    jmp 2b
3:  mov rdi, [rip + it + INI_val]
    mov rsi, [rip + it + INI_vallen]
    call parse_color
    test edx, edx
    jz .Ltl_next
    lea rcx, [rip + g_theme]
    mov [rcx + r12*4], eax
    bts qword ptr [rip + defined], r12
    jmp .Ltl_next
.Ltl_derive:
    call theme_derive
    EPILOGUE

# ISDEF slot: carry set when the theme gave the slot
.macro ISDEF slot
    bt qword ptr [rip + defined + 8 * ((\slot) / 64)], (\slot) % 64
.endm

# DERIVE slot, a, b, t  : if slot undefined, slot = mix(color a, color b, t)
.macro DERIVE slot, a, b, t
    ISDEF \slot
    jc 88f
    mov edi, [rip + g_theme + 4*(\a)]
    mov esi, [rip + g_theme + 4*(\b)]
    mov edx, \t
    call color_mix
    mov [rip + g_theme + 4*(\slot)], eax
88:
.endm
.macro DERIVE_C slot, a, c, t
    ISDEF \slot
    jc 88f
    mov edi, [rip + g_theme + 4*(\a)]
    mov esi, \c
    mov edx, \t
    call color_mix
    mov [rip + g_theme + 4*(\slot)], eax
88:
.endm
.macro COPY slot, src
    ISDEF \slot
    jc 88f
    mov eax, [rip + g_theme + 4*(\src)]
    mov [rip + g_theme + 4*(\slot)], eax
88:
.endm
.macro CONST slot, c
    ISDEF \slot
    jc 88f
    mov dword ptr [rip + g_theme + 4*(\slot)], \c
88:
.endm

theme_derive:
    push rbx
    CONST T_BG, 0xff1e1f24
    CONST T_FG, 0xffd4d6dc
    CONST T_ACCENT, 0xff7aa2f7
    COPY T_UI_FG, T_FG
    cmp dword ptr [rip + g_theme_dark], 0
    je .Ltd_light
    DERIVE_C T_PANEL, T_BG, 0xff000000, 40
    DERIVE_C T_BORDER, T_PANEL, 0xff000000, 70
    DERIVE T_LINE_HL, T_BG, T_FG, 10
    DERIVE T_SELECTION, T_BG, T_ACCENT, 72
    DERIVE T_HOVER, T_PANEL, T_UI_FG, 18
    DERIVE T_ACTIVE, T_PANEL, T_ACCENT, 56
    DERIVE T_POPUP, T_BG, T_FG, 12
    DERIVE_C T_INPUT, T_BG, 0xff000000, 30
    DERIVE T_GUIDE, T_BG, T_FG, 24
    jmp .Ltd_common
.Ltd_light:
    DERIVE_C T_PANEL, T_BG, 0xff000000, 10
    DERIVE T_BORDER, T_PANEL, T_FG, 36
    DERIVE T_LINE_HL, T_BG, T_FG, 12
    DERIVE T_SELECTION, T_BG, T_ACCENT, 56
    DERIVE T_HOVER, T_PANEL, T_UI_FG, 16
    DERIVE T_ACTIVE, T_PANEL, T_ACCENT, 44
    DERIVE_C T_POPUP, T_BG, 0xffffffff, 140
    DERIVE_C T_INPUT, T_BG, 0xffffffff, 160
    DERIVE T_GUIDE, T_BG, T_FG, 28
.Ltd_common:
    COPY T_TITLEBAR, T_PANEL
    COPY T_STATUS, T_PANEL
    COPY T_TAB, T_PANEL
    COPY T_TAB_ACTIVE, T_BG
    COPY T_TITLEBAR_UNFOCUSED, T_TITLEBAR
    COPY T_TAB_ACTIVE_UNFOCUSED, T_TAB_ACTIVE
    DERIVE T_MUTED, T_FG, T_BG, 110
    # muted interface text: from ui_fg when the theme gives it, else the editor's
    ISDEF T_UI_FG
    jc 1f
    COPY T_UI_MUTED, T_MUTED
    jmp 2f
1:  DERIVE T_UI_MUTED, T_UI_FG, T_PANEL, 110
2:  DERIVE T_PANEL_FG, T_UI_FG, T_PANEL, 30
    DERIVE T_LINENO, T_FG, T_BG, 150
    COPY T_LINENO_ACTIVE, T_FG
    COPY T_CURSOR, T_ACCENT
    DERIVE T_SCROLLBAR, T_BG, T_FG, 60
    CONST T_ERROR, 0xffe06c75
    CONST T_WARNING, 0xffe5c07b
    CONST T_SUCCESS, 0xff98c379
    DERIVE T_MATCH, T_BG, T_WARNING, 70
    # text on accent: black or white by luminance
    ISDEF T_ACCENT_FG
    jc 1f
    mov eax, [rip + g_theme + 4*T_ACCENT]
    movzx ecx, al               # b
    imul ecx, ecx, 29
    movzx edx, ah               # g
    imul edx, edx, 150
    add ecx, edx
    shr eax, 16
    movzx eax, al               # r
    imul eax, eax, 77
    add eax, ecx
    shr eax, 8
    mov ecx, 0xffffffff
    mov edx, 0xff111217
    cmp eax, 165
    cmova ecx, edx
    mov [rip + g_theme + 4*T_ACCENT_FG], ecx
1:  # syntax defaults
    COPY T_SYN + C_TEXT, T_FG
    COPY T_SYN + C_KEYWORD, T_ACCENT
    COPY T_SYN + C_TYPE, T_ACCENT
    COPY T_SYN + C_FUNCTION, T_ACCENT
    COPY T_SYN + C_STRING, T_SUCCESS
    COPY T_SYN + C_NUMBER, T_WARNING
    COPY T_SYN + C_COMMENT, T_MUTED
    COPY T_SYN + C_CONSTANT, T_SYN + C_NUMBER
    COPY T_SYN + C_OPERATOR, T_FG
    DERIVE T_SYN + C_PUNCT, T_FG, T_BG, 60
    COPY T_SYN + C_PREPROC, T_SYN + C_KEYWORD
    COPY T_SYN + C_VARIABLE, T_FG
    COPY T_SYN + C_BUILTIN, T_SYN + C_FUNCTION
    COPY T_SYN + C_ATTRIBUTE, T_SYN + C_TYPE
    COPY T_SYN + C_TAG, T_SYN + C_KEYWORD
    COPY T_SYN + C_HEADING, T_SYN + C_KEYWORD
    COPY T_SYN + C_INSERTED, T_SUCCESS
    COPY T_SYN + C_DELETED, T_ERROR
    COPY T_SYN + C_ESCAPE, T_SYN + C_CONSTANT
    COPY T_SYN + C_LINK, T_ACCENT
    # terminal: background and text shades, the others from the syntax colors
    DERIVE T_TERM + 0, T_BG, T_FG, 40
    COPY T_TERM + 1, T_ERROR
    COPY T_TERM + 2, T_SUCCESS
    COPY T_TERM + 3, T_WARNING
    COPY T_TERM + 4, T_SYN + C_FUNCTION
    COPY T_TERM + 5, T_SYN + C_KEYWORD
    COPY T_TERM + 6, T_SYN + C_BUILTIN
    DERIVE T_TERM + 7, T_FG, T_BG, 40
    COPY T_TERM + 8, T_MUTED
    DERIVE_C T_TERM + 9, T_TERM + 1, 0xffffffff, 50
    DERIVE_C T_TERM + 10, T_TERM + 2, 0xffffffff, 50
    DERIVE_C T_TERM + 11, T_TERM + 3, 0xffffffff, 50
    DERIVE_C T_TERM + 12, T_TERM + 4, 0xffffffff, 50
    DERIVE_C T_TERM + 13, T_TERM + 5, 0xffffffff, 50
    DERIVE_C T_TERM + 14, T_TERM + 6, 0xffffffff, 50
    COPY T_TERM + 15, T_FG
    COPY T_GIT_ADD, T_SUCCESS
    COPY T_GIT_MOD, T_WARNING
    COPY T_GIT_DEL, T_ERROR
    pop rbx
    ret

# theme_scan(): register "Follow Omarchy" (on Omarchy), built-in themes and ~/.config/rhun/themes/*.theme
FN theme_scan
    PROLOGUE 16
    call omarchy_register
    xor ebx, ebx
.Lts_builtin:
    cmp rbx, [rip + themes_count]
    jae .Lts_user
    imul rax, rbx, 24
    lea rcx, [rip + themes_table]
    add rcx, rax
    mov r12, [rcx]              # file name
    mov r13, [rcx + 8]          # data
    mov r14, [rcx + 16]         # end
    sub r14, r13
    lea rdi, [rip + g_themes]
    mov esi, TH_SIZE
    call vec_push
    mov r15, rax
    mov [r15 + TH_src], r13
    mov [r15 + TH_len], r14
    mov rdi, r12
    call stem_dup
    mov [r15 + TH_id], rax
    mov rdi, r15
    call theme_read_header
    inc rbx
    jmp .Lts_builtin
.Lts_user:
    lea rdi, [rip + .Lthemes_dir]
    lea rsi, [rip + .Ltheme_ext]
    lea rdx, [rip + add_user_theme]
    call config_dir_each
    EPILOGUE

# add_user_theme(path, name): callback from config_dir_each
add_user_theme:
    push rbx
    push r12
    push r13
    mov r12, rdi
    mov r13, rsi
    lea rdi, [rip + g_themes]
    mov esi, TH_SIZE
    call vec_push
    mov rbx, rax
    mov rdi, r12
    call strlen
    mov rdi, r12
    mov rsi, rax
    call mem_dup
    mov [rbx + TH_path], rax
    mov rdi, r13
    call stem_dup
    mov [rbx + TH_id], rax
    mov rdi, rbx
    call theme_read_header
    pop r13
    pop r12
    pop rbx
    ret

# stem_dup(filename cstr) -> copy without extension
stem_dup:
    push rbx
    mov rbx, rdi
    call strlen
    mov rcx, rax
1:  test rcx, rcx
    jz 2f
    cmp byte ptr [rbx + rcx - 1], '.'
    je 3f
    dec rcx
    jmp 1b
3:  dec rcx
    mov rax, rcx
2:  mov rdi, rbx
    mov rsi, rax
    call mem_dup
    pop rbx
    ret

# theme_text(entry) -> rax text, rdx len (user files are read each time)
theme_text:
    mov rax, [rdi + TH_src]
    test rax, rax
    jz 1f
    mov rdx, [rdi + TH_len]
    ret
1:  mov rdi, [rdi + TH_path]
    jmp file_read_all

# theme_read_header(entry): name + kind
theme_read_header:
    PROLOGUE INI_SIZE
    mov rbx, rdi
    mov rax, [rbx + TH_id]
    mov [rbx + TH_name], rax
    mov dword ptr [rbx + TH_dark], 1
    call theme_text
    test rax, rax
    jz .Lrh_ret
    mov r12, rax
    lea rdi, [rsp]
    mov rsi, rax
    call ini_init
.Lrh_next:
    lea rdi, [rsp]
    call ini_next
    test eax, eax
    jz .Lrh_done
    lea rdi, [rsp]
    lea rsi, [rip + .Lname]
    call ini_key_is
    test eax, eax
    jz 1f
    mov rdi, [rsp + INI_val]
    mov rsi, [rsp + INI_vallen]
    call mem_dup
    mov [rbx + TH_name], rax
    jmp .Lrh_next
1:  lea rdi, [rsp]
    lea rsi, [rip + .Lkind]
    call ini_key_is
    test eax, eax
    jz .Lrh_next
    mov rdi, [rsp + INI_val]
    mov rsi, [rsp + INI_vallen]
    lea rdx, [rip + .Llight]
    call str_eq_cstr
    xor eax, 1
    mov [rbx + TH_dark], eax
    jmp .Lrh_next
.Lrh_done:
    cmp qword ptr [rbx + TH_src], 0
    jne .Lrh_ret
    mov rdi, r12
    call mem_free
.Lrh_ret:
    EPILOGUE

# theme_find(id cstr) -> index or -1
FN theme_find
    push rbx
    push r12
    mov r12, rdi
    xor ebx, ebx
1:  cmp rbx, [rip + g_themes + VEC_len]
    jae 2f
    imul rax, rbx, TH_SIZE
    add rax, [rip + g_themes + VEC_ptr]
    mov rdi, [rax + TH_id]
    mov rsi, r12
    call strcmp_eq
    test eax, eax
    jnz 3f
    inc ebx
    jmp 1b
2:  mov rax, -1
    pop r12
    pop rbx
    ret
3:  mov rax, rbx
    pop r12
    pop rbx
    ret

# strcmp_eq(a, b) -> 1 if equal cstrs
FN strcmp_eq
1:  mov al, [rdi]
    cmp al, [rsi]
    jne 2f
    test al, al
    jz 3f
    inc rdi
    inc rsi
    jmp 1b
2:  xor eax, eax
    ret
3:  mov eax, 1
    ret

# theme_apply(index): load theme by registry index
FN theme_apply
    push rbx
    push r12
    push r13
    cmp rdi, [rip + g_themes + VEC_len]
    jb 1f
    xor edi, edi
1:  mov [rip + g_theme_cur], rdi
    cmp rdi, [rip + g_follow]
    jne 3f
    # "Follow Omarchy": colors of the theme Omarchy has set
    call omarchy_target
    mov [rip + g_follow_target], rax
    mov rdi, rax
3:  imul rbx, rdi, TH_SIZE
    add rbx, [rip + g_themes + VEC_ptr]
    mov rdi, rbx
    call theme_text
    test rax, rax
    jz 2f
    mov r12, rax
    mov rdi, rax
    mov rsi, rdx
    call theme_load
    cmp qword ptr [rbx + TH_src], 0
    jne 2f
    mov rdi, r12
    call mem_free
2:  mov dword ptr [rip + g_dirty], 1
    pop r13
    pop r12
    pop rbx
    ret

# theme_current_id() -> cstr
FN theme_current_id
    mov rax, [rip + g_theme_cur]
    imul rax, rax, TH_SIZE
    add rax, [rip + g_themes + VEC_ptr]
    mov rax, [rax + TH_id]
    ret

# theme_entry(index) -> TH*
FN theme_entry
    imul rax, rdi, TH_SIZE
    add rax, [rip + g_themes + VEC_ptr]
    ret

.section .rodata
.Lkind: .asciz "kind"
.Lname: .asciz "name"
.Llight: .asciz "light"
.Lthemes_dir: .asciz "themes"
.Ltheme_ext: .asciz ".theme"
.p2align 3
slot_names:
    .quad .Ls0, .Ls1, .Ls2, .Ls3, .Ls4, .Ls5, .Ls6, .Ls7, .Ls8, .Ls9
    .quad .Ls10, .Ls11, .Ls12, .Ls13, .Ls14, .Ls15, .Ls16, .Ls17, .Ls18, .Ls19
    .quad .Ls20, .Ls21, .Ls22, .Ls23, .Ls24, .Ls25, .Ls26
    .quad .Lc0, .Lc1, .Lc2, .Lc3, .Lc4, .Lc5, .Lc6, .Lc7, .Lc8, .Lc9
    .quad .Lc10, .Lc11, .Lc12, .Lc13, .Lc14, .Lc15, .Lc16, .Lc17, .Lc18, .Lc19
    .quad .Lt0, .Lt1, .Lt2, .Lt3, .Lt4, .Lt5, .Lt6, .Lt7, .Lt8, .Lt9
    .quad .Lt10, .Lt11, .Lt12, .Lt13, .Lt14, .Lt15, .Lg0, .Lg1, .Lg2
    .quad .Lu0, .Lu1, .Lu2, .Lu3
.Ls0: .asciz "bg"
.Ls1: .asciz "fg"
.Ls2: .asciz "accent"
.Ls3: .asciz "panel"
.Ls4: .asciz "titlebar"
.Ls5: .asciz "border"
.Ls6: .asciz "muted"
.Ls7: .asciz "line_number"
.Ls8: .asciz "line_number_active"
.Ls9: .asciz "line_highlight"
.Ls10: .asciz "selection"
.Ls11: .asciz "cursor"
.Ls12: .asciz "hover"
.Ls13: .asciz "active"
.Ls14: .asciz "popup"
.Ls15: .asciz "input"
.Ls16: .asciz "scrollbar"
.Ls17: .asciz "status"
.Ls18: .asciz "tab"
.Ls19: .asciz "tab_active"
.Ls20: .asciz "error"
.Ls21: .asciz "warning"
.Ls22: .asciz "success"
.Ls23: .asciz "match"
.Ls24: .asciz "guide"
.Ls25: .asciz "accent_fg"
.Ls26: .asciz "panel_fg"
.Lc0: .asciz "text"
.Lc1: .asciz "keyword"
.Lc2: .asciz "type"
.Lc3: .asciz "function"
.Lc4: .asciz "string"
.Lc5: .asciz "number"
.Lc6: .asciz "comment"
.Lc7: .asciz "constant"
.Lc8: .asciz "operator"
.Lc9: .asciz "punctuation"
.Lc10: .asciz "preproc"
.Lc11: .asciz "variable"
.Lc12: .asciz "builtin"
.Lc13: .asciz "attribute"
.Lc14: .asciz "tag"
.Lc15: .asciz "heading"
.Lc16: .asciz "inserted"
.Lc17: .asciz "deleted"
.Lc18: .asciz "escape"
.Lc19: .asciz "link"
.Lt0: .asciz "black"
.Lt1: .asciz "red"
.Lt2: .asciz "green"
.Lt3: .asciz "yellow"
.Lt4: .asciz "blue"
.Lt5: .asciz "magenta"
.Lt6: .asciz "cyan"
.Lt7: .asciz "white"
.Lt8: .asciz "bright_black"
.Lt9: .asciz "bright_red"
.Lt10: .asciz "bright_green"
.Lt11: .asciz "bright_yellow"
.Lt12: .asciz "bright_blue"
.Lt13: .asciz "bright_magenta"
.Lt14: .asciz "bright_cyan"
.Lt15: .asciz "bright_white"
.Lg0: .asciz "git_added"
.Lg1: .asciz "git_modified"
.Lg2: .asciz "git_deleted"
.Lu0: .asciz "ui_fg"
.Lu1: .asciz "ui_muted"
.Lu2: .asciz "titlebar_unfocused"
.Lu3: .asciz "tab_active_unfocused"
