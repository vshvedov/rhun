// rhun on macOS: process entry and the helpers translated x86 code calls
.include "mac.inc"

.equ STACK_SIZE, 16 << 20
.equ GUARD, 16384

// main(argc, argv, envp): an x86 stack as Linux starts a process, then sys_init and main
FN _main
    ENTER 1024
    mov x19, x0
    mov x20, x1
    mov x21, x2
    // Finder starts apps in /: the home folder is the project then
    mov x0, sp
    mov x1, #1024
    bl _getcwd
    cbz x0, 1f
    ldrh w9, [sp]
    cmp w9, #'/'
    b.ne 1f
    ADR x0, s_home
    bl _getenv
    cbz x0, 1f
    bl _chdir
1:  // and may pass -psn_ arguments
    mov x9, #1
    mov x10, #1
2:  cmp x9, x19
    b.hs 4f
    ldr x11, [x20, x9, lsl #3]
    ldr w12, [x11]
    mov w13, #0x702d            // "-psn"
    movk w13, #0x6e73, lsl #16
    add x9, x9, #1
    cmp w12, w13
    b.eq 2b
    str x11, [x20, x10, lsl #3]
    add x10, x10, #1
    b 2b
4:  mov x19, x10
    mov x0, #0
    mov x1, #STACK_SIZE
    mov w2, #3                  // PROT_READ | PROT_WRITE
    mov w3, #0x1002             // MAP_PRIVATE | MAP_ANON
    mov w4, #-1
    mov x5, #0
    bl _mmap
    cmn x0, #1
    b.eq 9f
    mov x22, x0
    mov x1, #GUARD
    mov w2, #0
    bl _mprotect
    mov x9, #STACK_SIZE
    add x28, x22, x9
    // argc, argv..., 0, envp..., 0
    mov x10, #0
1:  ldr x11, [x21, x10, lsl #3]
    cbz x11, 2f
    add x10, x10, #1
    b 1b
2:  add x11, x19, x10
    add x11, x11, #3
    sub x28, x28, x11, lsl #3
    and x28, x28, #~15
    str x19, [x28]
    add x12, x28, #8
    mov x13, #0
3:  cmp x13, x19
    b.hs 4f
    ldr x14, [x20, x13, lsl #3]
    str x14, [x12], #8
    add x13, x13, #1
    b 3b
4:  str xzr, [x12], #8
    mov x13, #0
5:  cmp x13, x10
    b.hs 6f
    ldr x14, [x21, x13, lsl #3]
    str x14, [x12], #8
    add x13, x13, #1
    b 5b
6:  str xzr, [x12]
    mov x0, x28
    XCALL sys_init
    XCALL main
    mov w0, w8
    bl _exit
9:  mov w0, #111
    bl _exit

.section __TEXT,__cstring,cstring_literals
s_home: .asciz "HOME"
.text

// ---- string instructions: rdi x0, rsi x1, rcx x3, rax x8; flags are kept (movs, stos)

// rep movsb, forward
FN x_rep_movsb
    cbz x3, 9f
    mrs x16, nzcv
    sub x9, x0, x1
    cmp x9, x3
    b.lo 5f                     // src < dst < src + n: bytes repeat, copy one by one
1:  cmp x3, #32
    b.lo 3f
    ldp q24, q25, [x1], #32
    stp q24, q25, [x0], #32
    sub x3, x3, #32
    b 1b
3:  cbz x3, 8f
5:  ldrb w9, [x1], #1
    strb w9, [x0], #1
    subs x3, x3, #1
    b.ne 5b
8:  msr nzcv, x16
9:  ret

// rep movsb with the direction flag set: rsi and rdi point at the last bytes
FN x_rep_movsb_back
    cbz x3, 9f
    mrs x16, nzcv
    cmp x0, x1
    b.lo 5f
1:  cmp x3, #16
    b.lo 3f
    ldur q24, [x1, #-15]
    stur q24, [x0, #-15]
    sub x1, x1, #16
    sub x0, x0, #16
    sub x3, x3, #16
    b 1b
3:  cbz x3, 8f
5:  ldrb w9, [x1], #-1
    strb w9, [x0], #-1
    subs x3, x3, #1
    b.ne 5b
8:  msr nzcv, x16
9:  ret

// rep stosb / stosd / stosq
FN x_rep_stosb
    cbz x3, 9f
    mrs x16, nzcv
    dup v24.16b, w8
1:  cmp x3, #16
    b.lo 3f
    str q24, [x0], #16
    sub x3, x3, #16
    b 1b
3:  cbz x3, 8f
4:  strb w8, [x0], #1
    sub x3, x3, #1
    cbnz x3, 4b
8:  msr nzcv, x16
9:  ret

FN x_rep_stosd
    cbz x3, 9f
    mrs x16, nzcv
    dup v24.4s, w8
1:  cmp x3, #4
    b.lo 3f
    str q24, [x0], #16
    sub x3, x3, #4
    b 1b
3:  cbz x3, 8f
4:  str w8, [x0], #4
    sub x3, x3, #1
    cbnz x3, 4b
8:  msr nzcv, x16
9:  ret

FN x_rep_stosq
    cbz x3, 9f
    mrs x16, nzcv
    dup v24.2d, x8
1:  cmp x3, #2
    b.lo 3f
    str q24, [x0], #16
    sub x3, x3, #2
    b 1b
3:  cbz x3, 8f
    str x8, [x0], #8
    sub x3, x3, #1
8:  msr nzcv, x16
9:  ret

// repe cmpsb: compare [rsi] with [rdi] while equal; flags of the last compare, as 8-bit values
FN x_repe_cmpsb
    cbz x3, 9f
1:  ldrb w9, [x1], #1
    ldrb w10, [x0], #1
    sub x3, x3, #1
    cmp w9, w10
    b.ne 2f
    cbnz x3, 1b
2:  lsl w9, w9, #24
    lsl w10, w10, #24
    cmp w9, w10
9:  ret

// repne scasb: scan [rdi] for al
FN x_repne_scasb
    cbz x3, 9f
    and w11, w8, #0xff
1:  ldrb w10, [x0], #1
    sub x3, x3, #1
    cmp w11, w10
    b.eq 2f
    cbnz x3, 1b
2:  lsl w9, w11, #24
    lsl w10, w10, #24
    cmp w9, w10
9:  ret

// div r64 with rdx not known to be zero: rdx:rax / x12 -> rax, remainder rdx
FN x_udiv128
    cbnz x2, 1f
    udiv x11, x8, x12
    msub x2, x11, x12, x8
    mov x8, x11
    ret
1:  mov x9, #64
2:  lsr x13, x2, #63
    extr x2, x2, x8, #63
    lsl x8, x8, #1
    cmp x2, x12
    cset x14, hs
    orr x14, x14, x13
    cbz x14, 3f
    sub x2, x2, x12
    orr x8, x8, #1
3:  subs x9, x9, #1
    b.ne 2b
    ret

// mac_pid_cwd(pid, buf, size) -> x8: the length of the process's current folder, written to buf with a
// NUL, or -1 (proc_pidinfo PROC_PIDVNODEPATHINFO: pvi_cdir.vip_path, 152 bytes into its 2352)
FN mac_pid_cwd
    ENTER 2368
    mov x19, x1
    mov x20, x2
    mov w1, #9
    mov x2, #0
    mov x3, sp
    mov w4, #2352
    bl _proc_pidinfo
    cmp w0, #2352
    b.ne 8f
    add x0, sp, #152
    bl _strlen
    cbz x0, 8f
    cmp x0, x20
    b.hs 8f
    mov x21, x0
    mov x0, x19
    add x1, sp, #152
    add x2, x21, #1
    bl _memcpy
    mov x8, x21
    b 9f
8:  mov x8, #-1
9:  LEAVE
    XRET

// mac_proc_list(buf, cap) -> x8: the number of pids written to buf (4 bytes each), or -1
FN mac_proc_list
    ENTER
    mov x19, x0
    mov x20, x1
    mov w0, #1                  // PROC_ALL_PIDS
    mov w1, #0
    mov x2, x19
    mov w3, w20
    bl _proc_listpids
    cmp w0, #0
    b.le 8f
    lsr w8, w0, #2              // bytes to pids; the int result's upper half is not defined
    b 9f
8:  mov x8, #-1
9:  LEAVE
    XRET

// mac_proc_name(pid, buf, size) -> x8: the process name's length, written with a NUL, or -1
FN mac_proc_name
    ENTER
    bl _proc_name               // pid, buf and size are already in w0, x1 and w2
    cmp w0, #0
    b.le 8f
    mov w8, w0
    b 9f
8:  mov x8, #-1
9:  LEAVE
    XRET

// mac_exe_path(buf, size) -> x8: the length of the running program's real path, written to buf with
// a NUL, or -1
FN mac_exe_path
    ENTER 1040
    mov x19, x0
    mov x20, x1
    mov w9, #1024
    str w9, [sp]
    add x0, sp, #16
    mov x1, sp
    bl __NSGetExecutablePath
    cbnz w0, 8f
    add x0, sp, #16
    mov x1, #0
    bl _realpath
    cbz x0, 8f
    mov x21, x0
    bl _strlen
    cmp x0, x20
    b.hs 7f
    mov x22, x0
    mov x0, x19
    mov x1, x21
    add x2, x22, #1
    bl _memcpy
    mov x0, x21
    bl _free
    mov x8, x22
    b 9f
7:  mov x0, x21
    bl _free
8:  mov x8, #-1
9:  LEAVE
    XRET
