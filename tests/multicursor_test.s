# Multi-cursor editing test: tests selection, simultaneous typing, undo/redo, movement, and cleanup
.include "rhun.inc"

.bss
.p2align 3
out: .zero SB_SIZE
doc: .quad 0

.text

# compare_doc(expected_str, len) -> 1 on match, 0 on mismatch
compare_doc:
    PROLOGUE 32
    mov r12, rdi                # expected str
    mov r13, rsi                # expected len
    mov rbx, [rip + doc]
    mov rdi, rbx
    call doc_len
    cmp rax, r13
    jne .Lcmp_fail

    lea rdi, [rip + out]
    call sb_clear
    lea rdi, [rip + out]
    mov rsi, r13
    call sb_reserve
    mov rdi, rbx
    xor esi, esi
    mov rdx, r13
    mov rcx, rax
    call doc_copy

    mov r8, [rip + out + SB_ptr]
    mov r9, r12
    mov rcx, r13
.Lcmp_loop:
    test rcx, rcx
    jz .Lcmp_ok
    mov al, [r8]
    cmp al, [r9]
    jne .Lcmp_fail
    inc r8
    inc r9
    dec rcx
    jmp .Lcmp_loop
.Lcmp_ok:
    mov eax, 1
    EPILOGUE
.Lcmp_fail:
    xor eax, eax
    EPILOGUE

FN main
    PROLOGUE 48
    # Initialize fonts & metrics
    call app_load_fonts
    call ui_update_metrics

    # Create document
    call doc_new
    mov [rip + doc], rax
    mov [rip + g_doc], rax
    mov rbx, rax

    # 1. Setup initial text:
    # "user_id = 101\nuser_id = 102\nuser_id = 103\n"
    mov rdi, rbx
    xor esi, esi
    lea rdx, [rip + s_initial]
    mov ecx, s_initial_end - s_initial
    xor r8d, r8d
    call doc_insert

    # Verify initial text
    lea rdi, [rip + s_initial]
    mov rsi, s_initial_end - s_initial
    call compare_doc
    test eax, eax
    jz .Lfail_1

    # 2. Select first "user_id" (0..7)
    mov qword ptr [rbx + DOC_anchor], 0
    mov qword ptr [rbx + DOC_cur], 7

    # Press Ctrl+D (cmd_select_next) -> adds 2nd occurrence (14..21)
    call cmd_select_next
    cmp qword ptr [rbx + DOC_cursors + VEC_len], 1
    jne .Lfail_2

    # Press Ctrl+D again -> adds 3rd occurrence (28..35)
    call cmd_select_next
    cmp qword ptr [rbx + DOC_cursors + VEC_len], 2
    jne .Lfail_2

    # 3. Simultaneous typing: replace "user_id" with "customer_id" across all 3 cursors!
    # Type 'c', 'u', 's', 't', 'o', 'm', 'e', 'r', '_', 'i', 'd'
    lea r12, [rip + s_cust]
    mov r13, s_cust_end - s_cust
.Ltype_loop:
    test r13, r13
    jz .Ltype_done
    movzx edi, byte ptr [r12]
    call ed_type
    inc r12
    dec r13
    jmp .Ltype_loop
.Ltype_done:

    # Verify document text is now:
    # "customer_id = 101\ncustomer_id = 102\ncustomer_id = 103\n"
    lea rdi, [rip + s_expected_cust]
    mov rsi, s_expected_cust_end - s_expected_cust
    call compare_doc
    test eax, eax
    jz .Lfail_3

    # 4. Test Undo grouping:
    # A single Ctrl+Z must undo the entire multi-cursor replacement!
    mov rdi, rbx
    call doc_undo
    test eax, eax
    jz .Lfail_4

    # Verify document reverted back to original "user_id" text in ONE undo!
    lea rdi, [rip + s_initial]
    mov rsi, s_initial_end - s_initial
    call compare_doc
    test eax, eax
    jz .Lfail_4

    # 5. Test Redo grouping:
    # A single Ctrl+Shift+Z / Redo must re-apply the entire replacement!
    mov rdi, rbx
    call doc_redo
    test eax, eax
    jz .Lfail_5

    lea rdi, [rip + s_expected_cust]
    mov rsi, s_expected_cust_end - s_expected_cust
    call compare_doc
    test eax, eax
    jz .Lfail_5

    # 6. Test select all matches (Ctrl+Shift+L):
    # Select first "customer_id" (0..11)
    mov qword ptr [rbx + DOC_anchor], 0
    mov qword ptr [rbx + DOC_cur], 11
    call cmd_select_all_matches
    # Must have found all 3 matches -> 2 secondary cursors
    cmp qword ptr [rbx + DOC_cursors + VEC_len], 2
    jne .Lfail_6

    # 7. Test simultaneous backspace:
    # Collapse all selections to their ends using multi-cursor Right Arrow
    mov edi, 1
    xor esi, esi
    call ed_move
    # Backspace 3 times: deletes 'd', 'i', '_' at each cursor
    xor edi, edi
    call ed_backspace
    xor edi, edi
    call ed_backspace
    xor edi, edi
    call ed_backspace

    # Verify document text is now:
    # "customer = 101\ncustomer = 102\ncustomer = 103\n"
    lea rdi, [rip + s_after_bs]
    mov rsi, s_after_bs_end - s_after_bs
    call compare_doc
    test eax, eax
    jz .Lfail_7

    # 8. Test Escape / cursor cleanup:
    mov rdi, rbx
    call cursors_clear
    cmp qword ptr [rbx + DOC_cursors + VEC_len], 0
    jne .Lfail_8

    # 9. Test duplicate cursor merging:
    # Add cursors at the same position and verify normalization merges them
    mov rdi, rbx
    mov rsi, 5
    mov rdx, 5
    mov rcx, -1
    call cursors_add
    mov rdi, rbx
    mov rsi, 5
    mov rdx, 5
    mov rcx, -1
    call cursors_add
    mov qword ptr [rbx + DOC_cur], 5
    mov qword ptr [rbx + DOC_anchor], 5
    mov rdi, rbx
    call cursors_normalize
    # All duplicate carets at 5 should merge to 1 primary cursor, 0 secondary
    cmp qword ptr [rbx + DOC_cursors + VEC_len], 0
    jne .Lfail_9

    # Clean up doc
    mov rdi, rbx
    call doc_free

    # Success: print OK and exit 0
    lea rdi, [rip + s_ok]
    mov rsi, s_ok_end - s_ok
    call log_write
    xor eax, eax
    EPILOGUE

.Lfail_1:
    lea rdi, [rip + s_err1]
    mov rsi, s_err1_end - s_err1
    call log_write
    mov eax, 1
    EPILOGUE
.Lfail_2:
    lea rdi, [rip + s_err2]
    mov rsi, s_err2_end - s_err2
    call log_write
    mov eax, 1
    EPILOGUE
.Lfail_3:
    lea rdi, [rip + s_err3]
    mov rsi, s_err3_end - s_err3
    call log_write
    mov eax, 1
    EPILOGUE
.Lfail_4:
    lea rdi, [rip + s_err4]
    mov rsi, s_err4_end - s_err4
    call log_write
    mov eax, 1
    EPILOGUE
.Lfail_5:
    lea rdi, [rip + s_err5]
    mov rsi, s_err5_end - s_err5
    call log_write
    mov eax, 1
    EPILOGUE
.Lfail_6:
    lea rdi, [rip + s_err6]
    mov rsi, s_err6_end - s_err6
    call log_write
    mov eax, 1
    EPILOGUE
.Lfail_7:
    lea rdi, [rip + s_err7]
    mov rsi, s_err7_end - s_err7
    call log_write
    mov eax, 1
    EPILOGUE
.Lfail_8:
    lea rdi, [rip + s_err8]
    mov rsi, s_err8_end - s_err8
    call log_write
    mov eax, 1
    EPILOGUE
.Lfail_9:
    lea rdi, [rip + s_err9]
    mov rsi, s_err9_end - s_err9
    call log_write
    mov eax, 1
    EPILOGUE

.section .rodata
s_initial:
    .ascii "user_id = 101\nuser_id = 102\nuser_id = 103\n"
s_initial_end:

s_cust:
    .ascii "customer_id"
s_cust_end:

s_expected_cust:
    .ascii "customer_id = 101\ncustomer_id = 102\ncustomer_id = 103\n"
s_expected_cust_end:

s_after_bs:
    .ascii "customer = 101\ncustomer = 102\ncustomer = 103\n"
s_after_bs_end:

s_ok:
    .ascii "ok multicursor_test\n"
s_ok_end:

s_err1: .ascii "FAIL step 1: initial text mismatch\n"
s_err1_end:
s_err2: .ascii "FAIL step 2: cmd_select_next cursor count mismatch\n"
s_err2_end:
s_err3: .ascii "FAIL step 3: ed_multi_type result mismatch\n"
s_err3_end:
s_err4: .ascii "FAIL step 4: doc_undo result mismatch\n"
s_err4_end:
s_err5: .ascii "FAIL step 5: doc_redo result mismatch\n"
s_err5_end:
s_err6: .ascii "FAIL step 6: cmd_select_all_matches cursor count mismatch\n"
s_err6_end:
s_err7: .ascii "FAIL step 7: ed_multi_backspace result mismatch\n"
s_err7_end:
s_err8: .ascii "FAIL step 8: cursors_clear failure\n"
s_err8_end:
s_err9: .ascii "FAIL step 9: cursors_normalize duplicate merge failure\n"
s_err9_end:
