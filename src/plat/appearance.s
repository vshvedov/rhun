# Linux: the system's dark mode for follow_system, read as Chromium (and so VS Code) reads it. First
# the XDG desktop portal's color-scheme over D-Bus: GNOME, KDE Plasma, Cinnamon, COSMIC, and wlroots
# desktops with xdg-desktop-portal-gtk (which serves GNOME's setting). Without a dark or light
# answer there, GTK's theme: gtk-application-prefer-dark-theme from settings.ini, or a theme name
# with "dark" in it ("Adwaita-dark") from XSETTINGS (X11: Xfce, MATE, LXDE, xsettingsd; read in
# src/plat/x11.s), the portal (GNOME's gtk-theme) or settings.ini (window managers set up with
# lxappearance or nwg-look). The portal's "no preference" with no GTK theme means light (GNOME's
# Default style); nothing at all leaves the mode unknown, which keeps the dark theme. Every source is
# watched: the portal's SettingChanged signal, XSETTINGS' PropertyNotify and settings.ini by inotify.
.include "rhun.inc"

.equ SYS_getuid, 102
.equ DB_BUF, 16384
.equ DB_WAIT_MS, 400            # how long startup waits for the portal (it may be starting)
.equ SER_SCHEME, 4              # the serials of the two Read calls below
.equ SER_GTK, 5
.equ INI_DIR_EVENTS, IN_CLOSE_WRITE | IN_MOVED_TO | IN_MOVED_FROM | IN_CREATE | IN_DELETE | IN_ONLYDIR
.equ AGAIN_MS, 250              # the second look at the folders after inotify activity (ini_again)

.data
.p2align 2
db_fd: .long -1
ino_fd: .long -1
scheme: .long -1                # the portal's color-scheme: 0 no preference, 1 dark, 2 light
portal_name: .long -1           # each source's GTK theme: 1 a dark one, 0 another, -1 none
xs_name: .long -1
ini_name: .long -1
ini_prefer: .long -1            # settings.ini's gtk-application-prefer-dark-theme
again_fd: .long -1              # a timerfd for ini_again
seen_end: .long -1              # where ini_add_watches last left the watches: the search's end and the
seen_gtk3: .long -1             # gtk folders' watches (or errors)
seen_gtk4: .long -1
.p2align 3
again_in: .quad 0, 0, 0, AGAIN_MS * 1000000    # itimerspec: once, AGAIN_MS from now

.bss
.p2align 3
db_len: .quad 0                 # bytes in db_in
db_skip: .quad 0                # bytes of a message too big for db_in still to drop
answers: .long 0                # bit 0: the color-scheme Read was answered, bit 1: gtk-theme
reporting: .long 0              # after startup, changes go to theme_system_changed
authing: .long 0                # the bus has not answered AUTH by the end of startup's wait
xs_known: .long 0               # XSETTINGS was read (X11, with the window) or there is none (Wayland)
cfg_root: .zero 1024            # $XDG_CONFIG_HOME or ~/.config, or empty
path_buf: .zero 1100
ino_buf: .zero 4096
db_in: .zero DB_BUF

.text

# linux_appearance_init(): the mode into g_sys_dark before the first theme, then its changes
FN linux_appearance_init
    PROLOGUE
    call find_config_root
    call ini_watch
    call ini_read
    call db_open
    call combine
    mov [rip + g_sys_dark], eax
    mov dword ptr [rip + reporting], 1
    EPILOGUE

# linux_xsettings(dark): XSETTINGS' theme name is a dark one (1), another (0), or there is none (-1),
# as the X11 window reads it; Wayland, which has none, says -1 once it has connected
FN linux_xsettings
    mov [rip + xs_name], edi
    mov dword ptr [rip + xs_known], 1
    jmp report

# linux_name_dark(ptr, len) -> 1 if a GTK theme's name has "dark" in it, in any case
FN linux_name_dark
    xor eax, eax
    cmp rsi, 4
    jb 9f
    sub rsi, 3
1:  mov ecx, [rdi]
    or ecx, 0x20202020          # lower case; only capitals become the letters looked for
    cmp ecx, 0x6b726164         # "dark"
    je 8f
    inc rdi
    dec rsi
    jnz 1b
    ret
8:  mov eax, 1
9:  ret

# report(): after startup, the mode as now known to the theme
report:
    PROLOGUE
    cmp dword ptr [rip + reporting], 0
    je 9f
    call combine
    mov edi, eax
    call theme_system_changed
9:  EPILOGUE

# combine() -> eax 1 dark, 0 light, -1 unknown, from what the sources said
combine:
    mov ecx, [rip + scheme]
    mov eax, 1
    cmp ecx, 1
    je 9f
    xor eax, eax
    cmp ecx, 2
    je 9f
    # GTK: prefer-dark, else the theme's name from XSETTINGS, the portal or settings.ini
    mov eax, 1
    cmp dword ptr [rip + ini_prefer], 1
    je 9f
    # XSETTINGS outranks the rest, so they wait for it: unknown until then
    mov eax, -1
    cmp dword ptr [rip + xs_known], 0
    je 9f
    mov eax, [rip + xs_name]
    test eax, eax
    jns 9f
    mov eax, [rip + portal_name]
    test eax, eax
    jns 9f
    mov eax, [rip + ini_name]
    test eax, eax
    jns 9f
    mov eax, [rip + ini_prefer]
    test eax, eax
    jns 9f
    # no GTK theme: the portal's "no preference" is light, no answer unknown
    mov eax, -1
    test ecx, ecx
    jnz 9f
    xor eax, eax
9:  ret

# ---------------------------------------------------------------- settings.ini

# find_config_root(): cfg_root = $XDG_CONFIG_HOME or $HOME/.config
find_config_root:
    PROLOGUE
    mov byte ptr [rip + cfg_root], 0
    lea r12, [rip + .Lempty]
    lea rdi, [rip + .Lenv_config]
    call getenv
    mov rbx, rax
    test rax, rax
    jz 1f
    cmp byte ptr [rax], 0
    jne 2f
1:  lea rdi, [rip + .Lenv_home]
    call getenv
    mov rbx, rax
    test rax, rax
    jz 9f
    lea r12, [rip + .Ldot_config]
2:  mov rdi, rbx
    call strlen
    cmp rax, 900
    jae 9f
    lea rdi, [rip + cfg_root]
    mov rsi, rbx
    call cstr_copy
    mov rdi, rax
    mov rsi, r12
    call cstr_copy
9:  EPILOGUE

# user_path(suffix) -> path_buf = cfg_root + suffix, or 0 without cfg_root
user_path:
    PROLOGUE
    xor eax, eax
    cmp byte ptr [rip + cfg_root], 0
    je 9f
    mov rbx, rdi
    lea rdi, [rip + path_buf]
    lea rsi, [rip + cfg_root]
    call cstr_copy
    mov rdi, rax
    mov rsi, rbx
    call cstr_copy
    lea rax, [rip + path_buf]
9:  EPILOGUE

# ini_read(): the user's settings.ini, gtk-3.0's over gtk-4.0's. Those in /etc are a distribution's
# defaults (Ubuntu's names Adwaita), not a mode anyone chose, so a desktop nobody set up stays dark.
ini_read:
    PROLOGUE
    mov dword ptr [rip + ini_prefer], -1
    mov dword ptr [rip + ini_name], -1
    lea rdi, [rip + .Lgtk4_ini]
    call user_path
    test rax, rax
    jz 9f
    mov rdi, rax
    call ini_file
    lea rdi, [rip + .Lgtk3_ini]
    call user_path
    mov rdi, rax
    call ini_file
9:  EPILOGUE

# ini_file(path): the [Settings] keys it has
ini_file:
    PROLOGUE INI_SIZE
    call file_read_all
    test rax, rax
    jz 9f
    mov rbx, rax
    lea rdi, [rsp]
    mov rsi, rax
    call ini_init
1:  lea rdi, [rsp]
    call ini_next
    test eax, eax
    jz 8f
    lea rdi, [rsp]
    lea rsi, [rip + .Ls_settings]
    call ini_sec_is
    test eax, eax
    jz 1b
    lea rdi, [rsp]
    lea rsi, [rip + .Lk_prefer]
    call ini_key_is
    test eax, eax
    jz 2f
    mov rdi, [rsp + INI_val]
    mov rsi, [rsp + INI_vallen]
    call parse_bool
    mov [rip + ini_prefer], eax
    jmp 1b
2:  lea rdi, [rsp]
    lea rsi, [rip + .Lk_theme]
    call ini_key_is
    test eax, eax
    jz 1b
    mov rdi, [rsp + INI_val]
    mov rsi, [rsp + INI_vallen]
    call linux_name_dark
    mov [rip + ini_name], eax
    jmp 1b
8:  mov rdi, rbx
    call mem_free
9:  EPILOGUE

# ini_watch(): settings.ini files written or replaced (and their folders appearing) are read again
ini_watch:
    PROLOGUE
    cmp byte ptr [rip + cfg_root], 0
    je 9f
    mov edi, IN_NONBLOCK | IN_CLOEXEC
    SYS SYS_inotify_init1
    test rax, rax
    js 9f
    mov [rip + ino_fd], eax
    call ini_add_watches
    mov edi, [rip + ino_fd]
    mov esi, POLLIN
    lea rdx, [rip + ini_readable]
    xor ecx, ecx
    call watch_add
    mov edi, CLOCK_MONOTONIC
    mov esi, O_NONBLOCK | O_CLOEXEC
    SYS SYS_timerfd_create
    test rax, rax
    js 9f
    mov [rip + again_fd], eax
    mov edi, eax
    mov esi, POLLIN
    lea rdx, [rip + ini_again]
    xor ecx, ecx
    call watch_add
    call again_arm              # folders may be in the making as rhun starts too
9:  EPILOGUE

# ini_add_watches() -> eax 1 when the watches end elsewhere than last time: the config folder (for
# gtk-3.0 and gtk-4.0 appearing), or while it does not exist the nearest folder above it (for it
# appearing), and the gtk folders. Adding a watch again only renews it. A folder made below the one
# found before its watch began sends nothing (mkdir -p makes them all at once), so the search runs
# again until it ends at the same watch twice: the same folder, watched since the last search looked
# below it, not one made again in its place.
ini_add_watches:
    PROLOGUE
    lea rdi, [rip + cfg_root]
    call strlen
    mov r14d, eax               # the config folder's length
    mov r12d, -1                # the watch the last search ended at
    mov r13d, 16                # searches at most, should folders keep coming and going
0:  lea rdi, [rip + path_buf]
    lea rsi, [rip + cfg_root]
    call cstr_copy
1:  mov edi, [rip + ino_fd]
    lea rsi, [rip + path_buf]
    mov edx, IN_CREATE | IN_MOVED_TO | IN_ONLYDIR
    SYS SYS_inotify_add_watch
    mov ebx, eax                # the watch, if it took
    test rax, rax
    jns 3f
    lea rdi, [rip + path_buf]
    call strlen
    lea rcx, [rip + path_buf]
2:  dec rax
    jle 4f                      # nothing above it but /
    cmp byte ptr [rcx + rax], '/'
    jne 2b
    mov byte ptr [rcx + rax], 0
    jmp 1b
3:  lea rdi, [rip + path_buf]
    call strlen
    cmp eax, r14d
    jae 4f                      # the config folder itself
    cmp ebx, r12d
    je 4f                       # the same watch as the last search: nothing new below it
    mov r12d, ebx
    dec r13d
    jnz 0b
4:  xor r15d, r15d
    cmp ebx, [rip + seen_end]
    setne r15b
    mov [rip + seen_end], ebx
    lea rdi, [rip + .Lgtk3_dir]
    call user_path
    mov edi, [rip + ino_fd]
    mov rsi, rax
    mov edx, INI_DIR_EVENTS
    SYS SYS_inotify_add_watch
    cmp eax, [rip + seen_gtk3]
    setne cl
    or r15b, cl
    mov [rip + seen_gtk3], eax
    lea rdi, [rip + .Lgtk4_dir]
    call user_path
    mov edi, [rip + ino_fd]
    mov rsi, rax
    mov edx, INI_DIR_EVENTS
    SYS SYS_inotify_add_watch
    cmp eax, [rip + seen_gtk4]
    setne cl
    or r15b, cl
    mov [rip + seen_gtk4], eax
    mov eax, r15d
    EPILOGUE

# ini_readable(fd, revents, ctx)
ini_readable:
    PROLOGUE
1:  mov edi, [rip + ino_fd]
    lea rsi, [rip + ino_buf]
    mov edx, 4096
    SYS SYS_read
    test rax, rax
    jg 1b
    call ini_add_watches
    call ini_read
    call report
    call again_arm
    EPILOGUE

# ini_again(fd, revents, ctx): a second look, AGAIN_MS after inotify spoke. A folder made in the
# moment its parent's watch is added can go unreported even though the search looked below that
# parent again once its watch was in place (a stress loop of tests/linux-appearance.py's made-at-once
# rounds lost one in 1,000 to 12,000 that way), and so can settings.ini in a gtk folder just watched.
# So the folders and the files are looked at again, and again for as long as the watches move.
ini_again:
    PROLOGUE
    mov edi, [rip + again_fd]
    lea rsi, [rip + ino_buf]
    mov edx, 8
    SYS SYS_read
    call ini_add_watches
    mov ebx, eax
    call ini_read
    call report
    test ebx, ebx
    jz 9f
    call again_arm
9:  EPILOGUE

# again_arm(): ini_again AGAIN_MS from now (a later arming moves it)
again_arm:
    mov edi, [rip + again_fd]
    test edi, edi
    js 1f
    xor esi, esi
    lea rdx, [rip + again_in]
    xor r10d, r10d
    SYS SYS_timerfd_settime
1:  ret

# ---------------------------------------------------------------- the portal over D-Bus

# db_open(): connect to the session bus, ask the portal, and wait a moment for its answers
db_open:
    PROLOGUE
    mov qword ptr [rip + db_len], 0
    mov qword ptr [rip + db_skip], 0
    mov dword ptr [rip + answers], 0
    call db_connect
    test eax, eax
    js 9f
    mov [rip + db_fd], eax
    call time_ms
    lea rbx, [rax + DB_WAIT_MS]
    mov rdi, rbx
    call db_auth
    test eax, eax
    jz 8f
    jns 3f
    mov dword ptr [rip + authing], 1    # a busy bus: its answer to AUTH comes to db_readable
    jmp 2f
3:  call db_send
    test eax, eax
    jz 8f
1:  cmp dword ptr [rip + answers], 3
    je 2f
    mov rdi, rbx
    call db_poll
    test eax, eax
    jz 2f
    call db_read
    test rax, rax
    jle 8f
    call db_process
    cmp dword ptr [rip + db_fd], 0
    jl 9f
    jmp 1b
2:  # later answers and signals arrive here
    mov edi, [rip + db_fd]
    mov esi, POLLIN
    lea rdx, [rip + db_readable]
    xor ecx, ecx
    call watch_add
    EPILOGUE
8:  call db_close
9:  EPILOGUE

# db_close()
db_close:
    PROLOGUE
    mov ebx, [rip + db_fd]
    test ebx, ebx
    js 9f
    mov dword ptr [rip + db_fd], -1
    mov edi, ebx
    call watch_remove
    mov edi, ebx
    SYS SYS_close
9:  EPILOGUE

# db_readable(fd, revents, ctx)
db_readable:
    PROLOGUE
    test esi, POLLIN
    jnz 1f
    test esi, POLLHUP | POLLERR
    jz 9f
    jmp 8f
1:  call db_read
    test rax, rax
    jle 8f
    cmp dword ptr [rip + authing], 0
    je 2f
    # the bus answers AUTH late: once it takes us, the requests
    call db_auth_line
    test eax, eax
    jz 9f
    js 8f
    mov dword ptr [rip + authing], 0
    call db_send
    test eax, eax
    jz 8f
    EPILOGUE
2:  call db_process
    call report
    EPILOGUE
8:  call db_close               # the bus went away: what it said last stays
9:  EPILOGUE

# db_connect() -> eax a socket connected to the session bus, or -1. The address is
# DBUS_SESSION_BUS_ADDRESS (unix: entries with path= or abstract=, values %-escaped), or without
# it systemd's $XDG_RUNTIME_DIR/bus.
db_connect:
    PROLOGUE 128
    lea rdi, [rip + .Lenv_bus]
    call getenv
    mov rbx, rax
    test rax, rax
    jnz .Ldc_entry
    lea rdi, [rip + .Lenv_runtime]
    call getenv
    test rax, rax
    jz .Ldc_fail
    mov r12, rax
    mov rdi, rax
    call strlen
    cmp rax, 96
    jae .Ldc_fail
    lea rdi, [rsp + 2]
    mov rsi, r12
    call cstr_copy
    mov rdi, rax
    lea rsi, [rip + .Lslash_bus]
    call cstr_copy
    lea rcx, [rsp + 2]
    sub rax, rcx
    lea esi, [rax + 3]          # the family, the path and its NUL
    lea rdi, [rsp]
    call db_try
    jmp .Ldc_ret
.Ldc_entry:
    cmp byte ptr [rbx], 0
    je .Ldc_fail
    mov rdi, rbx
    lea rsi, [rip + .Lunix]
    call prefix_is
    test eax, eax
    jz .Ldc_skip_entry
    add rbx, rax
.Ldc_pair:
    mov rdi, rbx
    lea rsi, [rip + .Lpath_eq]
    call prefix_is
    test eax, eax
    jz 1f
    add rbx, rax
    lea r14, [rsp + 2]
    jmp 3f
1:  mov rdi, rbx
    lea rsi, [rip + .Labstract_eq]
    call prefix_is
    test eax, eax
    jz .Ldc_skip_pair
    add rbx, rax
    mov byte ptr [rsp + 2], 0   # abstract names start with a NUL
    lea r14, [rsp + 3]
3:  xor r13d, r13d              # the value's length
4:  movzx eax, byte ptr [rbx]
    test eax, eax
    jz 5f
    cmp eax, ','
    je 5f
    cmp eax, ';'
    je 5f
    cmp r13d, 100
    jae .Ldc_skip_pair
    inc rbx
    cmp eax, '%'
    jne 41f
    movzx edi, byte ptr [rbx]
    call hex_digit
    test eax, eax
    js .Ldc_skip_pair
    mov r12d, eax
    movzx edi, byte ptr [rbx + 1]
    call hex_digit
    test eax, eax
    js .Ldc_skip_pair
    shl r12d, 4
    or eax, r12d
    add rbx, 2
41: mov [r14 + r13], al
    inc r13d
    jmp 4b
5:  mov byte ptr [r14 + r13], 0
    lea esi, [r13 + 3]          # path: family, path, NUL; abstract: family, NUL, name
    lea rdi, [rsp]
    call db_try
    test eax, eax
    jns .Ldc_ret
.Ldc_skip_pair:
    movzx eax, byte ptr [rbx]
    test eax, eax
    jz .Ldc_fail
    inc rbx
    cmp eax, ','
    je .Ldc_pair
    cmp eax, ';'
    je .Ldc_entry
    jmp .Ldc_skip_pair
.Ldc_skip_entry:
    movzx eax, byte ptr [rbx]
    test eax, eax
    jz .Ldc_fail
    inc rbx
    cmp eax, ';'
    je .Ldc_entry
    jmp .Ldc_skip_entry
.Ldc_fail:
    mov eax, -1
.Ldc_ret:
    EPILOGUE

# prefix_is(str, prefix cstr) -> eax the prefix's length if str starts with it, else 0
prefix_is:
    xor ecx, ecx
1:  movzx eax, byte ptr [rsi + rcx]
    test eax, eax
    jz 2f
    cmp al, [rdi + rcx]
    jne 3f
    inc ecx
    jmp 1b
2:  mov eax, ecx
    ret
3:  xor eax, eax
    ret

# hex_digit(c) -> eax 0-15, or -1
hex_digit:
    lea eax, [rdi - '0']
    cmp eax, 9
    jbe 9f
    or edi, 0x20
    lea eax, [rdi - 'a']
    cmp eax, 5
    ja 8f
    add eax, 10
    ret
8:  mov eax, -1
9:  ret

# db_try(sockaddr_un, length) -> eax a connected socket, or -1
db_try:
    PROLOGUE
    mov r12, rdi
    mov r13d, esi
    mov word ptr [r12], AF_UNIX
    mov edi, AF_UNIX
    mov esi, SOCK_STREAM | SOCK_CLOEXEC
    xor edx, edx
    SYS SYS_socket
    test rax, rax
    js 8f
    mov ebx, eax
    mov edi, eax
    mov rsi, r12
    mov edx, r13d
    SYS SYS_connect
    test rax, rax
    js 7f
    mov eax, ebx
    EPILOGUE
7:  mov edi, ebx
    SYS SYS_close
8:  mov eax, -1
    EPILOGUE

# db_poll(deadline ms) -> 1 when the bus has sent something before the deadline
db_poll:
    PROLOGUE 16
    mov rbx, rdi
1:  call time_ms
    mov rdx, rbx
    sub rdx, rax
    jle 8f
    mov eax, [rip + db_fd]
    mov [rsp], eax
    mov dword ptr [rsp + 4], POLLIN
    lea rdi, [rsp]
    mov esi, 1
    SYS SYS_poll
    cmp rax, -EINTR
    je 1b
    cmp rax, 1
    jne 8f
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# db_read() -> rax bytes added to db_in, or <= 0 when the bus closed or failed
db_read:
    mov rcx, [rip + db_len]
    mov edx, DB_BUF
    sub rdx, rcx
    jz 1f
    mov edi, [rip + db_fd]
    lea rsi, [rip + db_in]
    add rsi, rcx
    SYS SYS_read
    test rax, rax
    jle 2f
    add [rip + db_len], rax
2:  ret
1:  mov eax, 1                  # full: db_process makes room
    ret

# db_auth(deadline) -> 1 when the bus takes us, 0 when it refuses or fails, -1 when it has not
# answered by the deadline: AUTH EXTERNAL with our uid, its decimal digits in hex
db_auth:
    PROLOGUE 96
    mov r12, rdi
    mov byte ptr [rsp], 0       # the protocol starts with a NUL
    lea rdi, [rsp + 1]
    lea rsi, [rip + .Lauth]
    call cstr_copy
    mov r13, rax
    SYS SYS_getuid
    lea rdi, [rsp + 64]
    mov esi, eax
    call fmt_u64
    xor ecx, ecx
1:  movzx edx, byte ptr [rsp + 64 + rcx]
    mov byte ptr [r13], '3'
    mov [r13 + 1], dl
    add r13, 2
    inc ecx
    cmp rcx, rax
    jb 1b
    mov word ptr [r13], 0x0a0d
    add r13, 2
    lea rcx, [rsp]
    sub r13, rcx
    mov edi, [rip + db_fd]
    lea rsi, [rsp]
    mov rdx, r13
    call write_all
    test rax, rax
    jnz 8f
    # one line back: "OK <guid>"
2:  mov rdi, r12
    call db_poll
    test eax, eax
    jz 7f
    call db_read
    test rax, rax
    jle 8f
    call db_auth_line
    test eax, eax
    jz 2b
    js 8f
    EPILOGUE
7:  mov eax, -1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# db_auth_line() -> eax 1 when db_in holds the bus's "OK <guid>" line, 0 while the line is not whole,
# -1 for another answer
db_auth_line:
    mov rcx, [rip + db_len]
    lea rdi, [rip + db_in]
    xor eax, eax
    test rcx, rcx
    jz 9f
    cmp byte ptr [rdi + rcx - 1], 10
    je 3f
    cmp rcx, 1000
    jb 9f
    mov eax, -1
    ret
3:  mov qword ptr [rip + db_len], 0
    mov eax, -1
    cmp word ptr [rdi], 0x4b4f  # "OK "
    jne 9f
    cmp byte ptr [rdi + 2], ' '
    jne 9f
    mov eax, 1
9:  ret

# db_send() -> 1 once BEGIN and the requests are written
db_send:
    PROLOGUE
    lea rbx, [rip + requests]
1:  mov rsi, [rbx]
    test rsi, rsi
    jz 7f
    mov rdx, [rbx + 8]
    sub rdx, rsi
    mov edi, [rip + db_fd]
    call write_all
    test rax, rax
    jnz 8f
    add rbx, 16
    jmp 1b
7:  mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# db_process(): handle the whole messages in db_in
db_process:
    PROLOGUE
.Ldp_next:
    mov rax, [rip + db_skip]
    test rax, rax
    jz 1f
    mov rcx, [rip + db_len]
    cmp rax, rcx
    cmova rax, rcx
    sub [rip + db_skip], rax
    mov rdi, rax
    call db_shift
    cmp qword ptr [rip + db_skip], 0
    jne .Ldp_ret
1:  cmp qword ptr [rip + db_len], 16
    jb .Ldp_ret
    lea rbx, [rip + db_in]
    mov eax, [rbx + 12]         # header fields' length
    mov edx, [rbx + 4]          # body length
    cmp byte ptr [rbx], 'l'
    je 2f
    cmp byte ptr [rbx], 'B'
    jne .Ldp_broken
    bswap eax
    bswap edx
2:  cmp eax, 1 << 26
    ja .Ldp_broken
    cmp edx, 1 << 27
    ja .Ldp_broken
    add eax, 16 + 7
    and eax, -8
    mov r12d, eax               # the body's offset
    add rax, rdx
    mov r13, rax                # the message's length
    cmp r13, DB_BUF
    jbe 3f
    # nothing rhun asks for is that long: drop it
    sub r13, [rip + db_len]
    mov [rip + db_skip], r13
    mov qword ptr [rip + db_len], 0
    jmp .Ldp_ret
3:  cmp r13, [rip + db_len]
    ja .Ldp_ret
    cmp byte ptr [rbx], 'l'
    jne 4f                      # big-endian: not from this machine's portal
    mov rdi, r13
    mov esi, r12d
    call db_message
4:  mov rdi, r13
    call db_shift
    jmp .Ldp_next
.Ldp_broken:
    call db_close
.Ldp_ret:
    EPILOGUE

# db_shift(n): drop db_in's first n bytes
db_shift:
    mov rcx, [rip + db_len]
    sub rcx, rdi
    mov [rip + db_len], rcx
    lea rsi, [rip + db_in]
    add rsi, rdi
    lea rdi, [rip + db_in]
    rep movsb
    ret

# Message readers: rbx the message, r14 the offset read next, r15 the message's length. Carry set
# when the message ends first.
rd_align:
    lea r14, [r14 + rdi - 1]
    neg rdi
    and r14, rdi
    cmp r15, r14
    ret
rd_u32:
    mov edi, 4
    call rd_align
    jc 9f
    lea rax, [r14 + 4]
    cmp r15, rax
    jc 9f
    mov eax, [rbx + r14]
    add r14, 4
    clc
9:  ret
# rd_str() -> rax, rdx a string (or object path) without its NUL
rd_str:
    call rd_u32
    jc 9f
    mov edx, eax
    lea rax, [r14 + rdx + 1]
    cmp r15, rax
    jc 9f
    lea rax, [rbx + r14]
    lea r14, [r14 + rdx + 1]
    clc
9:  ret
# rd_sig() -> rax, rdx a signature
rd_sig:
    lea rax, [r14 + 1]
    cmp r15, rax
    jc 9f
    movzx edx, byte ptr [rbx + r14]
    lea rax, [r14 + rdx + 2]
    cmp r15, rax
    jc 9f
    lea rax, [rbx + r14 + 1]
    lea r14, [r14 + rdx + 2]
    clc
9:  ret
# rd_variant() -> ecx 'u' with edx the number, 's' with rax, rdx the string, or 0 for another type.
# Variants in variants are opened: Read answers with its value in one more.
rd_variant:
    push r12
    mov r12d, 4
1:  call rd_sig
    jc 9f
    cmp rdx, 1
    jne 8f
    movzx ecx, byte ptr [rax]
    cmp ecx, 'v'
    jne 2f
    dec r12d
    jnz 1b
    jmp 8f
2:  cmp ecx, 'u'
    jne 3f
    call rd_u32
    jc 9f
    mov edx, eax
    mov ecx, 'u'
    pop r12
    ret
3:  cmp ecx, 's'
    jne 8f
    call rd_str
    jc 9f
    mov ecx, 's'
    pop r12
    ret
8:  xor ecx, ecx
    pop r12
    clc
    ret
9:  pop r12
    stc
    ret

# db_message(length, body offset): a whole little-endian message at db_in
db_message:
    PROLOGUE 64
    lea rbx, [rip + db_in]
    mov r15, rdi
    mov [rsp], esi              # the body's offset
    mov dword ptr [rsp + 4], 0  # REPLY_SERIAL
    xor eax, eax
    mov [rsp + 8], rax          # MEMBER
    mov [rsp + 16], rax
    mov [rsp + 24], rax         # INTERFACE
    mov [rsp + 32], rax
    mov [rsp + 40], rax         # SIGNATURE
    mov [rsp + 48], rax
    mov r14d, 16
    mov eax, [rbx + 12]
    lea r13, [rax + 16]         # the header fields' end
.Ldm_field:
    cmp r14, r13
    jae .Ldm_fields
    mov edi, 8
    call rd_align
    jc .Ldm_ret
    lea rax, [r14 + 4]
    cmp r15, rax
    jc .Ldm_ret
    movzx r12d, byte ptr [rbx + r14]
    cmp byte ptr [rbx + r14 + 1], 1
    jne .Ldm_ret
    movzx ecx, byte ptr [rbx + r14 + 2]
    add r14, 4
    cmp ecx, 'u'
    je 1f
    cmp ecx, 'g'
    je 2f
    cmp ecx, 's'
    je 3f
    cmp ecx, 'o'
    je 3f
    jmp .Ldm_ret
1:  call rd_u32
    jc .Ldm_ret
    cmp r12d, 5
    jne .Ldm_field
    mov [rsp + 4], eax
    jmp .Ldm_field
2:  call rd_sig
    jc .Ldm_ret
    cmp r12d, 8
    jne .Ldm_field
    mov [rsp + 40], rax
    mov [rsp + 48], rdx
    jmp .Ldm_field
3:  call rd_str
    jc .Ldm_ret
    cmp r12d, 3
    jne 31f
    mov [rsp + 8], rax
    mov [rsp + 16], rdx
31: cmp r12d, 2
    jne .Ldm_field
    mov [rsp + 24], rax
    mov [rsp + 32], rdx
    jmp .Ldm_field
.Ldm_fields:
    mov r14d, [rsp]
    movzx eax, byte ptr [rbx + 1]
    cmp eax, 4
    je .Ldm_signal
    cmp eax, 2
    jb .Ldm_ret
    cmp eax, 3
    ja .Ldm_ret
    # an answer (2) or an error (3) for one of the Reads
    mov r12d, 1
    mov ecx, [rsp + 4]
    cmp ecx, SER_SCHEME
    je 4f
    mov r12d, 2
    cmp ecx, SER_GTK
    jne .Ldm_ret
4:  or [rip + answers], r12d
    cmp eax, 3
    je .Ldm_ret
    mov rdi, [rsp + 40]
    mov rsi, [rsp + 48]
    lea rdx, [rip + .Lsig_v]
    call str_eq_cstr
    test eax, eax
    jz .Ldm_ret
    call rd_variant
    jc .Ldm_ret
    cmp r12d, 1
    jne 5f
    cmp ecx, 'u'
    jne .Ldm_ret
    call set_scheme
    jmp .Ldm_ret
5:  cmp ecx, 's'
    jne .Ldm_ret
    mov rdi, rax
    mov rsi, rdx
    call linux_name_dark
    mov [rip + portal_name], eax
    jmp .Ldm_ret
.Ldm_signal:
    # SettingChanged(namespace, key, value) of the portal's Settings
    mov rdi, [rsp + 8]
    mov rsi, [rsp + 16]
    lea rdx, [rip + .Lsetting_changed]
    call str_eq_cstr
    test eax, eax
    jz .Ldm_ret
    mov rdi, [rsp + 24]
    mov rsi, [rsp + 32]
    lea rdx, [rip + .Lsettings_iface]
    call str_eq_cstr
    test eax, eax
    jz .Ldm_ret
    mov rdi, [rsp + 40]
    mov rsi, [rsp + 48]
    lea rdx, [rip + .Lsig_ssv]
    call str_eq_cstr
    test eax, eax
    jz .Ldm_ret
    call rd_str
    jc .Ldm_ret
    mov [rsp + 8], rax          # the namespace
    mov [rsp + 16], rdx
    call rd_str
    jc .Ldm_ret
    mov [rsp + 24], rax         # the key
    mov [rsp + 32], rdx
    call rd_variant
    jc .Ldm_ret
    mov [rsp + 40], rax
    mov [rsp + 48], rdx
    mov [rsp + 56], ecx
    mov rdi, [rsp + 8]
    mov rsi, [rsp + 16]
    lea rdx, [rip + .Lns_appearance]
    call str_eq_cstr
    test eax, eax
    jz 6f
    mov rdi, [rsp + 24]
    mov rsi, [rsp + 32]
    lea rdx, [rip + .Lk_scheme]
    call str_eq_cstr
    test eax, eax
    jz .Ldm_ret
    cmp dword ptr [rsp + 56], 'u'
    jne .Ldm_ret
    mov edx, [rsp + 48]
    call set_scheme
    jmp .Ldm_ret
6:  mov rdi, [rsp + 8]
    mov rsi, [rsp + 16]
    lea rdx, [rip + .Lns_gnome]
    call str_eq_cstr
    test eax, eax
    jz .Ldm_ret
    mov rdi, [rsp + 24]
    mov rsi, [rsp + 32]
    lea rdx, [rip + .Lk_gtk_theme]
    call str_eq_cstr
    test eax, eax
    jz .Ldm_ret
    cmp dword ptr [rsp + 56], 's'
    jne .Ldm_ret
    mov rdi, [rsp + 40]
    mov rsi, [rsp + 48]
    call linux_name_dark
    mov [rip + portal_name], eax
.Ldm_ret:
    EPILOGUE

# set_scheme(edx color-scheme): values past the spec's three are no preference
set_scheme:
    cmp edx, 2
    jbe 1f
    xor edx, edx
1:  mov [rip + scheme], edx
    ret

.section .rodata
.Lempty: .byte 0
.Lenv_config: .asciz "XDG_CONFIG_HOME"
.Lenv_home: .asciz "HOME"
.Ldot_config: .asciz "/.config"
.Lenv_bus: .asciz "DBUS_SESSION_BUS_ADDRESS"
.Lenv_runtime: .asciz "XDG_RUNTIME_DIR"
.Lslash_bus: .asciz "/bus"
.Lunix: .asciz "unix:"
.Lpath_eq: .asciz "path="
.Labstract_eq: .asciz "abstract="
.Lauth: .asciz "AUTH EXTERNAL "
.Lgtk3_ini: .asciz "/gtk-3.0/settings.ini"
.Lgtk4_ini: .asciz "/gtk-4.0/settings.ini"
.Lgtk3_dir: .asciz "/gtk-3.0"
.Lgtk4_dir: .asciz "/gtk-4.0"
.Ls_settings: .asciz "Settings"
.Lk_prefer: .asciz "gtk-application-prefer-dark-theme"
.Lk_theme: .asciz "gtk-theme-name"
.Lsig_v: .asciz "v"
.Lsig_ssv: .asciz "ssv"
.Lsetting_changed: .asciz "SettingChanged"
.Lsettings_iface: .asciz "org.freedesktop.portal.Settings"
.Lns_appearance: .asciz "org.freedesktop.appearance"
.Lk_scheme: .asciz "color-scheme"
.Lns_gnome: .asciz "org.gnome.desktop.interface"
.Lk_gtk_theme: .asciz "gtk-theme"

# The requests, as little-endian D-Bus messages: Hello, two AddMatch calls for the portal's
# SettingChanged signals (no reply wanted), and Read for color-scheme and for gtk-theme (serials
# SER_SCHEME and SER_GTK). Each message starts 8-aligned, so .balign inside it aligns as D-Bus
# counts from the message's start.
.macro DSTR text
    .balign 4
    .long 99f - 98f
98: .ascii "\text"
99: .byte 0
.endm
.macro HFIELD code, type, text
    .balign 8
    .byte \code, 1, \type, 0
    DSTR "\text"
.endm
.macro HSIG text
    .balign 8
    .byte 8, 1, 0x67, 0
    .byte 99f - 98f
98: .ascii "\text"
99: .byte 0
.endm
.macro BUS_CALL member
    HFIELD 1, 0x6f, "/org/freedesktop/DBus"
    HFIELD 6, 0x73, "org.freedesktop.DBus"
    HFIELD 2, 0x73, "org.freedesktop.DBus"
    HFIELD 3, 0x73, "\member"
.endm
.macro PORTAL_CALL member
    HFIELD 1, 0x6f, "/org/freedesktop/portal/desktop"
    HFIELD 6, 0x73, "org.freedesktop.portal.Desktop"
    HFIELD 2, 0x73, "org.freedesktop.portal.Settings"
    HFIELD 3, 0x73, "\member"
.endm

.Lbegin: .ascii "BEGIN\r\n"
.Lbegin_end:
.p2align 3
.Lhello:
    .byte 0x6c, 1, 0, 1
    .long 0, 1, 2f - 1f
1:  BUS_CALL Hello
2:  .balign 8
.Lhello_end:
.p2align 3
.Lmatch_appearance:
    .byte 0x6c, 1, 1, 1
    .long 4f - 3f, 2, 2f - 1f
1:  BUS_CALL AddMatch
    HSIG "s"
2:  .balign 8
3:  DSTR "type='signal',sender='org.freedesktop.portal.Desktop',interface='org.freedesktop.portal.Settings',member='SettingChanged',path='/org/freedesktop/portal/desktop',arg0='org.freedesktop.appearance'"
4:
.Lmatch_appearance_end:
.p2align 3
.Lmatch_gnome:
    .byte 0x6c, 1, 1, 1
    .long 4f - 3f, 3, 2f - 1f
1:  BUS_CALL AddMatch
    HSIG "s"
2:  .balign 8
3:  DSTR "type='signal',sender='org.freedesktop.portal.Desktop',interface='org.freedesktop.portal.Settings',member='SettingChanged',path='/org/freedesktop/portal/desktop',arg0='org.gnome.desktop.interface'"
4:
.Lmatch_gnome_end:
.p2align 3
.Lread_scheme:
    .byte 0x6c, 1, 0, 1
    .long 4f - 3f, SER_SCHEME, 2f - 1f
1:  PORTAL_CALL Read
    HSIG "ss"
2:  .balign 8
3:  DSTR "org.freedesktop.appearance"
    DSTR "color-scheme"
4:
.Lread_scheme_end:
.p2align 3
.Lread_gtk:
    .byte 0x6c, 1, 0, 1
    .long 4f - 3f, SER_GTK, 2f - 1f
1:  PORTAL_CALL Read
    HSIG "ss"
2:  .balign 8
3:  DSTR "org.gnome.desktop.interface"
    DSTR "gtk-theme"
4:
.Lread_gtk_end:
.p2align 3
requests:
    .quad .Lbegin, .Lbegin_end, .Lhello, .Lhello_end
    .quad .Lmatch_appearance, .Lmatch_appearance_end, .Lmatch_gnome, .Lmatch_gnome_end
    .quad .Lread_scheme, .Lread_scheme_end, .Lread_gtk, .Lread_gtk_end
    .quad 0
