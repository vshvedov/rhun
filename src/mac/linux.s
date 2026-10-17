// rhun on macOS: the Linux system calls rhun makes, on libSystem
//
// x_syscall takes the number in x8 (rax) and arguments in x0 x1 x2 x6 x4 x5 (rdi rsi rdx r10 r8 r9),
// returns the result or -errno (Linux numbering) in x8 and keeps every other register the x86
// syscall instruction keeps. Flags, structures and error numbers are converted where they differ.
.include "mac.inc"

.equ NSYS, 300
.equ L_EAGAIN, 11
.equ L_ENOSYS, 38

.text

FN x_syscall
    // AppKit may call back into rhun while poll waits: its x86 stack continues from here
    adrp x9, g_xsp@PAGE
    str x28, [x9, g_xsp@PAGEOFF]
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    sub sp, sp, #304
    stp x0, x1, [sp, #0]
    stp x2, x4, [sp, #16]
    stp x5, x6, [sp, #32]
    stp q0, q1, [sp, #48]
    stp q2, q3, [sp, #80]
    stp q4, q5, [sp, #112]
    stp q6, q7, [sp, #144]
    stp q16, q17, [sp, #176]
    stp q18, q19, [sp, #208]
    stp q20, q21, [sp, #240]
    stp q22, q23, [sp, #272]
    mov x3, x6
    cmp x8, #NSYS
    b.hs 1f
    ADR x9, sys_table
    ldr x9, [x9, x8, lsl #3]
    cbz x9, 1f
    blr x9
    b 2f
1:  mov x0, #-L_ENOSYS
2:  mov x8, x0
    ldp x0, x1, [sp, #0]
    ldp x2, x4, [sp, #16]
    ldp x5, x6, [sp, #32]
    ldp q0, q1, [sp, #48]
    ldp q2, q3, [sp, #80]
    ldp q4, q5, [sp, #112]
    ldp q6, q7, [sp, #144]
    ldp q16, q17, [sp, #176]
    ldp q18, q19, [sp, #208]
    ldp q20, q21, [sp, #240]
    ldp q22, q23, [sp, #272]
    mov sp, x29
    ldp x29, x30, [sp], #16
    ret

// linux_ret(x0): -1 becomes -errno in Linux numbering
linux_ret:
    cmn x0, #1
    b.ne 1f
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl ___error
    ldr w0, [x0]
    bl linux_errno
    neg x0, x0
    ldp x29, x30, [sp], #16
1:  ret

// linux_errno(w0 Darwin errno) -> x0 Linux errno
FN linux_errno
    cmp w0, #107
    b.hs 1f
    ADR x9, errno_map
    ldrb w0, [x9, w0, uxtw]
    ret
1:  mov x0, #5
    ret

// a system call that is one libSystem function; kind 32 when it returns int
.macro LIBC name, fn, kind=64
\name:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl \fn
    .if \kind == 32
    sxtw x0, w0
    .endif
    bl linux_ret
    ldp x29, x30, [sp], #16
    ret
.endm

LIBC sys_read, _read
LIBC sys_write, _write
LIBC sys_fsync, _fsync, 32
LIBC sys_fchmod, _fchmod, 32
LIBC sys_rename, _rename, 32
LIBC sys_mkdir, _mkdir, 32
LIBC sys_rmdir, _rmdir, 32
LIBC sys_unlink, _unlink, 32
LIBC sys_access, _access, 32
LIBC sys_readlink, _readlink
LIBC sys_getpid, _getpid, 32
LIBC sys_kill, _kill, 32
LIBC sys_ftruncate, _ftruncate, 32
LIBC sys_lseek, _lseek
LIBC sys_listen, _listen, 32
LIBC sys_pread, _pread
LIBC sys_nanosleep, _nanosleep, 32
LIBC sys_munmap, _munmap, 32
LIBC sys_dup2, _dup2, 32
LIBC sys_setsid, _setsid, 32
LIBC sys_chdir, _chdir, 32
LIBC sys_execve, _execve, 32

// vfork: a fork, as the child only reads memory before it execs (proc_spawn)
LIBC sys_vfork, _fork, 32
LIBC sys_fork, _fork, 32
// the extension sandbox: sandbox_init(profile, flags, &errorbuf) -> 0 or -1
LIBC sys_sandbox_init, _sandbox_init, 32
// realpath(path, buf) -> buf, or 0 (the Linux side sees 0 as failure)
LIBC sys_realpath, _realpath

// wait4(pid, status, options, rusage): Darwin encodes the status alike; rusage is not filled
sys_wait4:
    mov x3, #0
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl _wait4
    sxtw x0, w0
    bl linux_ret
    ldp x29, x30, [sp], #16
    ret

sys_exit:
    bl _exit

// open_flags(w1 Linux open flags) -> w1 Darwin flags
open_flags:
    and w9, w1, #3
    tst w1, #0x40
    b.eq 1f
    orr w9, w9, #0x200          // O_CREAT
1:  tst w1, #0x80
    b.eq 1f
    orr w9, w9, #0x800          // O_EXCL
1:  tst w1, #0x200
    b.eq 1f
    orr w9, w9, #0x400          // O_TRUNC
1:  tst w1, #0x400
    b.eq 1f
    orr w9, w9, #0x8            // O_APPEND
1:  tst w1, #0x800
    b.eq 1f
    orr w9, w9, #0x4            // O_NONBLOCK
1:  tst w1, #0x10000
    b.eq 1f
    orr w9, w9, #0x100000       // O_DIRECTORY
1:  tst w1, #0x20000
    b.eq 1f
    orr w9, w9, #0x100          // O_NOFOLLOW
1:  tst w1, #0x80000
    b.eq 1f
    orr w9, w9, #0x1000000      // O_CLOEXEC
1:  tst w1, #0x100
    b.eq 1f
    orr w9, w9, #0x20000        // O_NOCTTY
1:  mov w1, w9
    ret

// open(path, flags, mode): mode is variadic, so on the stack
sys_open:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    bl pts_path
    bl open_flags
    str x2, [sp, #16]
    sub sp, sp, #16
    str x2, [sp]
    bl _open
    add sp, sp, #16
    sxtw x0, w0
    bl linux_ret
    ldp x29, x30, [sp], #32
    ret

// openat(dirfd, path, flags, mode)
sys_openat:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    cmn w0, #100
    b.ne 1f
    mov w0, #-2                 // AT_FDCWD
1:  mov x10, x1
    mov w1, w2
    bl open_flags
    mov w2, w1
    mov x1, x10
    sub sp, sp, #16
    str x3, [sp]
    bl _openat
    add sp, sp, #16
    sxtw x0, w0
    bl linux_ret
    ldp x29, x30, [sp], #16
    ret

// pts_path(x0 path) -> x0: the Linux name of a pseudo-terminal, /dev/pts/N, is /dev/ttysNNN here
pts_path:
    ADR x9, pts_prefix
    mov x10, #0
1:  ldrb w11, [x9, x10]
    cbz w11, 2f
    ldrb w12, [x0, x10]
    cmp w11, w12
    b.ne 9f
    add x10, x10, #1
    b 1b
2:  mov x11, #0                 // N
    mov x13, #10
3:  ldrb w12, [x0, x10]
    cbz w12, 4f
    sub w12, w12, #'0'
    cmp w12, #9
    b.hi 9f
    madd x11, x11, x13, x12
    add x10, x10, #1
    b 3b
4:  stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x1, x2, [sp, #16]
    str x3, [sp, #32]
    ADR x0, pts_buf
    mov x1, #32
    ADR x2, pts_fmt
    sub sp, sp, #16
    str x11, [sp]
    bl _snprintf
    add sp, sp, #16
    ADR x0, pts_buf
    ldp x1, x2, [sp, #16]
    ldr x3, [sp, #32]
    ldp x29, x30, [sp], #48
9:  ret

// ioctl3(w0 fd, x1 request, x2 arg) -> w0: the argument is variadic, so on the stack
ioctl3:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    sub sp, sp, #16
    str x2, [sp]
    bl _ioctl
    add sp, sp, #16
    ldp x29, x30, [sp], #16
    ret

// ioctl(fd, request, arg): the terminal requests rhun makes, in Darwin numbering
.equ T_TIOCSCTTY, 0x20007461
.equ T_TIOCSWINSZ, 0x80087467
.equ T_TIOCGWINSZ, 0x40087468
.equ T_TIOCPTYGRANT, 0x20007454
.equ T_TIOCPTYUNLK, 0x20007452
.equ T_TIOCPTYGNAME, 0x40807453
.equ T_TIOCGETA, 0x40487413
.equ T_TIOCSETA, 0x80487414
.macro IMM32 reg, v
    mov \reg, #((\v) & 0xffff)
    movk \reg, #((\v) >> 16), lsl #16
.endm
.macro IS req, label
    IMM32 w9, \req
    cmp w1, w9
    b.eq \label
.endm
sys_ioctl:
    stp x29, x30, [sp, #-240]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov w19, w0
    mov x20, x2
    IS 0x540e, 1f
    IS 0x5414, 2f
    IS 0x5413, 3f
    IS 0x40045431, 4f
    IS 0x80045430, 5f
    IS 0x5401, 6f
    IS 0x5402, 7f
    mov x0, #-25                // ENOTTY
    b 99f
1:  IMM32 w1, T_TIOCSCTTY
    b 10f
2:  IMM32 w1, T_TIOCSWINSZ
    b 10f
3:  IMM32 w1, T_TIOCGWINSZ
10: bl ioctl3
    b 98f
4:  // TIOCSPTLCK: unlocking is grantpt and unlockpt; a pty cannot be locked again
    ldr w9, [x20]
    mov w0, #0
    cbnz w9, 98f
    mov w0, w19
    IMM32 w1, T_TIOCPTYGRANT
    bl ioctl3
    cbnz w0, 98f
    mov w0, w19
    IMM32 w1, T_TIOCPTYUNLK
    bl ioctl3
    b 98f
5:  // TIOCGPTN: the number at the end of the slave's name
    mov w0, w19
    IMM32 w1, T_TIOCPTYGNAME
    add x2, sp, #64
    bl ioctl3
    cbnz w0, 98f
    add x9, sp, #64
    mov x10, #0
    mov x13, #10
51: ldrb w11, [x9], #1
    cbz w11, 52f
    sub w11, w11, #'0'
    cmp w11, #9
    b.hi 53f
    madd x10, x10, x13, x11
    b 51b
53: mov x10, #0                 // not a digit: start over
    b 51b
52: str w10, [x20]
    mov w0, #0
    b 98f
6:  // TCGETS: Darwin termios (flags 8 bytes each, c_cc[20], speeds) -> Linux's kernel termios
    mov w0, w19
    IMM32 w1, T_TIOCGETA
    add x2, sp, #64
    bl ioctl3
    cbnz w0, 98f
    add x9, sp, #64
    mov x10, #0
61: ldr x11, [x9, x10, lsl #3]  // flag words pass unchanged: rhun only adds IUTF8, the same bit on both
    str w11, [x20, x10, lsl #2]
    add x10, x10, #1
    cmp x10, #4
    b.lo 61b
    strb wzr, [x20, #16]        // c_line
    ADR x12, cc_map
    mov x10, #0
62: ldrb w11, [x12, x10]
    mov w13, #0
    cmp w11, #0xff
    b.eq 63f
    add x13, x9, #32
    ldrb w13, [x13, x11]
63: add x14, x20, #17
    strb w13, [x14, x10]
    add x10, x10, #1
    cmp x10, #19
    b.lo 62b
    mov w0, #0
    b 98f
7:  // TCSETS: onto the current Darwin termios, which keeps the speeds and characters Linux lacks
    mov w0, w19
    IMM32 w1, T_TIOCGETA
    add x2, sp, #64
    bl ioctl3
    cbnz w0, 98f
    add x9, sp, #64
    mov x10, #0
71: ldr w11, [x20, x10, lsl #2]
    str x11, [x9, x10, lsl #3]
    add x10, x10, #1
    cmp x10, #4
    b.lo 71b
    ADR x12, cc_map
    mov x10, #0
72: ldrb w11, [x12, x10]
    cmp w11, #0xff
    b.eq 73f
    add x14, x20, #17
    ldrb w13, [x14, x10]
    add x15, x9, #32
    strb w13, [x15, x11]
73: add x10, x10, #1
    cmp x10, #19
    b.lo 72b
    mov w0, w19
    IMM32 w1, T_TIOCSETA
    add x2, sp, #64
    bl ioctl3
98: sxtw x0, w0
    bl linux_ret
99: ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #240
    ret

// close(fd): directories being listed close with their DIR
sys_close:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    cmp w0, #1024
    b.hs 1f
    ADR x9, dirs
    ldr x10, [x9, w0, uxtw #3]
    cbz x10, 1f
    str xzr, [x9, w0, uxtw #3]
    ADR x9, pend
    str xzr, [x9, w0, uxtw #3]
    mov x0, x10
    bl _closedir
    b 2f
1:  bl _close
2:  sxtw x0, w0
    bl linux_ret
    ldp x29, x30, [sp], #16
    ret

// stat_linux(x0 Darwin stat, x1 Linux stat)
stat_linux:
    ldrsw x9, [x0, #0]
    str x9, [x1, #0]            // st_dev
    ldr x9, [x0, #8]
    str x9, [x1, #8]            // st_ino
    ldrh w9, [x0, #6]
    str x9, [x1, #16]           // st_nlink
    ldrh w9, [x0, #4]
    str w9, [x1, #24]           // st_mode
    ldr w9, [x0, #16]
    str w9, [x1, #28]           // st_uid
    ldr w9, [x0, #20]
    str w9, [x1, #32]           // st_gid
    str wzr, [x1, #36]
    ldrsw x9, [x0, #24]
    str x9, [x1, #40]           // st_rdev
    ldr x9, [x0, #96]
    str x9, [x1, #48]           // st_size
    ldrsw x9, [x0, #112]
    str x9, [x1, #56]           // st_blksize
    ldr x9, [x0, #104]
    str x9, [x1, #64]           // st_blocks
    ldp x9, x10, [x0, #32]
    stp x9, x10, [x1, #72]      // st_atim
    ldp x9, x10, [x0, #48]
    stp x9, x10, [x1, #88]      // st_mtim
    ldp x9, x10, [x0, #64]
    stp x9, x10, [x1, #104]     // st_ctim
    stp xzr, xzr, [x1, #120]
    str xzr, [x1, #136]
    ret

// stat(path, buf), lstat, fstat(fd, buf)
.macro STAT name, fn
\name:
    stp x29, x30, [sp, #-176]!
    mov x29, sp
    str x1, [sp, #16]
    add x1, sp, #32
    bl \fn
    sxtw x0, w0
    bl linux_ret
    tbnz x0, #63, 1f
    add x0, sp, #32
    ldr x1, [sp, #16]
    bl stat_linux
    mov x0, #0
1:  ldp x29, x30, [sp], #176
    ret
.endm
STAT sys_stat, _stat
STAT sys_lstat, _lstat
STAT sys_fstat, _fstat

// getdents64(fd, buf, count): readdir on a DIR kept per descriptor; an entry that does not fit
// waits in pend (readdir's buffer stays valid until the next call) instead of telldir/seekdir,
// which is linear in the position on Darwin
sys_getdents64:
    ENTER 16
    mov w19, w0
    mov x20, x1
    mov x21, x2
    mov x22, #0                 // bytes written
    cmp w19, #1024
    b.hs 6f
    ADR x9, dirs
    ldr x23, [x9, w19, uxtw #3]
    cbnz x23, 1f
    mov w0, w19
    bl _fdopendir
    cbz x0, 8f
    mov x23, x0
    ADR x9, dirs
    str x23, [x9, w19, uxtw #3]
1:  ADR x9, pend
    ldr x25, [x9, w19, uxtw #3]
    str xzr, [x9, w19, uxtw #3]
    cbnz x25, 2f
    mov x0, x23
    bl _readdir
    cbz x0, 7f
    mov x25, x0
2:  ldrh w26, [x25, #18]        // d_namlen
    add x27, x26, #19 + 1 + 7   // header, name, NUL, rounded to 8
    and x27, x27, #~7
    add x9, x22, x27
    cmp x9, x21
    b.hi 5f
    add x0, x20, x22
    ldr x9, [x25, #0]
    str x9, [x0, #0]            // d_ino
    str x9, [x0, #8]            // d_off (unused)
    strh w27, [x0, #16]         // d_reclen
    ldrb w9, [x25, #20]
    strb w9, [x0, #18]          // d_type
    add x0, x0, #19
    add x1, x25, #21
    mov x2, x26
    bl _memcpy
    add x9, x20, x22
    add x9, x9, #19
    strb wzr, [x9, x26]
    add x22, x22, x27
    b 1b
5:  ADR x9, pend               // no room: next time
    str x25, [x9, w19, uxtw #3]
    cbnz x22, 7f
6:  mov x0, #-22                // EINVAL: buffer too small, or a descriptor past the table
    b 9f
7:  mov x0, x22
    b 9f
8:  mov x0, #-1
    bl linux_ret
9:  LEAVE
    ret

// mmap(addr, len, prot, flags, fd, off)
sys_mmap:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    mov w10, #0x13              // MAP_SHARED MAP_PRIVATE MAP_FIXED
    and w9, w3, w10
    tst w3, #0x20
    b.eq 1f
    orr w9, w9, #0x1000         // MAP_ANON
    mov w4, #-1
1:  mov w3, w9
    bl _mmap
    bl linux_ret
    ldp x29, x30, [sp], #16
    ret

// rt_sigaction(sig, act, oact, size): only SIG_IGN and SIG_DFL
sys_rt_sigaction:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    cbz x1, 1f
    ldr x1, [x1]
    cmp x1, #1
    b.hi 1f
    bl _signal
1:  mov x0, #0
    ldp x29, x30, [sp], #16
    ret

// set_fl(w0 fd, w1 Linux flags): O_NONBLOCK and O_CLOEXEC after the fact; keeps x0
.globl set_fl
set_fl:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x0, x1, [sp, #16]
    tbnz w0, #31, 9f
    tst w1, #0x800
    b.eq 1f
    sub sp, sp, #16
    mov x9, #4                  // O_NONBLOCK
    str x9, [sp]
    mov w1, #4                  // F_SETFL
    bl _fcntl
    add sp, sp, #16
1:  ldp x0, x1, [sp, #16]
    tst w1, #0x80000
    b.eq 9f
    sub sp, sp, #16
    mov x9, #1                  // FD_CLOEXEC
    str x9, [sp]
    mov w1, #2                  // F_SETFD
    bl _fcntl
    add sp, sp, #16
9:  ldp x0, x1, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// socket(domain, type | flags, proto)
sys_socket:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x1, [sp, #16]
    and w1, w1, #0xf
    bl _socket
    sxtw x0, w0
    bl linux_ret
    ldr x1, [sp, #16]
    bl set_fl
    ldp x29, x30, [sp], #32
    ret

// sockaddr_mac(x1 Linux sockaddr, x9 buffer of 112) -> x1 Darwin sockaddr, w2 length
sockaddr_mac:
    ldrh w10, [x1]
    cmp w10, #1
    b.ne 9f
    mov w10, #0
    add x11, x1, #2
    add x12, x9, #2
1:  ldrb w13, [x11, x10]
    strb w13, [x12, x10]
    cbz w13, 2f
    add w10, w10, #1
    cmp w10, #103
    b.lo 1b
    mov x1, #0                  // too long: no address
    ret
2:  add w2, w10, #3
    strb w2, [x9]
    mov w13, #1
    strb w13, [x9, #1]
    mov x1, x9
9:  ret

.macro SOCKADDR name, fn
\name:
    stp x29, x30, [sp, #-144]!
    mov x29, sp
    str x0, [sp, #128]
    add x9, sp, #16
    bl sockaddr_mac
    mov x0, #-36                // ENAMETOOLONG
    cbz x1, 9f
    ldr x0, [sp, #128]
    bl \fn
    sxtw x0, w0
    bl linux_ret
9:  ldp x29, x30, [sp], #144
    ret
.endm
SOCKADDR sys_bind, _bind
SOCKADDR sys_connect, _connect

// accept4(fd, addr, addrlen, flags): addresses are not reported
sys_accept4:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x3, [sp, #16]
    mov x1, #0
    mov x2, #0
    bl _accept
    sxtw x0, w0
    bl linux_ret
    tbnz x0, #63, 9f
    // Darwin passes the listener's O_NONBLOCK on; Linux does not
    str x0, [sp, #24]
    ldr x9, [sp, #16]
    tst w9, #0x800
    cset w9, ne
    lsl w9, w9, #2              // O_NONBLOCK or nothing
    sub sp, sp, #16
    str x9, [sp]
    mov w1, #4                  // F_SETFL
    bl _fcntl
    add sp, sp, #16
    ldr x0, [sp, #24]
    ldr x1, [sp, #16]
    and w1, w1, #0x80000        // O_CLOEXEC
    bl set_fl
9:  ldp x29, x30, [sp], #32
    ret

// pipe2(fds, flags)
sys_pipe2:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x0, x1, [sp, #16]
    bl _pipe
    sxtw x0, w0
    bl linux_ret
    tbnz x0, #63, 9f
    ldp x9, x1, [sp, #16]
    ldr w0, [x9]
    bl set_fl
    ldp x9, x1, [sp, #16]
    ldr w0, [x9, #4]
    bl set_fl
    mov x0, #0
9:  ldp x29, x30, [sp], #32
    ret

// fcntl(fd, cmd, arg): the O_NONBLOCK and O_APPEND bits differ
sys_fcntl:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x1, [sp, #16]
    cmp w1, #4                  // F_SETFL
    b.ne 1f
    and w9, w2, #3
    tst w2, #0x800
    b.eq 2f
    orr w9, w9, #4
2:  tst w2, #0x400
    b.eq 3f
    orr w9, w9, #8
3:  mov w2, w9
1:  sub sp, sp, #16
    str x2, [sp]
    bl _fcntl
    add sp, sp, #16
    sxtw x0, w0
    bl linux_ret
    ldr x1, [sp, #16]
    cmp w1, #3                  // F_GETFL
    b.ne 9f
    tbnz x0, #63, 9f
    and w9, w0, #3
    tst w0, #4
    b.eq 4f
    orr w9, w9, #0x800
4:  tst w0, #8
    b.eq 5f
    orr w9, w9, #0x400
5:  mov w0, w9
9:  ldp x29, x30, [sp], #32
    ret

// poll(fds, n, timeout): the window system waits here while it runs
sys_poll:
    ADR x9, g_poll_hook
    ldr x9, [x9]
    cbz x9, 1f
    br x9
1:  stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl _poll
    sxtw x0, w0
    bl linux_ret
    ldp x29, x30, [sp], #16
    ret

// clock_gettime(clock, ts): CLOCK_MONOTONIC is 6 here
sys_clock_gettime:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    cmp w0, #1
    b.ne 1f
    mov w0, #6
1:  bl _clock_gettime
    sxtw x0, w0
    bl linux_ret
    ldp x29, x30, [sp], #16
    ret

// getcwd(buf, size) -> length with the NUL
sys_getcwd:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x0, [sp, #16]
    bl _getcwd
    cbnz x0, 1f
    mov x0, #-1
    bl linux_ret
    b 9f
1:  ldr x0, [sp, #16]
    bl _strlen
    add x0, x0, #1
9:  ldp x29, x30, [sp], #32
    ret

// mremap: rhun copies when it fails
sys_mremap:
    mov x0, #-L_ENOSYS
    ret

.section __DATA,__const
.p2align 3
.macro SYS num, fn
    .org sys_table + \num * 8
    .quad \fn
.endm
sys_table:
    SYS 0, sys_read
    SYS 1, sys_write
    SYS 2, sys_open
    SYS 3, sys_close
    SYS 4, sys_stat
    SYS 5, sys_fstat
    SYS 6, sys_lstat
    SYS 7, sys_poll
    SYS 8, sys_lseek
    SYS 9, sys_mmap
    SYS 11, sys_munmap
    SYS 13, sys_rt_sigaction
    SYS 16, sys_ioctl
    SYS 17, sys_pread
    SYS 21, sys_access
    SYS 25, sys_mremap
    SYS 33, sys_dup2
    SYS 35, sys_nanosleep
    SYS 39, sys_getpid
    SYS 41, sys_socket
    SYS 42, sys_connect
    SYS 49, sys_bind
    SYS 50, sys_listen
    SYS 57, sys_fork
    SYS 58, sys_vfork
    SYS 59, sys_execve
    SYS 60, sys_exit
    SYS 61, sys_wait4
    SYS 62, sys_kill
    SYS 72, sys_fcntl
    SYS 74, sys_fsync
    SYS 77, sys_ftruncate
    SYS 79, sys_getcwd
    SYS 80, sys_chdir
    SYS 82, sys_rename
    SYS 83, sys_mkdir
    SYS 84, sys_rmdir
    SYS 87, sys_unlink
    SYS 89, sys_readlink
    SYS 91, sys_fchmod
    SYS 112, sys_setsid
    SYS 217, sys_getdents64
    SYS 228, sys_clock_gettime
    SYS 231, sys_exit
    SYS 254, sys_inotify_add_watch
    SYS 255, sys_inotify_rm_watch
    SYS 257, sys_openat
    SYS 288, sys_accept4
    SYS 290, sys_sandbox_init
    SYS 291, sys_realpath
    SYS 293, sys_pipe2
    SYS 294, sys_inotify_init1
    .org sys_table + NSYS * 8

pts_prefix: .asciz "/dev/pts/"
pts_fmt: .asciz "/dev/ttys%03u"
// Linux c_cc index -> Darwin's (0xff: none): VINTR VQUIT VERASE VKILL VEOF VTIME VMIN VSWTC VSTART
// VSTOP VSUSP VEOL VREPRINT VDISCARD VWERASE VLNEXT VEOL2, then two unused
cc_map: .byte 8, 9, 3, 5, 0, 17, 16, 0xff, 12, 13, 10, 1, 6, 15, 4, 14, 2, 0xff, 0xff

// Darwin errno -> Linux errno
errno_map:
    .byte 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 35, 12, 13, 14, 15, 16, 17, 18, 19
    .byte 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 11, 115, 114, 88, 89
    .byte 90, 91, 92, 93, 94, 95, 96, 97, 98, 99, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109
    .byte 110, 111, 40, 36, 112, 113, 39, 11, 87, 122, 116, 66, 5, 5, 5, 5, 5, 37, 38, 5
    .byte 5, 5, 5, 5, 75, 5, 5, 5, 5, 125, 43, 42, 84, 61, 74, 72, 61, 67, 63, 60
    .byte 71, 62, 95, 5, 131, 130, 5

.data
.p2align 3
.globl g_poll_hook, g_xsp
g_poll_hook: .quad 0
g_xsp: .quad 0                  // x86 stack pointer when rhun last entered native code

.bss
.p2align 3
pts_buf: .zero 32
dirs: .zero 8 * 1024
pend: .zero 8 * 1024
