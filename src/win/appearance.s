# system appearance query
.include "win.inc"

FN win_system_appearance_dark
    PROLOGUE 64
    mov rcx, 0xffffffff80000001  # HKEY_CURRENT_USER
    lea rdx, [rip + .Lpersonalize]
    lea r8, [rip + .Lapps_light]
    mov r9d, 0x10               # RRF_RT_REG_DWORD
    mov qword ptr [rsp + 32], 0 # no type output
    lea rax, [rip + light_value]
    mov [rsp + 40], rax
    mov dword ptr [rsp + 48], 4
    API RegGetValueW
    test eax, eax
    jnz 1f
    cmp dword ptr [rip + light_value], 0
    sete al
    movzx eax, al
    EPILOGUE
1:  mov eax, 1                 # use dark mode when Windows has no preference value
    EPILOGUE

.bss
.p2align 2
light_value: .long 0

.section .rdata,"dr"
.p2align 1
.Lpersonalize: .short 83,111,102,116,119,97,114,101,92,77,105,99,114,111,115,111,102,116,92,87,105,110,100,111,119,115,92,67,117,114,114,101,110,116,86,101,114,115,105,111,110,92,84,104,101,109,101,115,92,80,101,114,115,111,110,97,108,105,122,101,0
.Lapps_light: .short 65,112,112,115,85,115,101,76,105,103,104,116,84,104,101,109,101,0
