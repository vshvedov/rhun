# rhun: shared macros and constants
.intel_syntax noprefix

# ---- linux x86-64 syscalls ----
.equ SYS_read, 0
.equ SYS_write, 1
.equ SYS_open, 2
.equ SYS_close, 3
.equ SYS_fstat, 5
.equ SYS_lstat, 6
.equ SYS_poll, 7
.equ SYS_lseek, 8
.equ SYS_mmap, 9
.equ SYS_munmap, 11
.equ SYS_rt_sigaction, 13
.equ SYS_ioctl, 16
.equ SYS_access, 21
.equ SYS_mremap, 25
.equ SYS_shmget, 29
.equ SYS_shmat, 30
.equ SYS_shmctl, 31
.equ SYS_dup2, 33
.equ SYS_getpid, 39
.equ SYS_socket, 41
.equ SYS_connect, 42
.equ SYS_accept, 43
.equ SYS_sendmsg, 46
.equ SYS_recvmsg, 47
.equ SYS_bind, 49
.equ SYS_listen, 50
.equ SYS_vfork, 58
.equ SYS_execve, 59
.equ SYS_exit, 60
.equ SYS_wait4, 61
.equ SYS_kill, 62
.equ SYS_fcntl, 72
.equ SYS_fsync, 74
.equ SYS_ftruncate, 77
.equ SYS_getcwd, 79
.equ SYS_chdir, 80
.equ SYS_rename, 82
.equ SYS_mkdir, 83
.equ SYS_unlink, 87
.equ SYS_readlink, 89
.equ SYS_fchmod, 91
.equ SYS_setsid, 112
.equ SYS_shmdt, 67
.equ SYS_getdents64, 217
.equ SYS_clock_gettime, 228
.equ SYS_exit_group, 231
.equ SYS_inotify_add_watch, 254
.equ SYS_inotify_rm_watch, 255
.equ SYS_openat, 257
.equ SYS_timerfd_create, 283
.equ SYS_timerfd_settime, 286
.equ SYS_accept4, 288
.equ SYS_pipe2, 293
.equ SYS_inotify_init1, 294
.equ SYS_memfd_create, 319
.equ SYS_close_range, 436

.equ O_RDONLY, 0
.equ O_WRONLY, 1
.equ O_RDWR, 2
.equ O_CREAT, 0x40
.equ O_EXCL, 0x80
.equ O_NOCTTY, 0x100
.equ O_TRUNC, 0x200
.equ O_APPEND, 0x400
.equ O_NONBLOCK, 0x800
.equ O_DIRECTORY, 0x10000
.equ O_CLOEXEC, 0x80000

.equ PROT_READ, 1
.equ PROT_WRITE, 2
.equ MAP_SHARED, 1
.equ MAP_PRIVATE, 2
.equ MAP_ANONYMOUS, 0x20
.equ MREMAP_MAYMOVE, 1

.equ AF_UNIX, 1
.equ SOCK_STREAM, 1
.equ SOCK_NONBLOCK, 0x800
.equ SOCK_CLOEXEC, 0x80000
.equ SOL_SOCKET, 1
.equ SCM_RIGHTS, 1
.equ MSG_DONTWAIT, 0x40
.equ MSG_NOSIGNAL, 0x4000

.equ POLLIN, 1
.equ POLLOUT, 4
.equ POLLERR, 8
.equ POLLHUP, 16

.equ CLOCK_REALTIME, 0
.equ CLOCK_MONOTONIC, 1

.equ IN_MODIFY, 0x2
.equ IN_CLOSE_WRITE, 0x8
.equ IN_MOVED_FROM, 0x40
.equ IN_MOVED_TO, 0x80
.equ IN_CREATE, 0x100
.equ IN_DELETE, 0x200
.equ IN_ONLYDIR, 0x1000000
.equ IN_NONBLOCK, 0x800
.equ IN_CLOEXEC, 0x80000

.equ EAGAIN, 11
.equ EIO, 5
.equ WNOHANG, 1
.equ SIGHUP, 1
.equ SIGKILL, 9
.equ EINTR, 4

# ---- function helpers ----
.macro FN name
    .text
    .globl \name
    .ifndef WINDOWS
    .type \name, @function
    .endif
    .p2align 4
\name:
.endm

# Saves rbp, rbx, r12-r15 and reserves `frame` bytes (multiple of 16) at [rsp].
.macro PROLOGUE frame=0
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8 + \frame
.ifdef WINDOWS
    # Shared leaf callers need not align the internal stack. Win32 calls always must.
    and rsp, -16
.endif
.endm

.macro EPILOGUE
    lea rsp, [rbp - 40]
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret
.endm

.macro SYS num
    mov eax, \num
    XSYS
.endm

.macro XSYS
    .ifdef WINDOWS
    call win_syscall
    .else
    syscall
    .endif
.endm

# ---- struct layout ----
.macro STRUCT
    .set __so, 0
.endm
.macro F name, size
    .equ \name, __so
    .set __so, __so + \size
.endm
.macro ENDSTRUCT name
    .equ \name, __so
.endm

# zero-terminated string in .rodata, label = name
.macro CSTR name, text
    .section .rodata
\name: .asciz "\text"
    .text
.endm

# ---- shared structs ----

# growable byte buffer
STRUCT
F SB_ptr, 8
F SB_len, 8
F SB_cap, 8
ENDSTRUCT SB_SIZE

# generic growable array of fixed-size items
STRUCT
F VEC_ptr, 8
F VEC_len, 8
F VEC_cap, 8
ENDSTRUCT VEC_SIZE

# rectangle (i32)
STRUCT
F R_x, 4
F R_y, 4
F R_w, 4
F R_h, 4
ENDSTRUCT RECT_SIZE

# ---- key symbols (X11 keysym values; printable keys use unicode) ----
.equ KEY_BACKSPACE, 0xff08
.equ KEY_TAB, 0xff09
.equ KEY_RETURN, 0xff0d
.equ KEY_ESCAPE, 0xff1b
.equ KEY_HOME, 0xff50
.equ KEY_LEFT, 0xff51
.equ KEY_UP, 0xff52
.equ KEY_RIGHT, 0xff53
.equ KEY_DOWN, 0xff54
.equ KEY_PAGEUP, 0xff55
.equ KEY_PAGEDOWN, 0xff56
.equ KEY_END, 0xff57
.equ KEY_INSERT, 0xff63
.equ KEY_KP_ENTER, 0xff8d
.equ KEY_F1, 0xffbe
.equ KEY_SHIFT_L, 0xffe1
.equ KEY_SUPER_R, 0xffec
.equ KEY_ISO_LEFT_TAB, 0xfe20
.equ KEY_DELETE, 0xffff

.equ MOD_SHIFT, 1
.equ MOD_CTRL, 4
.equ MOD_ALT, 8
.equ MOD_SUPER, 64

# mouse buttons
.equ BTN_LEFT, 1
.equ BTN_MIDDLE, 2
.equ BTN_RIGHT, 3

# cursor shapes
.equ CUR_DEFAULT, 0
.equ CUR_TEXT, 1
.equ CUR_POINTER, 2
.equ CUR_EW, 3
.equ CUR_NS, 4
.equ CUR_NWSE, 5
.equ CUR_NESW, 6

# cursor image (xcursor_load / xcursor_builtin)
STRUCT
F XC_file, 8            # mem_free when done
F XC_pixels, 8          # premultiplied ARGB, w * h
F XC_w, 4
F XC_h, 4
F XC_xhot, 4
F XC_yhot, 4
ENDSTRUCT XC_SIZE

# ---- big-endian loads (font tables) ----
.macro LDBE16 r32, r16, mem
    movzx \r32, word ptr \mem
    rol \r16, 8
.endm
.macro LDBE16S r32, r16, mem
    movzx \r32, word ptr \mem
    rol \r16, 8
    movsx \r32, \r16
.endm
.macro LDBE32 r32, mem
    mov \r32, dword ptr \mem
    bswap \r32
.endm

# ---- graphics ----
STRUCT
F CV_pixels, 8
F CV_w, 4
F CV_h, 4
F CV_stride, 4          # in pixels
F CV_cx0, 4             # clip rect [x0,x1) x [y0,y1)
F CV_cy0, 4
F CV_cx1, 4
F CV_cy1, 4
F CV_pad, 4
ENDSTRUCT CV_SIZE

# cached glyph bitmap
STRUCT
F GL_key, 4             # codepoint + 1
F GL_w, 2
F GL_h, 2
F GL_left, 2            # x offset from pen
F GL_top, 2             # rows above baseline
F GL_adv, 4             # advance, 26.6 fixed
F GL_bits, 8            # w*h alpha bytes
ENDSTRUCT GL_SIZE

# parsed TrueType font
STRUCT
F FONT_data, 8
F FONT_glyf, 8
F FONT_loca, 8
F FONT_hmtx, 8
F FONT_cmap, 8          # selected subtable
F FONT_cmapfmt, 4
F FONT_upem, 4
F FONT_localong, 4
F FONT_nglyphs, 4
F FONT_nhmetrics, 4
F FONT_ascent, 4
F FONT_descent, 4
F FONT_linegap, 4
F FONT_xheight, 4
F FONT_capheight, 4
ENDSTRUCT FONT_SIZE

# font at a pixel size
STRUCT
F FACE_font, 8
F FACE_scale, 4         # float px per unit
F FACE_px, 4            # size in px
F FACE_ascent, 4
F FACE_descent, 4
F FACE_lineh, 4
F FACE_cellw, 4         # advance of '0', px (rounded)
F FACE_tab, 8           # hash table of GL*
F FACE_tabcap, 4
F FACE_tabn, 4
F FACE_ascii, 1024  # fast path GL* for cp < 128
F FACE_embolden, 4
F FACE_pad2, 4
ENDSTRUCT FACE_SIZE

# ---- event loop fd watchers ----
STRUCT
F PW_fd, 4
F PW_events, 4
F PW_handler, 8         # handler(fd, revents, ctx)
F PW_ctx, 8
ENDSTRUCT PW_SIZE
.equ MAX_WATCH, 96

# ---- platform vtable (wayland / x11 / headless) ----
STRUCT
F P_flush, 8            # ()
F P_timeout, 8          # () -> ms or -1
F P_tick, 8             # ()
F P_draw, 8             # () renders if possible
F P_cursor, 8           # (shape)
F P_clip_set, 8         # (ptr, len)
F P_clip_get, 8         # () -> async app_on_paste
F P_move, 8             # ()
F P_resize, 8           # (edges)
F P_minimize, 8         # ()
F P_maximize, 8         # () toggle
F P_title, 8            # (cstr)
F P_menu, 8             # (x, y)
ENDSTRUCT PLAT_SIZE

.equ EDGE_TOP, 1
.equ EDGE_BOTTOM, 2
.equ EDGE_LEFT, 4
.equ EDGE_RIGHT, 8

.macro PCALL fn
    call [rip + g_plat + \fn]
.endm

# ---- key = value file iterator ----
STRUCT
F INI_p, 8
F INI_end, 8
F INI_sec, 8
F INI_seclen, 8
F INI_key, 8
F INI_keylen, 8
F INI_val, 8
F INI_vallen, 8
ENDSTRUCT INI_SIZE

# ---- theme color slots ----
.equ T_BG, 0
.equ T_FG, 1
.equ T_ACCENT, 2
.equ T_PANEL, 3
.equ T_TITLEBAR, 4
.equ T_BORDER, 5
.equ T_MUTED, 6
.equ T_LINENO, 7
.equ T_LINENO_ACTIVE, 8
.equ T_LINE_HL, 9
.equ T_SELECTION, 10
.equ T_CURSOR, 11
.equ T_HOVER, 12
.equ T_ACTIVE, 13
.equ T_POPUP, 14
.equ T_INPUT, 15
.equ T_SCROLLBAR, 16
.equ T_STATUS, 17
.equ T_TAB, 18
.equ T_TAB_ACTIVE, 19
.equ T_ERROR, 20
.equ T_WARNING, 21
.equ T_SUCCESS, 22
.equ T_MATCH, 23
.equ T_GUIDE, 24
.equ T_ACCENT_FG, 25
.equ T_PANEL_FG, 26
.equ T_SYN, 27              # + syntax class
# syntax classes
.equ C_TEXT, 0
.equ C_KEYWORD, 1
.equ C_TYPE, 2
.equ C_FUNCTION, 3
.equ C_STRING, 4
.equ C_NUMBER, 5
.equ C_COMMENT, 6
.equ C_CONSTANT, 7
.equ C_OPERATOR, 8
.equ C_PUNCT, 9
.equ C_PREPROC, 10
.equ C_VARIABLE, 11
.equ C_BUILTIN, 12
.equ C_ATTRIBUTE, 13
.equ C_TAG, 14
.equ C_HEADING, 15
.equ C_INSERTED, 16
.equ C_DELETED, 17
.equ C_ESCAPE, 18
.equ C_LINK, 19
.equ C_COUNT, 20
.equ T_TERM, T_SYN + C_COUNT    # 16 terminal colors
.equ T_GIT_ADD, T_TERM + 16
.equ T_GIT_MOD, T_TERM + 17
.equ T_GIT_DEL, T_TERM + 18
.equ T_UI_FG, T_TERM + 19       # text on the interface: bars, tabs, panels, menus, fields
.equ T_UI_MUTED, T_TERM + 20
.equ T_TITLEBAR_UNFOCUSED, T_TERM + 21
.equ T_TAB_ACTIVE_UNFOCUSED, T_TERM + 22
.equ T_COUNT, T_TERM + 23

.macro COLOR reg, slot
    mov \reg, [rip + g_theme + 4*(\slot)]
.endm

# ---- settings schema ----
.equ ST_BOOL, 0
.equ ST_INT, 1
.equ ST_STR, 2
.equ ST_THEME, 3
.equ ST_CHOICE, 4              # index into SET_opts: pairs of cstr (config value, label), "" ends
.equ ST_ACTION, 5              # a button: SET_ptr is the function it calls, SET_desc a buffer that
                               # changes; not in the config file
STRUCT
F SET_sec, 8
F SET_key, 8
F SET_ptr, 8
F SET_label, 8
F SET_desc, 8
F SET_type, 4
F SET_min, 4
F SET_max, 4
F SET_step, 4
F SET_decimal, 4
F SET_pad, 4
F SET_opts, 8
ENDSTRUCT SET_SIZE

# ---- updates (g_update_state) ----
.equ UP_IDLE, 0
.equ UP_AVAILABLE, 1            # a newer release to install
.equ UP_INSTALLING, 2
.equ UP_READY, 3                # installed; a restart runs it

# ---- document ----
STRUCT
F DOC_buf, 8
F DOC_cap, 8
F DOC_gs, 8             # gap start
F DOC_ge, 8             # gap end
F DOC_lines, 8          # u64 line start offsets
F DOC_nlines, 8
F DOC_lcap, 8
F DOC_states, 8         # u32 syntax state at line start
F DOC_svalid, 8         # states valid for lines < svalid
F DOC_path, 8           # absolute path or 0
F DOC_name, 8           # display name
F DOC_lang, 8           # grammar or 0
F DOC_undo, VEC_SIZE
F DOC_redo, VEC_SIZE
F DOC_cur, 8
F DOC_anchor, 8
F DOC_prefx, 8          # preferred column for vertical motion, -1 = none
F DOC_scrolly, 8        # 1/256 lines
F DOC_scrollx, 8        # pixels
F DOC_wtop, 8           # wrapped view: line that DOC_woff belongs to
F DOC_woff, 8           # wrapped view: 1/256 rows into that line (used while scrolly is on DOC_wtop)
F DOC_group, 8
F DOC_lastedit, 8
F DOC_lastkind, 8
F DOC_savepoint, 8
F DOC_crlf, 4
F DOC_flags, 4
F DOC_mtime, 8
F DOC_version, 8
F DOC_sold, 8           # syntax states were valid below this line before the last edits
F DOC_ehi, 8            # highest line touched by edits since then
F DOC_ghash, 8          # git: hashes of its lines
F DOC_gnl, 8            # git: their count
F DOC_gmarks, 8         # git: GM_* per line
F DOC_gmcap, 8
F DOC_gver, 8           # git: DOC_version the marks were made for
F DOC_gstate, 4         # GS_*
F DOC_gseq, 4           # git: request number; answers to older requests are dropped
F DOC_diff, 8           # diff view: DV* with the kind and numbers of each line
F DOC_lhash, 8          # hash of each line (for git marks), 0 = not known yet
F DOC_img, 8            # image view of a TAB_IMAGE document, or 0
ENDSTRUCT DOC_SIZE

# DOC_flags
.equ DF_GROUP, 1
.equ DF_READONLY, 2              # diff views
.equ DF_EOL, 4                   # the text ended in a newline when read or saved: vim has no line after it

# return 0 at once when the document is read-only: g_doc, or the one in reg
.macro READONLY_RET reg=0
.ifc \reg,0
    push rax
    mov rax, [rip + g_doc]
    test rax, rax
    jz .Lro\@
    test dword ptr [rax + DOC_flags], DF_READONLY
    pop rax
    jz .Lro2\@
    xor eax, eax
    ret
.Lro\@:
    pop rax
.Lro2\@:
.else
    test dword ptr [\reg + DOC_flags], DF_READONLY
    jz .Lro\@
    xor eax, eax
    ret
.Lro\@:
.endif
.endm

# diff view: DOC_diff
STRUCT
F DV_lines, 8           # DL per line
F DV_n, 8
F DV_name, 8            # tab title
F DV_rev, 8             # commit, or 0 for the work tree
F DV_path, 8            # path in the work tree
F DV_maxno, 4           # largest line number
F DV_pad, 4
ENDSTRUCT DV_SIZE
STRUCT
F DL_kind, 4            # DK_*
F DL_old, 4             # line number before, 0 none
F DL_new, 4             # line number after, 0 none
ENDSTRUCT DL_SIZE
.equ DK_CTX, 0
.equ DK_ADD, 1
.equ DK_DEL, 2
.equ DK_HUNK, 3
.equ DK_INFO, 4

# a changed file in the history view
STRUCT
F GF_path, 8
F GF_code, 4
F GF_add, 4             # lines added, -1 binary, -2 unknown
F GF_del, 4
F GF_group, 4           # work tree: GG_*
ENDSTRUCT GF_SIZE
# groups of the work tree's changes, in the order they are shown
.equ GG_MERGE, 1                # conflicts
.equ GG_STAGED, 2
.equ GG_CHANGES, 3              # not staged, untracked

# what HEAD is (g_git_head)
.equ HD_BRANCH, 0
.equ HD_DETACHED, 1
.equ HD_UNBORN, 2               # a branch without commits yet

# git state of a document
.equ GS_NONE, 0
.equ GS_ASKED, 1
.equ GS_BASE, 2
.equ GS_NOBASE, 3
# gutter marks per line
.equ GM_ADD, 1
.equ GM_MOD, 2
.equ GM_DELUP, 4                # lines deleted above
.equ GM_DELDOWN, 8              # lines deleted below the last line

STRUCT
F UR_kind, 8            # 1 insert, 2 delete
F UR_pos, 8
F UR_len, 8
F UR_text, 8
F UR_group, 8
F UR_cur, 8
F UR_anchor, 8
ENDSTRUCT UR_SIZE

.equ EK_OTHER, 0
.equ EK_TYPE, 1
.equ EK_BACK, 2
.equ EK_DEL, 3

# ---- ui metrics (scaled logical sizes) ----
.equ MI_1, 0
.equ MI_2, 1
.equ MI_3, 2
.equ MI_4, 3
.equ MI_6, 4
.equ MI_8, 5
.equ MI_10, 6
.equ MI_12, 7
.equ MI_14, 8
.equ MI_16, 9
.equ MI_20, 10
.equ MI_24, 11
.equ MI_28, 12
.equ MI_32, 13
.equ MI_40, 14
.equ MI_48, 15
.equ MI_TITLE, 16
.equ MI_TAB, 17
.equ MI_STATUS, 18
.equ MI_ROW, 19
.equ MI_ICON, 20
.equ MI_RADIUS, 21
.equ MI_64, 22
.equ MI_5, 23
.equ MI_COUNT, 24
.macro M reg, idx
    mov \reg, [rip + g_mt + 4*(\idx)]
.endm

# ui_btn result bits
.equ UB_HOVER, 1
.equ UB_PRESS, 2
.equ UB_CLICK, 4
.equ UB_HELD, 8
.equ UB_RPRESS, 16
.equ UB_DOUBLE, 32

# single-line text field (a text area has lines)
STRUCT
F TF_sb, SB_SIZE
F TF_cur, 8
F TF_anchor, 8
F TF_scroll, 4
F TF_id, 4
F TF_top, 4             # text area: the first line shown
F TF_pad, 4
ENDSTRUCT TF_SIZE

# icons
.equ IC_CHEV_R, 0
.equ IC_CHEV_D, 1
.equ IC_FOLDER, 2
.equ IC_FILE, 3
.equ IC_CLOSE, 4
.equ IC_SIDEBAR, 5
.equ IC_PANEL_R, 6
.equ IC_SLIDERS, 7
.equ IC_SEARCH, 8
.equ IC_SPARK, 9
.equ IC_MIN, 10
.equ IC_MAX, 11
.equ IC_RESTORE, 12
.equ IC_WCLOSE, 13
.equ IC_DOT, 14
.equ IC_PLUS, 15
.equ IC_CHECK, 16
.equ IC_TERMINAL, 17
.equ IC_BACK, 18
.equ IC_USER, 19
.equ IC_ARROW_DN, 20
.equ IC_REFRESH, 21
.equ IC_CHEV_UP, 22
.equ IC_CHEV_DN2, 23
.equ IC_CASE, 24
.equ IC_WORD, 25
.equ IC_RUNE, 26                # the app mark (Raido)
.equ IC_BRANCH, 27
.equ IC_ARROW_UP, 28
.equ IC_MINUS, 29
.equ IC_DISCARD, 30
.equ IC_COUNT, 31

# ---- images ----
.equ IMF_PNG, 1
.equ IMF_JPEG, 2
.equ IMF_GIF, 3
.equ IMF_BMP, 4
.equ IMF_ICO, 5
.equ IMF_QOI, 6
.equ IMF_PNM, 7
.equ IMF_TGA, 8
.equ IMG_MAXDIM, 32768
.equ IMG_MAXPX, 1 << 26

# decoded image
STRUCT
F IMG_px, 8             # premultiplied ARGB, w * h (mem_alloc_try)
F IMG_w, 4
F IMG_h, 4
F IMG_fmt, 4            # IMF_*
F IMG_opaque, 4         # 1 when every pixel is opaque
ENDSTRUCT IMG_SIZE

# ---- app ----
.equ TAB_DOC, 1
.equ TAB_SETTINGS, 2
.equ TAB_IMAGE, 3               # TAB_doc is a DOC without text; DOC_img holds the view
.equ TAB_GIT, 4
STRUCT
F TAB_kind, 8
F TAB_doc, 8
ENDSTRUCT TAB_SIZE

.equ FOCUS_EDITOR, 0
.equ FOCUS_PALETTE, 1
.equ FOCUS_FIND, 2
.equ FOCUS_EXPLORER, 3
.equ FOCUS_SETTINGS, 4
.equ FOCUS_DIALOG, 5
.equ FOCUS_AGENTS, 6
.equ FOCUS_PROMPT, 7
.equ FOCUS_TERMINAL, 8
.equ FOCUS_SCM, 9               # the commit message

# grammar (syntax definition)
STRUCT
F GR_name, 8
F GR_files, 8           # space separated patterns
F GR_first, 8           # first-line prefixes (shebang)
F GR_regions, VEC_SIZE  # REG items
F GR_lines, VEC_SIZE    # LR items: line prefix -> class
F GR_words, 8           # hash table of WORD
F GR_wcap, 8
F GR_wn, 8
F GR_comment, 8         # line comment token (for toggle comment)
F GR_commentlen, 8
F GR_flags, 8           # GF_*
F GR_identx, 32         # extra identifier chars
F GR_prefixes, 32       # chars that start variables ($) / attributes (@)
F GR_rstart, 256        # 1 for bytes that can start a region
F GR_wchar, 256         # 1 for identifier bytes
F GR_src, 8             # built-in text not parsed yet (syntax_ready parses it), or 0
F GR_srclen, 8
ENDSTRUCT GR_SIZE
.equ GF_NOCASE, 1
.equ GF_FUNCS, 2
.equ GF_CAPTYPES, 4
.equ GF_MARKUP, 8
.equ GF_LABELS, 16
.equ GF_NUMBERS, 32
.equ GF_OPS, 64
.equ GF_COLON, 128          # indent after a line ending with ":"

STRUCT
F REG_start, 16
F REG_end, 16           # empty = end of line
F REG_slen, 1
F REG_elen, 1
F REG_class, 1
F REG_esc, 1
F REG_multi, 1
F REG_bol, 1            # only at line start (after blanks)
F REG_pad, 2
ENDSTRUCT REG_SIZE

# prompt kinds (palette used as a one-line input)
.equ PROMPT_SAVE_AS, 1
.equ PROMPT_NEW_FILE, 2
.equ PROMPT_NEW_FOLDER, 3
.equ PROMPT_RENAME, 4
.equ PROMPT_DELETE, 6

# vim modes (g_vim_mode)
.equ VM_NORMAL, 0
.equ VM_INSERT, 1
.equ VM_VISUAL, 2
.equ VM_VLINE, 3

# command table entry
STRUCT
F CMD_name, 8
F CMD_title, 8
F CMD_fn, 8
F CMD_keys, 8           # default bindings, space separated
ENDSTRUCT CMD_SIZE

# json
.equ JT_NULL, 0
.equ JT_FALSE, 1
.equ JT_TRUE, 2
.equ JT_NUM, 3
.equ JT_STR, 4
.equ JT_ARR, 5
.equ JT_OBJ, 6

# theme registry entry
STRUCT
F TH_id, 8              # file stem (cstr)
F TH_name, 8            # display name (cstr)
F TH_dark, 4
F TH_pad, 4
F TH_src, 8             # embedded text or 0
F TH_len, 8
F TH_path, 8            # user file path or 0
ENDSTRUCT TH_SIZE

# ---- terminal ----
# cell: codepoint | A_* attributes, fg, bg; colors are 0 (default), TC_IDX | index or TC_RGB | rrggbb
.equ CELL_SIZE, 12
.equ CP_MASK, 0x1fffff
.equ A_BOLD, 1 << 21
.equ A_DIM, 1 << 22
.equ A_ITALIC, 1 << 23
.equ A_UNDER, 1 << 24
.equ A_INVERSE, 1 << 25
.equ A_HIDDEN, 1 << 26
.equ A_STRIKE, 1 << 27
.equ A_WIDE, 1 << 28            # left half of a double-width character
.equ A_WIDE2, 1 << 29           # its right half
.equ A_BLINK, 1 << 30
.equ TC_IDX, 0x01000000
.equ TC_RGB, 0x02000000
# line: u32 cells allocated, u32 flags, then the cells
.equ LN_cap, 0
.equ LN_flags, 4
.equ LN_HDR, 8
.equ LF_WRAPPED, 1              # continues on the next line

# modes
.equ TMM_WRAP, 1
.equ TMM_APPCUR, 2
.equ TMM_ORIGIN, 4
.equ TMM_HIDE, 8
.equ TMM_ALT, 16
.equ TMM_INSERT, 32
.equ TMM_PASTE, 64
.equ TMM_SGRMOUSE, 128
.equ TMM_FOCUS, 256
.equ TMM_LNM, 512
.equ TMM_SYNC, 1024

STRUCT
F TM_cols, 4
F TM_rows, 4
F TM_cx, 4
F TM_cy, 4
F TM_attr, 4            # attributes for new characters
F TM_fg, 4
F TM_bg, 4
F TM_top, 4             # scroll region, inclusive rows
F TM_bot, 4
F TM_modes, 4
F TM_wrapnext, 4        # the next character goes to a new line
F TM_state, 4           # parser
F TM_np, 4
F TM_params, 64
F TM_colon, 4           # bit i: parameter i followed a ':'
F TM_priv, 4            # '?' '>' '<' '=' or 0
F TM_inter, 4           # intermediate byte or 0
F TM_utf, 4
F TM_utfn, 4            # continuation bytes still expected
F TM_g0, 4              # 1: DEC line drawing
F TM_g1, 4
F TM_gl, 4              # 0 G0, 1 G1
F TM_scx, 4             # saved cursor
F TM_scy, 4
F TM_sattr, 4
F TM_sfg, 4
F TM_sbg, 4
F TM_sg0, 4
F TM_cursor, 4          # DECSCUSR style
F TM_mouse, 4           # 0, 1000, 1002 or 1003
F TM_lastcp, 4
F TM_sbcap, 4
F TM_sbhead, 4          # oldest line in the ring
F TM_sblen, 4
F TM_view, 4            # lines scrolled back
F TM_tabcap, 4
F TM_lines, 8           # line pointers of the active screen
F TM_other, 8           # the inactive screen
F TM_sb, 8              # scrollback ring
F TM_total, 8           # lines ever moved into scrollback
F TM_tabs, 8            # byte per column, 1 = tab stop
F TM_out, SB_SIZE       # replies for the program
F TM_str, SB_SIZE       # OSC string
F TM_title, SB_SIZE
ENDSTRUCT TM_SIZE

# Branch on rooted paths without clobbering registers.
.macro PATH_ABSOLUTE reg, target
    cmp byte ptr [\reg], '/'
    je \target
.ifdef WINDOWS
    cmp byte ptr [\reg], 92
    je \target
    cmp byte ptr [\reg], 0
    je .Lpath_relative\@
    cmp byte ptr [\reg + 1], ':'
    jne .Lpath_relative\@
    cmp byte ptr [\reg + 2], '/'
    je \target
    cmp byte ptr [\reg + 2], 92
    je \target
.Lpath_relative\@:
.endif
.endm
