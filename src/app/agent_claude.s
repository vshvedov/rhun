# the Claude Code driver (agent_drv.s's table for AS_kind AG_CLAUDE): it runs the user's installed
# claude on stream-json pipes. Not built yet: every function fails politely, so a Claude Code
# conversation shows the prompt box and Send gives an error row with the report.
.include "rhun.inc"

.text

# cl_start(AL*) -> eax 0, AL_report set
cl_start:
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rbx + AL_report]
    call sb_clear
    lea rdi, [rbx + AL_report]
    lea rsi, [rip + .Lnot_built]
    call sb_push_cstr
    xor eax, eax
    EPILOGUE

# cl_send(AL*, ptr, len) -> eax 0
cl_send:
    xor eax, eax
    ret

# cl_stop(AL*), cl_release(AL*)
cl_stop:
    ret

# cl_answer(AL*, AQ*, n) -> eax 0
cl_answer:
    xor eax, eax
    ret

# cl_held(AL*) -> eax HOLDER_NONE
cl_held:
    mov eax, HOLDER_NONE
    ret

.section .rodata
.p2align 3
.globl claude_drv
claude_drv:
    .long AG_CLAUDE, DRVC_NEW | DRVC_RESUME
    .quad .Lname, cl_start, cl_send, cl_stop, cl_answer, cl_stop, cl_held
.Lname: .asciz "Claude Code"
.Lnot_built: .asciz "not built yet"
