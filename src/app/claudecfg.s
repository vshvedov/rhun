# Claude Code's settings that are not rows of g_settings (config.s has [claude] chat, executable,
# wrapper and initial_mode), and the places that follow from them: the program to start, its
# environment, the folder Claude Code keeps its conversations in and a conversation's file.
#
#   claudecfg_reset()                       the config file is read again: the env pairs go
#   claudecfg_key(sec, seclen, key, keylen, val, vallen) -> eax 1 taken: [claude] env.NAME = value
#                                           (NAME [A-Za-z_][A-Za-z0-9_]*, 64 pairs, 8 KiB a pair; others
#                                           are dropped with a log line that names no value)
#   claudecfg_key also takes [claude] spinner_verb = TEXT lines (VERB_LINES of VERB_MAX bytes at most; empty
#                                           ones and more are dropped)
#   claudecfg_done()                        the config was read or spinner_verbs changed: claude_verb_list (the
#                                           Claude driver's DRV_verbs) is the built-in verbs (claude_verbs) and
#                                           the lines, or the lines alone with spinner_verbs = replace and any
#   claudecfg_save(sb)                      the pairs, then the spinner_verb lines, as lines of [claude]
#   claudecfg_pairs() -> eax                how many (config_save writes the file 0600 with any)
#   claudecfg_dump(sb)                      "claude.env.NAME=(set)" a line each (print-settings): people
#                                           put keys in these pairs, so a value is never printed, logged
#                                           or shown outside the config file and the child's environment
#   claude_exe() -> rax argv prefix [wrapper,] executable, 0-ended, one mem_alloc'd block (strings
#                   included: mem_free it), edx the count; or rax 0 when the program (or a wrapper
#                   that is set) is not found. In a remote window it is the host's, as set ("claude" by
#                   default, "~/" the host's home), looked for only when it starts there
#   claude_host_place() -> rax a usual place of claude on the remote host that can be run (mem_free), or 0
#   In a remote window the environment, HOME and CLAUDE_CONFIG_DIR are the host's (host_env: its agent
#   tells them, remoteui.s); claude_env is the pairs and rhun's values alone, sent to the host
#   claude_env() -> rax envp: the login environment, the env pairs, rhun's forced values, without the
#                   variables a surrounding Claude Code sets (uproc_env_make; mem_free the array; its
#                   strings live until the config is read again)
#       claude_exe and claude_env read the login environment: call them only once uproc_env_ready()
#       returned 1
#   claude_expand_home(cstr) -> rax "~/" as the home folder, as the start reads a configured path
#   claude_mode() -> rax the --permission-mode value of [claude] initial_mode, or 0 (the CLI's own)
#   claude_mode_gated() -> eax 1 when initial_mode is bypassPermissions and that is not allowed
#   claude_mode_alias(ptr, len) -> rax ptr, rdx len: the initial_mode value config.s looks up
#   claude_dir(sb) -> eax 1: appended, the first of an absolute env.CLAUDE_CONFIG_DIR, the environment's
#                   CLAUDE_CONFIG_DIR (not empty), "$HOME/.claude" (HOME: an env.HOME pair, else the
#                   environment's); 0 without any. The environment is
#                   the one claude gets (uproc_env_get): the login shell's once known, rhun's own until
#                   then. The one source for the driver, the holder check and discovery
#   claude_dir_pin(cstr or 0)  claude_dir gives that folder until it is called with 0: a conversation's
#                   own (the one its program was started with: agent_claude.s keeps it)
#   claude_env_dir(dir) -> rax claude_env() with CLAUDE_CONFIG_DIR=dir over everything
#   claude_dir_moved() -> eax 1 once, when the login environment has become known and gives another
#                   folder than the one discovery last ran with: discovery runs again (agents_tick)
#   claude_slug(sb, path) -> rax bytes appended: the folder name Claude Code gives a working directory
#   claude_transcript(sb, cwd, sid) -> eax 1: <claude dir>/projects/<slug>/<sid>.jsonl appended. The
#                   CLI slugs its working directory with symbolic links resolved
#                   (tests/data/claude-shapes/README.txt, decision 6), so cwd is resolved first; a slug
#                   over 200 bytes is cut to 200 (the CLI adds a hash then: the path is provisional)
#   claude_term_env(folder or 0) -> eax 0, 1 CLAUDE_CONFIG_DIR, 2 HOME, rdx its value: what the terminal's
#                   claude needs to use a conversation's profile (Sign In, Run claude in Terminal)
#   claude_index_envp() -> rax the environment the discovery worker starts with: rhun's own, with an
#                   absolute env.CLAUDE_CONFIG_DIR in it (borrowed until the next call)
#   claude_ctl: print-claude-exe, print-claude-path (control.s)
.include "rhun.inc"

.equ PAIRS_MAX, 64
.equ PAIR_MAX, 8192
.equ NAME_LOG, 64               # a dropped pair's name is logged up to this many bytes
.equ SLUG_MAX, 200
.equ ENV_WAIT_MS, 10000         # print-claude-exe waits this long for the login environment
.equ CONFIG_DIR_LEN, 18         # "CLAUDE_CONFIG_DIR="
.equ MODE_OPT_BYPASS, 5         # bypassPermissions' index in g_claude_mode_opts
.equ VERB_LINES, 64             # [claude] spinner_verb lines kept
.equ VERB_MAX, 40               # bytes of one
.equ BUILTIN_MAX, 128           # the built-in verbs counted at most

.bss
.p2align 3
pairs: .zero VEC_SIZE           # owned "NAME=value" cstrs, 8-byte slots, in the file's order
verbs: .zero VEC_SIZE           # owned spinner_verb texts (cstr, 8-byte slots), in the file's order
.globl claude_verb_list
claude_verb_list: .zero 8 * (BUILTIN_MAX + VERB_LINES + 1)  # the spinner's verbs (claudecfg_done), 0-ended
index_env: .quad 0              # claude_index_envp's last array
xsb: .zero SB_SIZE              # a path with "~/" expanded
idx_dir: .zero SB_SIZE          # the folder discovery last ran with (claude_index_envp), "" none yet
idx_pair: .zero SB_SIZE         # "CLAUDE_CONFIG_DIR=" and it, for the worker
idx_set: .zero 16               # the worker's sets: idx_pair's text, 0
dir_now: .zero SB_SIZE          # claude_dir_moved's
dir_checked: .long 0            # claude_dir_moved looked once the login environment was known
.p2align 3
dir_pin: .quad 0                # claude_dir_pin's folder, or 0
pin_pair: .zero SB_SIZE         # claude_env_dir's "CLAUDE_CONFIG_DIR=..."
pin_forced: .zero 8 * 8         # forced's entries (p6b: and a re-run's two), then pin_pair's text, 0
rpath: .zero 4096 + 16          # a resolved working directory

.text

# claudecfg_reset(): the config file is read again
FN claudecfg_reset
    PROLOGUE
    xor ebx, ebx
1:  cmp rbx, [rip + pairs + VEC_len]
    jae 2f
    mov rax, [rip + pairs + VEC_ptr]
    mov rdi, [rax + rbx*8]
    call mem_free
    inc rbx
    jmp 1b
2:  lea rdi, [rip + pairs]
    call vec_free
    xor ebx, ebx
3:  cmp rbx, [rip + verbs + VEC_len]
    jae 4f
    mov rax, [rip + verbs + VEC_ptr]
    mov rdi, [rax + rbx*8]
    call mem_free
    inc rbx
    jmp 3b
4:  lea rdi, [rip + verbs]
    call vec_free
    call claudecfg_done
    EPILOGUE

# FN claudecfg_done(): claude_verb_list from the built-in verbs and the spinner_verb lines: with spinner_verbs
#   = replace and a line or more, the lines alone (the extension's GRn: replace with none keeps its own)
FN claudecfg_done
    PROLOGUE
    lea r12, [rip + claude_verb_list]
    xor r13d, r13d              # entries
    cmp dword ptr [rip + cfg_claude_spinner_verbs], 0
    je 1f
    cmp qword ptr [rip + verbs + VEC_len], 0
    jne 3f
1:  xor ebx, ebx                # the built-in ones
2:  cmp ebx, BUILTIN_MAX
    jae 3f
    lea rax, [rip + claude_verbs]
    mov rax, [rax + rbx*8]
    test rax, rax
    jz 3f
    mov [r12 + r13*8], rax
    inc r13d
    inc ebx
    jmp 2b
3:  xor ebx, ebx                # the lines
4:  cmp rbx, [rip + verbs + VEC_len]
    jae 8f
    mov rax, [rip + verbs + VEC_ptr]
    mov rax, [rax + rbx*8]
    mov [r12 + r13*8], rax
    inc r13d
    inc rbx
    jmp 4b
8:  mov qword ptr [r12 + r13*8], 0
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# verb_key(key, keylen, val, vallen) -> eax 1 when it is a spinner_verb line (taken, or dropped when empty, too
#   long or one too many)
verb_key:
    PROLOGUE
    mov rbx, rdx
    mov r12, rcx
    lea rdx, [rip + .Lverb_key]
    call str_eq_cstr
    test eax, eax
    jz 9f
    mov rdi, rbx
    mov rsi, r12
    call trim
    mov rbx, rax
    mov r12, rdx
    test r12, r12
    jz 8f
    cmp r12, VERB_MAX
    ja 8f
    cmp qword ptr [rip + verbs + VEC_len], VERB_LINES
    jae 8f
    xor ecx, ecx                # one line of printable text: no controls
1:  cmp rcx, r12
    jae 2f
    cmp byte ptr [rbx + rcx], 32
    jb 8f
    cmp byte ptr [rbx + rcx], 127
    je 8f
    inc rcx
    jmp 1b
2:  mov rdi, rbx
    mov rsi, r12
    call mem_dup
    mov r13, rax
    lea rdi, [rip + verbs]
    mov esi, 8
    call vec_push
    mov [rax], r13
8:  mov eax, 1
9:  EPILOGUE

# claudecfg_key(sec, seclen, key, keylen, val, vallen) -> eax 1 when it is a [claude] env.NAME pair or a
#   spinner_verb line
FN claudecfg_key
    PROLOGUE
    mov rbx, rdx
    mov r12, rcx
    mov r13, r8
    mov r14, r9
    lea rdx, [rip + .Ls_claude]
    call str_eq_cstr
    test eax, eax
    jz 8f
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    mov rcx, r14
    call verb_key
    test eax, eax
    jnz 9f
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lenv_dot]
    mov ecx, 4
    call str_starts
    test eax, eax
    jz 8f
    add rbx, 4                  # the name
    sub r12, 4
    jz .Lck_drop
    # [A-Za-z_][A-Za-z0-9_]*
    xor ecx, ecx
1:  movzx eax, byte ptr [rbx + rcx]
    cmp al, '_'
    je 3f
    mov edx, eax
    or edx, 0x20
    sub edx, 'a'
    cmp edx, 25
    jbe 3f
    test rcx, rcx
    jz .Lck_drop
    sub eax, '0'
    cmp eax, 9
    ja .Lck_drop
3:  inc rcx
    cmp rcx, r12
    jb 1b
    lea rax, [r12 + r14 + 2]    # NAME=value and its NUL
    cmp rax, PAIR_MAX
    ja .Lck_drop
    # the same name again: the later line wins, in the earlier one's place
    xor r15d, r15d
4:  cmp r15, [rip + pairs + VEC_len]
    jae 5f
    mov rax, [rip + pairs + VEC_ptr]
    mov rdi, [rax + r15*8]
    call name_len
    cmp rax, r12
    jne 41f
    mov rax, [rip + pairs + VEC_ptr]
    mov rdi, [rax + r15*8]
    mov rsi, rbx
    mov rdx, r12
    call memeq
    test eax, eax
    jnz 6f
41: inc r15
    jmp 4b
5:  cmp qword ptr [rip + pairs + VEC_len], PAIRS_MAX
    jae .Lck_drop
    lea rdi, [rip + pairs]
    mov esi, 8
    call vec_push
    mov qword ptr [rax], 0
    mov r15, [rip + pairs + VEC_len]
    dec r15
6:  mov rax, [rip + pairs + VEC_ptr]
    mov rdi, [rax + r15*8]
    call mem_free
    lea rdi, [r12 + r14 + 2]
    call mem_alloc
    mov rcx, [rip + pairs + VEC_ptr]
    mov [rcx + r15*8], rax
    mov r15, rax
    mov rdi, rax
    mov rsi, rbx
    mov rdx, r12
    call memcpy
    mov byte ptr [r15 + r12], '='
    lea rdi, [r15 + r12 + 1]
    mov rsi, r13
    mov rdx, r14
    call memcpy
    lea rax, [r12 + r14 + 1]
    mov byte ptr [r15 + rax], 0
    jmp 9f
.Lck_drop:
    lea rdi, [rip + .Ldrop_a]
    call log_cstr
    mov rsi, r12
    cmp rsi, NAME_LOG
    jbe 1f
    mov esi, NAME_LOG
1:  mov rdi, rbx
    call log_write
    lea rdi, [rip + .Ldrop_b]
    call log_cstr
9:  mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN claudecfg_pairs() -> eax how many [claude] env.NAME pairs there are
FN claudecfg_pairs
    mov rax, [rip + pairs + VEC_len]
    ret

# claudecfg_save(sb): "env.NAME = value" a line each
FN claudecfg_save
    PROLOGUE
    mov r12, rdi
    xor ebx, ebx
1:  cmp rbx, [rip + pairs + VEC_len]
    jae 9f
    mov rax, [rip + pairs + VEC_ptr]
    mov r13, [rax + rbx*8]
    mov rdi, r13
    call name_len
    mov r14, rax
    mov rdi, r12
    lea rsi, [rip + .Lenv_dot]
    call sb_push_cstr
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    call sb_push
    mov rdi, r12
    lea rsi, [rip + .Leq]
    call sb_push_cstr
    mov rdi, r12
    lea rsi, [r13 + r14 + 1]
    call sb_push_cstr
    mov rdi, r12
    mov esi, 10
    call sb_push_byte
    inc rbx
    jmp 1b
9:  lea rsi, [rip + .Lverb_line]   # then the spinner_verb lines
    mov rdi, r12
    call verb_lines
    EPILOGUE

# verb_lines(sb, prefix): prefix, a spinner_verb's text and a line feed, a line each
verb_lines:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    xor ebx, ebx
1:  cmp rbx, [rip + verbs + VEC_len]
    jae 9f
    mov rdi, r12
    mov rsi, r13
    call sb_push_cstr
    mov rax, [rip + verbs + VEC_ptr]
    mov rsi, [rax + rbx*8]
    mov rdi, r12
    call sb_push_cstr
    mov rdi, r12
    mov esi, 10
    call sb_push_byte
    inc rbx
    jmp 1b
9:  EPILOGUE

# claudecfg_dump(sb): "claude.env.NAME=(set)" a line each: never the value; then "claude.spinner_verb=TEXT"
FN claudecfg_dump
    PROLOGUE
    mov r12, rdi
    xor ebx, ebx
1:  cmp rbx, [rip + pairs + VEC_len]
    jae 9f
    mov rax, [rip + pairs + VEC_ptr]
    mov r13, [rax + rbx*8]
    mov rdi, r13
    call name_len
    mov r14, rax
    mov rdi, r12
    lea rsi, [rip + .Ldump_env]
    call sb_push_cstr
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    call sb_push
    mov rdi, r12
    lea rsi, [rip + .Ldump_set]
    call sb_push_cstr
    inc rbx
    jmp 1b
9:  mov rdi, r12
    lea rsi, [rip + .Ldump_verb]
    call verb_lines
    EPILOGUE

# name_len(pair) -> rax the bytes before its '='
name_len:
    xor eax, eax
1:  cmp byte ptr [rdi + rax], '='
    je 2f
    cmp byte ptr [rdi + rax], 0
    je 2f
    inc rax
    jmp 1b
2:  ret

# pairs_list() -> rax the pairs as a 0-ended array (mem_free it; the strings are the pairs')
pairs_list:
    PROLOGUE
    mov rbx, [rip + pairs + VEC_len]
    lea rdi, [rbx*8 + 8]
    call mem_alloc
    mov r12, rax
    mov rdi, rax
    mov rsi, [rip + pairs + VEC_ptr]
    lea rdx, [rbx*8]
    call memcpy
    mov qword ptr [r12 + rbx*8], 0
    mov rax, r12
    EPILOGUE

# config_dir_pair() -> rax the "CLAUDE_CONFIG_DIR=..." pair when its value is an absolute path, or 0
config_dir_pair:
    PROLOGUE
    xor ebx, ebx
1:  cmp rbx, [rip + pairs + VEC_len]
    jae 8f
    mov rax, [rip + pairs + VEC_ptr]
    mov r12, [rax + rbx*8]
    mov rdi, r12
    lea rsi, [rip + .Lconfig_dir_eq]
    mov edx, CONFIG_DIR_LEN
    call memeq
    test eax, eax
    jnz 2f
    inc rbx
    jmp 1b
2:  lea rax, [r12 + CONFIG_DIR_LEN]
    PATH_ABSOLUTE rax, 3f
8:  xor eax, eax
    EPILOGUE
3:  mov rax, r12
    EPILOGUE

# FN claude_term_env(folder cstr or 0) -> eax what the terminal's claude must be given to use the same
#   profile as a conversation's program, rdx its value (borrowed): 0 nothing, 1 CLAUDE_CONFIG_DIR, 2 HOME.
#   folder: the conversation's own (agent_claude.s live_dir), 0 for the configuration's. Its program gets
#   CLAUDE_CONFIG_DIR = folder when that is not claude_dir's now (claude_env_dir), else an absolute
#   env.CLAUDE_CONFIG_DIR, else the environment's absolute one; without any, HOME from an env.HOME pair or
#   the environment. The terminal has the environment (the login shell's, as far as rhun knows it): what
#   differs is named, CLAUDE_CONFIG_DIR first. HOME only when claude gets no CLAUDE_CONFIG_DIR: its stored
#   sign-in is named after the folder only when CLAUDE_CONFIG_DIR is set (Claude Code 2.1.330), so
#   CLAUDE_CONFIG_DIR=HOME/.claude would not be the same sign-in as HOME=...
FN claude_term_env
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rip + dir_now]
    call sb_clear
    lea rdi, [rip + dir_now]
    call claude_dir
    test rbx, rbx
    jz 1f
    test eax, eax
    jz 2f
    mov rdi, rbx
    mov rsi, [rip + dir_now + SB_ptr]
    call strcmp_eq
    test eax, eax
    jz 2f                       # the folder the configuration names now is another: it gets its own
1:  call config_dir_pair
    test rax, rax
    jz 11f
    lea rbx, [rax + CONFIG_DIR_LEN]
    jmp 2f
11: lea rdi, [rip + .Lconfig_dir]
    call host_env
    xor ebx, ebx
    test rax, rax
    jz 2f
    PATH_ABSOLUTE rax, 12f
    jmp 2f
12: mov rbx, rax
2:  lea rdi, [rip + .Lconfig_dir]   # what the terminal has
    call host_env
    mov r12, rax
    test rbx, rbx
    jz 5f
    test r12, r12               # claude gets CLAUDE_CONFIG_DIR: named unless the terminal has the same
    jz 3f
    mov rdi, rbx
    mov rsi, r12
    call strcmp_eq
    test eax, eax
    jnz 8f
3:  mov eax, 1
    mov rdx, rbx
    EPILOGUE
5:  lea rdi, [rip + .Lhome_eq]   # none: an env.HOME pair the terminal's HOME is not
    mov esi, 5
    call pair_value
    test rax, rax
    jz 8f
    cmp byte ptr [rax], 0
    je 8f
    mov rbx, rax
    lea rdi, [rip + .Lhome]
    call host_env
    test rax, rax
    jz 6f
    mov rdi, rbx
    mov rsi, rax
    call strcmp_eq
    test eax, eax
    jnz 8f
6:  mov eax, 2
    mov rdx, rbx
    EPILOGUE
8:  xor eax, eax
    xor edx, edx
    EPILOGUE

# pair_value(name_eq, len) -> rax the value of the [claude] env pair "NAME=" (len bytes with its '='
#   names it), or 0
pair_value:
    PROLOGUE
    mov r13, rdi
    mov r14, rsi
    xor ebx, ebx
1:  xor eax, eax
    cmp rbx, [rip + pairs + VEC_len]
    jae 9f
    mov rax, [rip + pairs + VEC_ptr]
    mov r12, [rax + rbx*8]
    inc rbx
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    call memeq
    test eax, eax
    jz 1b
    lea rax, [r12 + r14]
9:  EPILOGUE

# claude_env() -> envp (see the top of the file)
FN claude_env
    PROLOGUE
    call pairs_list
    mov rbx, rax
    mov rdi, rax
    call dir_unsets
    mov rdx, rax
    mov rdi, rbx
    lea rsi, [rip + forced]
    cmp dword ptr [rip + claude_rerun_env], 0   # p6b: a re-run of a cut turn (claude_fork.s)
    je 1f
    lea rsi, [rip + forced_rerun]
1:  call env_lists
    mov r12, rax
    mov rdi, rbx
    call mem_free
    mov rax, r12
    EPILOGUE

# env_lists(sets, sets2, unsets) -> envp: uproc_env_make's; in a remote window uproc_env_sets' (the host has
#   its login environment: only the lists go, and nothing waits for this machine's login shell)
env_lists:
    cmp dword ptr [rip + g_remote], 0
    jne uproc_env_sets
    jmp uproc_env_make

# host_env(name cstr) -> rax the value of a variable in the environment claude gets (borrowed), or 0: in a
#   remote window the host's login environment as its agent told it (HOME, CLAUDE_CONFIG_DIR: remoteui.s),
#   else uproc_env_get's
host_env:
    cmp dword ptr [rip + g_remote], 0
    jne 1f
    jmp uproc_env_get
1:  PROLOGUE
    mov rbx, rdi
    lea rsi, [rip + .Lhome]
    call strcmp_eq
    lea r12, [rip + g_remote_home]
    test eax, eax
    jnz 2f
    mov rdi, rbx
    lea rsi, [rip + .Lconfig_dir]
    call strcmp_eq
    lea r12, [rip + g_remote_claude_dir]
    test eax, eax
    jz 8f
2:  xor eax, eax
    cmp byte ptr [r12], 0
    je 9f
    mov rax, r12
9:  EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN claude_host_place() -> rax the first of the places installers put claude in on a remote window's host
#   that can be run there (one request each; mem_free it), or 0: a start whose "claude" the host's PATH
#   does not have tries it (agent_claude.s)
FN claude_host_place
    PROLOGUE
    lea rbx, [rip + host_places]
1:  cmp byte ptr [rbx], 0
    je 8f
    mov rdi, rbx
    call expand_home
    mov r12, rax
    mov rdi, rax
    mov esi, 1                  # X_OK
    call vfs_access
    test rax, rax
    jz 7f
    mov rdi, rbx
    call strlen
    lea rbx, [rbx + rax + 1]
    jmp 1b
7:  mov rdi, r12
    call dup_cstr
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# dup_cstr(cstr) -> rax a mem_dup of it
dup_cstr:
    push rbx
    mov rbx, rdi
    call strlen
    mov rdi, rbx
    mov rsi, rax
    call mem_dup
    pop rbx
    ret

# FN claude_dir_pin(cstr or 0): claude_dir gives that folder until it is called with 0
FN claude_dir_pin
    mov [rip + dir_pin], rdi
    ret

# FN claude_env_dir(dir cstr) -> rax envp: claude_env's, with CLAUDE_CONFIG_DIR=dir whatever the pairs and
#   the login environment say (a conversation goes on in the folder it lives in)
FN claude_env_dir
    PROLOGUE
    mov r12, rdi
    lea rdi, [rip + pin_pair]
    call sb_clear
    lea rdi, [rip + pin_pair]
    lea rsi, [rip + .Lconfig_dir_eq]
    mov edx, CONFIG_DIR_LEN
    call sb_push
    lea rdi, [rip + pin_pair]
    mov rsi, r12
    call sb_push_cstr
    lea rcx, [rip + pin_forced]
    lea rax, [rip + .Lf_entry]
    mov [rcx], rax
    lea rax, [rip + .Lf_mcp]
    mov [rcx + 8], rax
    lea rax, [rip + .Lf_preview]
    mov [rcx + 16], rax
    lea rax, [rip + .Lf_ckpt]   # p6b: file checkpoints (rewind_files)
    mov [rcx + 24], rax
    add rcx, 32
    cmp dword ptr [rip + claude_rerun_env], 0   # p6b: a re-run of a cut turn (claude_fork.s)
    je 1f
    lea rax, [rip + .Lf_rerun]
    mov [rcx], rax
    lea rax, [rip + .Lf_rerun_age]
    mov [rcx + 8], rax
    add rcx, 16
1:  mov rax, [rip + pin_pair + SB_ptr]
    mov [rcx], rax
    mov qword ptr [rcx + 8], 0
    call pairs_list
    mov rbx, rax
    mov rdi, rax
    lea rsi, [rip + pin_forced]
    lea rdx, [rip + unsets]
    call env_lists
    mov r12, rax
    mov rdi, rbx
    call mem_free
    mov rax, r12
    EPILOGUE

# dir_unsets(list) -> rax the names claude_env removes: unsets, and CLAUDE_CONFIG_DIR when the environment's
#   is not an absolute path (or is empty). A pair of that kind leaves the list (the environment's counts
#   then, as in claude_dir). Claude would resolve a relative one against the conversation's folder, which
#   claude_dir cannot follow; without it both use $HOME/.claude. A log line names the variable, never its
#   value
dir_unsets:
    PROLOGUE
    mov rbx, rdi
    xor ecx, ecx
1:  mov rax, [rbx + rcx*8]
    test rax, rax
    jz 4f
    mov r12, rcx
    mov rdi, rax
    lea rsi, [rip + .Lconfig_dir_eq]
    mov edx, CONFIG_DIR_LEN
    call memeq
    mov rcx, r12
    inc rcx
    test eax, eax
    jz 1b
    mov rax, [rbx + r12*8]      # the pair: kept when absolute
    add rax, CONFIG_DIR_LEN
    PATH_ABSOLUTE rax, 8f
2:  mov rax, [rbx + r12*8 + 8]  # it leaves the list
    mov [rbx + r12*8], rax
    inc r12
    test rax, rax
    jnz 2b
    lea rdi, [rip + .Ldir_dropped]
    call log_cstr
4:  lea rdi, [rip + .Lconfig_dir]   # no pair (that counts): the environment's
    call host_env
    test rax, rax
    jz 8f
    PATH_ABSOLUTE rax, 8f
    lea rdi, [rip + .Ldir_dropped]
    call log_cstr
    lea rax, [rip + unsets_dir]
    EPILOGUE
8:  lea rax, [rip + unsets]
    EPILOGUE

# claude_exe() -> rax argv prefix, edx count (see the top of the file)
FN claude_exe
    PROLOGUE 16
    cmp dword ptr [rip + g_remote], 0
    jne .Lce_host
    call claude_env
    mov [rsp], rax
    xor r12d, r12d              # the wrapper's path
    xor r13d, r13d              # the program's
    mov rdi, [rip + cfg_claude_wrapper]
    cmp byte ptr [rdi], 0
    je 1f
    mov rsi, [rsp]
    call find_program
    test rax, rax
    jz .Lce_none
    mov r12, rax
1:  mov rdi, [rip + cfg_claude_executable]
    cmp byte ptr [rdi], 0
    je 2f
    mov rsi, [rsp]
    call find_program
    jmp 3f
2:  lea rdi, [rip + .Lclaude]
    mov rsi, [rsp]
    call uproc_which
    test rax, rax
    jnz 3f
    call usual_place
3:  test rax, rax
    jz .Lce_none
    mov r13, rax
.Lce_block:
    # one block: the array, then the strings
    mov rdi, r13
    call strlen
    lea r14, [rax + 1 + 24]     # the program, three slots
    test r12, r12
    jz 4f
    mov rdi, r12
    call strlen
    lea r14, [r14 + rax + 1]
4:  mov rdi, r14
    call mem_alloc
    mov rbx, rax
    lea r15, [rax + 24]         # where the next string goes
    xor r14d, r14d              # slots filled
    test r12, r12
    jz 5f
    mov [rbx], r15
    mov rdi, r15
    mov rsi, r12
    call cstr_copy
    lea r15, [rax + 1]
    inc r14d
5:  mov [rbx + r14*8], r15
    mov rdi, r15
    mov rsi, r13
    call cstr_copy
    inc r14d
    mov qword ptr [rbx + r14*8], 0
    mov rdi, r12
    call mem_free
    mov rdi, r13
    call mem_free
    mov rdi, [rsp]
    call mem_free
    mov rax, rbx
    mov edx, r14d
    EPILOGUE
.Lce_none:
    mov rdi, r12
    call mem_free
    mov rdi, [rsp]
    call mem_free
    xor eax, eax
    xor edx, edx
    EPILOGUE
.Lce_host:
    # a remote window: the program runs on the host, found there when it starts (a name on the host's PATH,
    # a path with "~/" the host's home); nothing here can tell whether it is there
    mov qword ptr [rsp], 0
    xor r12d, r12d
    mov rdi, [rip + cfg_claude_wrapper]
    cmp byte ptr [rdi], 0
    je 1f
    call expand_home
    mov rdi, rax
    call dup_cstr
    mov r12, rax
1:  lea rdi, [rip + .Lclaude]
    mov rax, [rip + cfg_claude_executable]
    cmp byte ptr [rax], 0
    je 2f
    mov rdi, rax
    call expand_home
    mov rdi, rax
2:  call dup_cstr
    mov r13, rax
    jmp .Lce_block

# find_program(setting cstr, envp) -> rax path (mem_free it) or 0: a path ("~/" is the home folder)
#   when it can be run, else the name looked up on the environment's PATH
find_program:
    PROLOGUE
    mov r12, rsi
    call expand_home
    mov rbx, rax
    PATH_ABSOLUTE rbx, 2f
    xor ecx, ecx
1:  movzx eax, byte ptr [rbx + rcx]
    test eax, eax
    jz 3f
    cmp eax, '/'
    je 2f
.ifdef WINDOWS
    cmp eax, 92
    je 2f
.endif
    inc rcx
    jmp 1b
2:  mov rdi, rbx
    call runnable
    EPILOGUE
3:  mov rdi, rbx
    mov rsi, r12
    call uproc_which
    EPILOGUE

# runnable(path) -> rax a copy of it (mem_free it) when it is a file that can be run, else 0 (not a folder)
runnable:
    PROLOGUE
    mov rbx, rdi
    call file_type
    cmp eax, 0x8000             # a regular file (links followed)
    jne 8f
    mov rdi, rbx
    mov esi, 1                  # X_OK
    SYS SYS_access
    test rax, rax
    jnz 8f
    mov rdi, rbx
    call strlen
    mov rdi, rbx
    mov rsi, rax
    call mem_dup
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN claude_expand_home(cstr) -> rax it, or "$HOME/rest" for "~/rest" (borrowed until the next call): a
#   configured program's path as the start reads it (cl_terminal's command line)
FN claude_expand_home
    jmp expand_home

# expand_home(cstr) -> rax it, or "$HOME/rest" for "~/rest" (in xsb, until the next call)
expand_home:
    PROLOGUE
    mov rbx, rdi
    cmp byte ptr [rbx], '~'
    jne 8f
    cmp byte ptr [rbx + 1], '/'
    jne 8f
    call vfs_home               # a remote window's: the host's (the program runs there)
    test rax, rax
    jz 8f
    mov r12, rax
    lea rdi, [rip + xsb]
    call sb_clear
    lea rdi, [rip + xsb]
    mov rsi, r12
    call sb_push_cstr
    lea rdi, [rip + xsb]
    lea rsi, [rbx + 1]
    call sb_push_cstr
    mov rax, [rip + xsb + SB_ptr]
    EPILOGUE
8:  mov rax, rbx
    EPILOGUE

# usual_place() -> rax the first of the places installers put claude in that can be run, or 0
usual_place:
    PROLOGUE
    lea rbx, [rip + places]
1:  cmp byte ptr [rbx], 0
    je 8f
    mov rdi, rbx
    call expand_home
    mov rdi, rax
    call runnable
    test rax, rax
    jnz 9f
    mov rdi, rbx
    call strlen
    lea rbx, [rbx + rax + 1]
    jmp 1b
8:  xor eax, eax
9:  EPILOGUE

# FN claude_mode_gated() -> eax 1 when [claude] initial_mode names bypassPermissions and
#   allow_bypass_permissions is off (claude_mode gives default then)
FN claude_mode_gated
    xor eax, eax
    cmp dword ptr [rip + cfg_claude_initial_mode], MODE_OPT_BYPASS
    jne 1f
    cmp dword ptr [rip + cfg_claude_allow_bypass], 0
    sete al
1:  ret

# claude_mode() -> rax the initial_mode value to pass, or 0 for the CLI's own default. Bypass
#   permissions is rhun's gate alone ([claude] allow_bypass_permissions): without it, default
FN claude_mode
    mov esi, [rip + cfg_claude_initial_mode]
    xor eax, eax
    test esi, esi
    jz 1f
    cmp esi, MODE_OPT_BYPASS
    jne 2f
    cmp dword ptr [rip + cfg_claude_allow_bypass], 0
    jne 2f
    lea rax, [rip + .Ldefault]
    ret
2:  lea rdi, [rip + g_claude_mode_opts]
    jmp choice_entry
1:  ret

# claude_mode_alias(ptr, len) -> rax ptr, rdx len: empty is the CLI's own default (the choice " "),
#   manual (the extension's word for default) is default
FN claude_mode_alias
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    test rsi, rsi
    jnz 1f
    lea rax, [rip + g_claude_mode_opts]
    mov edx, 1
    EPILOGUE
1:  lea rdx, [rip + .Lmanual]
    call str_ieq_cstr
    test eax, eax
    jz 2f
    lea rax, [rip + .Ldefault]
    mov edx, 7
    EPILOGUE
2:  mov rax, rbx
    mov rdx, r12
    EPILOGUE

# claude_dir(sb) -> eax 1 with the Claude folder appended, 0 without one (see the top of the file)
FN claude_dir
    PROLOGUE
    mov rbx, rdi
    mov rsi, [rip + dir_pin]
    test rsi, rsi
    jz 0f
    call sb_push_cstr           # a conversation's own folder (claude_dir_pin)
    mov eax, 1
    EPILOGUE
0:  call config_dir_pair
    test rax, rax
    jz 1f
    lea r12, [rax + CONFIG_DIR_LEN]
    xor r13d, r13d
    jmp 3f
1:  lea rdi, [rip + .Lconfig_dir]   # the environment claude gets: only an absolute one is passed on
                                    #   (a pair that is not absolute is not: dir_unsets)
    call host_env
    test rax, rax
    jz 2f
    PATH_ABSOLUTE rax, 11f
    jmp 2f
11: mov r12, rax
    xor r13d, r13d
    jmp 3f
2:  lea rdi, [rip + .Lhome_eq]   # the HOME claude gets: an env.HOME pair, else the environment's
    mov esi, 5
    call pair_value
    test rax, rax
    jz 21f
    cmp byte ptr [rax], 0
    jne 22f
21: lea rdi, [rip + .Lhome]
    call host_env
22:
    test rax, rax
    jz 8f
    mov r12, rax
    lea r13, [rip + .Ldot_claude]
3:  mov r14, [rbx + SB_len]
    mov rdi, rbx
    mov rsi, r12
    call sb_push_cstr
    # without the separators it ends in (one stays: "/" is a folder too)
4:  mov rax, [rbx + SB_len]
    sub rax, r14
    cmp rax, 1
    jbe 5f
    mov rcx, [rbx + SB_ptr]
    add rcx, [rbx + SB_len]
    cmp byte ptr [rcx - 1], '/'
.ifdef WINDOWS
    je 41f
    cmp byte ptr [rcx - 1], 92
.endif
    jne 5f
41: dec qword ptr [rbx + SB_len]
    mov byte ptr [rcx - 1], 0
    jmp 4b
5:  test r13, r13
    jz 9f
    mov rdi, rbx
    mov rsi, r13
    call sb_push_cstr
9:  mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# claude_slug(sb, path cstr) -> rax bytes appended: every code point but [0-9A-Za-z] is '-', and one
#   past U+FFFF is two (Claude's JS regex has no Unicode flag: it sees UTF-16 units)
FN claude_slug
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r15, [rbx + SB_len]
    mov rdi, rsi
    call strlen
    lea r13, [r12 + rax]
1:  cmp r12, r13
    jae 4f
    mov rdi, r12
    mov rsi, r13
    sub rsi, r12
    call utf8_decode
    add r12, rdx
    mov r14d, eax
    mov esi, eax
    lea ecx, [rax - '0']
    cmp ecx, 9
    jbe 2f
    or eax, 0x20
    sub eax, 'a'
    cmp eax, 25
    jbe 2f
    mov esi, '-'
2:  mov rdi, rbx
    call sb_push_byte
    cmp r14d, 0xffff
    jbe 1b
    mov rdi, rbx
    mov esi, '-'
    call sb_push_byte
    jmp 1b
4:  mov rax, [rbx + SB_len]
    sub rax, r15
    EPILOGUE

# claude_transcript(sb, cwd, sid) -> eax 1 with the conversation's path appended (see the top)
FN claude_transcript
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    call claude_dir
    test eax, eax
    jz 9f
    mov rdi, rbx
    lea rsi, [rip + .Lprojects]
    call sb_push_cstr
    mov rdi, r12
    lea rsi, [rip + rpath]
    call vfs_realpath           # a remote window's folder is the host's
    lea rsi, [rip + rpath]
    test rax, rax
    cmovle rsi, r12
    mov r14, [rbx + SB_len]
    mov rdi, rbx
    call claude_slug
    cmp rax, SLUG_MAX
    jbe 1f
    add r14, SLUG_MAX
    mov [rbx + SB_len], r14
    mov rax, [rbx + SB_ptr]
    mov byte ptr [rax + r14], 0
1:  mov rdi, rbx
    mov esi, '/'
    call sb_push_byte
    mov rdi, rbx
    mov rsi, r13
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Ljsonl]
    call sb_push_cstr
    mov eax, 1
9:  EPILOGUE

# claude_index_envp() -> the discovery worker's environment (see the top of the file): rhun's own with
#   CLAUDE_CONFIG_DIR the folder claude_dir gives now (kept in idx_dir for claude_dir_moved)
FN claude_index_envp
    PROLOGUE
    mov rdi, [rip + index_env]
    call mem_free
    mov qword ptr [rip + index_env], 0
    lea rdi, [rip + idx_dir]    # (a remote window's: the host's folder, claude_dir; the pair is all that goes)
    call sb_clear
    lea rdi, [rip + idx_dir]
    call claude_dir
    test eax, eax
    jz 8f
    lea rdi, [rip + idx_pair]
    call sb_clear
    lea rdi, [rip + idx_pair]
    lea rsi, [rip + .Lconfig_dir_eq]
    mov edx, CONFIG_DIR_LEN
    call sb_push
    lea rdi, [rip + idx_pair]
    mov rsi, [rip + idx_dir + SB_ptr]
    mov rdx, [rip + idx_dir + SB_len]
    call sb_push
    lea rdi, [rip + idx_pair]
    xor esi, esi
    call sb_push_byte
    mov rax, [rip + idx_pair + SB_ptr]
    mov [rip + idx_set], rax
    mov qword ptr [rip + idx_set + 8], 0
    lea rdi, [rip + idx_set]
    call env_make
    mov [rip + index_env], rax
    EPILOGUE
8:  mov rax, [rip + g_envp]
    EPILOGUE

# FN claude_dir_moved() -> eax 1 once: the login environment became known and claude_dir differs from the
#   folder discovery last ran with (a discovery that has not run yet will use the right one)
FN claude_dir_moved
    PROLOGUE
    xor eax, eax
    cmp dword ptr [rip + dir_checked], 0
    jne 9f
    call uproc_env_known
    test eax, eax
    jz 9f
    mov dword ptr [rip + dir_checked], 1
    xor eax, eax
    cmp qword ptr [rip + idx_dir + SB_len], 0
    je 9f
    lea rdi, [rip + dir_now]
    call sb_clear
    lea rdi, [rip + dir_now]
    call claude_dir
    mov rax, [rip + dir_now + SB_len]
    cmp rax, [rip + idx_dir + SB_len]
    jne 8f
    mov rdi, [rip + dir_now + SB_ptr]
    mov rsi, [rip + idx_dir + SB_ptr]
    mov rdx, rax
    call memeq
    xor eax, 1
    EPILOGUE
8:  mov eax, 1
9:  EPILOGUE

# ---- headless control commands: fn(out, rest, rest len) -> rax 0 ok, -1 error ----

# print-claude-exe: the program the chat would start, one argv word a line, or "none"
c_print_claude_exe:
    PROLOGUE
    mov rbx, rdi
    call time_ms
    lea r12, [rax + ENV_WAIT_MS]
1:  call uproc_env_ready
    test eax, eax
    jnz 2f
    call time_ms
    cmp rax, r12
    jae 2f
    mov edi, 20
    call loop_poll
    call app_tick
    jmp 1b
2:  call claude_exe
    test rax, rax
    jz 8f
    mov r12, rax
    mov r13, rax
3:  mov rsi, [r13]
    test rsi, rsi
    jz 4f
    mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    add r13, 8
    jmp 3b
4:  mov rdi, r12
    call mem_free
    xor eax, eax
    EPILOGUE
8:  mov rdi, rbx
    lea rsi, [rip + .Lnone]
    call sb_push_cstr
    xor eax, eax
    EPILOGUE

# print-claude-path CWD SID: the file Claude Code keeps that conversation in
c_print_claude_path:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, r12
    mov rsi, r13
    call next_word
    add r12, rcx
    sub r13, rcx
    test rdx, rdx
    jz 8f
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov r14, rax                # CWD
    mov rdi, r12
    mov rsi, r13
    call next_word
    test rdx, rdx
    jz 7f
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov r15, rax                # SID
    mov rdi, rbx
    mov rsi, r14
    mov rdx, r15
    call claude_transcript
    test eax, eax
    jnz 1f
    mov rdi, rbx
    lea rsi, [rip + .Lnone]
    call sb_push_cstr
    jmp 2f
1:  mov rdi, rbx
    mov esi, 10
    call sb_push_byte
2:  mov rdi, r15
    call mem_free
    mov rdi, r14
    call mem_free
    xor eax, eax
    EPILOGUE
7:  mov rdi, r14
    call mem_free
8:  mov rax, -1
    EPILOGUE

.section .rodata
.p2align 3
.globl claude_ctl
claude_ctl:
    .quad .Lc_print_claude_exe, c_print_claude_exe
    .quad .Lc_print_claude_path, c_print_claude_path
    .quad 0, 0
# rhun's forced values (they win over the env pairs) and the variables a surrounding Claude Code sets
forced: .quad .Lf_entry, .Lf_mcp, .Lf_preview, .Lf_ckpt, 0
forced_rerun: .quad .Lf_entry, .Lf_mcp, .Lf_preview, .Lf_ckpt, .Lf_rerun, .Lf_rerun_age, 0   # p6b
unsets: .quad .Lu_claudecode, .Lu_child, .Lu_traceparent, .Lu_tracestate, 0
unsets_dir: .quad .Lu_claudecode, .Lu_child, .Lu_traceparent, .Lu_tracestate, .Lconfig_dir, 0

# [claude] initial_mode (config.s): " " is the CLI's own default, written as an empty value
.globl g_claude_mode_opts
g_claude_mode_opts:
    .asciz " ", "Claude Code's setting", "default", "Manual", "acceptEdits", "Edit automatically"
    .asciz "plan", "Plan", "auto", "Auto", "bypassPermissions", "Bypass permissions", ""

# where installers put claude, after the PATH ("~/" is the home folder)
places:
.ifdef WINDOWS
    .asciz "~/.local/bin/claude.exe"
.else
    .asciz "~/.local/bin/claude", "~/.claude/local/claude", "/opt/homebrew/bin/claude"
    .asciz "/usr/local/bin/claude", "~/.npm-global/bin/claude", "~/.bun/bin/claude"
.endif
    .byte 0
# where installers put claude on a remote window's host (Linux), after its PATH
host_places:
    .asciz "~/.local/bin/claude", "~/.claude/local/claude", "/usr/local/bin/claude"
    .asciz "~/.npm-global/bin/claude", "~/.bun/bin/claude"
    .byte 0

.Lc_print_claude_exe: .asciz "print-claude-exe"
.Lc_print_claude_path: .asciz "print-claude-path"
.Lf_entry: .asciz "CLAUDE_CODE_ENTRYPOINT=rhun"
.Lf_mcp: .asciz "MCP_CONNECTION_NONBLOCKING=true"
.Lf_preview: .asciz "CLAUDE_CODE_QUESTION_PREVIEW_FORMAT=markdown"
.Lf_ckpt: .asciz "CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING=true"     # p6b: rewind_files (finding 103)
.Lf_rerun: .asciz "CLAUDE_CODE_RESUME_INTERRUPTED_TURN=1"             # p6b: a cut turn runs again (finding 105)
.Lf_rerun_age: .asciz "CLAUDE_CODE_RESUME_INTERRUPTED_TURN_MAX_AGE_MS=3600000"
.Lu_claudecode: .asciz "CLAUDECODE"
.Lu_child: .asciz "CLAUDE_CODE_CHILD_SESSION"
.Lu_traceparent: .asciz "TRACEPARENT"
.Lu_tracestate: .asciz "TRACESTATE"
.Ls_claude: .asciz "claude"
.Lenv_dot: .asciz "env."
.Leq: .asciz " = "
.Ldump_env: .asciz "claude.env."
.Ldump_set: .asciz "=(set)\n"
.Lverb_key: .asciz "spinner_verb"
.Lverb_line: .asciz "spinner_verb = "
.Ldump_verb: .asciz "claude.spinner_verb="
.Ldrop_a: .asciz "rhun: [claude] env."
.Ldir_dropped: .asciz "rhun: CLAUDE_CONFIG_DIR is not an absolute path: claude is started without it\n"
.Ldrop_b: .asciz " dropped: the name is not a variable's, the pair is over 8 KiB, or there are 64 already\n"
.Lconfig_dir_eq: .ascii "CLAUDE_CONFIG_DIR="
.Lconfig_dir: .asciz "CLAUDE_CONFIG_DIR"
.Lhome: .asciz "HOME"
.Lhome_eq: .ascii "HOME="
.Ldot_claude: .asciz "/.claude"
.Lprojects: .asciz "/projects/"
.Ljsonl: .asciz ".jsonl"
.Lclaude: .asciz "claude"
.Lmanual: .asciz "manual"
.Ldefault: .asciz "default"
.Lnone: .asciz "none\n"
