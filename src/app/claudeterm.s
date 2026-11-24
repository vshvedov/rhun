# Claude Code in rhun's terminal (design 8.6; ext-host-ide.md 3, 5.2, 6): terminal mode and the commands
# around terminal claude. With [claude] use_terminal, Claude: Open and Ctrl+Esc (Cmd+Esc on macOS) start
# claude in a new terminal tab instead of showing the chat, as the extension's useTerminal does; in either
# mode a claude in rhun's terminal connects to rhun through the bridge (ide_server.s).
#
#   cmd_agents_open             Agents: Open: the terminal (use_terminal), else the agents panel with the keys
#                               (phase 4's task 13 owns the chat's side: it keeps the terminal branch)
#   cmd_claude_open_terminal    Claude: Open in Terminal: claude ([claude] executable, else claude on the PATH)
#                               in a new terminal tab named CLAUDE_CODE_TERMINAL_TITLE or "Claude Code", in the
#                               project, with the keys; its environment is every terminal's (the bridge's port)
#   cmd_agents_focus_input      Ctrl+Esc: the terminal (use_terminal); else the chat's side, agentctx.s's
#                               agctx_focus_input (the box, the selection's mention)
#   cmd_claude_mention_terminal Ctrl+Alt+K: at_mentioned to the connected claude (the file, its selected lines),
#                               then the terminal has the keys; with none connected, a toast says so
.include "rhun.inc"

.text

# FN cmd_agents_open()
FN cmd_agents_open
    cmp dword ptr [rip + cfg_claude_use_terminal], 0
    jne cmd_claude_open_terminal
    jmp cmd_focus_agents

# FN cmd_agents_focus_input()
FN cmd_agents_focus_input
    cmp dword ptr [rip + cfg_claude_use_terminal], 0
    jne cmd_claude_open_terminal
    jmp agctx_focus_input       # the chat's side: the box, the selection's mention (agentctx.s)

# FN cmd_claude_open_terminal()
FN cmd_claude_open_terminal
    PROLOGUE 48
    # the program: [claude] executable ("~/" as the chat's start reads it), else claude on the login PATH
    lea rax, [rip + .Lclaude]
    mov rdi, [rip + cfg_claude_executable]
    cmp byte ptr [rdi], 0
    je 1f
    call claude_expand_home
1:  mov [rsp + 32], rax         # argv: the program, 0
    mov qword ptr [rsp + 40], 0
    lea rax, [rsp + 32]
    mov [rsp + PGM_argv], rax
    mov qword ptr [rsp + PGM_sets], 0
    mov qword ptr [rsp + PGM_unsets], 0
    mov qword ptr [rsp + PGM_cwd], 0
    lea rdi, [rip + .Ltitle_env]
    call getenv
    test rax, rax
    jz 2f
    cmp byte ptr [rax], 0
    jne 3f
2:  lea rax, [rip + .Ltitle]
3:  mov rsi, rax
    lea rdi, [rsp]
    mov edx, TK_TERMINAL | TRV_FOCUS
    xor ecx, ecx
    xor r8d, r8d
    call term_run
    test rax, rax
    jg 4f
    lea rdi, [rip + .Lt_busy]
    call app_toast
    EPILOGUE
4:  mov dword ptr [rip + g_panel_cur], -1   # the panel shows its terminals
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# FN cmd_claude_mention_terminal()
FN cmd_claude_mention_terminal
    PROLOGUE
    call ide_mention
    test eax, eax
    jz 1f
    call term_show              # the terminal claude runs in has the keys, as the extension focuses it
    EPILOGUE
1:  lea rdi, [rip + .Lt_none]
    call ide_connected
    test eax, eax
    jz 2f
    lea rdi, [rip + .Lt_nofile]
2:  call app_toast
    EPILOGUE

.section .rodata
.Lclaude: .asciz "claude"
.Ltitle_env: .asciz "CLAUDE_CODE_TERMINAL_TITLE"
.Ltitle: .asciz "Claude Code"
.Lt_busy: .asciz "No room for another terminal: close one first."
.Lt_none: .asciz "No claude in rhun's terminal is connected to rhun."
.Lt_nofile: .asciz "Open a file to mention it."
