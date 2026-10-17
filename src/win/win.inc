# Windows adapters use rhun's register convention internally. Reserve the first 96 bytes
# of each frame for the Win64 shadow space and stack arguments before calling a Windows API.
.include "rhun.inc"

.macro API name
    call [rip + __imp_\name]
.endm

# Windows callbacks must also preserve rdi, rsi and xmm6-xmm15, which rhun may clobber.
.macro CALLBACK frame=0
    PROLOGUE 272 + \frame
    mov [rsp + 96 + \frame], rdi
    mov [rsp + 104 + \frame], rsi
    movdqu [rsp + 112 + \frame], xmm6
    movdqu [rsp + 128 + \frame], xmm7
    movdqu [rsp + 144 + \frame], xmm8
    movdqu [rsp + 160 + \frame], xmm9
    movdqu [rsp + 176 + \frame], xmm10
    movdqu [rsp + 192 + \frame], xmm11
    movdqu [rsp + 208 + \frame], xmm12
    movdqu [rsp + 224 + \frame], xmm13
    movdqu [rsp + 240 + \frame], xmm14
    movdqu [rsp + 256 + \frame], xmm15
.endm
.macro CALLBACK_END frame=0
    mov rdi, [rsp + 96 + \frame]
    mov rsi, [rsp + 104 + \frame]
    movdqu xmm6, [rsp + 112 + \frame]
    movdqu xmm7, [rsp + 128 + \frame]
    movdqu xmm8, [rsp + 144 + \frame]
    movdqu xmm9, [rsp + 160 + \frame]
    movdqu xmm10, [rsp + 176 + \frame]
    movdqu xmm11, [rsp + 192 + \frame]
    movdqu xmm12, [rsp + 208 + \frame]
    movdqu xmm13, [rsp + 224 + \frame]
    movdqu xmm14, [rsp + 240 + \frame]
    movdqu xmm15, [rsp + 256 + \frame]
    EPILOGUE
.endm

.equ FD_handle, 0
.equ FD_write, 8
.equ FD_kind, 16
.equ FD_flags, 20
.equ FD_path, 24
.equ FD_aux, 32
.equ FD_wend, 40                # a pipe's write end (rhun writes, the child reads)
.equ FD_full, 48                # GetTickCount64 when a non-blocking write last found it full
.equ FD_SIZE, 64
.equ FD_MAX, 1024
.equ FD_FILE, 1
.equ FD_DIR, 2
.equ FD_PIPE, 3
.equ FD_PTY, 4
.equ FD_SLAVE, 5
.equ FD_WATCH, 6
