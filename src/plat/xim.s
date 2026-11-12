# xim: an X input method (XIM) client for the X11 backend, over the X transport: IBus, Fcitx and
# others serve it as XMODIFIERS=@im=NAME names them. Key presses go to the server, which sends
# back the keys it does not use (XIM_FORWARD_EVENT) and the text it composes: on-the-spot, so the
# composition is drawn at the editor's caret (XIM_PREEDIT_DRAW, ime.s) and committed text is typed
# (XIM_COMMIT). Strings come as compound text (ctext.s). Messages up to 20 bytes travel in client
# messages, longer ones in a window property the client message names.
.include "rhun.inc"

.equ XIM_CONNECT, 1
.equ XIM_CONNECT_REPLY, 2
.equ XIM_ERROR, 20
.equ XIM_OPEN, 30
.equ XIM_OPEN_REPLY, 31
.equ XIM_CREATE_IC, 50
.equ XIM_CREATE_IC_REPLY, 51
.equ XIM_SET_IC_FOCUS, 58
.equ XIM_UNSET_IC_FOCUS, 59
.equ XIM_FORWARD_EVENT, 60
.equ XIM_SYNC, 61
.equ XIM_SYNC_REPLY, 62
.equ XIM_COMMIT, 63
.equ XIM_PREEDIT_START, 73
.equ XIM_PREEDIT_START_REPLY, 74
.equ XIM_PREEDIT_DRAW, 75
.equ XIM_PREEDIT_CARET, 76
.equ XIM_PREEDIT_CARET_REPLY, 77
.equ XIM_PREEDIT_DONE, 78

.equ XS_OFF, 0
.equ XS_CONNECTING, 1           # _XIM_XCONNECT sent to the server's window
.equ XS_OPENING, 2              # XIM_CONNECT, then XIM_OPEN sent
.equ XS_CREATING, 3             # XIM_CREATE_IC sent
.equ XS_READY, 4                # an input context: keys go to the server

.equ PQ_MAX, 16                 # property reads in flight
.equ PE_MAX, 1024               # the composition, UTF-8

.bss
.p2align 2
state: .long 0
server: .long 0                 # the @server=NAME selection's owner
comm: .long 0                   # the server's window for this connection
a_xconnect: .long 0
a_protocol: .long 0
a_data: .long 0                 # rhun's property for long messages to the server
imid: .long 0
icid: .long 0
at_style: .long 0               # input context attribute ids from XIM_OPEN_REPLY
at_client: .long 0
at_focus: .long 0
focused: .long 0
pq_seq: .zero 4 * PQ_MAX        # GetProperty sequence numbers and message lengths, in order
pq_len: .zero 4 * PQ_MAX
pq_head: .long 0
pq_n: .long 0
pe_len: .long 0
pe: .zero PE_MAX
msg: .zero 512                  # a message being built
text: .zero 4096                # a decoded string
name: .zero 300

.text

# xim_open(): connect to the input method XMODIFIERS names, if its server runs. After the window
# exists, while synchronous requests are allowed.
FN xim_open
    PROLOGUE 16
    lea rdi, [rip + .Lxmodifiers]
    call getenv
    test rax, rax
    jz 9f
    # "@im=NAME", NAME up to the next @
    mov rsi, rax
1:  movzx eax, byte ptr [rsi]
    test eax, eax
    jz 9f
    cmp eax, '@'
    jne 2f
    cmp byte ptr [rsi + 1], 'i'
    jne 2f
    cmp byte ptr [rsi + 2], 'm'
    jne 2f
    cmp byte ptr [rsi + 3], '='
    je 3f
2:  inc rsi
    jmp 1b
3:  add rsi, 4
    lea rdi, [rip + name]
    lea rcx, [rip + .Lserver]
    mov edx, 8
4:  mov al, [rcx]
    mov [rdi], al
    inc rcx
    inc rdi
    dec edx
    jnz 4b
    xor edx, edx
5:  movzx eax, byte ptr [rsi + rdx]
    test eax, eax
    jz 6f
    cmp eax, '@'
    je 6f
    cmp edx, 255
    jae 9f
    mov [rdi + rdx], al
    inc edx
    jmp 5b
6:  test edx, edx
    jz 9f
    mov byte ptr [rdi + rdx], 0
    lea rdi, [rip + name + 8]
    lea rsi, [rip + .Lnone]
    call strcmp_eq
    test eax, eax
    jnz 9f
    lea rdi, [rip + name]
    call x_intern
    mov edi, eax
    call x_selection_owner
    test eax, eax
    jz 9f
    mov [rip + server], eax
    lea rdi, [rip + .Lxconnect]
    call x_intern
    mov [rip + a_xconnect], eax
    lea rdi, [rip + .Lprotocol]
    call x_intern
    mov [rip + a_protocol], eax
    lea rdi, [rip + .Ldata]
    call x_intern
    mov [rip + a_data], eax
    # _XIM_XCONNECT: rhun's window, transport version 0.0 (client messages and properties)
    mov edi, [rip + server]
    mov esi, [rip + a_xconnect]
    mov edx, 32
    mov ecx, [rip + x_send_main_window]
    xor r8d, r8d
    call client_message
    mov dword ptr [rip + state], XS_CONNECTING
    call x_flush
9:  EPILOGUE

# client_message(window, type, format, first long, data ptr or 0 (20 bytes when format 8))
client_message:
    PROLOGUE 48
    mov rbx, r8
    mov r12d, ecx
    mov r13d, edx
    mov r14d, edi
    mov r15d, esi
    mov rdi, rsp
    xor esi, esi
    mov edx, 44
    call memset
    mov byte ptr [rsp], 25      # SendEvent, no propagation, no event mask
    mov word ptr [rsp + 2], 11
    mov [rsp + 4], r14d
    mov byte ptr [rsp + 12], 33 # ClientMessage
    mov [rsp + 13], r13b
    mov [rsp + 16], r14d
    mov [rsp + 20], r15d
    test rbx, rbx
    jnz 1f
    mov [rsp + 24], r12d
    jmp 2f
1:  lea rdi, [rsp + 24]
    mov rsi, rbx
    mov edx, 20
    call memcpy
2:  mov rdi, rsp
    mov esi, 44
    call x_req
    EPILOGUE

# send(length): msg to the server, its header's length field filled in
send:
    PROLOGUE 48
    mov ebx, edi
    lea eax, [rbx - 4]
    shr eax, 2
    mov [rip + msg + 2], ax
    cmp ebx, 20
    ja 1f
    lea rdi, [rip + msg]
    add rdi, rbx
    mov edx, 20
    sub edx, ebx
    xor esi, esi
    call memset
    mov edi, [rip + comm]
    mov esi, [rip + a_protocol]
    mov edx, 8
    lea r8, [rip + msg]
    call client_message
    jmp 9f
1:  # ChangeProperty append, STRING, format 8, then a format 32 message naming it
    lea r12d, [rbx + 3]
    and r12d, -4
    lea edi, [r12 + 24]
    call mem_alloc
    test rax, rax
    jz 9f
    mov r13, rax
    mov byte ptr [r13], 18
    mov byte ptr [r13 + 1], 2   # PropModeAppend
    lea eax, [r12 + 24]
    shr eax, 2
    mov [r13 + 2], ax
    mov eax, [rip + comm]
    mov [r13 + 4], eax
    mov eax, [rip + a_data]
    mov [r13 + 8], eax
    mov dword ptr [r13 + 12], 31    # STRING
    mov dword ptr [r13 + 16], 8
    mov [r13 + 20], ebx
    lea rdi, [r13 + 24]
    mov esi, r12d
    xor eax, eax
    mov ecx, r12d
    push rdi
    rep stosb
    pop rdi
    lea rsi, [rip + msg]
    mov edx, ebx
    call memcpy
    mov rdi, r13
    lea esi, [r12 + 24]
    call x_req
    mov rdi, r13
    call mem_free
    mov [rsp], ebx
    mov eax, [rip + a_data]
    mov [rsp + 4], eax
    mov qword ptr [rsp + 8], 0
    mov qword ptr [rsp + 16], 0
    mov edi, [rip + comm]
    mov esi, [rip + a_protocol]
    mov edx, 32
    mov rcx, 0
    mov r8, rsp
    call client_message
9:  call x_flush
    EPILOGUE

# head(major): msg starts major, minor 0, imid, icid; -> 8
head:
    mov [rip + msg], dil
    mov byte ptr [rip + msg + 1], 0
    mov eax, [rip + imid]
    mov [rip + msg + 4], ax
    mov eax, [rip + icid]
    mov [rip + msg + 6], ax
    mov eax, 8
    ret

# xim_client(event) -> eax 1 when the client message was the input method's
FN xim_client
    PROLOGUE 16
    mov rbx, rdi
    cmp dword ptr [rip + state], XS_OFF
    je 8f
    mov eax, [rbx + 8]
    cmp eax, [rip + a_xconnect]
    je .Lxc_connect
    cmp eax, [rip + a_protocol]
    jne 8f
    cmp byte ptr [rbx + 1], 8
    je .Lxc_short
    # format 32: the message is in the property it names on rhun's window
    mov eax, [rip + pq_n]
    cmp eax, PQ_MAX
    jae 7f
    mov ecx, [rbx + 12]         # length
    mov edx, [rbx + 16]         # property
    test ecx, ecx
    jz 7f
    cmp ecx, 65536
    ja 7f
    mov [rsp], ecx
    mov byte ptr [rip + msg], 20    # GetProperty, deleting it, any type
    mov byte ptr [rip + msg + 1], 1
    mov word ptr [rip + msg + 2], 6
    mov eax, [rip + x_send_main_window]
    mov [rip + msg + 4], eax
    mov [rip + msg + 8], edx
    mov dword ptr [rip + msg + 12], 0
    mov dword ptr [rip + msg + 16], 0
    mov dword ptr [rip + msg + 20], 16384
    lea rdi, [rip + msg]
    mov esi, 24
    call x_req
    mov eax, [rip + pq_head]
    add eax, [rip + pq_n]
    and eax, PQ_MAX - 1
    mov ecx, [rip + x_wire_sequence]
    and ecx, 0xffff
    lea rdx, [rip + pq_seq]
    mov [rdx + rax*4], ecx
    mov ecx, [rsp]
    lea rdx, [rip + pq_len]
    mov [rdx + rax*4], ecx
    inc dword ptr [rip + pq_n]
    call x_flush
    jmp 7f
.Lxc_short:
    movzx esi, word ptr [rbx + 14]
    shl esi, 2
    add esi, 4
    cmp esi, 20
    jbe 1f
    mov esi, 20
1:  lea rdi, [rbx + 12]
    call message
    jmp 7f
.Lxc_connect:
    cmp dword ptr [rip + state], XS_CONNECTING
    jne 7f
    mov eax, [rbx + 12]
    mov [rip + comm], eax
    # its destruction (the server quit) gives the keys back to rhun: xim_destroyed
    mov byte ptr [rip + msg], 2         # ChangeWindowAttributes
    mov word ptr [rip + msg + 2], 4
    mov [rip + msg + 4], eax
    mov dword ptr [rip + msg + 8], 0x800    # CWEventMask
    mov dword ptr [rip + msg + 12], 0x20000 # StructureNotify
    lea rdi, [rip + msg]
    mov esi, 16
    call x_req
    # XIM_CONNECT: little-endian, protocol 1.0, no authentication
    mov byte ptr [rip + msg], XIM_CONNECT
    mov byte ptr [rip + msg + 1], 0
    mov byte ptr [rip + msg + 4], 'l'
    mov byte ptr [rip + msg + 5], 0
    mov word ptr [rip + msg + 6], 1
    mov word ptr [rip + msg + 8], 0
    mov word ptr [rip + msg + 10], 0
    mov dword ptr [rip + state], XS_OPENING
    mov edi, 12
    call send
7:  mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# xim_reply(reply, length) -> eax 1 when it was a property read of the input method's
FN xim_reply
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    cmp dword ptr [rip + pq_n], 0
    je 8f
    movzx eax, word ptr [rbx + 2]
    mov ecx, [rip + pq_head]
    lea rdx, [rip + pq_seq]
    cmp eax, [rdx + rcx*4]
    jne 8f
    lea rdx, [rip + pq_len]
    mov r13d, [rdx + rcx*4]
    inc ecx
    and ecx, PQ_MAX - 1
    mov [rip + pq_head], ecx
    dec dword ptr [rip + pq_n]
    cmp byte ptr [rbx], 1
    jne 7f
    mov eax, [rbx + 16]         # value length (format 8: bytes)
    cmp r13d, eax
    jbe 1f
    mov r13d, eax
1:  lea eax, [r12 - 32]
    cmp r13d, eax
    jbe 2f
    mov r13d, eax
2:  lea rdi, [rbx + 32]
    mov esi, r13d
    call message
7:  mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# xim_key(event) -> eax 1 when the key press went to the input method
FN xim_key
    PROLOGUE 16
    mov rbx, rdi
    xor eax, eax
    cmp dword ptr [rip + state], XS_READY
    jne 9f
    mov edi, XIM_FORWARD_EVENT
    call head
    mov word ptr [rip + msg + 8], 0     # asynchronous
    mov word ptr [rip + msg + 10], 0    # serial
    lea rdi, [rip + msg + 12]
    mov rsi, rbx
    mov edx, 32
    call memcpy
    mov edi, 44
    call send
    mov eax, 1
9:  EPILOGUE

# xim_focus(in): the input context follows the window's focus
FN xim_focus
    PROLOGUE
    mov [rip + focused], edi
    cmp dword ptr [rip + state], XS_READY
    jne 9f
    mov ebx, XIM_SET_IC_FOCUS
    test edi, edi
    jnz 1f
    mov ebx, XIM_UNSET_IC_FOCUS
1:  mov edi, ebx
    call head
    mov edi, eax
    call send
9:  EPILOGUE

# xim_destroyed(DestroyNotify event): the server's window went away with the server
FN xim_destroyed
    cmp dword ptr [rip + state], XS_CONNECTING
    jbe 9f
    mov eax, [rdi + 8]
    cmp eax, [rip + comm]
    jne 9f
    mov dword ptr [rip + state], XS_OFF
    mov dword ptr [rip + pq_n], 0
    mov dword ptr [rip + pe_len], 0
    push rbx
    xor edi, edi
    xor esi, esi
    call ime_preedit
    pop rbx
9:  ret

# message(ptr, length): one message from the server
message:
    PROLOGUE 16
    mov rbx, rdi
    mov r12d, esi
    cmp r12d, 4
    jb 9f
    movzx eax, byte ptr [rbx]
    cmp eax, XIM_CONNECT_REPLY
    je .Lxm_connected
    cmp eax, XIM_OPEN_REPLY
    je .Lxm_opened
    cmp eax, XIM_CREATE_IC_REPLY
    je .Lxm_created
    cmp eax, XIM_ERROR
    je .Lxm_error
    cmp dword ptr [rip + state], XS_READY
    jne 9f
    cmp r12d, 8
    jb 9f
    cmp eax, XIM_FORWARD_EVENT
    je .Lxm_forward
    cmp eax, XIM_COMMIT
    je .Lxm_commit
    cmp eax, XIM_SYNC
    je .Lxm_sync
    cmp eax, XIM_PREEDIT_START
    je .Lxm_pe_start
    cmp eax, XIM_PREEDIT_DRAW
    je .Lxm_pe_draw
    cmp eax, XIM_PREEDIT_CARET
    je .Lxm_pe_caret
    cmp eax, XIM_PREEDIT_DONE
    je .Lxm_pe_done
    jmp 9f
.Lxm_connected:
    cmp dword ptr [rip + state], XS_OPENING
    jne 9f
    # XIM_OPEN: the locale's name
    lea rdi, [rip + .Llc_all]
    call locale_name
    test rax, rax
    jnz 1f
    lea rdi, [rip + .Llc_ctype]
    call locale_name
    test rax, rax
    jnz 1f
    lea rdi, [rip + .Llang]
    call locale_name
    test rax, rax
    jnz 1f
    lea rax, [rip + .Lc]
1:  mov r13, rax
    mov rdi, rax
    call strlen
    cmp eax, 200
    jbe 2f
    mov eax, 200
2:  mov r14d, eax
    mov byte ptr [rip + msg], XIM_OPEN
    mov byte ptr [rip + msg + 1], 0
    mov [rip + msg + 4], al
    lea rdi, [rip + msg + 5]
    mov rsi, r13
    mov edx, r14d
    call memcpy
    lea edi, [r14 + 5]
    lea eax, [r14 + 5 + 3]
    and eax, -4
    lea rcx, [rip + msg]
3:  cmp edi, eax
    jae 4f
    mov byte ptr [rcx + rdi], 0
    inc edi
    jmp 3b
4:  mov edi, eax
    call send
    jmp 9f
.Lxm_opened:
    # imid, the IM attributes, then the IC attributes: id, type, name length, name, padding
    cmp r12d, 8
    jb .Lxm_fail
    movzx eax, word ptr [rbx + 4]
    mov [rip + imid], eax
    movzx eax, word ptr [rbx + 6]
    lea r13d, [rax + 8]         # the IC attributes' length
    cmp r13d, r12d
    jae .Lxm_fail
    movzx r14d, word ptr [rbx + r13]
    add r13d, 4
    add r14d, r13d              # their end
    cmp r14d, r12d
    jbe 1f
    mov r14d, r12d
1:  lea eax, [r13 + 6]
    cmp eax, r14d
    ja 5f
    movzx r15d, word ptr [rbx + r13 + 4]  # name length
    lea eax, [r13 + 6 + r15]
    cmp eax, r14d
    ja 5f
    lea rdi, [rbx + r13 + 6]
    mov esi, r15d
    lea rdx, [rip + .Lstyle]
    call str_eq_cstr
    lea rcx, [rip + at_style]
    test eax, eax
    jnz 2f
    lea rdi, [rbx + r13 + 6]
    mov esi, r15d
    lea rdx, [rip + .Lclient]
    call str_eq_cstr
    lea rcx, [rip + at_client]
    test eax, eax
    jnz 2f
    lea rdi, [rbx + r13 + 6]
    mov esi, r15d
    lea rdx, [rip + .Lfocus]
    call str_eq_cstr
    lea rcx, [rip + at_focus]
    test eax, eax
    jz 3f
2:  movzx eax, word ptr [rbx + r13]
    or eax, 0x10000             # found (an id may be 0)
    mov [rcx], eax
3:  lea r13d, [r13 + 6 + r15 + 3]
    and r13d, -4
    jmp 1b
5:  cmp dword ptr [rip + at_style], 0
    je .Lxm_fail
    cmp dword ptr [rip + at_client], 0
    je .Lxm_fail
    # XIM_CREATE_IC: on-the-spot composition, no status; rhun's window as client and focus
    mov byte ptr [rip + msg], XIM_CREATE_IC
    mov byte ptr [rip + msg + 1], 0
    mov eax, [rip + imid]
    mov [rip + msg + 4], ax
    lea r13, [rip + msg + 8]
    mov eax, [rip + at_style]
    mov [r13], ax
    mov word ptr [r13 + 2], 4
    mov dword ptr [r13 + 4], 0x0402     # XIMPreeditCallbacks | XIMStatusNothing
    mov eax, [rip + at_client]
    mov [r13 + 8], ax
    mov word ptr [r13 + 10], 4
    mov eax, [rip + x_send_main_window]
    mov [r13 + 12], eax
    mov ecx, 16
    cmp dword ptr [rip + at_focus], 0
    je 6f
    mov eax, [rip + at_focus]
    mov [r13 + 16], ax
    mov word ptr [r13 + 18], 4
    mov eax, [rip + x_send_main_window]
    mov [r13 + 20], eax
    mov ecx, 24
6:  mov [rip + msg + 6], cx
    lea edi, [rcx + 8]
    mov dword ptr [rip + state], XS_CREATING
    call send
    jmp 9f
.Lxm_created:
    cmp r12d, 8
    jb .Lxm_fail
    movzx eax, word ptr [rbx + 6]
    mov [rip + icid], eax
    mov dword ptr [rip + state], XS_READY
    cmp dword ptr [rip + focused], 0
    je 9f
    mov edi, 1
    call xim_focus
    jmp 9f
.Lxm_error:
    # before an input context there is none to use: keys stay rhun's
    cmp dword ptr [rip + state], XS_READY
    je 9f
.Lxm_fail:
    mov dword ptr [rip + state], XS_OFF
    lea rdi, [rip + .Lfailed]
    call log_cstr
    jmp 9f
.Lxm_forward:
    # flag, serial, then the key event the server did not use: rhun's own handling
    cmp r12d, 44
    jb 9f
    movzx eax, word ptr [rbx + 8]
    mov [rsp], eax
    movzx eax, byte ptr [rbx + 12]
    and eax, 0x7f
    cmp eax, 2                  # KeyPress
    jne 1f
    movzx edi, byte ptr [rbx + 13]
    movzx esi, word ptr [rbx + 12 + 28]
    call x_key_test
1:  test dword ptr [rsp], 1
    jz 9f
    jmp .Lxm_sync
.Lxm_commit:
    # flag: 1 synchronous, 2 characters, 4 keysym (before the characters)
    movzx eax, word ptr [rbx + 8]
    mov [rsp], eax
    mov r13d, 10
    test eax, 4
    jz 1f
    add r13d, 6
1:  test dword ptr [rsp], 2
    jz 2f
    lea eax, [r13 + 2]
    cmp eax, r12d
    ja 2f
    movzx esi, word ptr [rbx + r13]
    add eax, esi
    cmp eax, r12d
    ja 2f
    lea rdi, [rbx + r13 + 2]
    lea rdx, [rip + text]
    mov ecx, 4096
    call ct_decode
    lea rdi, [rip + text]
    mov rsi, rax
    call ime_commit
2:  test dword ptr [rsp], 1
    jz 9f
.Lxm_sync:
    mov edi, XIM_SYNC_REPLY
    call head
    mov edi, eax
    call send
    jmp 9f
.Lxm_pe_start:
    xor eax, eax
    mov [rip + pe_len], eax
    mov edi, XIM_PREEDIT_START_REPLY
    call head
    mov dword ptr [rip + msg + 8], -1   # no length limit
    mov edi, 12
    call send
    jmp 9f
.Lxm_pe_caret:
    mov edi, XIM_PREEDIT_CARET_REPLY
    call head
    xor eax, eax
    cmp r12d, 12
    jb 1f
    mov eax, [rbx + 8]
1:  mov [rip + msg + 8], eax
    mov edi, 12
    call send
    jmp 9f
.Lxm_pe_done:
    mov dword ptr [rip + pe_len], 0
    xor edi, edi
    xor esi, esi
    call ime_preedit
    jmp 9f
.Lxm_pe_draw:
    # caret, first changed character, changed count, status (1: no string), string
    cmp r12d, 26
    jb 9f
    xor eax, eax
    test dword ptr [rbx + 20], 1
    jnz 1f
    movzx esi, word ptr [rbx + 24]
    lea eax, [rsi + 26]
    cmp eax, r12d
    ja 9f
    lea rdi, [rbx + 26]
    lea rdx, [rip + text]
    mov ecx, PE_MAX
    call ct_decode
1:  mov r13, rax                # the new characters' bytes
    lea rdi, [rip + pe]
    mov esi, [rip + pe_len]
    mov edx, [rbx + 12]
    call char_offset
    mov r14, rax                # where the change starts
    lea rdi, [rip + pe]
    add rdi, r14
    mov esi, [rip + pe_len]
    sub esi, r14d
    mov edx, [rbx + 16]
    call char_offset
    lea r15, [r14 + rax]        # where it ends
    # pe = pe[..r14] text pe[r15..], if it fits
    mov eax, [rip + pe_len]
    sub eax, r15d
    mov [rsp], eax              # the tail's bytes
    lea rcx, [r14 + r13]
    add rcx, rax
    cmp rcx, PE_MAX
    ja 9f
    lea rdi, [rip + pe]
    lea rsi, [rdi + r15]
    add rdi, r14
    add rdi, r13
    mov edx, [rsp]
    call memmove
    lea rdi, [rip + pe]
    add rdi, r14
    lea rsi, [rip + text]
    mov rdx, r13
    call memcpy
    lea rax, [r14 + r13]
    add eax, [rsp]
    mov [rip + pe_len], eax
    lea rdi, [rip + pe]
    mov esi, eax
    call ime_preedit
9:  EPILOGUE

# char_offset(utf8, length, characters) -> rax: the byte offset of that many characters (clamped)
char_offset:
    xor eax, eax
    test edx, edx
    jle 9f
1:  cmp eax, esi
    jae 9f
    inc eax
2:  cmp eax, esi
    jae 3f
    movzx ecx, byte ptr [rdi + rax]
    and ecx, 0xc0
    cmp ecx, 0x80
    jne 3f
    inc eax
    jmp 2b
3:  dec edx
    jnz 1b
9:  ret

# locale_name(variable) -> rax: its value when set and not empty, else 0
locale_name:
    push rbx
    call getenv
    test rax, rax
    jz 9f
    cmp byte ptr [rax], 0
    jne 9f
    xor eax, eax
9:  pop rbx
    ret

.section .rodata
.Lxmodifiers: .asciz "XMODIFIERS"
.Lserver: .ascii "@server="
.Lnone: .asciz "none"
.Lxconnect: .asciz "_XIM_XCONNECT"
.Lprotocol: .asciz "_XIM_PROTOCOL"
.Ldata: .asciz "_RHUN_XIM_DATA"
.Lstyle: .asciz "inputStyle"
.Lclient: .asciz "clientWindow"
.Lfocus: .asciz "focusWindow"
.Llc_all: .asciz "LC_ALL"
.Llc_ctype: .asciz "LC_CTYPE"
.Llang: .asciz "LANG"
.Lc: .asciz "C"
.Lfailed: .asciz "rhun: the input method refused a connection; keys stay rhun's\n"
