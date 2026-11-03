# rhun: shared macros and constants
.intel_syntax noprefix

# Managed save flags and completion results. Pending callbacks receive stable document IDs.
.equ SAVE_READONLY, 1
.equ SAVE_BYPASS, 2
.equ SAVE_INTENT, 4
.equ SAVE_CANCELLED, -2
.equ SAVE_SUPERSEDED, -3

# ---- linux x86-64 syscalls ----
.equ SYS_read, 0
.equ SYS_write, 1
.equ SYS_open, 2
.equ SYS_close, 3
.equ SYS_fstat, 5
.equ SYS_lstat, 6
.equ SYS_poll, 7
.equ SYS_lseek, 8
.equ SYS_pread, 17
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
.equ SYS_fork, 57
.equ SYS_vfork, 58
.equ SYS_execve, 59
.equ SYS_exit, 60
.equ SYS_wait4, 61
.equ SYS_kill, 62
.equ SYS_uname, 63
.equ SYS_fcntl, 72
.equ SYS_fsync, 74
.equ SYS_ftruncate, 77
.equ SYS_getcwd, 79
.equ SYS_chdir, 80
.equ SYS_rename, 82
.equ SYS_mkdir, 83
.equ SYS_unlink, 87
.equ SYS_readlink, 89
.equ SYS_chmod, 90
.equ SYS_fchmod, 91
.equ SYS_getrlimit, 97
.equ SYS_setrlimit, 160
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
# remote hosts (src/app/remote.s): channels are socketpairs; remote pids carry REMOTE_PID_TAG
.equ SYS_shutdown, 48
.equ SYS_socketpair, 53
.equ SYS_renameat2, 316         # the agent's rename without replacing (Linux only)
.equ REMOTE_PID_TAG, 0x20000000
.equ SYS_prctl, 157
.equ PR_SET_PDEATHSIG, 1
.equ PR_SET_NO_NEW_PRIVS, 38
# confinement (src/app/confine.s): Landlock, namespaces, the macOS sandbox
.equ SYS_getuid, 102
.equ SYS_getgid, 104
.equ SYS_unshare, 272
.equ SYS_landlock_create_ruleset, 444
.equ SYS_landlock_add_rule, 445
.equ SYS_landlock_restrict_self, 446
.equ SYS_sandbox_init, 290          # macOS only: a pseudo number the translator maps to sandbox_init
.equ SYS_realpath, 291              # macOS only: realpath(path, buf) -> buf or 0
.equ CLONE_NEWUSER, 0x10000000
.equ CLONE_NEWNET, 0x40000000
.equ O_PATH, 0x200000
.equ LL_VERSION, 1                  # landlock_create_ruleset flag: report the ABI
.equ LL_RULE_PATH_BENEATH, 1
.equ LL_EXECUTE, 1
.equ LL_WRITE_FILE, 2
.equ LL_READ_FILE, 4
.equ LL_READ_DIR, 8
.equ LL_REMOVE_DIR, 16
.equ LL_REMOVE_FILE, 32
.equ LL_MAKE_CHAR, 64
.equ LL_MAKE_DIR, 128
.equ LL_MAKE_REG, 256
.equ LL_MAKE_SOCK, 512
.equ LL_MAKE_FIFO, 1024
.equ LL_MAKE_BLOCK, 2048
.equ LL_MAKE_SYM, 4096
.equ LL_REFER, 8192                 # ABI 2
.equ LL_TRUNCATE, 16384             # ABI 3
.equ LL_IOCTL_DEV, 32768            # ABI 5
.equ LL_FILE_RIGHTS, LL_READ_FILE | LL_WRITE_FILE | LL_EXECUTE | LL_TRUNCATE | LL_IOCTL_DEV
.equ LL_RO, LL_READ_FILE | LL_READ_DIR
.equ LL_RW, LL_RO | LL_WRITE_FILE | LL_TRUNCATE | LL_REMOVE_DIR | LL_REMOVE_FILE | LL_MAKE_DIR | LL_MAKE_REG | LL_MAKE_SYM | LL_MAKE_FIFO | LL_MAKE_SOCK | LL_REFER
.equ LL_NET_BIND_TCP, 1             # ABI 4
.equ LL_NET_CONNECT_TCP, 2
.equ CF_LANDLOCK, 1                 # confinement flags for the child
.equ CF_NETNS, 2                    # a user and network namespace
.equ CF_SANDBOX, 4                  # macOS: sandbox_init with the profile
.equ EXITC_NNP, 70                  # the child's exit codes when confinement fails
.equ EXITC_NETNS, 71
.equ EXITC_LANDLOCK, 72
.equ EXITC_RULE, 73
.equ EXITC_RESTRICT, 74
.equ EXITC_SANDBOX, 75
.equ CONFINED_NO, 0                 # EXT_confined: how the running program is held
.equ CONFINED_FULL, 1
.equ CONFINED_TCP, 2                # network cut by TCP rules only (no user namespaces)
.equ SIGTERM, 15
.equ F_SETFL, 4

.equ O_RDONLY, 0
.equ O_WRONLY, 1
.equ O_RDWR, 2
.equ O_CREAT, 0x40
.equ O_EXCL, 0x80
.equ O_NOCTTY, 0x100
.equ O_TRUNC, 0x200
.equ O_APPEND, 0x400
.equ O_NONBLOCK, 0x800
.equ O_NOFOLLOW, 0x20000
.equ O_DIRECTORY, 0x10000
.equ O_CLOEXEC, 0x80000

.equ PROT_READ, 1
.equ PROT_WRITE, 2
.equ MAP_SHARED, 1
.equ MAP_PRIVATE, 2
.equ MAP_ANONYMOUS, 0x20
.equ MREMAP_MAYMOVE, 1

.equ AF_UNIX, 1
.equ AF_INET, 2                 # remote hosts: forwarded ports (remotefwd.s, ragent.s)
.equ AF_INET6, 10
.equ SHUT_WR, 1
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
.equ IN_MOVE_SELF, 0x800
.equ IN_IGNORED, 0x8000
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
# Private per-call context for strict directory enumeration.
.equ DSC_max, 0
.equ DSC_count, 8
.equ DSC_callback, 16
.equ DSC_user, 24
.equ DSC_SIZE, 32
.equ DSC_CAP_MAX, 1048576

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
.equ KEY_SHIFT_R, 0xffe2
.equ KEY_CTRL_L, 0xffe3
.equ KEY_CTRL_R, 0xffe4
.equ KEY_ALT_L, 0xffe9
.equ KEY_ALT_R, 0xffea
.equ KEY_SUPER_L, 0xffeb
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
.equ CUR_ARROW, 7               # the arrow shape again, but claimed: unlike CUR_DEFAULT it is not "unset"

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
F FACE_oblique, 4       # views group: glyphs sheared right (Markdown emphasis), 0 upright
ENDSTRUCT FACE_SIZE

# ---- event loop fd watchers ----
STRUCT
F PW_fd, 4
F PW_events, 4
F PW_handler, 8         # handler(fd, revents, ctx)
F PW_ctx, 8
ENDSTRUCT PW_SIZE
.equ MAX_WATCH, 512

# ---- platform vtable (wayland / x11 / headless) ----
STRUCT
F P_flush, 8            # ()
F P_timeout, 8          # () -> ms or -1
F P_tick, 8             # ()
F P_draw, 8             # () renders if possible
F P_cursor, 8           # (shape)
F P_clip_set, 8         # (ptr, len) -> 1 accepted write request, 0 known failure
F P_clip_get, 8         # () snapshots app_clip_active_token, completes through app_clip_complete
F P_move, 8             # ()
F P_resize, 8           # (edges)
F P_minimize, 8         # ()
F P_maximize, 8         # () toggle
F P_title, 8            # (cstr)
F P_menu, 8             # (x, y)
F P_clip_write, 8       # optional (native wire, len) -> accepted bool; zero for plain fallback
ENDSTRUCT PLAT_SIZE

# Last normal window bounds, in the native backend's coordinates. Maximized axes are bits 0/1.
STRUCT
F WPOS_magic, 4
F WPOS_x, 4
F WPOS_y, 4
F WPOS_w, 4
F WPOS_h, 4
F WPOS_max, 4
ENDSTRUCT WPOS_SIZE
.equ WPOS_MAGIC, 0x31535752      # RWS1, little endian

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
.equ T_ICON, T_TERM + 19        # file icons: red orange yellow green blue purple pink cyan grey white
# editor presentation's colors (derived when a theme leaves them out)
.equ T_INLAY, T_ICON + 10       # inlay hints' text, and their pill
.equ T_INLAY_BG, T_INLAY + 1
.equ T_GHOST, T_INLAY + 2       # inline completion's text
.equ T_CODELENS, T_INLAY + 3
.equ T_HIGHLIGHT, T_INLAY + 4   # document highlights, and the written ones
.equ T_HIGHLIGHT_WRITE, T_INLAY + 5
.equ T_INFO, T_INLAY + 6        # info and hint diagnostics
.equ T_HINT, T_INLAY + 7
.equ T_COUNT, T_INLAY + 8

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

# ---- auto save (cfg_auto_save) ----
.equ AUTOSAVE_OFF, 0
.equ AUTOSAVE_AFTER_DELAY, 1
.equ AUTOSAVE_ON_FOCUS_CHANGE, 2
.equ AUTOSAVE_ON_WINDOW_CHANGE, 3


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
F DOC_wd, 8             # directory watch descriptor, -1 when unavailable
F DOC_reload_at, 8      # external writes coalesce before a reload, 0 when none is pending
F DOC_disk_seen, 8      # last external stamp handled
F DOC_disk_until, 8     # editor's external reload highlight fades until this time
F DOC_disk_lo, 8        # first changed line in the reloaded text
F DOC_wcols, 8          # editor: columns of the widest line (doc_widest)
F DOC_wkey, 8           # the text and tab width they were measured for, 0 = not yet
F DOC_disk_hi, 8        # line past the changed range (deletions highlight their surviving neighbor)
F DOC_real, 8           # a symlink's file: its path (owned) and name, and its folder's watch, or 0
F DOC_rname, 8
F DOC_wd2, 8
F DOC_hops, 8           # the symlinks it leads through before that file (watch.s), or 0
F DOC_id, 8             # extensions: session-unique id, given by doc_new
F DOC_saves, 8          # extensions: times the document was written (the "saved" event)
F DOC_xedits, 8         # extensions: SB* of edit records since the last frame (section 6a), or 0
F DOC_xmarks, 8         # extensions: VEC* of MK marks (diagnostics), or 0
F DOC_xresync, 4        # extensions: 1 when records were lost: the resync event is due
F DOC_xpad, 4
F DOC_oval, 16          # extensions: option overrides (section 6c), u32 each: OPT_TAB the width,
                        #   the booleans 1 = no, 2 = yes; 0 = no override
F DOC_oown, 32          # extensions: the EXT* that set each of them
F DOC_snippet, 8        # native prepared-field session, owned, or 0
F DOC_selections, 8     # owned secondary selection block, or 0; scalar primary remains authoritative
F DOC_selectionbatch, 8 # batch edits capture selection history only at their boundaries
F DOC_multilastcp, 8    # last scalar inserted by a multiple-selection typing run
F DOC_language_mode, 4  # DL_AUTO, DL_PLAIN or DL_NAMED
F DOC_language_syncing, 4
F DOC_language_name, 8  # owned explicit language name, retained even while unavailable
F DOC_language_epoch, 8
F DOC_language_revision, 8 # independent of text version; 0 permanently exhausts authority
F DOC_language_pending, 8
# source control (wider-parity C): quick-diff bases from extensions (scmext.s)
F DOC_gsrc, 4           # 1: DOC_ghash is an extension's quick-diff base, not HEAD's
F DOC_qdwant, 4         # 1: a quick-diff provider is to be asked for the base
F DOC_gext, 8           # the EXT that gave that base (its bases go when it stops)
F DOC_qbase, 8          # a copy of that base's text (mem_alloc'd), for the diff a panel's click opens
F DOC_qblen, 8
F DOC_nb, 8             # notebooks: the NB a TAB_NOTEBOOK tab's document stands for, or 0 (nbdoc.s)
F DOC_ce, 8             # custom editors: the CE whose tab shows this document, or 0 (customed.s)
F DOC_pres, 8           # editor presentation: PRS* (edtape.s), owned, or 0
F DOC_uri, 8            # resources group: a virtual document's URI (owned; vdoc.s), or 0
ENDSTRUCT DOC_SIZE
.equ DL_AUTO, 0
.equ DL_PLAIN, 1
.equ DL_NAMED, 2
.equ DOC_SELECTIONS_MAX, 512
.equ DOC_MULTI_BYTES_MAX, 67108864
STRUCT
F DMR_start, 8
F DMR_end, 8
F DMR_index, 8          # lowest original selection index in a merged range
F DMR_caret, 8
ENDSTRUCT DMR_SIZE
STRUCT
F DNS_count, 8
F DNS_doclen, 8
F DNS_ranges, DMR_SIZE*DOC_SELECTIONS_MAX
ENDSTRUCT DNS_SIZE
STRUCT
F DMS_count, 8          # number of secondary selections
ENDSTRUCT DMS_DATA
STRUCT
F DMP_cur, 8
F DMP_anchor, 8
ENDSTRUCT DMP_SIZE
.equ DOC_BATCH_EDITS_MAX, 1024
STRUCT
F DBE_start, 8
F DBE_end, 8
F DBE_text, 8
F DBE_len, 8
ENDSTRUCT DBE_SIZE
# Trusted native precommit guard. Context remains owned by the caller until return.
STRUCT
F GDC_callback, 8
F GDC_context, 8
ENDSTRUCT GDC_SIZE
STRUCT
F DBA_doc, 8
F DBA_count, 8
F DBA_npairs, 8
F DBA_doclen, 8
F DBA_final, 8
F DBA_inserted, 8
F DBA_deleted, 8
F DBA_text, 8           # owned aggregate payload
F DBA_before, 8         # owned extras snapshot until transferred to the first record
F DBA_cur, 8
F DBA_anchor, 8
F DBA_undo, 8
F DBA_grouped, 8
F DBA_error, 8
F DBA_callback, 8
F DBA_context, 8
F DBA_snapshot, 8      # owned DOC bytes, only for guarded preparation
F DBA_extras, 8        # owned secondary endpoints for the stale-state check
F DBA_edits, DBE_SIZE*DOC_BATCH_EDITS_MAX
F DBA_pairs, DMP_SIZE*DOC_SELECTIONS_MAX
ENDSTRUCT DBA_SIZE
# Native owned clipboard pieces and prepared multi-selection Copy/Cut.
STRUCT
F ECS_offset, 8
F ECS_len, 8
ENDSTRUCT ECS_SIZE
STRUCT
F ECM_count, 8
F ECM_total, 8
F ECM_segments, ECS_SIZE*DOC_SELECTIONS_MAX
ENDSTRUCT ECM_SIZE
# Native clipboard envelope. Header's count/total/table is a borrowed ECM view.
.equ CLW_MAGIC, 0x00504c434e554852
.equ CLW_VERSION, 1
.equ CLW_HEADER, 32
.equ CLW_MAX, DOC_MULTI_BYTES_MAX + 32 + ECS_SIZE*DOC_SELECTIONS_MAX
STRUCT
F CWB_text, 8
F CWB_len, 8
F CWB_line, 8
F CWB_metadata, 8
ENDSTRUCT CWB_SIZE
STRUCT
F ECR_start, 8
F ECR_end, 8
F ECR_append, 8
F ECR_unused, 8
ENDSTRUCT ECR_SIZE
STRUCT
F ECP_doc, 8
F ECP_cut, 8
F ECP_limit, 8
F ECP_dns, 8
F ECP_metadata, 8
F ECP_text, SB_SIZE
F ECP_npieces, 8
F ECP_ncuts, 8
F ECP_nedits, 8
F ECP_line, 8
F ECP_lastline, 8
F ECP_error, 8
F ECP_pieces, ECR_SIZE*DOC_SELECTIONS_MAX
F ECP_cuts, DMR_SIZE*DOC_SELECTIONS_MAX
F ECP_edits, DBE_SIZE*DOC_SELECTIONS_MAX
F ECP_pairs, DMP_SIZE*DOC_SELECTIONS_MAX
ENDSTRUCT ECP_SIZE
# Owned multiple-selection paste plan and copied native preparation options.
STRUCT
F PPO_mode, 8
F PPO_metadata, 8
F PPO_line, 8
F PPO_limit, 8
ENDSTRUCT PPO_SIZE
STRUCT
F EPP_doc, 8
F EPP_mode, 8
F EPP_line, 8
F EPP_limit, 8
F EPP_input, 8
F EPP_inputlen, 8
F EPP_dns, 8
F EPP_cooked, 8
F EPP_cookedlen, 8
F EPP_nspans, 8
F EPP_distributed, 8
F EPP_nedits, 8
F EPP_npairs, 8
F EPP_delta, 8
F EPP_inserted, 8
F EPP_lastline, 8
F EPP_noop, 8
F EPP_metadata, ECM_SIZE
F EPP_spans, ECS_SIZE*DOC_SELECTIONS_MAX
F EPP_payloads, ECS_SIZE*DOC_SELECTIONS_MAX
F EPP_edits, DBE_SIZE*DOC_SELECTIONS_MAX
F EPP_pairs, DMP_SIZE*DOC_SELECTIONS_MAX
ENDSTRUCT EPP_SIZE
STRUCT
F DME_input, 8          # borrowed until the general batch copies all payloads
F DME_len, 8
F DME_count, 8
F DME_doclen, 8
F DME_deleted, 8
F DME_error, 8
F DME_nedits, 8
F DME_ranges, DMR_SIZE*DOC_SELECTIONS_MAX
F DME_pairs, DMP_SIZE*DOC_SELECTIONS_MAX
F DME_edits, DBE_SIZE*DOC_SELECTIONS_MAX
ENDSTRUCT DME_SIZE
STRUCT
F ETP_doc, 8
F ETP_ranges, 8
F ETP_scalar, 8
F ETP_encoded, 8
F ETP_elen, 8
F ETP_nedits, 8
F ETP_bytes, 8
F ETP_delta, 8
F ETP_undo, 8
F ETP_joined, 8
F ETP_error, 8
F ETP_direction, 8
F ETP_temp, 8
F ETP_tlen, 8
F ETP_cur, 8
F ETP_anchor, 8
F ETP_write, 8
F ETP_built, 8
F ETP_edits, DBE_SIZE*DOC_SELECTIONS_MAX
F ETP_payloads, 8*DOC_SELECTIONS_MAX
F ETP_pairs, DMP_SIZE*DOC_SELECTIONS_MAX
ENDSTRUCT ETP_SIZE
STRUCT
F ENP_ranges, 8
F ENP_limit, 8
F ENP_bytes, 8
F ENP_scan, 8
F ENP_delta, 8
F ENP_built, 8
F ENP_error, 8
F ENP_edits, DBE_SIZE*DOC_SELECTIONS_MAX
F ENP_payloads, 8*DOC_SELECTIONS_MAX
F ENP_pairs, DMP_SIZE*DOC_SELECTIONS_MAX
ENDSTRUCT ENP_SIZE
STRUCT
F EDP_ranges, 8
F EDP_expanded, 8
F EDP_direction, 8
F EDP_word, 8
F EDP_scan, 8
F EDP_delta, 8
F EDP_kind, 8
F EDP_undo, 8
F EDP_joined, 8
F EDP_nedits, 8
F EDP_error, 8
F EDP_candidates, DMP_SIZE*DOC_SELECTIONS_MAX
F EDP_pairs, DMP_SIZE*DOC_SELECTIONS_MAX
F EDP_edits, DBE_SIZE*DOC_SELECTIONS_MAX
ENDSTRUCT EDP_SIZE
# Multiple selection Tab planning. Payloads are owned inline, never DOC views.
.equ ETB_CANDIDATES_MAX, DOC_BATCH_EDITS_MAX + DOC_SELECTIONS_MAX
STRUCT
F ETC_start, 8
F ETC_end, 8
F ETC_len, 8
F ETC_kind, 8          # 0 line prefix, 1 selection replacement
F ETC_data, 32
F ETC_output, 8        # compact output index
ENDSTRUCT ETC_SIZE
STRUCT
F ETL_line, 8
F ETL_empty, 8
ENDSTRUCT ETL_SIZE
STRUCT
F ETB_doc, 8
F ETB_ranges, 8
F ETB_mode, 8
F ETB_width, 8
F ETB_spaces, 8
F ETB_limit, 8
F ETB_scan, 8
F ETB_editlimit, 8
F ETB_ncandidates, 8
F ETB_nlines, 8
F ETB_nedits, 8
F ETB_bytes, 8
F ETB_error, 8
F ETB_candidates, ETC_SIZE*ETB_CANDIDATES_MAX
F ETB_order, 8*ETB_CANDIDATES_MAX
F ETB_lines, ETL_SIZE*DOC_BATCH_EDITS_MAX
F ETB_direction, 8*DOC_SELECTIONS_MAX
F ETB_class, 8*DOC_SELECTIONS_MAX
F ETB_replacements, 8*DOC_SELECTIONS_MAX
F ETB_sourcepairs, DMP_SIZE*DOC_SELECTIONS_MAX
F ETB_rangeorder, 8*DOC_SELECTIONS_MAX
F ETB_edits, DBE_SIZE*DOC_BATCH_EDITS_MAX
F ETB_payloads, 32*DOC_BATCH_EDITS_MAX
F ETB_pairs, DMP_SIZE*DOC_SELECTIONS_MAX
ENDSTRUCT ETB_SIZE
.equ OPT_TAB, 0
.equ OPT_SPACES, 1
.equ OPT_TRIM, 2
.equ OPT_FINAL, 3

# Prepared snippet fields and propagation. All indices are stable for a session.
.equ SN_FIELDS_MAX, 512
.equ SN_GROUPS_MAX, 256
.equ SN_DEPTH_MAX, 32
.equ SN_BYTES_MAX, 4194304
.equ SN_SESSIONS_MAX, 32
.equ SN_OPTIONS_MAX, 256
.equ SN_OPTION_MAX, 1048576
STRUCT
F SC_refs, 8
F SC_bytes, 8
ENDSTRUCT SC_DATA
STRUCT
F SF_group, 8
F SF_start, 8
F SF_end, 8
F SF_parent, 8          # zero, or one-based index of an earlier primary occurrence
F SF_gindex, 8
F SF_flags, 8           # bit0 alive, bit1 primary; higher bits replacement provenance
F SF_transform, 8       # one-based immutable transform record offset, or zero
ENDSTRUCT SF_SIZE
STRUCT
F SG_id, 8
F SG_primary, 8
F SG_alive, 8
F SG_dirty, 8
F SG_choice, 8         # one-based byte offset in immutable choice payload, or zero
ENDSTRUCT SG_SIZE
STRUCT
F SN_parent, 8         # owned enclosing session, or zero
F SN_child, 8          # borrowed current inner session, or zero
F SN_identity, 8
F SN_activation, 8
F SN_choice_pending, 8
F SN_choice, 8         # owned reference to immutable SC payload
F SN_choicebytes, 8
F SN_transform, 8       # owned immutable transform payload
F SN_transformbytes, 8
F SN_indent, 8          # owned original insertion whitespace, common SC header
F SN_indentbytes, 8
F SN_nfields, 8
F SN_ngroups, 8
F SN_docid, 8
F SN_active, 8
F SN_final, 8
F SN_finalend, 8
F SN_finalfield, 8
F SN_finalspan, 8
F SN_finalowner, 8
F SN_finalcollapseowner, 8
F SN_valid, 8
F SN_user, 8
F SN_beginundo, 8       # undo length at the outermost user operation
F SN_mutating, 8
F SN_replacing, 8
F SN_repla, 8
F SN_replb, 8
F SN_lastrecord, 8
F SN_lastpos, 8
F SN_lastlen, 8
F SN_lastkind, 8
F SN_lasttime, 8
F SN_lastgroup, 8
F SN_lastflags, 8
F SN_text, 8            # borrowed during validation only
F SN_tlen, 8
F SN_ntopo, 8           # surviving groups in propagation order; group indices stay stable
F SN_linked, 8          # wsedit: a linked-editing session (wslinked.s): Tab passes, no final caret
F SN_lwords, 16         # wsedit: its word characters besides letters and digits (ASCII bits)
F SN_fields, SF_SIZE*SN_FIELDS_MAX
F SN_groups, SG_SIZE*SN_GROUPS_MAX
F SN_edges, SN_GROUPS_MAX*SN_GROUPS_MAX
F SN_topo, 8*SN_GROUPS_MAX
F SN_degree, 8*SN_GROUPS_MAX
F SN_done, SN_FIELDS_MAX        # occurrences already mirrored in one propagation
ENDSTRUCT SN_SIZE

# Canonical private per-occurrence transform payload.
.equ STP_MAGIC, 0x58544e53
.equ STP_HEADER, 32
.equ STP_RECORD, 24

# A bounded private regex execution context. Program/input storage belongs to the caller.
.equ RX_WORK_MAX, 16777216
.equ RX_BRANCH_MAX, 4096
.equ RX_TRAIL_MAX, 65536
.equ RX_CALL_MAX, 32
.equ RX_VALUES_MAX, 642
.equ RX_PROGRAM_ERROR, 1
.equ RX_INPUT_ERROR, 2
.equ RX_START_ERROR, 3
.equ RX_WORK_ERROR, 4
.equ RX_BRANCH_ERROR, 5
.equ RX_TRAIL_ERROR, 6
.equ RX_CALL_ERROR, 7
.equ RX_STATE_ERROR, 8
.equ RX_TIME_ERROR, 9
STRUCT
F RX_program, 8
F RX_plen, 8
F RX_code, 8
F RX_classes, 8
F RX_ranges, 8
F RX_repeats, 8
F RX_flags, 8
F RX_ncaps, 8
F RX_ncode, 8
F RX_nclasses, 8
F RX_nranges, 8
F RX_nrepeats, 8
F RX_input, 8
F RX_ilen, 8
F RX_work, 8
F RX_deadline, 8
F RX_clockat, 8
F RX_pc, 8
F RX_pos, 8
F RX_backward, 8
F RX_attempt, 8
F RX_nvalues, 8
F RX_nslots, 8
F RX_ntrail, 8
F RX_nbranches, 8
F RX_ncalls, 8
F RX_error, 8
F RX_errpc, 8
F RX_errbyte, 8
F RX_tstage, 8
F RX_trecord, 8
F RX_ready, 8
F RX_hasmatch, 8
F RX_start, 8
F RX_end, 8
F RX_values, 8*RX_VALUES_MAX
F RX_trail, 16*RX_TRAIL_MAX
F RX_branches, 24*RX_BRANCH_MAX
F RX_calls, 48*RX_CALL_MAX
F RX_captures, 16*65
ENDSTRUCT RX_SIZE

.equ RX_CASE_OP_ERROR, 10
.equ RX_CASE_OUTPUT_ERROR, 11
.equ RX_CASE_ALLOC_ERROR, 12
# Private fixed stack scratch for native case conversion.
STRUCT
F SC_rx, 8
F SC_out, SB_SIZE
F SC_prep, SB_SIZE
F SC_pad, 8
ENDSTRUCT SC_SIZE
.equ RX_REPLACEMENT_ERROR, 13
.equ TRANSFORM_ARGUMENTS, 1
.equ TRANSFORM_FORMAT, 2
.equ TRANSFORM_MATCH, 3
.equ TRANSFORM_CASE, 4
.equ TRANSFORM_OUTPUT, 5
STRUCT
F TD_regex, 8
F TD_rlen, 8
F TD_format, 8
F TD_flen, 8
F TD_input, 8
F TD_ilen, 8
ENDSTRUCT TD_SIZE
STRUCT
F TI_input, 8
F TI_ilen, 8
F TI_prefix, 8
F TI_plen, 8
F TI_width, 8
F TI_spaces, 8
ENDSTRUCT TI_SIZE
STRUCT
F TXF_sc, SC_SIZE
F TXF_desc, 8
F TXF_format, 8
F TXF_blob, 8
F TXF_nrecords, 8
F TXF_cursor, 8
F TXF_next, 8
F TXF_found, 8
F TXF_fallback, 8
F TXF_temp, 8
F TXF_temp_len, 8
F TXF_pad, 16
ENDSTRUCT TXF_SIZE

STRUCT
F STLR_field, 8
F STLR_output, 8
F STLR_len, 8
F STLR_done, 8
ENDSTRUCT STLR_SIZE
STRUCT
F STL_sc, SC_SIZE
F STL_doc, 8
F STL_state, 8
F STL_plan, 8
F STL_count, 8
F STL_bytes, 8
F STL_total, 8
F STL_clone, 8
F STL_raw, 8
F STL_temp, 8
F STL_tlen, 8
F STL_group, 8
F STL_width, 8
F STL_spaces, 8
F STL_flags, 8
F STL_index, 8
F STL_td, TD_SIZE
F STL_ti, TI_SIZE
F STL_pad, 8
ENDSTRUCT STL_SIZE


# a diagnostic mark on a document
STRUCT
F MK_owner, 8           # EXT*
F MK_start, 8           # byte positions, half-open
F MK_end, 8
F MK_sev, 4             # SEV_*
F MK_pad, 4             # MKF_SOURCE, and MKT_* tags (feature diagnostic-tags)
F MK_msg, 8             # cstr (owned)
ENDSTRUCT MK_SIZE
.equ SEV_ERROR, 0
.equ SEV_WARNING, 1
.equ SEV_INFO, 2
.equ SEV_HINT, 3
.equ MKT_UNNECESSARY, 2         # MK_pad: faded (a hint then draws no underline)
.equ MKT_DEPRECATED, 4          # MK_pad: struck through
.equ MARKS_MAX, 2000
.equ MARK_MSG_MAX, 200
.equ HOVER_MAX, 4000
.equ HOVER_REST_MS, 500
.equ EDITS_MAX, 1048576
.equ ID_EXT_HOVER, 0x3e00


.equ DISK_FADE_MS, 800
.equ DISK_FRAME_MS, 50

# DOC_flags
.equ DF_GROUP, 1
.equ DF_READONLY, 2              # diff views
.equ DF_EOL, 4                   # the text ended in a newline when read or saved: vim has no line after it
.equ DF_DISK_CHANGED, 8          # external contents differ and unsaved edits were kept
.equ DF_REVEAL, 16               # its cursor was placed while it was not shown: in view when next drawn
.equ DF_CENTER, 32               # with DF_REVEAL: that reveal puts the cursor's line in the middle
.equ DF_CELL, 64                 # notebooks: a cell's text (nbdoc.s): no path and no tab of its own
.equ DF_ROWS, 128                # presentation (fold.s): the view scrolls by rows (folds), not lines

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
F DV_rev2, 8            # with DV_two: the second revision, or 0 for the work tree
F DV_path, 8            # path in the work tree
F DV_maxno, 4           # largest line number
F DV_two, 4             # 1: DV_rev against DV_rev2 (git-diff-open), not a commit against its parent
F DV_review, 8          # AI (review.s): the proposal a Review tab shows, or 0
F DV_flags, 4           # wsedit: DVF_*
F DV_flags_pad, 4
ENDSTRUCT DV_SIZE
.equ DVF_OWN, 1                 # wsedit: a diff tab of wsdiff.s, not git's (not reopened, not fetched)
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
.equ DK_FILE, 5                 # AI (review.s): a file's header in a Review tab

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
# source control row menus (scm_row_menu, scmext.s): their locations
.equ SL_HISTORY_COMMIT, 1
.equ SL_HISTORY_FILE, 2
.equ SL_SCM_RESOURCE, 3
.equ SL_SCM_GROUP, 4

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
F UR_aftercur, 8        # optional group replay caret; -1 for ordinary records
F UR_afteranchor, 8
F UR_beforeselections, 8 # owned secondary selection snapshot, or 0
F UR_afterselections, 8  # owned snapshot, 0 = single, -1 = unspecified
F UR_tx, 8              # wsedit: the workspace-edit transaction this group belongs to, 0 for none
ENDSTRUCT UR_SIZE

# ---- workspace-edit transactions (wsedit: wsedit.s, wstx.s, wsdisk.s) ----
# a transaction: one workspace edit across documents and files, undone and redone as one step
STRUCT
F TX_id, 8              # session-unique, never 0 (UR_tx names it)
F TX_label, 8           # owned cstr: names it in toasts and lists
F TX_journal, 8         # owned cstr: its journal folder, or 0 when it wrote nothing to disk
F TX_nparts, 8
F TX_parts, 8           # owned array of TP
F TX_flags, 8           # TXF_*
ENDSTRUCT TX_SIZE
.equ TX_MAX, 64
.equ TXF_DISK, 1        # it changed files on disk
# a participant of a transaction
STRUCT
F TP_kind, 8            # TPK_*
F TP_doc, 8             # TPK_BUF: the document
F TP_state, 8           # TPS_*
F TP_wrote, 8           # TPK_BUF: its text was also written to disk
F TP_path, 8            # owned cstr: the file (TPK_FILE, a written TPK_BUF, the file operations)
F TP_path2, 8           # owned cstr: a rename's target
F TP_before, 8          # FNV-1a of the file's bytes before and after (disk participants)
F TP_after, 8
F TP_slot, 8            # its journal slot, -1 for none
F TP_flags, 8           # TPF_*
ENDSTRUCT TP_SIZE
.equ TPK_BUF, 1         # an open document's buffer
.equ TPK_FILE, 2        # a file on disk that was not open
.equ TPK_CREATE, 3
.equ TPK_RENAME, 4
.equ TPK_DELETE, 5
.equ TPS_APPLIED, 0
.equ TPS_UNDONE, 1
.equ TPS_LOST, 2        # closed unsaved, or otherwise out of reach: skipped
.equ TPF_FOLDER, 1      # a create or delete of a folder
.equ TPF_PICK, 2        # tx_run: undo or redo this one
.equ TPF_DONE, 4        # a commit made its disk step (a rollback puts it back)
.equ TPF_HADTAB, 8      # a deleted file had a clean tab (undo opens it again)
.equ TPF_CASE, 16       # a rename that changes only letter case
.equ TPF_OVER, 32       # a create or rename replaced a file (in the journal as SLOT.over)
# a workspace edit being made (wsedit.s reads it, wsdisk.s writes its files)
.equ WK_TEXT, 0                 # entry kinds
.equ WK_CREATE, 1
.equ WK_RENAME, 2
.equ WK_DELETE, 3

.equ WP_VERSION, 0              # what a text group was made for (PRE)
.equ WP_DASH, 1                 # "-": the file on disk as it is
.equ WP_HASH, 2                 # "fnv1a64:HEX": the file whose bytes hash so

.equ WF_OVERWRITE, 1            # entry flags
.equ WF_IGNORE_EXISTING, 2
.equ WF_RECURSIVE, 4
.equ WF_IGNORE_MISSING, 8

# an entry of a workspace edit: a text group (one file) or a file operation
STRUCT
F WG_kind, 8                    # WK_*
F WG_path, 8                    # its PATH bytes (a rename's FROM)
F WG_plen, 8
F WG_path2, 8                   # a rename's TO
F WG_plen2, 8
F WG_pre, 8                     # WP_*
F WG_version, 8                 # WP_VERSION: the version; -1 otherwise
F WG_hash, 8                    # WP_HASH: the hash
F WG_flags, 8                   # WF_*
F WG_doc, 8                     # DOC* once resolved: the open document, or a hidden one (WG_hidden)
F WG_hidden, 8                  # 1: WG_doc was read for a closed file, never shown, freed after
F WG_first, 8                   # its edits: we[first .. first + count)
F WG_count, 8
F WG_opened, 8                  # 1: this edit opened its tab (v1; closed again if the edit fails)
F WG_real, 8                    # owned: the file's path as written on disk, or 0
F WG_stamp, 8                   # the file's stamp when it was read
F WG_orig, 8                    # owned: a closed file's bytes as read, raw
F WG_olen, 8
F WG_clean, 8                   # an open document that had no unsaved changes
F WG_ver0, 8                    # an open document's version when it was checked
F WG_new, 8                     # owned: a closed file's bytes to write
F WG_nlen, 8
F WG_before, 8                  # FNV-1a of the bytes read, and of the bytes to write
F WG_after, 8
F WG_real2, 8                   # owned: a rename's target as it will be on disk
F WG_skip, 8                    # a file operation that ignore-existing or ignore-missing skips
F WG_folder, 8                  # a file operation on a folder
F WG_exists, 8                  # its target exists (overwrite moves it into the journal)
F WG_case, 8                    # a rename that changes only letter case (two steps)
F WG_created, 8                 # a text group for a file an earlier create makes
ENDSTRUCT WG_SIZE

# an edit of a text group
STRUCT
F WE_l1, 4
F WE_c1, 4
F WE_l2, 4
F WE_c2, 4
F WE_start, 8                   # byte offsets, once resolved
F WE_end, 8
F WE_text, 8
F WE_len, 8
ENDSTRUCT WE_SIZE


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
F TF_top, 4             # text area: the first visual row shown
F TF_width, 4           # text area: available text width in pixels
F TF_prefx, 4           # text area: preferred x for vertical motion, -1 = none
F TF_pad, 4
F TF_revision, 8        # content or destination lifecycle mutation
ENDSTRUCT TF_SIZE

# Owned destination snapshot and queued clipboard request. No document pointers retained.
.equ CPX_kind, 0
.equ CPX_focus, 8
.equ CPX_identity, 16
.equ CPX_revision, 24
.equ CPX_cur, 32
.equ CPX_anchor, 40
.equ CPX_flags, 48
.equ CPX_vim, 56
.equ CPX_submode, 64
.equ CPX_extras, 72
.equ CPX_owner, 80
.equ CPX_length, 88
.equ CPX_SIZE, 96
.equ CPR_token, 96
.equ CPR_started, 104
.equ CPR_operation, 112
.equ CPR_putkind, 120
.equ CPR_putcount, 128
.equ CPR_putmode, 136
.equ CPR_SIZE, 144
.equ CPR_COUNT, 16
.equ CPX_DOCUMENT, 1
.equ CPX_FIELD, 2
.equ CPX_TERMINAL, 3
.equ CPX_PICTURE, 68             # views group: a picture with the keyboard (viewpic.s)

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
.equ IC_FILE_PLUS, 31
.equ IC_FOLDER_PLUS, 32
# icons from SVG files (tools/icons.py)
.equ IC_CLAUDE, 33
.equ IC_OPENAI, 34
.equ IC_GROK, 35
.equ IC_F_R, 36
.equ IC_F_APPLE, 37
.equ IC_F_ASM, 38
.equ IC_F_AUDIO, 39
.equ IC_F_BABEL, 40
.equ IC_F_BAZEL, 41
.equ IC_F_C, 42
.equ IC_F_C_SHARP, 43
.equ IC_F_CLOCK, 44
.equ IC_F_CLOJURE, 45
.equ IC_F_CODE, 46
.equ IC_F_CONFIG, 47
.equ IC_F_CPP, 48
.equ IC_F_CRYSTAL, 49
.equ IC_F_CSS, 50
.equ IC_F_CSV, 51
.equ IC_F_CU, 52
.equ IC_F_D, 53
.equ IC_F_DART, 54
.equ IC_F_DB, 55
.equ IC_F_DEFAULT, 56
.equ IC_F_DOCKER, 57
.equ IC_F_EDITORCONFIG, 58
.equ IC_F_EJS, 59
.equ IC_F_ELIXIR, 60
.equ IC_F_ELM, 61
.equ IC_F_ESLINT, 62
.equ IC_F_ETHEREUM, 63
.equ IC_F_F_SHARP, 64
.equ IC_F_FAVICON, 65
.equ IC_F_FONT, 66
.equ IC_F_GIT, 67
.equ IC_F_GO2, 68
.equ IC_F_GRADLE, 69
.equ IC_F_GRAILS, 70
.equ IC_F_GRAPHQL, 71
.equ IC_F_HAML, 72
.equ IC_F_HASKELL, 73
.equ IC_F_HAXE, 74
.equ IC_F_HEROKU, 75
.equ IC_F_HEX, 76
.equ IC_F_HTML, 77
.equ IC_F_HTML_ERB, 78
.equ IC_F_IGNORED, 79
.equ IC_F_ILLUSTRATOR, 80
.equ IC_F_IMAGE, 81
.equ IC_F_INFO, 82
.equ IC_F_JAVA, 83
.equ IC_F_JAVASCRIPT, 84
.equ IC_F_JENKINS, 85
.equ IC_F_JINJA, 86
.equ IC_F_JSON, 87
.equ IC_F_JULIA, 88
.equ IC_F_KOTLIN, 89
.equ IC_F_LESS, 90
.equ IC_F_LICENSE, 91
.equ IC_F_LIQUID, 92
.equ IC_F_LOCK, 93
.equ IC_F_LUA, 94
.equ IC_F_MAKEFILE, 95
.equ IC_F_MARKDOWN, 96
.equ IC_F_MAVEN, 97
.equ IC_F_MUSTACHE, 98
.equ IC_F_NIM, 99
.equ IC_F_NOTEBOOK, 100
.equ IC_F_NPM, 101
.equ IC_F_OCAML, 102
.equ IC_F_PDF, 103
.equ IC_F_PERL, 104
.equ IC_F_PHOTOSHOP, 105
.equ IC_F_PHP, 106
.equ IC_F_POWERSHELL, 107
.equ IC_F_PRISMA, 108
.equ IC_F_PROLOG, 109
.equ IC_F_PUG, 110
.equ IC_F_PUPPET, 111
.equ IC_F_PURESCRIPT, 112
.equ IC_F_PYTHON, 113
.equ IC_F_REACT, 114
.equ IC_F_RUBY, 115
.equ IC_F_RUST, 116
.equ IC_F_SASS, 117
.equ IC_F_SCALA, 118
.equ IC_F_SHELL, 119
.equ IC_F_SLIM, 120
.equ IC_F_SVELTE, 121
.equ IC_F_SVG, 122
.equ IC_F_SWIFT, 123
.equ IC_F_TERRAFORM, 124
.equ IC_F_TEX, 125
.equ IC_F_TODO, 126
.equ IC_F_TSCONFIG, 127
.equ IC_F_TWIG, 128
.equ IC_F_TYPESCRIPT, 129
.equ IC_F_VALA, 130
.equ IC_F_VIDEO, 131
.equ IC_F_VITE, 132
.equ IC_F_VUE, 133
.equ IC_F_WASM, 134
.equ IC_F_WAT, 135
.equ IC_F_WEBPACK, 136
.equ IC_F_WINDOWS, 137
.equ IC_F_WORD, 138
.equ IC_F_XLS, 139
.equ IC_F_XML, 140
.equ IC_F_YARN, 141
.equ IC_F_YML, 142
.equ IC_F_ZIG, 143
.equ IC_F_ZIP, 144
.equ IC_OPENCODE, 145
.equ IC_PIN, 146
.equ IC_PUZZLE, 147
.equ IC_MORE, 148
.equ IC_PLAY, 149
.equ IC_STOP, 150
.equ IC_DEBUG, 151
.equ IC_BUG, 152
.equ IC_WARNING, 153
.equ IC_ERROR, 154
.equ IC_INFO, 155
.equ IC_BELL, 156
.equ IC_GEAR, 157
.equ IC_EDIT, 158
.equ IC_TRASH, 159
.equ IC_EYE, 160
.equ IC_LOCK, 161
.equ IC_COPY, 162
.equ IC_FILTER, 163
.equ IC_LIST, 164
.equ IC_BEAKER, 165
.equ IC_CLOUD, 166
.equ IC_RING, 167
.equ IC_SLASH, 168
.equ IC_DBG_PAUSE, 169
.equ IC_DBG_OVER, 170
.equ IC_DBG_INTO, 171
.equ IC_DBG_OUT, 172
.equ IC_COUNT, 173
# end of the icons from SVG files

# explorer header buttons; the title bar's tooltips name them too
.equ ID_EXP_NEW, 0x3f00
.equ ID_EXP_REFRESH, 0x3f01
.equ ID_EXP_NEW_FOLDER, 0x3f03

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
# ---- protocol features (section 12 of the spec: named in "hello 1 NAME...", agreed by rhun's
# "0 features" before ready) ----
# One line per feature: FEATURE SYMBOL, "wire-name", ASKS. SYMBOL becomes the feature's index into
# EXT_features (a bit set); ASKS is 1 when rhun sends that feature's requests, so the extension's
# ok/error replies are read. Adding a feature is one line here, at the end (indices are not on the
# wire; "0 features" lists names in this order). Test one with FEAT_TEST or ext_feature.
.macro FEATURE_LIST
    FEATURE FEAT_VIEWS, "views", 0
    FEATURE FEAT_COMPLETE, "complete", 1
    FEATURE FEAT_SIGNATURE, "signature", 1
    FEATURE FEAT_DEFINITION, "definition", 1
    FEATURE FEAT_REFERENCES, "references", 1
    FEATURE FEAT_SYMBOLS, "symbols", 1
    FEATURE FEAT_ACTIONS, "actions", 1
    FEATURE FEAT_RENAME, "rename", 1
    FEATURE FEAT_FORMAT, "format", 1
    FEATURE FEAT_COMMANDS, "commands", 0          # protocol 1.1: remove a runtime command
    FEATURE FEAT_SAVE_ACTIONS, "save-actions", 1  # source code actions before saving
    FEATURE FEAT_SNIPPETS, "snippets", 0          # prepared fields and native editable sessions
    FEATURE FEAT_SNIPPET_VARIANTS, "snippet-variants", 0   # declared unequal initial mirrors
    FEATURE FEAT_SNIPPET_TRANSFORMS, "snippet-transforms", 0   # compiled field-exit transforms
    FEATURE FEAT_WORKSPACE_WATCH, "workspace_watch", 0
    # contributions and commands (invoke.s, when.s, extcontext.s)
    FEATURE FEAT_COMMAND_ARGS, "command-args", 1  # 0 run ... FROM LEN, run-command, call
    FEATURE FEAT_CONTEXT_KEYS, "context-keys", 0  # set-context
    # source control (wider-parity C): gitdata.s, scmext.s
    FEATURE FEAT_GIT_DATA, "git-data", 0          # git-repo, git-status, git-blame, git-log, git-show, git-diff-open
    FEATURE FEAT_COMMIT_MESSAGE, "commit-message", 1   # rhun asks a commit-message provider
    FEATURE FEAT_QUICKDIFF, "quickdiff", 1        # rhun asks a quick-diff provider for a base text
    FEATURE FEAT_SCM, "scm", 0                    # a second VCS provider's tabs
    # testing (testproto.s): test items, runs, results, coverage, test-exec
    FEATURE FEAT_TESTS, "tests", 1
    # AI (wider-parity D: agentext.s, review.s, tools.s)
    FEATURE FEAT_AGENTS, "agents", 1              # agent-sessions; rhun asks agent-transcript
    FEATURE FEAT_EDIT_REVIEW, "edit-review", 0    # propose, unpropose
    FEATURE FEAT_TOOLS, "tools", 1                # tools, tool-call; rhun asks owners: tool
    FEATURE FEAT_AGENT_PROMPTS, "agent-prompts", 1    # agent-ask; rhun asks agent-prompt
    # views group (places.s, rtree.s, rview.s)
    FEATURE FEAT_VIEW_TREE, "view-tree", 1        # retained views: vpatch, vshow; vkids, vmore
    # tasks and terminals (termproto.s, tasks.s)
    FEATURE FEAT_TERMINALS, "terminals", 0        # terminal-* requests; terminal-started/-ended/-output/-closed
    FEATURE FEAT_TASKS, "tasks", 0                # tasks-set, task-start, task-run; agreed only with terminals
    # language features (query.s, complete.s, langfeat.s)
    FEATURE FEAT_QUERY_STREAM, "query-stream", 0      # query-part, query-progress
    FEATURE FEAT_PROVIDER_SCOPE, "provider-scope", 0  # provides KEY VALUES
    FEATURE FEAT_COMPLETE_ITEMS, "complete-items", 1  # complete-resolve
    FEATURE FEAT_SIGNATURE_LIST, "signature-list", 1  # signatures
    FEATURE FEAT_NAVIGATION, "navigation", 1          # declaration, type-definition, implementation
    FEATURE FEAT_PARTIAL_FORMAT, "partial-format", 1  # range-format, type-format
    FEATURE FEAT_CODE_ACTIONS, "code-actions", 1      # code-actions, code-action-resolve
    FEATURE FEAT_PREPARE_RENAME, "prepare-rename", 1  # prepare-rename
    FEATURE FEAT_FILE_DIAGNOSTICS, "file-diagnostics", 0  # file-diagnostics into the Problems store
    FEATURE FEAT_HIERARCHY, "hierarchy", 1            # call/type hierarchies in the Results panel
    FEATURE FEAT_HOVER_QUERY, "hover-query", 1        # the hover card (hovercard.s)
    FEATURE FEAT_SELECTION_RANGES, "selection-ranges", 1  # Expand/Shrink Selection (selrange.s)
    FEATURE FEAT_WORKSPACE_SYMBOLS, "workspace-symbols", 1  # Go to Symbol in Project (wsym.s)
    FEATURE FEAT_DOCUMENT_LINKS, "document-links", 1  # links under ctrl+click (doclinks.s)
    # editor presentation (deco.s ...)
    FEATURE FEAT_DECORATIONS, "decorations", 0    # decoration-type, decorate, the visible event
    # workspace edits and the editor model (wsedit.s, wstx.s, wsdisk.s, wsops.s, editorsel.s):
    # ws_features_agreed withholds the ones whose host side is not in yet
    FEATURE FEAT_WORKSPACE_EDITS, "workspace-edits", 0
    FEATURE FEAT_FILE_OPERATIONS, "file-operations", 0   # agreed only with workspace-edits
    FEATURE FEAT_SELECTIONS, "selections", 0
    FEATURE FEAT_REVEAL, "reveal", 0
    FEATURE FEAT_DIFF, "diff", 0
    FEATURE FEAT_LINKED_EDITING, "linked-editing", 1     # rhun asks linked
    # contributions and commands: status bar items (statusitems.s)
    FEATURE FEAT_STATUS_ITEMS, "status-items", 0  # status-item, status-remove
    # resources, workspaces, secrets and lifecycle (extres.s, secrets.s and the files they name)
    FEATURE FEAT_IDLE, "idle", 0                  # busy yes|no
    FEATURE FEAT_SECRETS, "secrets", 0
    FEATURE FEAT_URLS, "urls", 0                  # open-url, external-uri, link
    FEATURE FEAT_URIS, "uris", 1                  # URIs, virtual documents (content requests)
    FEATURE FEAT_FILES, "files", 0                # find-files, search-text
    FEATURE FEAT_SCOPED_SETTINGS, "scoped-settings", 0
    FEATURE FEAT_WORKSPACE_FOLDERS, "workspace-folders", 0
    FEATURE FEAT_DIAG_TAGS, "diagnostic-tags", 0  # SEVERITY+TAG in diagnostics: faded, struck
    FEATURE FEAT_FOLDING_RANGES, "folding-ranges", 1  # rhun asks folding-ranges
    FEATURE FEAT_SEMANTIC_TOKENS, "semantic-tokens", 1    # semantic-legend; rhun asks semantic-tokens
    FEATURE FEAT_INLAY_HINTS, "inlay-hints", 1    # rhun asks inlay-hints
    FEATURE FEAT_CODE_LENS, "code-lens", 1        # rhun asks code-lens
    FEATURE FEAT_INLINE_COMPLETE, "inline-complete", 1    # rhun asks inline-complete
    FEATURE FEAT_DOC_COLORS, "document-colors", 1 # rhun asks colors, color-edit
    FEATURE FEAT_DOC_HIGHLIGHTS, "document-highlights", 1 # rhun asks highlights
    # notebooks (wider-parity A: nbdoc.s, nbproto.inc)
    FEATURE FEAT_NOTEBOOKS, "notebooks", 1        # nb-open, nb-save; runs and outputs
    FEATURE FEAT_VIEW_LOG, "view-log", 0          # views group: log views (with view-tree)
    FEATURE FEAT_NOTIFY, "notify", 0              # views group: notify, notify-set, unnotify
    FEATURE FEAT_PROGRESS, "progress", 0          # views group: progress, progress-set, progress-end
    FEATURE FEAT_VIEW_KEYS, "view-keys", 1        # views group: keys and focus for pictures; rhun asks vcopy
    FEATURE FEAT_VIEW_IMAGES, "view-images", 0    # views group: vimage, unimage, the image shape
    FEATURE FEAT_DEBUG, "debug", 1                # debugger: debug-resolve; debug-start, debug-ended
    FEATURE FEAT_CUSTOM_EDITORS, "custom-editors", 1   # custom editors (customed.s, ceproto.inc)
    FEATURE FEAT_VIEW_FORM, "view-form", 0        # views group: form views (rform.s)
    FEATURE FEAT_VIEW_TABLE, "view-table", 0      # views group: table views (columns, sorted, cell; sort)
    FEATURE FEAT_QUICK_INPUT, "quick-input", 0    # views group: quick, quick-set, quick-close (quick.s)
    FEATURE FEAT_VIEW_DOC, "view-doc", 0          # views group: doc views (rdoc.s, markdown.s)
    FEATURE FEAT_MARKDOWN, "markdown", 0          # views group: Markdown in node tooltips and notification messages
    FEATURE FEAT_VIEW_KEY_STATE, "view-key-state", 0 # paired key releases and window focus
.endm
# extproto.s sets FEATURE_NAMES and expands the list again as its name table
.macro FEATURE sym, name, asks
.ifdef FEATURE_NAMES
    .byte \asks
    .asciz "\name"
.else
    .equ \sym, __feat
    .set __feat, __feat + 1
.endif
.endm
.set __feat, 0
FEATURE_LIST
.equ FEAT_COUNT, __feat
.equ FEAT_MAX, 256              # EXT_features' bits
.if FEAT_COUNT > FEAT_MAX
.error "more features than EXT_features holds"
.endif
# The snippet decoders take the first 32 feature bits as one word (EXT_features' first dword).
.if FEAT_SNIPPET_TRANSFORMS >= 32
.error "the snippet features must stay in EXT_features' first dword"
.endif
# FEAT_TEST base, FEAT_X: ZF clear (jnz) when the extension at base agreed FEAT_X
.macro FEAT_TEST base, feat
    test byte ptr [\base + EXT_features + ((\feat) >> 3)], 1 << ((\feat) & 7)
.endm
# the kinds of request rhun sends providers (query.s's pk_table rows)
.equ PK_COMPLETE, 0
.equ PK_RESOLVE, 1               # complete-resolve
.equ PK_SIGNATURE, 2
.equ PK_HOVER, 3
.equ PK_DEFINITION, 4
.equ PK_DECLARATION, 5
.equ PK_TYPEDEF, 6
.equ PK_IMPLEMENTATION, 7
.equ PK_REFERENCES, 8
.equ PK_SYMBOLS, 9
.equ PK_WSYMBOLS, 10
.equ PK_SELECTION, 11
.equ PK_CALLH, 12                # call-hierarchy
.equ PK_TYPEH, 13                # type-hierarchy
.equ PK_HIERCALLS, 14            # calls-in, calls-out, supertypes, subtypes
.equ PK_ACTIONS, 15
.equ PK_ACTIONS_AUTO, 16         # code actions asked for the lightbulb
.equ PK_ACTION_RESOLVE, 17
.equ PK_PREPARE_RENAME, 18
.equ PK_RENAME, 19
.equ PK_FORMAT, 20
.equ PK_RANGE_FORMAT, 21
.equ PK_TYPE_FORMAT, 22
.equ PK_LINKS, 23
.equ PK_SAVE_ACTIONS, 24
.equ PK_COMMIT_MESSAGE, 25       # source control (scmext.s)
.equ PK_QUICKDIFF, 26
.equ PK_TESTS_RESOLVE, 27        # testing (testproto.s)
.equ PK_TEST_RUN, 28
.equ PK_TRANSCRIPT, 29           # AI: agent-transcript (agentext.s)
.equ PK_TOOL, 30                 # AI: tool, a call routed to its owner (tools.s)
.equ PK_PROMPT, 31               # AI: agent-prompt (agentext.s, D4)
.equ PK_NB_OPEN, 32              # notebooks: nb-open, nb-save (nbproto.inc)
.equ PK_NB_SAVE, 33
.equ PK_FOLDING, 34              # editor presentation (present.s)
.equ PK_TOKENS, 35
.equ PK_HINTS, 36
.equ PK_LENS, 37
.equ PK_INLINE, 38
.equ PK_COLORS, 39
.equ PK_COLOR_EDIT, 40
.equ PK_HIGHLIGHTS, 41
.equ PK_LINKED, 42               # wsedit: linked-editing ranges (wslinked.s)
.equ PK_ED_OPEN, 43              # custom editors: editor-open, editor-save, undo/redo/revert (ceproto.inc)
.equ PK_ED_SAVE, 44
.equ PK_ED_CMD, 45
.equ PK_DEBUG_RESOLVE, 46        # debugger: debug-resolve (debugext.s)
.equ PK_COUNT, 47
# who asked (query.s routes parts and expiries to them)
.equ QO_LANGFEAT, 1
.equ QO_COMPLETE, 2
.equ QO_SAVE, 3
.equ QO_SCM, 4                   # source control (scmext.s)
.equ QO_TESTS, 5                 # testing (testproto.s)
.equ QO_AI, 6                    # AI: agentext.s and tools.s (ai_query_expired)
.equ QO_NOTEBOOK, 7               # nbdoc.s's nb_reply
.equ QO_PRESENT, 8               # editor presentation (present.s)
.equ QO_LINKED, 9                # wsedit: linked editing (wslinked.s)
.equ QO_CUSTOM, 10               # customed.s's ce_reply
# FEAT_CLEAR base, FEAT_X: the feature is not agreed (wsedit: features withheld after hello)
.macro FEAT_CLEAR base, feat
    and byte ptr [\base + EXT_features + ((\feat) >> 3)], ~(1 << ((\feat) & 7)) & 0xff
.endm
.equ CP_MAX_ITEMS, 4096          # section 12b: a completion list's items and body at most
.equ CP_BODY_MAX, 1048576
.equ SG_BODY_MAX, 65536          # 12c: signature help's body
.equ REPLY_BODY_MAX, 4194304     # any answer's body (a workspace edit, 12g); each feature has its own cap
.equ ID_COMPLETE, 0x7800         # + row: the completion list's rows
.equ ICON_SLOTS, 4              # badge sizes an extension's icon is kept at
.equ ICON_MAXBYTES, 65536       # an extension's icon file, at most
.equ ICON_MAXDIM, 256           # and its width and height
.equ IMG_MAXPX, 1 << 26

# decoded image
STRUCT
F IMG_px, 8             # premultiplied ARGB, w * h (mem_alloc_try)
F IMG_w, 4
F IMG_h, 4
F IMG_fmt, 4            # IMF_*
F IMG_opaque, 4         # 1 when every pixel is opaque
ENDSTRUCT IMG_SIZE

# a PNG icon read once and kept at the size last drawn (iconspec.s icon_png_draw)
STRUCT
F PIC_state, 4          # 0 not read, 1 read, 2 cannot be shown
F PIC_mask, 4           # 1: drawn as its alpha in a color
F PIC_img, IMG_SIZE
F PIC_size, 8           # the kept copy's size
F PIC_px, 8             # the kept copy, or 0
ENDSTRUCT PIC_SIZE
# an explorer icon from a file icon theme (iconth.s)
.equ ITV_RHUN, -1               # rhun's own icon
.equ ITV_NONE, 0x20000000       # no icon
.equ ITV_IMAGE, 0x40000000      # | slot << 16 | the theme's icon

# ---- app ----
.equ TAB_DOC, 1
.equ TAB_SETTINGS, 2
.equ TAB_IMAGE, 3               # TAB_doc is a DOC without text; DOC_img holds the view
.equ TAB_GIT, 4
.equ TAB_EXT, 5                 # the Extensions page (extpage.s)
.equ TAB_VIEW, 6                # an extension's view (extview.s); TAB_flags >> TF_VIEW_SHIFT is its slot + 1
.equ TAB_NOTEBOOK, 120          # a notebook (nbview.s): TAB_doc is a DOC without text, DOC_nb its NB (notebooks' block 120-123)
.equ TF_VIEW_SHIFT, 16
.equ ID_VIEW, 0x7700            # + slot: a view's area
.equ VW_MAX, 32                 # views open at once, all extensions
.equ VIEWS_PER_EXT, 8
.equ VIEW_BODY_MAX, 1048576     # a draw body
.equ VIEW_SHAPES_MAX, 20000
.equ VIEW_POINTS_MAX, 10000     # points of one poly or fill
.equ ID_XB_PUZZLE, 0x7400       # the extensions button in the title bar; + 1 + i: a pinned one
STRUCT
F TAB_kind, 8
F TAB_doc, 8
F TAB_flags, 8
ENDSTRUCT TAB_SIZE
# TAB_flags
.equ TF_PIN, 1                  # pinned: the pinned tabs are the first ones in the strip
.equ TF_RVIEW, 2                # TAB_VIEW: a retained view's tab (rview.s); the slot field is its instance
.equ TF_CUSTOM, 4               # custom editors: a TAB_VIEW tab that is an extension's editor of TAB_doc

.equ SIDEBAR_W_DEFAULT, 240        # points: the explorer's and the agents panel's widths
.equ AGENTS_W_DEFAULT, 380

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
.equ FOCUS_AGENT_INPUT, 56      # AI (D4): the prompt box of an extension's agent session

# grammar (syntax definition)
STRUCT
F GR_name, 8
F GR_files, 8           # space separated patterns
F GR_first, 8           # first-line prefixes (shebang)
F GR_icon, 8            # explorer icon: icon and color names
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
F GR_ficon, 8           # GR_icon read by file_icon (0 until then)
F GR_lckeys, 8          # language configuration keys the grammar sets (langconf.s), or 0
F GR_ext, 8             # the extension it came from (syntax_add_dir), or 0
ENDSTRUCT GR_SIZE
.equ SN_EXACT, 0x10000           # syntax_for_name: an exact name fits
.equ GF_NOCASE, 1
.equ GF_FUNCS, 2
.equ GF_CAPTYPES, 4
.equ GF_MARKUP, 8
.equ GF_LABELS, 16
.equ GF_NUMBERS, 32
.equ GF_OPS, 64
.equ GF_COLON, 128          # indent after a line ending with ":"
.equ GF_USER, 256           # from ~/.config/rhun/syntax: its language keys win over extensions'
.equ GF_COLON_SET, 512      # colon_indent is in the file (yes or no)
.equ GF_IDENT_SET, 1024     # ident is in the file

# lc_type's plan for a typed character (langconf.s)
STRUCT
F LTP_kind, 4           # LTK_*
F LTP_clen, 4
F LTP_close, 8          # LTK_PAIR: the CLOSE to put after the caret; LTK_WRAP: its byte
F LTP_from, 8           # LTK_OUTDENT: the line's start
F LTP_text, 8           # and the text for [LTP_from, end)
F LTP_tlen, 8
ENDSTRUCT LTP_SIZE
.equ LTK_PLAIN, 0
.equ LTK_PAIR, 1
.equ LTK_OVER, 2
.equ LTK_WRAP, 3
.equ LTK_OUTDENT, 4

STRUCT
F REG_start, 16
F REG_end, 16           # empty = end of line
F REG_slen, 1
F REG_elen, 1
F REG_class, 1
F REG_esc, 1
F REG_multi, 1
F REG_bol, 1            # only at line start (after blanks)
F REG_word, 1           # opener has identifier boundaries on both sides
F REG_pad, 1
ENDSTRUCT REG_SIZE

# prompt kinds (palette used as a one-line input)
.equ PROMPT_SAVE_AS, 1
.equ PROMPT_NEW_FILE, 2
.equ PROMPT_NEW_FOLDER, 3
.equ PROMPT_RENAME, 4
.equ PROMPT_ASK, 5              # an extension's text prompt (ask)
.equ PROMPT_TERM, 6             # an extension's command for the terminal (term)
.equ PROMPT_EXT_INSTALL, 7      # Install from GitHub: owner/name
.equ PROMPT_EXT_SETTING, 8      # a text setting of an extension (extpage.s)
.equ PROMPT_RENAME_SYMBOL, 9    # the new name of a symbol (langfeat.s)
.equ PROMPT_REMOTE, 40          # remote hosts: a question for ssh, answered in plain text (remoteui.s)
.equ PROMPT_REMOTE_SECRET, 41   # remote hosts: a password or passphrase, drawn masked
# extension management: development installs (extinstall.s)
.equ PROMPT_EXT_FOLDER, 20      # Install from Folder: the folder, copied
.equ PROMPT_EXT_LINK, 21        # Link a Folder: the folder, linked
.equ PROMPT_EXT_ARCHIVE, 22     # Install from Archive: the .tar.gz
.equ PROMPT_WS_SAVE, 100        # resources group (block 100-103): Save Workspace As's file (workspace.s)

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

# ---- extensions (src/app/ext.s, extproto.s) ----
STRUCT
F EXT_name, 8           # cstr, the folder name ("echo")
F EXT_owner, 8          # cstr, the parent folder name
F EXT_title, 8          # cstr
F EXT_version, 8        # cstr
F EXT_dir, 8            # cstr, the extension folder
F EXT_state, 8          # cstr, its writable state folder
F EXT_prog, 8           # cstr, the program to run (the runtime for a script), or 0 when unusable
F EXT_script, 8         # cstr, the script given to the runtime, or 0
F EXT_args, 8           # cstr, extra arguments (space separated), or 0
F EXT_on, 4             # ON_* bits
F EXT_needs, 4          # NEEDS_* bits
F EXT_manifest_ok, 4    # full manifest validation passed; failed installs cannot be restarted
F EXT_status, 4         # ES_*
F EXT_pid, 4
F EXT_in, 4             # the pipe to the program's input, -1 when not running
F EXT_out, 4            # the pipe from its output
F EXT_log, 4            # its error output, a file
F EXT_hello, 4          # 1 once hello arrived
F EXT_crashes, 4        # within the current minute
F EXT_syntax_errs, 4    # in a row
F EXT_flood, 4          # frames in a row that used up the budget
F EXT_cmd0, 4           # its commands: first index into g_ext_cmds and count
F EXT_ncmd, 4
F EXT_reason, 8         # cstr, why it is stopped or failed, or 0
F EXT_started, 8        # time_ms of the start (hello deadline) or of the stop request (bye)
F EXT_crash_t0, 8       # time_ms of the first crash in the window
F EXT_full_since, 8     # time_ms since the outgoing queue has been full, 0 when not
F EXT_rbuf, SB_SIZE     # bytes read from the program, not yet parsed
F EXT_wq, SB_SIZE       # bytes to write to the program
F EXT_wq_off, 8         # of them, already written
F EXT_body, 8           # a pending message that waits for its body (owned cstr), or 0
F EXT_body_len, 8       # that body's length
F EXT_on_langs, 8       # cstr lists for on = lang:X and on = open:GLOB, or 0
F EXT_on_globs, 8
F EXT_sub_opened, 8     # [subscribe] patterns per event (cstr) or 0 when not subscribed
F EXT_sub_saved, 8
F EXT_sub_changed, 8
F EXT_sub_cursor, 8
F EXT_sub_selection, 8
F EXT_sub_edits, 8
F EXT_sub_hover, 8
F EXT_status_text, 8    # cstr, its status-bar text, or 0
F EXT_known, VEC_SIZE   # XK records: the documents this extension has seen, and what it was told
F EXT_active, 8         # DOC id last reported active, -1 before catch-up
F EXT_pending, 8 # owned exact PN request, or0; never a command index
F EXT_throttled, 4      # 1 while its reads wait for the next frame's budget
F EXT_wait_slot, 4      # 1 while it waits for a process slot
F EXT_fbytes, 8         # bytes parsed in the current 16 ms window
F EXT_win_t0, 8         # when that window began
F EXT_win_msgs, 8       # messages parsed in it
F EXT_win_hit, 4        # 1 when the window reached a cap (the rest waited)
F EXT_global_wait, 4    # shared parse budget, separate from this extension's flood limits
F EXT_global_until, 8   # deadline of the shared window that actually blocked this program
F EXT_in_closed_at, 8   # time_ms when the program closed its input, 0 otherwise
F EXT_mname, 8          # the manifest's name and owner (checked against the folders)
F EXT_mowner, 8
F EXT_rtcmds, 4         # commands registered at runtime (removed when it stops)
F EXT_confined, 4       # CONFINED_* of the running program
F EXT_runs, 8           # cstr: the [needs] run list (program names), or 0
F EXT_pinned, 4         # 1: its button is in the title bar (extensions.ini)
F EXT_disabled, 4       # 1: turned off (extensions.ini)
F EXT_edits, 4          # wsedit: 1: may change project files without asking (extensions.ini, the user allowed it)
F EXT_edits_pad, 4
F EXT_confine_why, 8    # cstr: why rhun cannot hold it to its permissions on this system, or 0
F EXT_restart, 4        # 1: start again once the stop in progress completes (a settings change)
F EXT_noconfine, 4      # 1: confinement failed in the child once: it runs without (EXT_confine_why)
F EXT_desc, 8           # cstr: the manifest's description, or 0
F EXT_sdefs, VEC_SIZE   # SD records: its own settings ([settings] in the manifest)
F EXT_color, 4          # the badge's background from the manifest's color (ARGB), 0 without
F EXT_icon_state, 4     # 0 not read yet, 1 read, 2 cannot be shown (the letter stands in)
F EXT_icon, 8           # cstr: the manifest's icon, a PNG in the extension's folder, or 0
F EXT_icon_img, IMG_SIZE    # the decoded icon
F EXT_icon_px, 8*ICON_SLOTS   # copies at the sizes badges ask for, corners rounded
F EXT_icon_sz, 4*ICON_SLOTS
F EXT_icon_next, 4      # the slot the next new size replaces
F EXT_icon_pad, 4
F EXT_features, FEAT_MAX / 8    # bit FEAT_*: what was agreed after hello (section 12 of the spec)
F EXT_feat_asks, 4      # 1 when an agreed feature has rhun send requests (its replies are read)
F EXT_feat_pad, 4
F EXT_pv_complete, 8    # [provides] complete: the files it completes in (patterns, cstr) or 0
F EXT_pv_ctrig, 8       # complete.triggers: characters that ask at once, space separated, or 0
F EXT_pv_signature, 8   # signature: the files it gives signature help in, or 0
F EXT_pv_strig, 8       # signature.triggers
F EXT_hreq, 8           # the id of the last request rhun sent it (ids are never reused)
F EXT_pv_definition, 8  # [provides] definition, references, symbols, actions, rename, format
F EXT_pv_references, 8
F EXT_pv_symbols, 8
F EXT_pv_actions, 8
F EXT_pv_rename, 8
F EXT_pv_format, 8
F EXT_pv_save_actions, 8
# source control (wider-parity C): [provides] commit_message, quickdiff, scm (cstr values or 0)
F EXT_pv_commit, 8      # "yes": a commit-message provider (scmext.s)
F EXT_pv_quickdiff, 8   # file patterns it gives quick-diff bases for
F EXT_pv_linked, 8      # wsedit: [provides] linked: patterns of documents it links ranges in
F EXT_pv_scm, 8         # "yes": it registers VCS provider tabs
F EXT_pv_tests, 8       # testing: [provides] tests, the files it has tests in (patterns, cstr) or 0
F EXT_tests_profiles, 8 # tests.profiles: run kinds it offers besides run (cstr) or 0
F EXT_tests_progs, 8    # [needs] tests: programs rhun may start for its test runs (cstr) or 0
# language features (query.s): the [provides] keys of 0.18's kinds, provider-scope's narrowed
# values and the session's statistics per kind
F EXT_pv_hover, 8       # [provides] hover: patterns, cstr, or 0
F EXT_pv_declaration, 8
F EXT_pv_type_definition, 8
F EXT_pv_implementation, 8
F EXT_pv_selection_ranges, 8
F EXT_pv_call_hierarchy, 8
F EXT_pv_type_hierarchy, 8
F EXT_pv_workspace_symbols, 8
F EXT_pv_range_format, 8
F EXT_pv_type_format, 8
F EXT_pv_ttrig, 8       # type_format.triggers
F EXT_pv_document_links, 8
# editor presentation (present.s): [provides] keys
F EXT_pv_semantic_tokens, 8
F EXT_pv_inlay_hints, 8
F EXT_pv_code_lens, 8
F EXT_pv_inline_complete, 8
F EXT_pv_colors, 8
F EXT_pv_highlights, 8
F EXT_pv_folding, 8
F EXT_scope, VEC_SIZE   # SC records: [provides] values narrowed at run time (provider-scope)
F EXT_qstats, 8         # PK_COUNT QS records (query.s), allocated on first use, or 0
F EXT_fdsrc, VEC_SIZE   # PS*: its file-diagnostics sources in the Problems store (filediag.s)
F EXT_pv_notebook, 8    # notebooks: [provides] notebook (patterns), notebook.title, notebook.kernel
F EXT_pv_nbtitle, 8
F EXT_pv_nbkernel, 8
F EXT_nb_kernels, 8     # [needs] kernels: programs rhun may start as the user for its notebooks (cstr) or 0
F EXT_pv_editor, 8      # custom editors: [provides] editor (patterns), editor.title, editor.model, editor.priority
F EXT_pv_edtitle, 8
F EXT_pv_edmodel, 8
F EXT_pv_edprio, 8
# WebAssembly extensions (extwasm.s)
F EXT_wasm, 8           # cstr: run.wasm32-wasip1's module (in the extension's folder), or 0
F EXT_wasm_run, 4       # 1: EXT_prog is rhun itself, running EXT_wasm in its --wasm-host mode
F EXT_wasm_pad, 4
# extension management (extrecord.s, extinstall.s, extupdate.s)
F EXT_rec, 8            # cstr: its install record (.rhun-install), or 0
F EXT_inst, 8           # cstr: a linked install's stub folder (EXT_dir is the linked folder), or 0
F EXT_prev, 8           # cstr: the version of its previous version (Roll back), or 0
F EXT_pack, 8           # cstr: a pack's members (OWNER/NAME, space separated), or 0
F EXT_xset, 8           # cstr: "setting.KEY = VALUE" lines its manifest does not declare, or 0
F EXT_fresh, 4          # 1: a new version with a previous one to go back to, until its first hello
F EXT_mgmt_pad, 4
# remote hosts (remoteext.s)
F EXT_where_local, 4    # 1: where = local: in a remote window it runs on this machine
F EXT_remote_wait, 4    # 1: its Linux build is being fetched; it starts when it is here
# data extensions (ext.s)
F EXT_prog_wanted, 4    # the manifest names a program (run, run.TARGET for any target, runtime) or
                        # what only one can do ([commands], [provides])
F EXT_data, 4           # 1: a data extension: none of those and no pack; its data files load, it never starts
ENDSTRUCT EXT_SIZE

# an extension's view (extview.s)
STRUCT
F VW_ext, 8             # its extension, 0 when the slot is free
F VW_title, 8           # cstr, mem_alloc'd
F VW_pic, SB_SIZE       # the picture, compiled into records
F VW_px, 8              # its pixels, VW_pw x VW_ph, rendered from the picture
F VW_id, 4              # the number the extension knows it by
F VW_pw, 4
F VW_ph, 4
F VW_dirty, 4           # to be rendered again before it is shown
F VW_lw, 4              # the size last sent, logical pixels (-1: none yet)
F VW_lh, 4
F VW_theme, 4           # the theme and background it was rendered with
F VW_bg, 4
F VW_in, 4              # the pointer is over it
F VW_mx, 4              # where the pointer was last said to be, logical
F VW_my, 4
F VW_shapes, 4          # how many shapes the picture has
F VW_scale, 4           # g_s's bits when the metrics were last sent
F VW_sx, 4              # where it was last drawn, physical (tests point at it)
F VW_sy, 4
F VW_down, 4             # the left button went down over it and is still down
F VW_fgen, 4             # g_face_gen when the metrics were last sent
F VW_ax, 4               # where the button went down, logical: a click is a release near it
F VW_ay, 4
F VW_pl, 4              # views group: a tab picture's place item for the keyboard, + 1 (0: none)
F VW_inplace, 4         # views group: 1 a picture view's instance (a place), 2 hosted elsewhere (a custom editor)
ENDSTRUCT VW_SIZE
.equ EXT_CAP, 128               # extension records; g_exts never moves (EXT* are held elsewhere)
.equ EXT_MANIFEST_MAX, 65536    # extension.ini, discovery and install preview
# extension management (extinstall.s, extupdate.s): where an install comes from, why it runs, and
# how an update ended
.equ IK_GITHUB, 0               # a release on GitHub (or RHUN_EXT_BASE)
.equ IK_ARCHIVE, 1              # a release archive on this computer
.equ IK_FOLDER, 2               # a folder, copied
.equ IK_LINK, 3                 # a folder, linked (development)
.equ IP_ADD, 0                  # Add: the permission dialog
.equ IP_UPDATE, 1               # an update asked for: a dialog when unreviewed or wider
.equ IP_AUTO, 2                 # an automatic update: never asks; wider waits
.equ XU_UPDATED, 0
.equ XU_ASKS, 1                 # it asks for more access: waits for the user
.equ XU_FAILED, 2
.equ XU_CANCELLED, 3
.equ XS_NONE, 0                 # extupdate_state: current, or nothing known
.equ XS_AVAILABLE, 1
.equ XS_ASKS, 2                 # it asks for more access: waits for the user
.equ XS_SKIPPED, 3              # the version rolled back from
.equ XS_ERROR, 4
.equ XM_INSTALL, 0              # [updates] extensions (cfg_ext_updates)
.equ XM_CHECK, 1
.equ XM_OFF, 2
.equ FOCUS_EXT_SEARCH, 30       # the Extensions page's Browse search (extpage.s)
# an entry of the rhun extensions index (extindexfile.s): pointers to cstrs, 0 when absent
STRUCT
F XI_name, 8                    # "owner/name"
F XI_title, 8
F XI_desc, 8
F XI_version, 8
F XI_tag, 8
F XI_digest, 8                  # sha256 of this system's archive, or 0
F XI_category, 8
F XI_keywords, 8
F XI_needs, 8                   # KEY=VALUE words (run=a,b)
F XI_rhun, 8                    # the oldest rhun it works with, or 0
F XI_pack, 8
F XI_color, 4                   # ARGB, 0 without
F XI_featured, 4
ENDSTRUCT XI_SIZE
.equ XI_FIELDS, 11              # the pointer fields above, in order
# an extension's own setting: [settings] in its manifest, its value in extensions.ini
STRUCT
F SD_key, 8             # cstr
F SD_title, 8           # cstr, or 0 (the key is shown)
F SD_desc, 8            # cstr, or 0
F SD_default, 8         # cstr, or 0 (empty)
F SD_value, 8           # cstr, owned: the value in force
F SD_opts, 8            # cstr: a choice's options, space separated, or 0
F SD_type, 4            # SDT_*
F SD_min, 4
F SD_max, 4
F SD_scope, 4          # resources group (extconfig.s): ECL scope in bits 0-1, SDS_LANGUAGES
ENDSTRUCT SD_SIZE
.equ SDS_LANGUAGES, 4   # KEY.languages = yes: KEY@LANG values apply
.equ SDT_STRING, 0
.equ SDT_BOOL, 1
.equ SDT_INT, 2
.equ SDT_CHOICE, 3
.equ EXT_RTCMDS_MAX, 64         # register: commands per extension
.equ EXT_CHOOSE_MAX, 1000       # choose: items
.equ EXT_TERM_MAX, 4096         # term: the command's bytes

# ---- resources, workspaces, secrets and lifecycle (extres.s and the files it names) ----
# a request rhun asked an extension, for the cost counters: answered slow, dropped or failed
STRUCT
F ELQ_id, 8
F ELQ_t, 8               # time_ms it went out
F ELQ_kind, 8            # cstr: its verb ("complete"), for "slowest"
F ELQ_cancelled, 8       # 1 after rhun sent 0 cancel ID
ENDSTRUCT ELQ_SIZE
.equ ELQ_MAX, 16                 # outstanding requests remembered per extension
# per extension, beside each EXT slot (extres_row): EL for "extension lifecycle": lifecycle and cost
STRUCT
F EL_last_work, 8       # time_ms of the last message either way
F EL_msgs_in, 8
F EL_msgs_out, 8
F EL_bytes_in, 8
F EL_bytes_out, 8
F EL_start_t, 8         # time_ms of the current run's start, 0 when it is not running
F EL_cpu_ns, 8          # the last sample: CPU nanoseconds of its processes, and when it was taken
F EL_cpu_t, 8
F EL_cpu0_ns, 8         # the older sample the rate "now" is measured from
F EL_cpu0_t, 8
F EL_rss, 8             # resident bytes of its live processes at the last sample
F EL_slowest, 8         # cstr: the kind of the slowest answer, or 0
F EL_contains, 8        # cstr: its on = contains: patterns, or 0
F EL_schemes, 8         # cstr: [provides] schemes, or 0
F EL_skeys, 8           # cstr: its stored secrets' keys, each followed by LF, as last read, or 0
F EL_ready_ms, 4        # the last start: milliseconds until hello
F EL_procs, 4           # processes at the last sample
F EL_slow, 4
F EL_dropped, 4
F EL_failed, 4
F EL_slowest_ms, 4
F EL_idle_cfg, 4        # idle.after in seconds, 0 when the manifest does not say
F EL_busy, 4            # 1 after busy yes
F EL_flags, 4           # ELF_*
F EL_starts, 4          # starts this session
F EL_nreq, 4            # entries in EL_req
F EL_pad, 4
F EL_req, ELQ_SIZE*ELQ_MAX
ENDSTRUCT EL_SIZE
.equ ELF_IDLE, 1                # idle = stop
.equ ELF_IDLE_STOPPING, 2       # the stop in progress is for idleness: it returns to idle
.equ ELF_OPEN_URLS, 4           # open_urls = yes: open-url opens without asking
.equ ELF_RUNS_LOCAL, 8          # runs = local
.equ ELF_STARTUP, 16            # this run started for on = startup (print-startup)
.equ ELF_SKEYS_ASKED, 32        # its page asked the store for the keys
.equ ELF_SECRETS_TOLD, 64       # the toast about secrets kept in memory was shown
.equ IDLE_AFTER_DEFAULT, 300    # seconds
.equ EXT_STARTS_PER_FRAME, 4    # on = startup and waiting extensions start at most this many a frame
# a secret request (secrets.s); src/mac/keychain.s reads the first fields by these offsets
.equ SECRET_KEY_MAX, 64
.equ SECRET_VALUE_MAX, 8192
.equ SECRET_KEYS_MAX, 64        # keys per extension
.equ SECRET_OUTSTANDING, 8      # requests per extension
.equ SECRET_BUF, 12288          # an answer: a value, or every key and its LF
STRUCT
F SECR_op, 4              # SO_*
F SECR_status, 4          # SS_*
F SECR_fd, 4              # macOS: the pipe the keychain's worker reports on
F SECR_pad, 4
F SECR_service, 8         # owned cstr: the store's service name for the extension
F SECR_key, 8             # owned cstr, or 0 (keys, clear)
F SECR_val, 8             # owned value (set), or 0
F SECR_len, 8
F SECR_outlen, 8          # the answer's bytes in SECR_buf
F SECR_next, 8            # the queue
F SECR_ext, 8
F SECR_id, 8              # the request's id, 0 for rhun's own (the page, a removal)
F SECR_gen, 8             # EL_starts when it was asked: an answer for an earlier run is dropped
F SECR_buf, SECRET_BUF
ENDSTRUCT SECR_SIZE
.equ SECO_GET, 1
.equ SECO_SET, 2
.equ SECO_DELETE, 3
.equ SECO_KEYS, 4
.equ SECO_CLEAR, 5                # every key of the extension
.equ SECS_OK, 0
.equ SECS_NONE, 1                 # get: nothing stored under the key
.equ SECS_REFUSED, -1             # locked and the unlock was cancelled, or access was denied
.equ SECS_NOSTORE, -2             # no store is available
.equ SECS_TOOBIG, -3              # 64 keys already
.equ SECB_SYSTEM, 0               # [extensions] secrets
.equ SECB_MEMORY, 1
.equ SECB_FILE, 2

# ---- contributions and commands (invoke.s, when.s, extcontext.s) ----
# How a command was invoked (feature command-args): cmd_invoke takes these as arguments and
# ext_cmd_run sends them as "0 run EXT.NAME DOC FROM LEN" + body
.equ INV_PALETTE, 0             # the palette, headless cmd, a menu of all commands (the default)
.equ INV_KEY, 1                 # a key binding; body: its ARGS
.equ INV_MENU, 2                # a menu item or title/item button; body: TARGET LF and its args
.equ INV_REF, 3                 # a command reference (lens, tree item, status item, notification)
STRUCT
F INV_from, 4           # INV_*
F INV_pad, 4
F INV_doc, 8            # the DOC id it is about, 0 for the active document
F INV_body, 8           # ptr, len: the body
F INV_len, 8
ENDSTRUCT INV_SIZE
.equ INV_BODY_MAX, 65536        # a body kept for a command that waits for its extension to start
# a command reference: "command NAME ARGS_LEN" + ARGS inside any body (cmdref_parse, cmdref_new)
STRUCT
F CRF_ext, 8            # EXT* whose command it names
F CRF_len, 8            # ARGS' length; the bytes follow the record
F CRF_name, 48          # the local command name, NUL-terminated (at most 40 bytes)
ENDSTRUCT CRF_SIZE
.equ CRF_ARGS_MAX, 8192
.equ CMD_NAME_MAX, 40           # a local command name: [a-z0-9_], 1 to 40 bytes
# When-clause context keys (when.s), one line each: CTXKEY SYMBOL, "name", FN. FN computes the
# value from rhun's state when a clause reads it (when.s); 0 marks a key another part publishes
# with ctx_set(SYMBOL, ptr, len) / ctx_set_bool(SYMBOL, 0|1) (at most CTX_VAL_MAX bytes, copied).
# Adding a key is one line here, at the end.
.macro CTXKEY_LIST
    CTXKEY CTX_EDITOR_FOCUS, "editorFocus", ck_editor_focus
    CTXKEY CTX_TEXT_INPUT_FOCUS, "textInputFocus", ck_text_input_focus
    CTXKEY CTX_PALETTE_FOCUS, "paletteFocus", ck_palette_focus
    CTXKEY CTX_FIND_FOCUS, "findFocus", ck_find_focus
    CTXKEY CTX_EXPLORER_FOCUS, "explorerFocus", ck_explorer_focus
    CTXKEY CTX_AGENTS_FOCUS, "agentsFocus", ck_agents_focus
    CTXKEY CTX_TERMINAL_FOCUS, "terminalFocus", ck_terminal_focus
    CTXKEY CTX_SCM_INPUT_FOCUS, "scmInputFocus", ck_scm_focus
    CTXKEY CTX_SETTINGS_FOCUS, "settingsFocus", ck_settings_focus
    CTXKEY CTX_FIND_VISIBLE, "findVisible", ck_find_visible
    CTXKEY CTX_COMPLETION_VISIBLE, "completionVisible", ck_completion_visible
    CTXKEY CTX_SIGNATURE_VISIBLE, "signatureVisible", ck_signature_visible
    CTXKEY CTX_SNIPPET_ACTIVE, "snippetActive", ck_snippet_active
    CTXKEY CTX_ACTIVE_TAB, "activeTab", ck_active_tab
    CTXKEY CTX_ACTIVE_TAB_PINNED, "activeTabPinned", ck_active_tab_pinned
    CTXKEY CTX_TAB_COUNT, "tabCount", ck_tab_count
    CTXKEY CTX_RESOURCE_LANG, "resourceLang", ck_resource_lang
    CTXKEY CTX_RESOURCE_EXT, "resourceExt", ck_resource_ext
    CTXKEY CTX_RESOURCE_FILENAME, "resourceFilename", ck_resource_filename
    CTXKEY CTX_RESOURCE_DIRNAME, "resourceDirname", ck_resource_dirname
    CTXKEY CTX_RESOURCE_PATH, "resourcePath", ck_resource_path
    CTXKEY CTX_RESOURCE_SCHEME, "resourceScheme", ck_resource_scheme
    CTXKEY CTX_RESOURCE_IN_PROJECT, "resourceInProject", ck_resource_in_project
    CTXKEY CTX_EDITOR_READONLY, "editorReadonly", ck_editor_readonly
    CTXKEY CTX_EDITOR_DIRTY, "editorDirty", ck_editor_dirty
    CTXKEY CTX_EDITOR_HAS_SELECTION, "editorHasSelection", ck_editor_has_selection
    CTXKEY CTX_EDITOR_HAS_MULTIPLE_SELECTIONS, "editorHasMultipleSelections", ck_editor_multi
    CTXKEY CTX_EDITOR_PROVIDERS, "editorProviders", ck_editor_providers
    CTXKEY CTX_VIM_MODE, "vimMode", ck_vim_mode
    CTXKEY CTX_SIDEBAR_VISIBLE, "sidebarVisible", ck_sidebar_visible
    CTXKEY CTX_AGENTS_VISIBLE, "agentsVisible", ck_agents_visible
    CTXKEY CTX_TERMINAL_VISIBLE, "terminalVisible", ck_terminal_visible
    CTXKEY CTX_PROJECT_OPEN, "projectOpen", ck_project_open
    CTXKEY CTX_PROJECT_PATH, "projectPath", ck_project_path
    CTXKEY CTX_GIT_REPO, "gitRepo", ck_git_repo
    CTXKEY CTX_GIT_BRANCH, "gitBranch", ck_git_branch
    CTXKEY CTX_GIT_CHANGES, "gitChanges", ck_git_changes
    CTXKEY CTX_IS_LINUX, "isLinux", ck_is_linux
    CTXKEY CTX_IS_MAC, "isMac", ck_is_mac
    CTXKEY CTX_IS_WINDOWS, "isWindows", ck_is_windows
    CTXKEY CTX_IS_WAYLAND, "isWayland", ck_is_wayland
    CTXKEY CTX_TARGET_KIND, "targetKind", ck_target_kind
    CTXKEY CTX_EXPLORER_RESOURCE_IS_FOLDER, "explorerResourceIsFolder", ck_target_is_folder
    CTXKEY CTX_EXPLORER_RESOURCE_IS_ROOT, "explorerResourceIsRoot", ck_target_is_root
    CTXKEY CTX_TAB_KIND, "tabKind", ck_tab_kind
    # published by other parts (ctx_set): views, debugging
    CTXKEY CTX_VIEW_FOCUS, "viewFocus", 0
    CTXKEY CTX_VIEW, "view", 0
    CTXKEY CTX_VIEW_ITEM, "viewItem", 0
    CTXKEY CTX_DEBUG_STATE, "debugState", 0        # "inactive" until the debugger sets it
    CTXKEY CTX_IN_DEBUG_MODE, "inDebugMode", 0     # "false" until the debugger sets it
    CTXKEY CTX_DEBUG_TYPE, "debugType", 0
    # source control (wider-parity C): gitTrusted (git.s), and a row menu's target (scmext.s)
    CTXKEY CTX_GIT_TRUSTED, "gitTrusted", 0         # false while git is paused for a linked folder
    CTXKEY CTX_SCM_PROVIDER, "scmProvider", 0       # "git" or the provider extension's OWNER/NAME
    CTXKEY CTX_SCM_RESOURCE_GROUP, "scmResourceGroup", 0   # merge, staged, changes, or a provider's
    CTXKEY CTX_SCM_RESOURCE_STATUS, "scmResourceStatus", 0 # the resource's letter (M A D R C U ?)
    # notebooks (nbkeys.s)
    CTXKEY CTX_NOTEBOOK_FOCUS, "notebookFocus", ck_nb_focus
    CTXKEY CTX_NOTEBOOK_CELL_EDITING, "notebookCellEditing", ck_nb_editing
    CTXKEY CTX_NOTEBOOK_CELL_TYPE, "notebookCellType", ck_nb_cell_type
    CTXKEY CTX_NOTEBOOK_KERNEL_STATE, "notebookKernelState", ck_nb_kernel_state
    # remote hosts (remote.s): "ssh", "docker", "podman", "wsl", "local" in a remote window, else empty
    CTXKEY CTX_REMOTE_NAME, "remoteName", 0
    CTXKEY CTX_REMOTE_HOST, "remoteHost", 0
.endm
# when.s expands the list as records: FN, the name, padding to 8 bytes
.macro CTXKEY sym, name, fn
.ifdef CTXKEY_NAMES
    .quad \fn
    .asciz "\name"
    .p2align 3
.else
    .equ \sym, __ctxk
    .set __ctxk, __ctxk + 1
.endif
.endm
.set __ctxk, 0
CTXKEY_LIST
.equ CTX_COUNT, __ctxk
.equ CTX_VAL_MAX, 256           # a context value: published keys, set-context
.equ WHEN_MAX, 512              # a clause's bytes, operations and nesting
.equ WHEN_OPS_MAX, 64
.equ WHEN_DEPTH_MAX, 8
# a menu target the resource and editor keys describe while a menu evaluates (ctx_push_target)
STRUCT
F MTG_kind, 8            # cstr: "editor" "file" "folder" "root" "tab" "terminal" "extension"
                        #   "view" "item" (targetKind), or 0 for no target
F MTG_doc, 8             # its DOC*, or 0
F MTG_path, 8            # cstr: its path, or 0
F MTG_tabkind, 8         # cstr: tabKind ("doc" "image" "settings" "git" "extensions" "view"), or 0
F MTG_view, 8            # cstr: the view a view_title / view_item target is in (the key view), or 0
F MTG_item, 8            # cstr: the targeted tree item's context value (the key viewItem), or 0
F MTG_scm, 8             # cstr: a source control target's provider, "git" or OWNER/NAME (the key
                        #   scmProvider while its menu or header buttons evaluate), or 0
ENDSTRUCT MTG_SIZE

# a prepared rule: struct landlock_path_beneath_attr (u64 allowed_access, s32 parent_fd), padded
STRUCT
F CR_access, 8
F CR_fd, 4
F CR_pad, 4
ENDSTRUCT CR_SIZE

# what an extension was last told about a document
STRUCT
F XK_id, 8
F XK_ver, 8
F XK_saves, 8
F XK_cur, 8
F XK_anchor, 8
F XK_seen, 8            # scratch: 1 when the document is still open (events pass)
F XK_eoff, 8            # edit records (DOC_xedits) delivered so far, as a byte offset
F XK_language_revision, 8
F XK_phase, 8           # XP_* accepted lifecycle prefix
F XK_text_ver, 8        # last accepted edit/resync/full-text baseline
F XK_resync, 8          # per-peer debt survives clearing DOC_xresync
F XK_replay, 8          # pending active1/cursor2/selection4 catch-up
F XK_selcur, 8          # cursor of last accepted selection, independent of XK_cur
F XK_selhash, 8         # feature selections: sel_hash of the selections last told (0: one caret)
ENDSTRUCT XK_SIZE
.equ XP_NEED_OPEN, 0
.equ XP_READY, 1
.equ XP_NEED_CLOSE, 2
.equ XP_POSITIONS, 3
.equ XP_DORMANT, 4       # no opened state; current path does not match the subscription

.equ ES_IDLE, 0                 # not started
.equ ES_STARTING, 1             # running, no hello yet
.equ ES_RUNNING, 2
.equ ES_STOPPING, 3             # bye sent, waiting before SIGTERM / SIGKILL
.equ ES_STOPPED, 4              # by the user or a limit: EXT_reason
.equ ES_CRASHED, 5              # exited on its own: EXT_reason
.equ ES_FAILED, 6               # could not start, or a bad manifest: EXT_reason
.equ ES_DISABLED, 7
.equ ES_REMOVED, 8              # uninstalled this session: hidden, its commands inert

.equ ON_STARTUP, 1
.equ ON_COMMAND, 2
.equ ON_LANG, 4
.equ ON_OPEN, 8
.equ ON_PROJECT, 16
.equ ON_CONTAINS, 0x100000         # resources group: on = contains:NAME

.equ NEEDS_DOC_READ, 1
.equ NEEDS_DOC_WRITE, 2
.equ NEEDS_PROJECT_READ, 4
.equ NEEDS_PROJECT_WRITE, 8
.equ NEEDS_HOME_READ, 16
.equ NEEDS_NETWORK, 32
.equ NEEDS_TERMINAL, 64
.equ NEEDS_GIT_READ, 128        # [needs] git = read: the project's Git data through rhun (gitdata.s)
.equ NEEDS_AUDIO, 0x2000000      # local audio devices and services
.equ NEEDS_SECRETS, 0x1000000      # resources group: [needs] secrets = yes

.equ EXT_MAX_RUNNING, EXT_CAP
.equ EXT_HELLO_MS, 5000
.equ EXT_LINE_MAX, 65536
.equ EXT_BODY_MAX, 4194304
.equ EXT_WQ_MAX, 1048576
.equ EXT_WQ_HARD, 8388608       # a queue this long ends the program at once
.equ EXT_LOG_MAX, 1048576
.equ EXT_READ_CHUNK, 65536      # one read
.equ EXT_WIN_MS, 16             # the window: a frame at 60 Hz
.equ EXT_WIN_BYTES, 262144      # per extension per window
.equ EXT_WIN_MSGS, 500
.equ EXT_GLOBAL_MS, 4           # all extension parsing per window (soft, complete handlers finish)
.equ EXT_GLOBAL_MSGS, 2000
.equ EXT_GLOBAL_BYTES, 1048576
.equ EXT_PUMP_MS, 2             # one parsing run
.equ EXT_FLOOD_FRAMES, 30       # windows in a row at a cap

# ---- testing (testmodel.s, testproto.s, testexec.s; feature "tests") ----
.equ TSK_CTRL, 0                # item kinds; the controller's own row is item 0
.equ TSK_GROUP, 1
.equ TSK_FILE, 2
.equ TSK_SUITE, 3
.equ TSK_TEST, 4
.equ TSS_NOTRUN, 0              # states, by precedence: a parent shows the highest of its own and
.equ TSS_SKIPPED, 1             # its children's
.equ TSS_PASSED, 2
.equ TSS_FAILED, 3
.equ TSS_ERRORED, 4
.equ TSS_QUEUED, 5
.equ TSS_RUNNING, 6
.equ TSS_COUNT, 7
.equ TSF_LAZY, 1                # item flags
.equ TSF_NODEBUG, 2
.equ TSF_EXPANDED, 4
.equ TSF_RESOLVING, 8           # a tests-resolve for its children is out
.equ TSF_MARK, 16               # scratch: kept by a replace
.equ TSF_SHOW, 32               # the Testing filter: shown (it or a descendant matches)
.equ TSF_FOPEN, 64              # the Testing filter: opened (a descendant matches)
.equ TSF_HIT, 128               # the Testing filter: its label or an ancestor's matches the text
.equ TSF_MOVE, 256              # scratch: a replace moves it (and its subtree) from elsewhere
.equ TSP_RUN, 0                 # run profiles (bit i of TSC_profiles)
.equ TSP_DEBUG, 1
.equ TSP_COVERAGE, 2
.equ TSRS_FREE, 0               # run states
.equ TSRS_QUEUED, 1             # waiting for a run slot: test-run not sent yet
.equ TSRS_RUNNING, 2
.equ TSRS_ENDED, 3
.equ TS_ITEMS_BODY, 10000       # items per test-items body or tests-resolve answer
.equ TS_ITEMS_EXT, 50000        # per controller
.equ TS_ITEMS_ALL, 100000       # all controllers
.equ TS_ID_MAX, 512
.equ TS_LABEL_MAX, 200
.equ TS_DESC_MAX, 200
.equ TS_ERROR_MAX, 1000
.equ TS_RESULTS_BODY, 1048576   # a test-update body
.equ TS_RESULTS_MAX, 2000       # records in it
.equ TS_MSG_MAX, 8000           # a message's text
.equ TS_MSGS_ITEM, 16           # messages per item per run
.equ TS_VALUE_MAX, 65536        # expected, actual
.equ TS_OUT_ITEM, 262144        # an item's output per run
.equ TS_OUT_RUN, 4194304        # the run's own output
.equ TS_BUDGET, 33554432        # messages, values and outputs of all runs
.equ TS_RUNS_KEPT, 10           # finished runs kept
.equ TS_RUNS_EXT, 4             # active runs per controller
.equ TS_RUNS_ACTIVE, 8          # active runs in all
.equ TS_RUNS_MAX, 32            # run slots: active, queued and kept
.equ TS_RESOLVE_MS, 30000       # a tests-resolve answer waits this long
.equ TS_CANCEL_KILL_MS, 2000    # after Cancel: processes get SIGTERM, then SIGKILL as long again
.equ TS_CANCEL_END_MS, 5000     # and rhun ends the run itself
.equ TS_COVER_BODY, 4194304     # a test-coverage body
.equ TS_COVER_FILES, 20000      # files per run
.equ TS_COVER_RANGES, 1000000   # ranges per run
.equ TS_COVER_LINES, 1048576    # lines per file
.equ TS_EXEC_BODY, 262144       # a test-exec body
.equ TS_EXEC_ARGS, 1000
.equ TS_EXEC_ARG_MAX, 32768
.equ TS_EXEC_ENVS, 64
.equ TS_PROCS_RUN, 4
.equ TS_PROCS_ALL, 8
.equ TS_OUT_EVENT, 65536        # bytes per test-out event
.equ TS_QUEUE_PAUSE, 262144     # pipes wait while the extension's queue holds this much
.equ TS_PROGS_MAX, 16           # [needs] tests: program names
.equ TS_PROG_NAME, 64
.equ TS_CTRL_MAX, 64            # controllers (extensions with tests agreed or declared)
.equ TS_RESOLVE_MAX, 64         # tests-resolve requests out at once, all controllers
# a controller: an extension's test tree
STRUCT
F TSC_ext, 8            # its EXT, 0 for a free slot
F TSC_items, VEC_SIZE   # TSI records; item 0 is the controller's own row, the parent of its roots
F TSC_map, 8            # id -> item: u32 slots holding the item's index + 1, 0 empty
F TSC_mapcap, 8         # slots, a power of two
F TSC_mapn, 8           # slots in use
F TSC_free, 4           # first free item slot (TSI_next chains them), -1 none
F TSC_count, 4          # items besides row 0
F TSC_ready, 4          # 1 once its program agreed tests (roots asked); 0 again when it stops
F TSC_pad, 4
ENDSTRUCT TSC_SIZE
# a test item
STRUCT
F TSI_id, 8             # owned bytes with a NUL after them; 0 marks a free slot
F TSI_label, 8          # owned cstr
F TSI_desc, 8           # owned cstr or 0
F TSI_error, 8          # owned cstr or 0: a discovery problem, or a failed tests-resolve
F TSI_path, 8           # owned cstr or 0: the file its range is in
F TSI_msg, 8            # owned cstr or 0: the first line of its last result's first message
F TSI_phash, 8          # hash_line of TSI_path (0 without one): the gutter compares this first
F TSI_ver, 8            # the version of TSI_path's open document when the range came, -1 none:
                        #   the gutter moves the range through later edits (edtape.s)
F TSI_idlen, 4
F TSI_kind, 4           # TSK_*
F TSI_flags, 4          # TSF_*
F TSI_l1, 4             # its range, one-based; all 0 for none
F TSI_c1, 4
F TSI_l2, 4
F TSI_c2, 4
F TSI_parent, 4         # item indices, -1 for none
F TSI_first, 4
F TSI_last, 4
F TSI_next, 4
F TSI_prev, 4
F TSI_gen, 4            # bumped when the slot is freed: results name (index, gen)
F TSI_own, 4            # TSS_* of its own last result
F TSI_state, 4          # the highest of its own and its children's (derived)
F TSI_ms, 4             # its last duration, -1 none
F TSI_run, 4            # the run of its last result, 0 none (or dropped)
F TSI_rent, 4           # that result's entry in the run
F TSI_cnt, 4*TSS_COUNT    # its children by derived state
ENDSTRUCT TSI_SIZE
# a run
STRUCT
F TSR_ext, 8            # its controller's EXT, 0 for a free slot
F TSR_num, 8            # the run number (unique for the session)
F TSR_ids, SB_SIZE      # the items asked for, each ending in LF (none: everything)
F TSR_out, SB_SIZE      # the run's own output
F TSR_ents, VEC_SIZE    # TSE records
F TSR_t0, 8             # time_ms it started (was sent), and ended
F TSR_t1, 8
F TSR_cancel_at, 8      # time_ms of the user's Cancel, 0 none
F TSR_req, 8            # the id of its test-run request, 0 before it is sent
F TSR_bytes, 8          # messages, values and outputs it holds
F TSR_state, 4          # TSRS_*
F TSR_profile, 4        # TSP_*
F TSR_nids, 4
F TSR_dropped, 4        # records for unknown items
F TSR_procs, 4          # its live processes
F TSR_err, 4            # 1 when the run itself errored
F TSR_cut, 4            # 1 once output was cut for the budget
F TSR_killed, 4         # 1 once its processes were sent SIGTERM after a Cancel
ENDSTRUCT TSR_SIZE
# a result: one item in one run (item -1: the run itself)
STRUCT
F TSE_item, 4
F TSE_gen, 4
F TSE_state, 4          # TSS_*; NOTRUN when the run ended with it queued or running
F TSE_ms, 4
F TSE_prev_own, 4       # the item's result before this run touched it
F TSE_prev_ms, 4
F TSE_prev_run, 4
F TSE_prev_rent, 4
F TSE_nmsg, 4
F TSE_cut, 4            # 1 once its output was cut
F TSE_prev_msg, 8       # owned copy of the item's summary before this run touched it, or 0
F TSE_msgs, SB_SIZE     # messages: TSM header + text, path, expected, actual
F TSE_out, SB_SIZE      # its output
ENDSTRUCT TSE_SIZE
# a message's header in TSE_msgs
STRUCT
F TSM_l1, 4
F TSM_c1, 4
F TSM_l2, 4
F TSM_c2, 4
F TSM_text, 4           # lengths of the bytes after the header
F TSM_path, 4
F TSM_exp, 4            # -1: no expected value
F TSM_act, 4            # -1: no actual value
F TSM_ver, 8            # the version of the path's open document when it came, -1 none
ENDSTRUCT TSM_SIZE

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

# kitty keyboard protocol, per screen: +0 the flags in effect, +4 pushes kept, +8 the pushed flags
.equ KK_DEPTH, 8
.equ KK_BLOCK, 8 + 4 * KK_DEPTH
.equ KK_SUPPORTED, 1            # disambiguate escape codes
.equ KK_SIZE, 2 * KK_BLOCK      # the main and the alternate screen
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
F TM_kk, KK_SIZE        # kitty keyboard flags of the main and the alternate screen
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
F TM_tap, 8             # SB* that each finished line goes to (tasks' matchers), or 0
F TM_tapdrop, 8         # lines left out while the tap held 64 KB
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

# ---- agent session metadata and transcript state ----
STRUCT
F AS_path, 8
F AS_title, 8
F AS_mtime, 8
F AS_off, 8             # bytes parsed
F AS_msgs, VEC_SIZE     # AM
F AS_part, SB_SIZE      # incomplete trailing line
F AS_kind, 4            # 1 claude, 2 codex, 3 grok, 4 opencode
F AS_loaded, 4          # messages parsed (opened at least once)
F AS_titled, 4          # has a custom title
F AS_pad, 4
F AS_changed, 8         # time_ms of the last growth
F AS_stamp, 8           # file_stamp, to see every write
F AS_index_title, 8    # parent: last title returned by the metadata index
F AS_recency, 8        # nanosecond mtime used for ordering
F AS_cwd, 8            # worker cache: originating checkout
F AS_seen, 8           # worker cache: present in this scan
F AS_worktree, 8        # linked checkout's name, or 0 for the main checkout
F AS_prefix_hash, 8     # worker: bounded prefix identity for append detection
F AS_title_off, 8       # worker: bytes covered by the last successful title read
F AS_title_rev, 8       # identity of the last indexed custom title record
F AS_record_off, 8      # worker: current title record's newline offset plus one
F AS_replaced, 8        # worker page: metadata came from a replaced or truncated log
F AS_bytes, 8           # worker, OpenCode: the conversation copy's estimated size
F AS_model, 8           # the model the session last used (its row), or 0
F AS_log_model, 8       # parse: the model the log names for the replies that follow
F AS_shown_model, 8     # parse: the model on the last reply labeled with one
# AI (wider-parity D1): a row an extension lists (AS_kind 5) keeps its title, model, CWD (AS_cwd)
# and worktree in the fields above
F AS_ext, 8             # kind 5: the extension that lists it (EXT*)
F AS_sid, 8             # kind 5: its session id, cstr
F AS_state, 4           # kind 5: AGS_*
F AS_xflags, 4          # kind 5: AXF_*
F AS_total, 8           # kind 5: messages the extension says the session has
F AS_dirty, 8           # kind 5: the first message to fetch again, -1 when the copy is current
F AS_req, 8             # kind 5: the agent-transcript request in flight (its id), 0 when none
F AS_from, 8            # kind 5: the FROM of that request
F AS_ask, 8             # kind 5 (D4): the open card, an AK record, or 0
ENDSTRUCT AS_SIZE

# ---- debugger (DAP client): debugcfg.s, dapwire.s, dap.s, bp.s, debugconsole.s, debugctl.s ----
.equ NEEDS_DEBUG, 0x10000           # [needs] debug = yes: start debug adapters that run as the user
.equ DBG_MAX, 64                    # debuggers ([debugger.TYPE] sections), in all
.equ DBG_PER_EXT, 8
.equ DBG_ATTRS_MAX, 128             # attr.* per debugger
.equ DS_MAX, 8                      # sessions, child sessions included
.equ DS_PEND, 256                   # requests in flight per session
.equ DAP_BODY_MAX, 8388608          # one message
.equ DAP_CONNECT_MS, 10000          # tcp: the adapter accepts a connection within this
.equ DAP_COPY_MS, 60000             # remote window: an adapter's extension reaches the host within this
.equ DAP_CONNECT_EVERY, 100         # and is tried this often
.equ DAP_LOOPBACK, 0x0100007f       # 127.0.0.1 in network order
.equ DBGX_BODY_MAX, 1048576 + 256     # debug-start's body: NAME and a configuration body
.equ DCE_SYNTAX, 1                   # dcfg_from_leaves: the configuration body does not parse
.equ DCE_REFUSED, 2                  # its type is not one of the extension's debuggers
.equ DCE_ASK, 3                      # dcfg_prepare: a ${ask:} ${pick:} ${process} needs the user's answer
.equ DTR_STDIO, 0                   # DS_transport: the adapter's standard input and output
.equ DTR_TCP, 1                     # rhun picks a port, starts the adapter and connects
.equ DTR_SERVER, 2                  # launch.ini's server = HOST:PORT: no process
.equ DSK_getsockname, 51           # Linux system call numbers (the macOS shim converts them)
.equ DSK_getpeername, 52
.equ DSK_AF_INET, 2
.equ DSK_SOL_SOCKET, 1
.equ DSK_SO_ERROR, 4
.equ DSK_F_DUPFD, 0
.equ DSK_F_SETFD, 2
.equ DSK_FD_CLOEXEC, 1
.equ DSK_EINPROGRESS, 115
.equ DSK_EALREADY, 114
.equ DSK_EISCONN, 106
.equ DAP_HEADER_MAX, 1024
.equ DAP_WQ_MAX, 4194304            # bytes queued for one adapter
.equ DAP_NODES_MAX, 262144          # JSON values in one message
.equ DAP_DEPTH_MAX, 64
.equ DAP_MSGS_TICK, 64              # messages handled per session per frame
.equ DAP_TICK_US, 2000              # and time spent on them
.equ DAP_INIT_MS, 10000             # the initialize answer
.equ DAP_REQ_MS, 10000              # UI requests (stack, scopes, variables, evaluate)
.equ DAP_VARS_MAX, 20000            # variable nodes per stop
.equ DAP_STRS_MAX, 4194304          # their strings
.equ DAP_FRAMES, 20                 # frames asked for at a time
.equ DAP_THREADS_MAX, 1024
.equ DAP_EXPANDED_MAX, 512
.equ BP_MAX, 4096
.equ BP_PER_FILE, 1000
.equ WATCH_MAX, 64

# debugger: a [debugger.TYPE] section of an extension's manifest
STRUCT
F DBG_ext, 8            # EXT*
F DBG_type, 8           # cstr
F DBG_title, 8          # cstr or 0
F DBG_languages, 8      # cstr: grammar names, space separated, or 0
F DBG_program, 8        # cstr: names tried in order, or a path inside the extension (with a /)
F DBG_program_t, 8      # program.TARGET for this system, or 0
F DBG_paths, 8          # cstr: extra folders to search, or 0
F DBG_args, 8           # cstr: words with variables, or 0
F DBG_args_t, 8         # args.TARGET, or 0
F DBG_requests, 8       # cstr or 0 (launch attach)
F DBG_templates, 8      # cstr or 0
F DBG_install, 8        # cstr or 0
F DBG_attrs, 8          # owned SB* of "NAME\tTYPE\n" lines, or 0
F DBG_transport, 4      # 0 stdio, 1 tcp
F DBG_resolve, 4        # 1: debug-resolve before every launch
F DBG_nattrs, 4
F DBG_pad, 4
ENDSTRUCT DBG_SIZE

# a request in flight to an adapter
STRUCT
F PD_seq, 4
F PD_kind, 4            # RQ_*
F PD_epoch, 4
F PD_pad, 4
F PD_ctx, 8             # per kind: a node index, an owned list of breakpoint ids...
F PD_sent, 8            # time_ms
ENDSTRUCT PD_SIZE
.equ RQ_INITIALIZE, 1
.equ RQ_LAUNCH, 2
.equ RQ_CONFIGDONE, 3
.equ RQ_SETBP, 4
.equ RQ_SETFBP, 5
.equ RQ_SETEXC, 6
.equ RQ_THREADS, 7
.equ RQ_STACK, 8
.equ RQ_SCOPES, 9
.equ RQ_VARIABLES, 10
.equ RQ_EVALUATE, 11
.equ RQ_RESUME, 12      # continue, next, stepIn, stepOut
.equ RQ_PAUSE, 13
.equ RQ_TERMINATE, 14
.equ RQ_DISCONNECT, 15
.equ RQ_SETVARIABLE, 16
.equ RQ_EXCINFO, 17
.equ RQ_RESTART, 18
.equ RQ_REPL, 19        # evaluate from the console
.equ RQ_WATCH, 20       # evaluate for a watch
.equ RQ_HOVER, 21
.equ RQ_REVERSE, 22     # (never pending) an answer rhun sent

# session states
.equ DSS_FREE, 0
.equ DSS_INITIALIZING, 1
.equ DSS_CONFIGURING, 2
.equ DSS_RUNNING, 3
.equ DSS_PAUSED, 4
.equ DSS_TERMINATING, 5
.equ DSS_ENDED, 6
.equ DSS_CONNECTING, 7
.equ DSS_APPROVAL, 8        # waiting for the user to allow it

# session flags
.equ DSF_INITIALIZED, 1     # the initialized event came
.equ DSF_CONFIGDONE, 2      # configurationDone went out (or was not needed)
.equ DSF_TERMINATED, 4      # the terminated event came
.equ DSF_DISCONNECT, 8      # disconnect went out
.equ DSF_EOF, 16            # the adapter closed its output
.equ DSF_LAUNCHED, 32       # the launch answer came, successfully
.equ DSF_EXITED, 64         # the exited event came
.equ DSF_STALE, 128         # the variables shown are from an earlier stop
.equ DSF_THREADS, 256       # the thread list must be fetched again
.equ DSF_TNAMED, 512        # the stop named the focused thread (kept listed though the list omits it)

# adapter capabilities (initialize answer)
.equ CAP_CONFIGDONE, 1
.equ CAP_COND, 2
.equ CAP_HIT, 4
.equ CAP_LOG, 8
.equ CAP_FUNCBP, 16
.equ CAP_TERMINATE, 32
.equ CAP_RESTART, 64
.equ CAP_SETVAR, 128
.equ CAP_HOVER, 256
.equ CAP_EXCINFO, 512
.equ CAP_CANCEL, 1024
.equ CAP_EXCOPTIONS, 2048

# a thread of the paused program
STRUCT
F THR_id, 8
F THR_name, 4            # offset into DS_strs
F THR_namelen, 4
ENDSTRUCT THR_SIZE

# a stack frame of the focused thread
STRUCT
F FR_id, 8
F FR_name, 4
F FR_namelen, 4
F FR_path, 4            # offset into DS_strs (0 length: no source path)
F FR_pathlen, 4
F FR_line, 4
F FR_col, 4
F FR_hint, 4            # 0 normal, 1 subtle, 2 label
F FR_pad, 4
ENDSTRUCT FR_SIZE

# a variables-tree node: a scope (depth 0), a variable, or a watch result
STRUCT
F VN_ref, 8             # variablesReference (0: no children)
F VN_parent, 4          # node index, -1 for roots
F VN_kid0, 4            # first child (children are contiguous), -1 before they load
F VN_nkids, 4
F VN_depth, 4
F VN_flags, 4           # VNF_*
F VN_epoch, 4
F VN_name, 4            # offsets and lengths into DS_strs
F VN_namelen, 4
F VN_value, 4
F VN_valuelen, 4
F VN_type, 4
F VN_typelen, 4
F VN_eval, 4
F VN_evallen, 4
F VN_indexed, 4         # indexedVariables (a chunk: its count)
F VN_start, 4           # a chunk: its first index
ENDSTRUCT VN_SIZE
.equ VNF_EXPANDED, 1
.equ VNF_LOADING, 2
.equ VNF_ERROR, 4
.equ VNF_EXPENSIVE, 8
.equ VNF_CHANGED, 16
.equ VNF_WATCH, 32      # a watch expression's result (a root)
.equ VNF_CHUNK, 64      # a range of its parent's indexed children ([0..99]), asked for by start and count
.equ DAP_CHUNK, 100     # indexed children per chunk

# a debug session
STRUCT
F DS_state, 4           # DSS_*
F DS_id, 4              # 1, 2, ... (never reused in a run)
F DS_dbg, 4             # index into g_debuggers
F DS_parent, 4          # the parent session's id, or 0
F DS_request, 4         # 0 launch, 1 attach
F DS_nodebug, 4
F DS_pid, 4             # the adapter, 0 when none (or reaped)
F DS_in, 4              # its input (rhun writes), -1
F DS_out, 4             # its output (rhun reads), -1
F DS_err, 4             # its error output, -1
F DS_aout, 4            # tcp: its standard output (lines to the console), -1
F DS_ain, 4             # tcp: its standard input (kept open until the end), -1
F DS_csock, 4           # tcp, server: the socket while it connects, -1
F DS_transport, 4       # DTR_*
F DS_port, 4            # tcp, server: the port it listens on
F DS_addr, 4            # and the IPv4 address (network order)
F DS_conn_until, 8      # time_ms when connecting gives up
F DS_rit_seq, 4         # the runInTerminal request still owed an answer, 0 none
F DS_vgen, 4            # bumped whenever the variable pool starts again (a stop, another frame)
F DS_wgen, 4            # the last round of watch evaluations sent
F DS_rconn, 4           # remote window, tcp: 0 no attempt, 1 the host connects, 2 connected, 3 refused
F DS_rtry, 4            # and the attempt's number (an older attempt's answer is ignored)
F DS_rcopy, 4           # remote window: 1 while its extension's files are copied to the host first
F DS_pad3, 4
F DS_owner_ok, 4        # debug-start: the extension was told ok (debug-ended follows)
F DS_wlist, 4           # the watch list's version its last round evaluated (g_dwlist)
F DS_owner, 8           # debug-start: the EXT* that started it, 0 for the user's sessions
F DS_owner_id, 8        # and its request still owed an answer, 0 none
F DS_after, 8           # owned cstr: launch.ini's after task, run when the session ends, or 0
F DS_seq, 4             # the next request number
F DS_epoch, 4           # bumped on every stop and resume
F DS_flags, 4           # DSF_*
F DS_cfgwait, 4         # configuration answers still awaited
F DS_stopstep, 4        # Stop's escalation step, 0 before the first press
F DS_exit, 4            # the debuggee's exit code, -1 unknown
F DS_thread, 8          # the focused thread's id, 0 for none
F DS_frame, 4           # the focused frame's index
F DS_hasvars, 4         # scopes were asked for this stop
F DS_caps, 8            # CAP_*
F DS_name, 8            # owned cstr: the configuration's name
F DS_reason, 8          # owned cstr: why it stopped or ended, or 0
F DS_desc, 8            # owned cstr: the stop's description, or 0
F DS_deadline, 8        # time_ms: initialize, a Stop step, a kill, or 0
F DS_killat, 8          # time_ms when SIGKILL follows SIGTERM, or 0
F DS_launch, SB_SIZE    # the launch or attach arguments (JSON), kept for restart
F DS_rbuf, SB_SIZE      # bytes from the adapter not yet parsed
F DS_wq, SB_SIZE        # bytes to write to it
F DS_wq_off, 8
F DS_ebuf, SB_SIZE      # its error output: the line in progress
F DS_etail, SB_SIZE     # and the last lines (for a crash message)
F DS_obuf, SB_SIZE      # tcp: its standard output's line in progress
F DS_prevvals, SB_SIZE  # the last stop's values: "PATH" TAB "VALUE" LF (changed values stand out)
F DS_filters, SB_SIZE   # exception filters: "FILTER\tLABEL\tDEFAULT\n" lines
F DS_threads, VEC_SIZE  # TH
F DS_frames, VEC_SIZE   # FR of the focused thread
F DS_vars, VEC_SIZE     # VN
F DS_strs, SB_SIZE      # their strings
F DS_expanded, SB_SIZE  # paths of expanded nodes, one per line, kept across stops
F DS_total_frames, 4    # the stack's total as the adapter reports it
F DS_npend, 4
F DS_args, SB_SIZE      # the adapter's argv, each NUL-terminated (copied from g_lc_args)
F DS_nargs, 4
F DS_reading, 4         # 1 while its output is watched (0: the read buffer is full)
F DS_exited_at, 8       # time_ms the adapter's output closed, 0 before
F DS_more, 4            # 1: complete messages wait for the next frame (the tick's budget ran out)
F DS_pgrp, 4            # an exited adapter's process group still to be killed at DS_killat, 0 none
F DS_dbg_ext, 8         # the debugger's EXT* when the session started
F DS_pend, PD_SIZE*DS_PEND
ENDSTRUCT DS_SIZE

# a breakpoint (line or function), with what each session reports about it
STRUCT
F BP_id, 4
F BP_line, 4            # one-based; the user's line
F BP_enabled, 4
F BP_kind, 4            # 0 line, 1 function
F BP_path, 8            # owned cstr: the file (or the function's name)
F BP_cond, 8            # owned cstrs or 0
F BP_hit, 8
F BP_log, 8
F BP_sid, 4*DS_MAX      # the adapter's id per session slot, 0 none
F BP_aline, 4*DS_MAX    # the line it reports, 0 unknown
F BP_ver, 4*DS_MAX      # 0 not sent, 1 unverified, 2 verified, 3 rejected
F BP_msg, 8*DS_MAX      # owned message cstrs or 0
ENDSTRUCT BP_SIZE
# debug console categories
.equ DCON_STDOUT, 0
.equ DCON_STDERR, 1
.equ DCON_CONSOLE, 2
.equ DCON_IMPORTANT, 3
.equ DCON_ADAPTER, 4        # the adapter's own error output and stray bytes
.equ DCON_ERROR, 5          # rhun's messages about a failure
.equ DCON_INFO, 6           # rhun's notes ("Program exited with code 3")
.equ DCON_INPUT, 7          # an expression typed into the console
.equ DCON_RESULT, 8         # its value
.equ PROMPT_DEBUG, 80           # the debugger's text prompts (the debugger's block: 80-83) (debugview.s: condition, watch...)
.equ DCON_LINE_MAX, 4096
# ---- tasks and terminals: programs run as the user (uproc.s) in terminal tabs (termview.s) ----
.equ SIGINT, 2
.equ TK_SHELL, 0                # a terminal tab's kind: the user's shell
.equ TK_TERMINAL, 1             # a program an extension opened (terminal-open, a debugger's runInTerminal)
.equ TK_TASK, 2                 # a task
.equ TRV_FOCUS, 0x100           # term_run: the new tab also gets the keyboard
.equ TRV_SILENT, 0x200          # term_run: the tab is added without showing the panel
.equ TRV_WAIT, 0x400            # term_run: the tab waits: its program starts with term_start
.equ TASK_DONE, 0               # tasks_run_named's callback: the task exited 0 (or a background one is ready)
.equ TASK_FAILED, 1             # another code, stopped, could not start, refused, or a dependency failed
.equ TE_EXIT, 0                 # term_run's fn(cookie, TERM, event, code): exited with code
.equ TE_STOPPED, 1              # stopped (Stop, Restart, its tab closed while it ran)
.equ TE_FAILED, 2               # could not start (no TE_STARTED before it)
.equ TE_CLOSED, 3               # its tab closed: the TERM is gone
.equ TE_STARTED, 4              # started, code its pid; again after each restart
# a program for term_run (the lists are copied)
STRUCT
F PGM_argv, 8            # 0-terminated cstr list; argv[0] a name looked up on the login PATH, or a path
F PGM_sets, 8            # "NAME=value" list, or 0
F PGM_unsets, 8          # "NAME" list, or 0
F PGM_cwd, 8             # cstr or 0 (the project, else home); a relative one is inside the project
ENDSTRUCT PGM_SIZE
# the Problems store (problems.s): a source, and a problem
STRUCT
F PS_key, 8             # owned cstr: what finds it again
F PS_label, 8           # owned cstr: shown as the problems' source
F PS_count, 4
F PS_errors, 4
F PS_warnings, 4
F PS_dropped, 4         # not kept: past the caps
ENDSTRUCT PS_SIZE
STRUCT
F PR_src, 8             # PS*
F PR_path, 8            # absolute path (owned in the store)
F PR_line, 4            # 1-based, 0 none
F PR_col, 4             # 1-based bytes (characters with PRF_CHARS), 0 the line's first non-blank
F PR_endline, 4         # exclusive end, 0 none
F PR_endcol, 4
F PR_sev, 4             # SEV_*
F PR_flags, 4           # PRF_*
F PR_msg, 8             # cstr
F PR_code, 8            # cstr or 0
F PR_seq, 8             # set by the store: its id in the Problems tab
ENDSTRUCT PR_SIZE
.equ PRF_CHARS, 1
.equ MKF_SOURCE, 1              # MK_pad: the mark's owner is a problems source (PS*), not an extension
# [needs] terminal is a ladder (tasks design 2): suggest (= v1's yes, NEEDS_TERMINAL) < run < input < output
.equ NEEDS_TERM_RUN, 0x100000   # run programs in terminal tabs, once allowed per project
.equ NEEDS_TERM_INPUT, 0x200000 # and type into them
.equ NEEDS_TERM_OUTPUT, 0x400000 # and read what they show
# a program or task definition from the wire (termproto.s def_parse; tasks design 3.2)
.equ DF_MATCHERS, 4
.equ DF_PATTERNS, 8
STRUCT
F DF_strs, 8            # owned block: every string below, each with its NUL
F DF_id, 8              # cstr: the task id ("-" for a terminal)
F DF_label, 8           # cstr
F DF_detail, 8          # cstr, "" for none (lists show the command)
F DF_cmd, 8             # shell: the command (cstr, "" an interactive shell); argv: the arguments
F DF_cmdlen, 8          #   each with its NUL, DF_cmdlen bytes in all
F DF_cwd, 8             # cstr, "" for the project
F DF_env, 8             # owned "NAME=value" list
F DF_unset, 8           # owned "NAME" list
F DF_deps, 8            # owned list of task ids
F DF_form, 4            # 0 shell, 1 argv
F DF_group, 4           # 0 none, 1 build, 2 test
F DF_default, 4         # the default task of its group
F DF_reveal, 4          # 0 show, 1 focus, 2 silent
F DF_output, 4          # 1: terminal-output for it
F DF_order, 4           # its depends: 1 sequence, 2 parallel
F DF_nmatch, 4
F DF_mown, 4            # bit i: DF_match[i] was compiled for it (freed with it); else a built-in
F DF_nready, 4
F DF_nbusy, 4
F DF_match, 8*DF_MATCHERS       # MT*
F DF_ready, 8*DF_PATTERNS       # compiled patterns (taskmatch.s CP, owned)
F DF_busy, 8*DF_PATTERNS
F DF_refs, 4            # tasks.s: holders beyond the first (the registry, run nodes, a tab)
F DF_pad, 4
ENDSTRUCT DF_SIZE
# an extension's terminal or task run (termproto.s; tasks.s)
STRUCT
F TRC_term, 8            # its TERM (termview.s)
F TRC_ext, 8             # the extension that opened it
F TRC_live, 4            # 1 while that runtime runs: then the TERM is its handle
F TRC_flags, 4           # TRCF_*
F TRC_out, SB_SIZE       # finished lines waiting for terminal-output
F TRC_dropped, 8         # lines left out since the last terminal-output
F TRC_mrun, 8            # its matchers (taskmatch.s mrun), owned, or 0
F TRC_task, 8            # owned cstr: the task id it runs, or 0
F TRC_hook, 8            # tasks.s: fn(cookie, TR*, TE_* event, code), or 0
F TRC_linefn, 8          # tasks.s: fn(cookie, line, len) for each finished line (len -1: a run begins)
F TRC_cookie, 8
F TRC_ready, 4           # tasks.s: a background task that is ready since its last start or busy
F TRC_pad, 4
F TRC_df, 8              # tasks.s: the task (held) whose ready and busy patterns read its lines
ENDSTRUCT TRC_SIZE
.equ TRCF_OUTPUT, 1             # terminal-output for it
.equ AS_KIND_EXT, 5
.equ AGS_IDLE, 0
.equ AGS_WORKING, 1
.equ AGS_WAITING, 2
.equ AGS_ERROR, 3
.equ AXF_MATCH, 1               # its CWD is the project or one of its worktrees
.equ AXF_FETCHED, 2             # a transcript answer came at least once
.equ ID_AI_SOURCE, 0x7a00       # + extension index: its switch in Settings > Agents
.equ ID_AI_REVIEW, 0x8100       # review.s: the Review tab's buttons
.equ ID_AI_CARD, 0x8200         # D4: the prompt box, Stop and card buttons

# AI (wider-parity D): what one extension contributes, indexed like g_exts (ai_ext)
STRUCT
F AX_agents, 4          # [provides] agents = yes
F AX_hidden, 4          # its sessions are switched off ([agents] OWNER/NAME = false)
F AX_title, 8           # agents.title, cstr or 0
F AX_rows, VEC_SIZE     # AS*, its session rows, owned
F AX_tools, VEC_SIZE    # TL records from [tools] (tools.s)
F AX_grants, 8          # tools.s: bit i set when the user allowed tool i for this session
F AX_proposals, 4       # review.s: proposals of it still pending
F AX_pad, 4
ENDSTRUCT AX_SIZE

# ---- views group: places, the shared tree widget, retained extension views ----
# (places.s, rtree.s, rview.s; docs/extensions/v1.1.md "Retained views")
.equ FOCUS_VIEW, 10             # a place item has the keyboard (g_place_focus names it)
.equ FOCUS_QUICK, 69            # views group: an extension's quick input (quick.s)

# a place item: a sidebar section, a bottom panel tab or a side (right column) tab. Built-in code
# and extension views register the same way (place_add); the slot index is the item's id.
.equ PLACE_SIDEBAR, 1
.equ PLACE_PANEL, 2
.equ PLACE_SIDE, 3
.equ PLACE_TAB, 4               # retained views only: an editor tab of its own (not a place item)
.equ PL_MAX, 128
STRUCT
F PL_place, 4           # PLACE_*, 0 when the slot is free
F PL_flags, 4           # PLF_*
F PL_ops, 8             # PLO*: its callbacks, a table that outlives the item
F PL_ctx, 8             # handed to every callback
F PL_name, 8            # cstr, owned: its key in the config ("explorer", "OWNER/NAME.KEY")
F PL_title, 8           # cstr, owned: shown in its header or tab
F PL_icon, 4            # IC_* on panel and side tabs, -1 for none
F PL_badge, 4           # a count beside the title, 0 for none
F PL_weight, 4          # sidebar: its share of the height left by the headers
F PL_seq, 4             # registration order (sections and tabs show in this order)
F PL_x, 4               # its body as last drawn (tests point at it); w 0 when not drawn
F PL_y, 4
F PL_w, 4
F PL_h, 4
F PL_hy, 4              # sidebar: its header's top as last drawn
F PL_pad, 4
ENDSTRUCT PL_SIZE
.equ PLF_COLLAPSED, 1           # sidebar: only its header shows
.equ PLF_HIDDEN, 2              # left out of its place until shown again
.equ PLF_BUSY, 4                # a spinner in its header or tab
.equ PLF_DRAWN, 8               # drawn this frame (visibility)
.equ PLF_VISIBLE, 16            # was drawn last frame: its visible(1) was called
# a place item's callbacks; a zero entry is not called. Bodies are immediate-mode: draw also takes
# the pointer (ui_btn, ui_in) as the rest of rhun's UI does; a press inside the body gives the item
# the keyboard before draw runs.
STRUCT
F PLO_draw, 8           # draw(ctx, x, y, w, h): the body, clipped to it
F PLO_key, 8            # key(ctx, keysym, cp, mods) -> eax 1 when taken (while it has the keyboard)
F PLO_focus, 8          # focus(ctx, on): the keyboard came (1) or went (0); at most once a frame
F PLO_close, 8          # close(ctx): the × on its panel or side tab; 0: no ×
F PLO_actions, 8        # actions(ctx, right, y, h) -> eax the x left of the buttons it drew in its
                        #   header (sidebar), right of its title
F PLO_visible, 8        # visible(ctx, on): it came on (1) or went off (0) screen; at most once a frame
ENDSTRUCT PLO_SIZE

# the shared tree widget (rtree.s): a node store and its rows, drawn and driven by tree_draw and
# tree_key; extension views fill it from patches, built-in code through tree_kids_begin/tree_kid/
# tree_kids_end. Nodes are indices (u32) into TR_nodes; the root is node 0.
.equ TREE_NODES_MAX, 100000
.equ KIDS_LEAF, 0
.equ KIDS_CLOSED, 1
.equ KIDS_OPEN, 2
STRUCT
F ND_blob, 8            # owned: id bytes then label bytes then the raw extra records
F ND_idlen, 4
F ND_lablen, 4
F ND_xlen, 4            # extra bytes after the label
F ND_kids, 4            # KIDS_* as last given
F ND_parent, 4          # node index, -1 for the root and free slots
F ND_first, 4           # first child, -1 for none
F ND_last, 4
F ND_next, 4            # next sibling (the free list's link for free slots)
F ND_prev, 4
F ND_nkids, 4
F ND_flags, 4           # NF_*
F ND_icon, 4            # IC_*, or -1; NDI_FILE | its index: file:NAME (looked up once)
F ND_icolor, 4          # T_* slot of the icon's color, -1: muted
F ND_lcolor, 4          # T_* slot of the label's color, -1: panel text
F ND_badge, 4
F ND_mark, 4            # scratch generation marks (kids diffing, patch checks)
F ND_desc, 8            # owned cstr or 0
F ND_tip, 8             # owned cstr or 0
F ND_user, 8            # its owner's value (built-in code)
F ND_gen, 4             # TR_gen when it was made: a request about a node is not about a later one
F ND_pend, 4            # a patch check: the bytes a record it takes brings (rview.s)
ENDSTRUCT ND_SIZE
.equ NF_LIVE, 1
.equ NF_OPEN, 2                 # expanded
.equ NF_GIVEN, 4                # its children were given (lazy ones are asked for until then)
.equ NF_MORE, 8                 # a "Load more" row after its children
.equ NF_LOADING, 16             # its children were asked for
.equ NF_ERROR, 32               # asking failed: an error row with Retry
.equ NF_CHECK, 64               # has a checkbox
.equ NF_CHECKED, 128
.equ NF_SEL, 256                # selected (multi-select)
.equ NF_MOREWAIT, 512           # "Load more" was asked for
.equ NF_PCOUNT, 1024            # a patch check counted its bytes out (cleared after the check)
.equ NDI_FILE, 0x40000000
# the store's callbacks for its owner; a zero entry is not called
STRUCT
F TRO_activate, 8       # activate(ctx, tr, node): Enter, a double click, a click on a leaf
F TRO_expand, 8         # expand(ctx, tr, node, on): the user expanded (1) or collapsed (0) it;
                        #   a node whose children were not given is then waiting for them
F TRO_select, 8         # select(ctx, tr): the selection changed (at most once a frame)
F TRO_check, 8          # check(ctx, tr, node, state): its checkbox was toggled
F TRO_menu, 8           # menu(ctx, tr, node, x, y): right click or Shift+F10 on it
F TRO_more, 8           # more(ctx, tr, parent): its "Load more" row came on screen (NF_MOREWAIT is
                        #   set until tree_add_end)
F TRO_retry, 8          # retry(ctx, tr, node): Retry on its error row
F TRO_load, 8           # load(ctx, tr, node): it is expanded and on screen with its children not
                        #   given: they are wanted (NF_LOADING is set until tree_kids_end)
F TRO_action, 8         # action(ctx, tr, node, key, keylen): one of its inline buttons was pressed
ENDSTRUCT TRO_SIZE
# an action a tree's nodes may show as inline buttons (record "inline LEN" + keys): tree_set_actions
STRUCT
F TA_key, 8             # its key's bytes
F TA_keylen, 8
F TA_icon, 4            # IC_*, -1: its title as text
F TA_pad, 4
F TA_title, 8           # cstr: the tooltip (or the text)
ENDSTRUCT TA_SIZE
# a table's column (views group: tree_set_columns)
STRUCT
F TBC_title, 8           # cstr, mem_alloc'd
F TBC_align, 4           # 0 left, 1 right
F TBC_min, 4             # its minimum width in characters; 0 takes a share of the rest
F TBC_sort, 4            # 1 when its header sorts
F TBC_user, 4            # the width the user dragged it to, physical (0: none)
F TBC_x, 4               # laid out when last drawn, physical
F TBC_w, 4
ENDSTRUCT TBC_SIZE
.equ TBC_MAX, 16                # columns a table may have
STRUCT
F TR_nodes, VEC_SIZE    # ND
F TR_free, 8            # first free slot, -1 for none
F TR_map, 8             # id hash: u32 node + 1 per slot (0 empty, -1 removed)
F TR_mapcap, 8          # slots, a power of two
F TR_mapused, 8         # slots not empty (live and removed)
F TR_rows, VEC_SIZE     # RW: the rows shown, flattened from the expanded nodes
F TR_order, VEC_SIZE    # u32: children listed since tree_kids_begin
F TR_ops, 8             # TRO*
F TR_ctx, 8
F TR_count, 8           # live nodes, not counting the root
F TR_bytes, 8           # their blob bytes
F TR_scroll, 4          # pixels
F TR_cursor, 4          # the keyboard's node, -1 for none
F TR_flags, 4           # TRF_*
F TR_idbase, 4          # ui ids of its rows: + visible row
F TR_kparent, 4         # tree_kids_begin's parent
F TR_kgen, 4            # its generation mark
F TR_anchor, 4          # scroll anchor: a node, -1 none, and the pixels above its row's top
F TR_anchor_off, 4
F TR_rect, 16           # where it was last drawn
F TR_typed, 32          # type-to-jump: the prefix typed so far
F TR_typedlen, 4
F TR_hover, 4           # the row under the pointer, -1
F TR_typed_at, 8        # when the last character came
F TR_loading_at, 8      # when a Loading row first showed (it waits 300 ms)
F TR_user, 8            # its owner's value
F TR_actions, 8         # TA records the inline keys are looked up in (tree_set_actions), or 0
F TR_nactions, 8
F TR_selanchor, 4       # multi-select: where a Shift range starts
F TR_pad2, 4
F TR_rowfn, 8           # tree_set_rowbuttons: fn(ctx, tr, node, right, y, h) -> width drawn, or 0
F TR_rowbw, 4           # the width it drew last frame, and for which node
F TR_rownode, 4
F TR_gen, 4             # nodes made so far
F TR_pad3, 4
F TR_cols, 8            # views group: a table's columns (TBC, tree_set_columns), 0 for a plain tree
F TR_sortfn, 8          # sortfn(ctx, tr, col, dir): the user sorted while children are paged
F TR_ncols, 4
F TR_sort, 4            # the sorted column from 1 (0: none) | 1 << 8 descending | 1 << 16 the owner sorted
ENDSTRUCT TR_SIZE
.equ TRF_DIRTY, 1               # the rows are rebuilt before they are next used
.equ TRF_SELCHANGED, 2          # the select callback is due at the end of the frame
.equ TRF_MULTI, 4               # multi-select
.equ TRF_CHECKS, 8              # some node has a checkbox
.equ TRF_MDTIPS, 4096           # views group: node tooltips are Markdown (an extension with markdown agreed)
# a row: a node, or a marker row under a parent
STRUCT
F RW_node, 4            # node index; for a marker row the parent
F RW_depth, 2
F RW_kind, 2            # RWK_*
ENDSTRUCT RW_SIZE
.equ RWK_NODE, 0
.equ RWK_LOADING, 1
.equ RWK_MORE, 2
.equ RWK_ERROR, 3
.equ TRF_APPEND, 16              # tree_add_begin: children are appended
# one record of a patch or of a node's extra bytes: "NAME ARGS... LEN" LF, then LEN bytes
STRUCT
F RR_f, 16*8            # ptr, len of each field of the header line (8 at most)
F RR_n, 8               # fields
F RR_data, 8            # the LEN bytes
F RR_len, 8
ENDSTRUCT RR_SIZE

# ---- notebooks (wider-parity design, part A: nbdoc.s, nbview.s, nbout.s, nbproto.inc) ----
# A notebook is a TAB_NOTEBOOK tab whose cells are DOCs of their own (DF_CELL). The extension that
# provides the file's notebook reads and writes it (nb-open, nb-save) and runs cells (nb-run);
# rhun keeps the cells, their outputs and what they show.
STRUCT
F NB_host, 8            # DOC*: the tab's document (path and name, no text; DOC_nb points back)
F NB_ext, 8             # EXT*: the extension that reads, writes and runs it
F NB_id, 8              # the number extensions know it by (session-unique)
F NB_cells, VEC_SIZE    # CL* each, in order
F NB_meta, SB_SIZE      # the notebook's metadata, opaque, returned on save
F NB_undo, VEC_SIZE     # NU records: the last cell operations, for z
F NB_kernel, SB_SIZE    # the kernel button's text
F NB_err, SB_SIZE       # why it could not be opened
F NB_scroll, 8          # px from the top of the cells to the top of the view
F NB_sel, 8             # the selected cell
F NB_req, 8             # the nb-open or nb-save rhun waits on, 0 none
F NB_reqat, 8           # when it went out (time_ms), or when the wait for the program began
F NB_savefn, 8          # nb_save_start's callback(doc id, arg, result) and its argument, or 0
F NB_savearg, 8
F NB_outbytes, 8        # bytes of all its outputs' items
F NB_total, 8           # px of all cells at the last layout
F NB_lastkey, 8         # command mode: the last key and when (d d, i i, 0 0)
F NB_lastkeyt, 8
F NB_state, 4           # NBS_*
F NB_reqkind, 4         # NBR_* of NB_req
F NB_want, 4            # NBR_* waiting for the program to run
F NB_editing, 4         # 1 edit mode, 0 command mode
F NB_kstate, 4          # NBK_*
F NB_dirty, 4           # cell operations or outputs changed since it was read or saved
F NB_reveal, 4          # bring the selected cell into view at the next frame
F NB_layoutw, 4         # the width the cached heights are for
F NB_vy, 4              # where its cells were drawn last (physical px), for tests and clicks
F NB_vh, 4
F NB_sent, VEC_SIZE     # NBS2 records: per extension, the order of the cells it last heard (A3)
F NB_rev, 8             # bumped by every cell operation and output change (what NB_dirty records)
F NB_snap, VEC_SIZE     # nb-save's snapshot: NBC*, its document's undo length, version and history hash (32 B)
F NB_snaprev, 8         # NB_rev when nb-save's body was made
F NB_openstamp, 8       # nb_stamp when a reload's nb-open went out
ENDSTRUCT NB_SIZE
STRUCT
F NBS2_ext, 8           # EXT*
F NBS2_hash, 8          # a hash of the DOC ids of the cells it knows, in order
ENDSTRUCT NBS2_SIZE
.equ NBS_OPENING, 0
.equ NBS_READY, 1
.equ NBS_FAILED, 2
.equ NBR_OPEN, 1
.equ NBR_SAVE, 2
.equ NBK_NONE, 0
.equ NBK_IDLE, 1
.equ NBK_BUSY, 2
.equ NBK_STARTING, 3
.equ NBK_DEAD, 4
STRUCT
F NBC_doc, 8             # DOC* (DF_CELL): its source
F NBC_id, 8              # the number extensions know it by (session-unique, stable while it exists)
F NBC_run, 8             # the run in progress or the last one, 0 none
F NBC_count, 8           # execution count, -1 none
F NBC_lang, 8            # owned cstr: LANG as the extension named it (spaces as _), 0 for markup
F NBC_meta, SB_SIZE      # its metadata, opaque, returned on save
F NBC_outs, VEC_SIZE     # OU* each, in order
F NBC_outrev, 8          # changes with its outputs (the layout cache)
F NBC_h, 8               # height at the last layout
F NBC_hkey, 8            # what that height was measured for
F NBC_kind, 4            # NBCK_*
F NBC_state, 4           # RUN_*
F NBC_collapsed, 4       # its outputs are hidden (o)
F NBC_clearwait, 4       # clear-wait: the outputs clear when the next one arrives
F NBC_y, 4               # where it was drawn last (physical px; -1 not on screen)
F NBC_unsent, 4           # its run waits for the extension to run before nb-run goes out
F NBC_edit, 4            # it is the cell in edit mode (nb_mark_edit): a markup cell shows its source
F NBC_mdx, 4             # where its rendered Markdown was drawn last (physical px), for tests
F NBC_md, 8              # a markup cell's rendered Markdown (MD*, nbmd.s), or 0
F NBC_mdver, 8           # DOC_version + 1 of the source it was made from, 0 none
F NBC_mdy, 4
F NBC_tx, 4              # x of its text's column 0 and y of its first line as last drawn, for tests
F NBC_ty, 4
F NBC_pad2, 4
F NBC_mdbase, 8          # a hash of the notebook's path its relative links were set for
ENDSTRUCT NBC_SIZE
.equ NBCK_CODE, 0
.equ NBCK_MARKUP, 1
.equ NBRUN_NONE, 0
.equ NBRUN_QUEUED, 1
.equ NBRUN_RUNNING, 2
.equ NBRUN_DONE, 3
.equ NBRUN_FAILED, 4
.equ NBRUN_CANCELLED, 5
STRUCT
F NBO_kind, 4            # NBOK_*
F NBO_ierr, 4            # its image cannot be decoded
F NBO_id, 8              # owned cstr: OUTID (Jupyter's display_id), or 0
F NBO_keep, SB_SIZE      # opaque bytes returned on save (the jupyter extension keeps the JSON there)
F NBO_items, VEC_SIZE    # NI records, in order of preference
F NBO_show, 8            # the item drawn: the first one rhun supports, -1 none
F NBO_lines, 8           # text items: lines in all
F NBO_bytes, 8           # bytes its items count against NB_outbytes
F NBO_img, 8             # an image item scaled to fit (owned pixels), or 0
F NBO_iw, 4              # their size, physical px
F NBO_ih, 4
F NBO_ikey, 4            # the width they were made for
F NBO_pad, 4
F NBO_md, 8              # a rich item shown: its document (MD*), or 0
F NBO_pic, 8             # a picture item shown: the picture (pic_new), or 0
F NBO_pkey, 8            # what NBO_img holds a picture scaled for (nbmd.s), 0 nothing
ENDSTRUCT NBO_SIZE
.equ NBOK_STDOUT, 1
.equ NBOK_STDERR, 2
.equ NBOK_RESULT, 3
.equ NBOK_DISPLAY, 4
.equ NBOK_ERROR, 5
STRUCT
F NBI_type, 4            # NBIT_*
F NBI_w, 4               # intrinsic logical size (images, pictures), 0 0 natural
F NBI_h, 4
F NBI_pad, 4
F NBI_name, 8            # owned cstr: a type rhun does not know, kept to be returned, or 0
F NBI_data, SB_SIZE
ENDSTRUCT NBI_SIZE
.equ NBIT_OTHER, 0
.equ NBIT_TEXT, 1
.equ NBIT_ANSI, 2
.equ NBIT_PNG, 3
.equ NBIT_JPEG, 4
.equ NBIT_GIF, 5
.equ NBIT_RICH, 6
.equ NBIT_PICTURE, 7
STRUCT
F NBU_op, 8              # NBUO_*
F NBU_index, 8           # where
F NBU_index2, 8          # move: where to; kind: the old kind
F NBU_cell, 8            # delete: the cell taken out (owned by the record), or 0
ENDSTRUCT NBU_SIZE
.equ NBUO_INSERT, 1
.equ NBUO_DELETE, 2
.equ NBUO_MOVE, 3
.equ NBUO_KIND, 4
.equ NB_BODY_MAX, 67108864      # nb-open's answer and nb-save's body, each way
.equ NB_CELLS_MAX, 5000
.equ NB_SOURCE_MAX, 4194304     # a cell's source
.equ NB_OUTS_MAX, 1000          # outputs a cell
.equ NB_ITEMS_MAX, 32           # items an output
.equ NB_ITEM_MAX, 16777216      # an item
.equ NB_STREAM_MAX, 65536       # an nb-stream message
.equ NB_OUTALL_MAX, 67108864    # outputs in all, a notebook
.equ NB_OUTPUT_MAX, NB_ITEM_MAX + 1048576   # an nb-output body
.equ NB_UNDO_MAX, 100
.equ NB_TEXT_LINES, 400         # lines of a text output shown before "N more lines"
.equ NB_LABEL_MAX, 200          # the kernel button's text
.equ NB_OPEN_MS, 30000          # an nb-open or nb-save without an answer fails after this

# ---- custom editors (wider-parity design, part B: customed.s, ceproto.inc) ----
# A file an extension's [provides] editor matches opens in a TAB_VIEW tab with TF_CUSTOM: a 12a view
# the extension draws, bound to a CE. Text model: TAB_doc is the file's DOC (rhun's undo, dirty and
# save). Owned model: TAB_doc is a stand-in with the path and no text; the extension keeps the model
# and rhun asks it for the bytes in parts.
STRUCT
F CE_doc, 8             # DOC* (DOC_ce points back); its DOC_id is the CDOC extensions know
F CE_ext, 8             # EXT*: the extension
F CE_vid, 8             # its view's id (VW_id)
F CE_req, 8             # the request rhun waits on, 0 none
F CE_reqat, 8           # when it went out (time_ms)
F CE_savefn, 8          # app_save_start's callback(doc id, arg, result) and its argument, or 0
F CE_savearg, 8
F CE_buf, SB_SIZE       # owned saves: the parts so far
F CE_target, 8          # owned cstr: the path the save in progress writes
F CE_path, 8            # owned cstr: the path the extension was last told
F CE_part, 8            # the part asked for
F CE_model, 4           # CEM_*
F CE_state, 4           # CES_*
F CE_dirty, 4           # owned: the extension said its model differs from the file
F CE_reqkind, 4         # CER_* of CE_req
F CE_want, 4            # CER_OPEN: editor-open waits for the extension to run
F CE_skind, 4           # CEK_* of the save in progress
F CE_dirtyat, 8         # owned: when it last said dirty (time_ms): its backup follows 30 s later
F CE_bkdone, 4          # owned: the backup holds what it shows since it last said dirty
F CE_restore, 4         # owned: its bytes come from its backup (opened with SOURCE backup) until saved
F CE_gen, 8             # owned: one more with every editor-dirty (the model changed)
F CE_savegen, 8         # CE_gen when the save or backup in progress asked its first part
F CE_lost, 4            # its program ended: the next tick opens it again if the program runs again
F CE_pad, 4
ENDSTRUCT CE_SIZE
.equ CEM_TEXT, 0
.equ CEM_OWNED, 1
.equ CES_OPENING, 0
.equ CES_READY, 1
.equ CES_STOPPED, 2             # its extension stopped while it had unsaved changes in a backup
.equ CER_OPEN, 1
.equ CER_SAVE, 2
.equ CER_CMD, 3
.equ CEK_SAVE, 0
.equ CEK_SAVEAS, 1
.equ CEK_BACKUP, 2
.equ CE_PART_MAX, 4194304       # an editor-save part's bytes
.equ CE_SAVE_MAX, 1073741824    # a save's bytes in all
.equ CE_READ_MAX, 4194304       # an editor-read answer
.equ CE_WAIT_MS, 30000          # a request without an answer fails after this
.equ CE_BACKUP_MS, 30000        # an owned model's backup, after it last said dirty
.equ ID_CE_RESTORE, 0x7d20      # the stopped editor's Restore Unsaved Changes button
.equ PM_REOPEN, 120             # the palette's Reopen With list (notebooks' block 120-123)
# ---- editor presentation (edtape.s, deco.s, gutter.s, presctl.s) ----
# per-document presentation state, DOC_pres: the edit tape, decorations, glyph-lane entries
.equ TAPE_N, 256                # edits the tape keeps
STRUCT
F PRS_tape, 8            # TE[TAPE_N], a ring
F PRS_tn, 8              # edits written since the tape began (entry tn % TAPE_N is the next)
F PRS_tbase, 8           # the oldest version tape_map moves positions from
F PRS_gen, 8             # bumped by every change to what is drawn
F PRS_deco, VEC_SIZE     # DR decoration ranges, unsorted
F PRS_dpool, SB_SIZE     # their texts (before, after, tip, extra)
F PRS_dgarbage, 8        # pool bytes no range uses any more
F PRS_glyphs, VEC_SIZE   # GLE glyph-lane entries, sorted by position then kind
F PRS_folds, VEC_SIZE    # FLD folds (fold.s), sorted by their header's end
F PRS_hid, VEC_SIZE      # HI the hidden lines, merged (a cache of the folds)
F PRS_hidver, 8          # DOC_version and PRS_gen the cache was built for
F PRS_hidgen, 8
F PRS_hidden, 8          # hidden lines in all
F PRS_fr, VEC_SIZE       # FRG a folding provider's ranges, sorted by their header's line feed
F PRS_frext, 8           # the extension they came from; 0 while indentation decides
F PRS_tks, 8             # semantic tokens (semtok.s), owned, or 0
F PRS_hints, VEC_SIZE    # IH inlay hints (inlay.s), sorted by position
F PRS_lens, VEC_SIZE     # LNS code lenses (lens.s), sorted by position
F PRS_colors, VEC_SIZE   # CLR colors (hicolor.s)
ENDSTRUCT PRS_SIZE
# a fold: the lines after its header up to its last line are hidden; it follows edits as positions
STRUCT
F FLD_a, 8               # the header line's line feed
F FLD_b, 8               # the last hidden line's line feed (or the text's end)
F FLD_text, 8            # owned cstr: a provider's collapsed text, or 0
ENDSTRUCT FLD_SIZE
STRUCT
F HI_first, 8           # hidden lines first..last (0-based)
F HI_last, 8
F HI_before, 8          # hidden lines before them
ENDSTRUCT HI_SIZE
# a folding provider's range (present.s, fold.s): lines after the header up to the last can fold
STRUCT
F FRG_a, 8               # the header line's line feed
F FRG_b, 8               # the last line's line feed
F FRG_text, 8            # owned cstr: the collapsed text, or 0
F FRG_kind, 4            # FRK_*
F FRG_pad, 4
ENDSTRUCT FRG_SIZE
.equ FRK_NONE, 0
.equ FRK_REGION, 1
.equ FRK_COMMENT, 2
.equ FRK_IMPORTS, 3
.equ FRG_MAX, 50000              # ranges in one answer
.equ FRG_TEXT_MAX, 80            # a collapsed text's bytes
.equ FOLD_ALL_MAX, 4000000      # fold_all scans at most this many lines
# semantic tokens (semtok.s): a token's place, the class it draws in and its effects
STRUCT
F STK_start, 8
F STK_len, 4
F STK_cls, 1            # C_*, or STK_KEEP: the syntax class stays
F STK_fx, 1             # STKF_*
F STK_pad, 2
ENDSTRUCT STK_SIZE
.equ STK_KEEP, 255
.equ STKF_STRIKE, 1
.equ STKF_UNDER, 2
.equ STKF_FADED, 4
.equ SEMT_LEGENDS, 8            # legends per extension
.equ SEMT_TYPES, 256            # token types, modifiers per legend
.equ SEMT_MODS, 64
.equ SEMT_LEGEND_MAX, 16384     # a legend's body
.equ SEMT_TOKENS, 200000        # tokens per document
.equ SEMT_DELTA, 10000          # a delta's edits
.equ SEMT_HUGE_LINES, 200000    # a document past these is asked about in ranges
.equ SEMT_HUGE_BYTES, 8388608
.equ SEMT_FX_MAX, 256           # effects drawn per line
# a presentation request out (present.s; its answer's handler gets it)
STRUCT
F PQR_ext, 8
F PQR_id, 8
F PQR_doc, 8            # DOC_id
F PQR_kind, 8
F PQR_ver, 8            # the version it asked about
F PQR_l1, 8             # the lines it asked about (0-based, inclusive)
F PQR_l2, 8
ENDSTRUCT PQR_SIZE
# inlay hints (inlay.s)
STRUCT
F IH_pos, 8
F IH_owner, 8           # EXT*
F IH_blob, 8            # owned: IHP parts, IHE edits, then their bytes
F IH_ver, 8             # the version its edits are about
F IH_side, 1            # VS_*
F IH_nparts, 1
F IH_nedits, 1
F IH_pad, 5
ENDSTRUCT IH_SIZE
STRUCT
F IHP_loff, 4           # offsets into the blob: label, tip, extra records
F IHP_llen, 4
F IHP_toff, 4
F IHP_tlen, 4
F IHP_xoff, 4
F IHP_xlen, 4
ENDSTRUCT IHP_SIZE
STRUCT
F IHE_l1, 4             # 0-based, in the hint's version
F IHE_c1, 4
F IHE_l2, 4
F IHE_c2, 4
F IHE_toff, 4
F IHE_tlen, 4
ENDSTRUCT IHE_SIZE
.equ IH_MAX, 5000               # hints per answer
.equ IH_DOC_MAX, 50000          # per document
.equ IH_LABEL_MAX, 120          # a hint's label, all parts
.equ IH_PARTS, 8
.equ IH_TIP_MAX, 4000
.equ IH_PEXTRA_MAX, 9000
.equ IH_EDITS, 16
.equ IH_EXTRA_MAX, 65536
# code lens (lens.s)
STRUCT
F LNS_pos, 8            # its line's start (moves with the text)
F LNS_owner, 8          # EXT*
F LNS_blob, 8           # owned: TITLE then EXTRA
F LNS_tlen, 4
F LNS_xlen, 4
ENDSTRUCT LNS_SIZE
.equ LENS_MAX, 10000            # lenses per answer
.equ LENS_TITLE_MAX, 200
.equ LENS_EXTRA_MAX, 9000
.equ HL_MAX, 5000               # document highlights per answer (hicolor.s)
# a color in a document (hicolor.s)
STRUCT
F CLR_start, 8
F CLR_end, 8
F CLR_owner, 8          # EXT*
F CLR_rgba, 4           # RRGGBBAA
F CLR_pad, 4
ENDSTRUCT CLR_SIZE
.equ CLR_MAX, 10000             # colors per answer
.equ PROMPT_COLOR, 72           # a swatch's new color (hicolor.s; presentation's block 72-75)
# the kinds present.s asks for
.equ PQ_FOLDING, 0
.equ PQ_TOKENS, 1
.equ PQ_HINTS, 2
.equ PQ_LENS, 3
.equ PQ_COLORS, 4
.equ PQ_HIGHLIGHTS, 5
.equ PQ_COUNT, 6
# single-provider kinds for automatic use (extproviders.s numbers 0-11 its own)
.equ PP_TOKENS, 12
.equ PP_INLINE, 13
.equ PP_HIGHLIGHTS, 14
.equ PP_FOLDING, 15
.equ FOLD_SESSION_MAX, 1000     # folds a session line keeps per file
STRUCT
F TE_version, 8         # DOC_version after the edit
F TE_pos, 8
F TE_del, 8             # one of del and ins is 0
F TE_ins, 8
F TE_line, 8            # where pos was: 0-based line and byte column
F TE_col, 8
F TE_nl, 8              # line feeds in the inserted or deleted text
F TE_tail, 8            # its bytes after the last line feed (all of them when it has none)
ENDSTRUCT TE_SIZE
.equ GR_RIGHT, 0                # an insert at the position moves it (range start, marks)
.equ GR_LEFT, 1                 # an insert at the position leaves it (range end)

# decoration types (deco.s): one per extension and name; COLOR is two SPECs, dark and light
STRUCT
F DCS_value, 4           # argb, or the theme slot
F DCS_kind, 1            # DCSK_*
F DCS_pct, 1             # a slot's opacity, 0-100
F DCS_pad, 2
ENDSTRUCT DCS_SIZE
.equ DCSK_NONE, 0
.equ DCSK_ARGB, 1
.equ DCSK_SLOT, 2
.equ DCSK_TEXT, 3                # strike COLOR "-": the text's color
STRUCT
F DTY_owner, 8           # EXT*, 0 for a free slot
F DTY_name, 48           # cstr, 1-40 bytes of [a-z0-9_-]
F DTY_flags, 4           # DTYF_*
F DTY_prio, 4            # 0-100
F DTY_bwidth, 4          # border width 1-3
F DTY_ustyle, 4          # US_*
F DTY_gshape, 4          # GS_* in the gutter's left lane
F DTY_grow, 4            # DG_*
F DTY_width, 4           # before/after text cells, 0 natural
F DTY_seq, 4             # registration order, for ties
F DTY_color, 2*DCS_SIZE
F DTY_bg, 2*DCS_SIZE
F DTY_linebg, 2*DCS_SIZE
F DTY_border, 2*DCS_SIZE
F DTY_under, 2*DCS_SIZE
F DTY_strike, 2*DCS_SIZE
F DTY_gutter, 2*DCS_SIZE
F DTY_scroll, 2*DCS_SIZE
F DTY_before, 2*DCS_SIZE
F DTY_beforebg, 2*DCS_SIZE
F DTY_after, 2*DCS_SIZE
F DTY_afterbg, 2*DCS_SIZE
ENDSTRUCT DTY_SIZE
.equ DTYF_COLOR, 1
.equ DTYF_BG, 2
.equ DTYF_LINEBG, 4
.equ DTYF_BORDER, 8
.equ DTYF_UNDER, 16
.equ DTYF_STRIKE, 32
.equ DTYF_FADED, 64
.equ DTYF_BEFORE, 128
.equ DTYF_AFTER, 256
.equ DTYF_GUTTER, 512
.equ DTYF_SCROLL, 1024
.equ US_SOLID, 1
.equ US_DOUBLE, 2
.equ US_DOTTED, 3
.equ US_DASHED, 4
.equ US_SQUIGGLE, 5
.equ DG_NONE, 0
.equ DG_START, 1
.equ DG_END, 2
.equ DG_BOTH, 3
# a decorated range on a document
STRUCT
F DR_start, 8
F DR_end, 8
F DR_type, 4            # index into the types
F DR_flags, 4           # DRF_*
F DR_text, 4            # offset of its texts in PRS_dpool
F DR_blen, 2            # before, after, tip lengths
F DR_alen, 2
F DR_tlen, 2
F DR_pad, 2
F DR_xlen, 4            # extra records' length
ENDSTRUCT DR_SIZE
.equ DRF_WASEMPTY, 1            # empty when it came: kept at an edge of a deletion

# the gutter's glyph lane (gutter.s): GLE entries per document, kinds registered by built-in code
STRUCT
F GLE_pos, 8            # start of the glyph's line (moves with the text before it)
F GLE_kind, 4
F GLE_glyph, 4          # shape | slot << 8 | GF_* << 16
ENDSTRUCT GLE_SIZE
.equ GS_DOT, 1                  # glyph shapes (gutter_shape_draw)
.equ GS_CIRCLE, 2
.equ GS_RING, 3
.equ GS_SQUARE, 4
.equ GS_DIAMOND, 5
.equ GS_TRIANGLE, 6             # pointing right: run
.equ GS_BAR, 7
.equ GS_CHECK, 8
.equ GS_CROSS, 9
.equ GS_PLUS, 10
.equ GS_MINUS, 11
.equ GS_ARROW, 12               # the debugger's current line
.equ GS_CIRCLE_BAR, 13          # a circle with a bar (a breakpoint with a condition)
.equ GS_CIRCLE_TRI, 14          # a circle with a warning triangle (rejected)
.equ GS_BULB, 15
.equ GS_COUNT, 16
.equ GF_FAINT, 1                # glyph flags (bits 16-23): drawn at a third of the color's alpha
.equ GK_EMPTY, 1                # gutter_kind flags: clicks on lines without a glyph come here
.equ GK_RESERVE, 2              # the lane keeps its width with line numbers off
.equ GK_MAX, 32
.equ LANE_NONE, 0                 # gutter_hit lanes
.equ LANE_LEFT, 1
.equ LANE_DIGITS, 2
.equ LANE_FOLD, 3
.equ LANE_GIT, 4
.equ GK_PRIO_DOT, 10            # built-in lane priorities: the diagnostic dot, decoration icons,
.equ GK_PRIO_DECO, 20           #   suggested ones for the others (the highest shows on a line)
.equ GK_PRIO_TEST, 40
.equ GK_PRIO_BULB, 50
.equ GK_PRIO_BREAKPOINT, 80
.equ GK_PRIO_DEBUG_LINE, 90
# caps
.equ DTY_MAX_EXT, 64             # decoration types per extension
.equ DTY_MAX, 512                # in all
.equ DTY_BODY_MAX, 4096
.equ DECO_BODY_MAX, 4194304     # a decorate body
.equ DECO_MAX_MSG, 20000        # records per message, and per extension and document
.equ DECO_MAX_DOC, 50000        # per document in all
.equ DECO_TEXT_MAX, 200         # before/after bytes
.equ DECO_TIP_MAX, 1000
.equ DECO_EXTRA_MAX, 9000
.equ DECO_PIECES, 4096          # decoration pieces drawn per frame
.equ DECO_TICKS, 1024           # scrollbar ticks
# virtual text (vtext.s): a line's inlays, merged from their sources, in drawing order
STRUCT
F VI_off, 8             # the gap it sits at: between bytes off - 1 and off of the line
F VI_text, 8            # its text (one line, UTF-8)
F VI_ref, 8             # what it came from (a DR* for a decoration)
F VI_len, 4
F VI_cells, 4           # its width in cells
F VI_side, 1            # VS_AFTER: it belongs to the text before the gap; VS_BEFORE: after it
F VI_kind, 1            # VK_*
F VI_flags, 2
F VI_fg, 4              # text color
F VI_bg, 4              # its pill's color, 0 for none
F VI_prio, 4
ENDSTRUCT VI_SIZE
.equ VS_AFTER, 0
.equ VS_BEFORE, 1
.equ VK_GHOST, 0                # kinds, in their order at one gap among the after ones
.equ VK_FOLD, 1
.equ VK_HINT, 2
.equ VK_DECO, 3
.equ VK_SWATCH, 4
.equ VK_LENS, 5                 # (not an inlay: a code lens item under the pointer, lens.s)
.equ VTM_LEFT, 0                # vt_x modes: before every inlay at the gap, after them, the caret's
.equ VTM_RIGHT, 1
.equ VTM_CARET, 2
.equ VT_LINE_MAX, 256           # inlays on one line
