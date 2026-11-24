# Bounded decoding for externally owned CF_UNICODETEXT allocations.
.include "win.inc"
.bss
.p2align 3
.globl win_clip_format_id
win_clip_format_id: .quad 0
.section .rdata,"dr"
win_clip_format_name: .short 'c','o','m','.','r','1','3','.','r','h','u','n','.','c','l','i','p','b','o','a','r','d','.','v','1',0
win_png_name: .short 'P','N','G',0      # the image formats browsers and the system's tools register (phase 4 task 4)
win_mime_png_name: .short 'i','m','a','g','e','/','p','n','g',0
.text

# Registered IDs are shared by name across processes. Retry a failed registration.
FN win_clip_format
    mov rax, [rip + win_clip_format_id]
    test eax, eax
    jnz 1f
    PROLOGUE 96
    lea rcx, [rip + win_clip_format_name]
    API RegisterClipboardFormatW
    mov eax, eax
    mov [rip + win_clip_format_id], rax
    EPILOGUE
1:  ret

# wire_size(ptr, allocation bytes) -> physical envelope length, or0.
# GlobalSize may include padding. Read only a complete header before bounding the span.
FN win_clip_wire_size
    xor eax, eax
    test rdi, rdi
    jz 1f
    cmp rsi, CLW_HEADER
    jb 1f
    mov rcx, [rdi + 16]
    cmp rcx, DOC_SELECTIONS_MAX
    ja 1f
    mov rdx, [rdi + 24]
    cmp rdx, DOC_MULTI_BYTES_MAX
    ja 1f
    shl rcx, 4
    lea rcx, [rcx + rdx + CLW_HEADER]
    cmp rcx, rsi
    ja 1f
    mov rax, rcx
1:  ret

# Caller holds clipboard open. Return detached, fully validated wire, count; or0/0.
FN win_clip_read_native_handle
    PROLOGUE 128
    test rdi, rdi
    jz .Lnative_handle_fail
    mov rbx, rdi
    mov rcx, rdi
    API GlobalSize
    test rax, rax
    jz .Lnative_handle_fail
    mov r12, rax
    mov rcx, rbx
    API GlobalLock
    test rax, rax
    jz .Lnative_handle_fail
    mov r13, rax
    mov rdi, rax
    mov rsi, r12
    call win_clip_wire_size
    mov r14, rax
    xor r15d, r15d
    test rax, rax
    jz .Lnative_handle_unlock
    lea rdi, [rax + 1]
    call mem_alloc_try
    mov r15, rax
    test rax, rax
    jz .Lnative_handle_unlock
    mov rdi, rax
    mov rsi, r13
    mov rdx, r14
    call memcpy
.Lnative_handle_unlock:
    mov rcx, rbx
    API GlobalUnlock
    test r15, r15
    jz .Lnative_handle_fail
    mov rdi, r15
    mov rsi, r14
    lea rdx, [rsp + 96]
    call clip_wire_decode
    test eax, eax
    jz .Lnative_handle_free
    mov rax, r15
    mov rdx, r14
    EPILOGUE
.Lnative_handle_free:
    mov rdi, r15
    call mem_free
.Lnative_handle_fail:
    xor eax, eax
    xor edx, edx
    EPILOGUE

# global_copy(ptr, len) -> unlocked, caller-owned movable HGLOBAL, or0.
win_clip_global_copy:
    PROLOGUE 96
    mov rbx, rdi
    mov r12, rsi
    mov ecx, 2
    mov rdx, rsi
    API GlobalAlloc
    test rax, rax
    jz .Lglobal_copy_done
    mov r13, rax
    mov rcx, rax
    API GlobalLock
    test rax, rax
    jz .Lglobal_copy_free
    mov rdi, rax
    mov rsi, rbx
    mov rdx, r12
    call memcpy
    mov rcx, r13
    API GlobalUnlock
    mov rax, r13
    jmp .Lglobal_copy_done
.Lglobal_copy_free:
    mov rcx, r13
    API GlobalFree
    xor eax, eax
.Lglobal_copy_done:
    EPILOGUE

# write(wire,len) -> accepted only after both representations were transferred safely.
FN win_clip_write
    PROLOGUE 208
    mov rbx, rdi
    mov r12, rsi
    lea rdi, [rsp + 96]
    xor esi, esi
    mov edx, 112
    call memset
    mov [rsp + 128], rbx
    mov [rsp + 136], r12
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rsp + 96]
    call clip_wire_decode
    test eax, eax
    jz .Lnative_write_cleanup
    cmp qword ptr [rip + win_hwnd], 0
    je .Lnative_write_cleanup
    mov rdi, [rsp + 96 + CWB_text]
    mov rsi, [rsp + 96 + CWB_len]
    xor ecx, ecx
.Lnative_write_nul:
    cmp rcx, rsi
    jae .Lnative_write_prepare
    cmp byte ptr [rdi + rcx], 0
    je .Lnative_write_cleanup
    inc rcx
    jmp .Lnative_write_nul
.Lnative_write_prepare:
    inc qword ptr [rip + win_clip_depth]
    mov qword ptr [rsp + 152], 1
    mov rax, [rip + win_deferred_overflow]
    mov [rsp + 144], rax
    call win_clip_format
    test eax, eax
    jz .Lnative_write_cleanup
    mov rdi, [rsp + 128]
    mov rsi, [rsp + 136]
    call win_clip_global_copy
    mov [rsp + 168], rax
    test rax, rax
    jz .Lnative_write_cleanup
    mov rdi, [rsp + 96 + CWB_text]
    mov rsi, [rsp + 96 + CWB_len]
    call mem_dup
    mov [rsp + 184], rax
    mov rdi, rax
    call win_wide
    mov [rsp + 192], rax
    test rax, rax
    jz .Lnative_write_cleanup
    xor esi, esi
.Lnative_write_wide_len:
    add rsi, 2
    cmp word ptr [rax + rsi - 2], 0
    jne .Lnative_write_wide_len
    mov rdi, rax
    call win_clip_global_copy
    mov [rsp + 176], rax
    test rax, rax
    jz .Lnative_write_cleanup
    call win_clip_open
    test eax, eax
    jz .Lnative_write_cleanup
    mov qword ptr [rsp + 200], 1
    API EmptyClipboard
    test eax, eax
    jz .Lnative_write_cleanup
    mov ecx, 13
    mov rdx, [rsp + 176]
    API SetClipboardData
    test rax, rax
    jz .Lnative_write_cleanup
    mov qword ptr [rsp + 176], 0
    mov ecx, [rip + win_clip_format_id]
    mov rdx, [rsp + 168]
    API SetClipboardData
    test rax, rax
    jz .Lnative_write_cleanup
    mov qword ptr [rsp + 168], 0
    mov qword ptr [rsp + 160], 1
.Lnative_write_cleanup:
    cmp qword ptr [rsp + 200], 0
    je 1f
    API CloseClipboard
1:  mov rcx, [rsp + 168]
    test rcx, rcx
    jz 2f
    API GlobalFree
2:  mov rcx, [rsp + 176]
    test rcx, rcx
    jz 3f
    API GlobalFree
3:  mov rdi, [rsp + 184]
    call mem_free
    mov rdi, [rsp + 192]
    call mem_free
    cmp qword ptr [rsp + 152], 0
    je 4f
    dec qword ptr [rip + win_clip_depth]
    mov rax, [rip + win_deferred_overflow]
    cmp rax, [rsp + 144]
    je 4f
    mov qword ptr [rsp + 160], 0
4:  mov rax, [rsp + 160]
    EPILOGUE

# win_clip_decode(ptr, allocation bytes, UTF-8 limit) -> owned text, rdx count; 0/0 on failure.
# The caller keeps the input span alive. CF_UNICODETEXT ends at its first complete NUL unit.
FN win_clip_decode
    PROLOGUE 96
    test rdi, rdi
    jz .Lclip_decode_fail
    cmp rdx, DOC_MULTI_BYTES_MAX
    ja .Lclip_decode_fail
    mov rbx, rdi
    mov r12, rdx
    shr rsi, 1
    lea rax, [rdx + 1]
    cmp rsi, rax
    cmova rsi, rax
    xor r13d, r13d
.Lclip_decode_scan:
    cmp r13, rsi
    jae .Lclip_decode_fail
    cmp word ptr [rbx + r13*2], 0
    je .Lclip_decode_found
    inc r13
    jmp .Lclip_decode_scan
.Lclip_decode_found:
    test r13, r13
    jnz .Lclip_decode_size
    mov edi, 1
    call mem_alloc
    xor edx, edx
    EPILOGUE
.Lclip_decode_size:
    mov ecx, 65001             # CP_UTF8
    mov edx, 0x80              # WC_ERR_INVALID_CHARS
    mov r8, rbx
    mov r9d, r13d              # counted UTF-16 units, excluding the terminator
    mov qword ptr [rsp + 32], 0
    mov qword ptr [rsp + 40], 0
    mov qword ptr [rsp + 48], 0
    mov qword ptr [rsp + 56], 0
    API WideCharToMultiByte
    test eax, eax
    jz .Lclip_decode_fail
    mov r14d, eax
    cmp r14, r12
    ja .Lclip_decode_fail
    lea rdi, [r14 + 1]
    call mem_alloc
    mov r15, rax
    mov ecx, 65001
    mov edx, 0x80
    mov r8, rbx
    mov r9d, r13d
    mov [rsp + 32], r15
    mov [rsp + 40], r14
    mov qword ptr [rsp + 48], 0
    mov qword ptr [rsp + 56], 0
    API WideCharToMultiByte
    cmp eax, r14d
    jne .Lclip_decode_free
    mov rax, r15
    mov rdx, r14
    EPILOGUE
.Lclip_decode_free:
    mov rdi, r15
    call mem_free
.Lclip_decode_fail:
    xor eax, eax
    xor edx, edx
    EPILOGUE

# win_clip_read_handle(HGLOBAL, UTF-8 limit) -> owned text, rdx count; 0/0 on failure.
# The clipboard remains open until the caller has returned from this function.
FN win_clip_read_handle
    PROLOGUE 96
    test rdi, rdi
    jz .Lclip_handle_fail
    cmp rsi, DOC_MULTI_BYTES_MAX
    ja .Lclip_handle_fail
    mov rbx, rdi
    mov r12, rsi
    mov rcx, rbx
    API GlobalSize
    test rax, rax
    jz .Lclip_handle_fail
    mov r13, rax
    mov rcx, rbx
    API GlobalLock
    test rax, rax
    jz .Lclip_handle_fail
    mov rdi, rax
    mov rsi, r13
    mov rdx, r12
    call win_clip_decode
    mov r14, rax
    mov r15, rdx
    mov rcx, rbx
    API GlobalUnlock
    mov rax, r14
    mov rdx, r15
    EPILOGUE
.Lclip_handle_fail:
    xor eax, eax
    xor edx, edx
    EPILOGUE

# ---- phase 4 tasks 4 and 5: files (CF_HDROP, WM_DROPFILES) and PNG images ----
.bss
.p2align 3
hd_sb: .zero SB_SIZE
.text

# win_hdrop_list(HDROP) -> rax owned paths ("/" separators, a NUL after each) or 0, rdx their bytes; at most
#   CLIP_FILES_MAX bytes (the paths past that are left out)
FN win_hdrop_list
    PROLOGUE 96
    mov rbx, rdi
    lea rdi, [rip + hd_sb]
    call sb_clear
    mov rcx, rbx
    mov edx, -1
    xor r8d, r8d
    xor r9d, r9d
    API DragQueryFileW
    mov r12d, eax               # the count
    xor r13d, r13d
1:  cmp r13d, r12d
    jae 8f
    mov rcx, rbx
    mov edx, r13d
    xor r8d, r8d
    xor r9d, r9d
    API DragQueryFileW
    inc r13d
    test eax, eax
    jz 1b
    cmp eax, 32767
    ja 1b
    mov r14d, eax
    lea edi, [rax*2 + 2]
    call mem_alloc
    mov r15, rax
    mov rcx, rbx
    lea edx, [r13 - 1]
    mov r8, r15
    lea r9d, [r14 + 1]
    API DragQueryFileW
    mov rdi, r15
    call win_utf8
    mov r14, rax
    mov rdi, r15
    call mem_free
    test r14, r14
    jz 1b
    mov rdi, r14
    call win_slashes
    mov rdi, r14
    call strlen
    mov r15, rax
    mov rcx, [rip + hd_sb + SB_len]
    lea rcx, [rcx + rax + 1]
    cmp rcx, CLIP_FILES_MAX
    ja 7f
    lea rdi, [rip + hd_sb]
    mov rsi, r14
    mov rdx, r15
    call sb_push
    lea rdi, [rip + hd_sb]
    xor esi, esi
    call sb_push_byte
    mov rdi, r14
    call mem_free
    jmp 1b
7:  mov rdi, r14
    call mem_free
8:  xor eax, eax
    xor edx, edx
    cmp qword ptr [rip + hd_sb + SB_len], 0
    je 9f
    mov rdi, [rip + hd_sb + SB_ptr]
    mov rsi, [rip + hd_sb + SB_len]
    call mem_dup
    mov rdx, [rip + hd_sb + SB_len]
9:  EPILOGUE

# win_clip_png(limit) -> rax owned bytes, rdx count, rcx 4 an image; rcx 3: an image of limit bytes or more (not
#   copied); rcx 5: a bitmap (CF_DIB) and no text; rcx 0: none. The clipboard is open
FN win_clip_png
    PROLOGUE 96
    mov ebx, edi
    lea rcx, [rip + win_png_name]
    API RegisterClipboardFormatW
    test eax, eax
    jz 1f
    mov ecx, eax
    API GetClipboardData
    test rax, rax
    jnz 3f
1:  lea rcx, [rip + win_mime_png_name]
    API RegisterClipboardFormatW
    test eax, eax
    jz 2f
    mov ecx, eax
    API GetClipboardData
    test rax, rax
    jnz 3f
2:  mov ecx, 8                  # CF_DIB without CF_UNICODETEXT
    API IsClipboardFormatAvailable
    test eax, eax
    jz 8f
    mov ecx, 13
    API IsClipboardFormatAvailable
    test eax, eax
    jnz 8f
    xor eax, eax
    xor edx, edx
    mov ecx, 5
    EPILOGUE
3:  mov r12, rax                # the PNG: its size first
    mov rcx, rax
    API GlobalSize
    test rax, rax
    jz 8f
    mov r13, rax
    cmp r13, rbx
    jb 4f
    xor eax, eax
    xor edx, edx
    mov ecx, 3
    EPILOGUE
4:  mov rcx, r12
    API GlobalLock
    test rax, rax
    jz 8f
    mov r14, rax
    lea rdi, [r13 + 1]
    call mem_alloc_try
    mov r15, rax
    test rax, rax
    jz 5f
    mov rdi, rax
    mov rsi, r14
    mov rdx, r13
    call memcpy
5:  mov rcx, r12
    API GlobalUnlock
    test r15, r15
    jz 8f
    mov rax, r15
    mov rdx, r13
    mov ecx, 4
    EPILOGUE
8:  xor eax, eax
    xor edx, edx
    xor ecx, ecx
    EPILOGUE

# win_drop_files(HDROP): WM_DROPFILES: the paths, where they were dropped (client pixels), then DragFinish
FN win_drop_files
    PROLOGUE 112
    mov rbx, rdi
    mov qword ptr [rsp + 96], 0
    mov rcx, rbx
    lea rdx, [rsp + 96]
    API DragQueryPoint
    mov rdi, rbx
    call win_hdrop_list
    mov r12, rax
    mov r13, rdx
    mov rcx, rbx
    API DragFinish
    test r12, r12
    jz 9f
    mov edi, DROP_FILES
    mov esi, [rsp + 96]
    mov edx, [rsp + 100]
    mov rcx, r12
    mov r8, r13
    call app_on_drop
    mov rdi, r12
    call mem_free
9:  EPILOGUE
