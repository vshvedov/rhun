# Claude Code's settings that are not rows of g_settings (config.s has [claude] chat, executable,
# wrapper and initial_mode), and the places that follow from them: the program to start, its
# environment, the folder Claude Code keeps its conversations in and a conversation's file.
#
#   claudecfg_reset()                       the config file is read again: the env pairs go
#   claudecfg_key(sec, seclen, key, keylen, val, vallen) -> eax 1 taken: [claude] env.NAME = value
#                                           (NAME [A-Za-z_][A-Za-z0-9_]*, 64 pairs, 8 KiB a pair; others
#                                           are dropped with a log line that names no value)
#   claudecfg_save(sb)                      the pairs, as lines of [claude]
#   claudecfg_pairs() -> eax                how many (config_save writes the file 0600 with any)
#   claudecfg_dump(sb)                      "claude.env.NAME=(set)" a line each (print-settings): people
#                                           put keys in these pairs, so a value is never printed, logged
#                                           or shown outside the config file and the child's environment
#   claude_exe() -> rax argv prefix [wrapper,] executable, 0-ended, one mem_alloc'd block (strings
#                   included: mem_free it), edx the count; or rax 0 when the program (or a wrapper
#                   that is set) is not found
#   claude_env() -> rax envp: the login environment, the env pairs, rhun's forced values, without the
#                   variables a surrounding Claude Code sets (uproc_env_make; mem_free the array; its
#                   strings live until the config is read again)
#       claude_exe and claude_env read the login environment: call them only once uproc_env_ready()
#       returned 1
#   claude_expand_home(cstr) -> rax "~/" as the home folder, as the start reads a configured path
#   claude_mode() -> rax the --permission-mode value of [claude] initial_mode, or 0 (the CLI's own)
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
#   claude_config_dir_value() -> rax env.CLAUDE_CONFIG_DIR's value, or 0 (the terminal's sign-in)
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

.bss
.p2align 3
pairs: .zero VEC_SIZE           # owned "NAME=value" cstrs, 8-byte slots, in the file's order
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
pin_forced: .zero 8 * 4         # forced's entries, then pin_pair's text, 0
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
    EPILOGUE

# claudecfg_key(sec, seclen, key, keylen, val, vallen) -> eax 1 when it is a [claude] env.NAME pair
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
9:  EPILOGUE

# claudecfg_dump(sb): "claude.env.NAME=(set)" a line each: never the value
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
9:  EPILOGUE

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

# FN claude_config_dir_value() -> rax the value of [claude] env.CLAUDE_CONFIG_DIR (a cstr, borrowed until
#   the config is read again), or 0 when it is not set or not absolute (claude does not get it then)
FN claude_config_dir_value
    PROLOGUE
    call config_dir_pair
    test rax, rax
    jz 9f
    add rax, CONFIG_DIR_LEN
9:  EPILOGUE

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
    call uproc_env_make
    mov r12, rax
    mov rdi, rbx
    call mem_free
    mov rax, r12
    EPILOGUE

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
    mov rax, [rip + pin_pair + SB_ptr]
    mov [rcx + 16], rax
    mov qword ptr [rcx + 24], 0
    call pairs_list
    mov rbx, rax
    mov rdi, rax
    lea rsi, [rip + pin_forced]
    lea rdx, [rip + unsets]
    call uproc_env_make
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
    call uproc_env_get
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
    lea rdi, [rip + .Lhome]
    call getenv
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

# claude_mode() -> rax the initial_mode value to pass, or 0 for the CLI's own default
FN claude_mode
    mov esi, [rip + cfg_claude_initial_mode]
    xor eax, eax
    test esi, esi
    jz 1f
    lea rdi, [rip + g_claude_mode_opts]
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
    call uproc_env_get
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
    call uproc_env_get
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
    call local_realpath
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
    cmp dword ptr [rip + g_remote], 0       # remote hosts: the host's own folder
    jne 8f
    lea rdi, [rip + idx_dir]
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
forced: .quad .Lf_entry, .Lf_mcp, 0
unsets: .quad .Lu_claudecode, .Lu_child, .Lu_traceparent, .Lu_tracestate, 0
unsets_dir: .quad .Lu_claudecode, .Lu_child, .Lu_traceparent, .Lu_tracestate, .Lconfig_dir, 0

# [claude] initial_mode (config.s): " " is the CLI's own default, written as an empty value
.globl g_claude_mode_opts
g_claude_mode_opts:
    .asciz " ", "Claude Code's setting", "default", "Manual", "acceptEdits", "Edit automatically"
    .asciz "plan", "Plan", ""

# where installers put claude, after the PATH ("~/" is the home folder)
places:
.ifdef WINDOWS
    .asciz "~/.local/bin/claude.exe"
.else
    .asciz "~/.local/bin/claude", "~/.claude/local/claude", "/opt/homebrew/bin/claude"
    .asciz "/usr/local/bin/claude", "~/.npm-global/bin/claude", "~/.bun/bin/claude"
.endif
    .byte 0

.Lc_print_claude_exe: .asciz "print-claude-exe"
.Lc_print_claude_path: .asciz "print-claude-path"
.Lf_entry: .asciz "CLAUDE_CODE_ENTRYPOINT=rhun"
.Lf_mcp: .asciz "MCP_CONNECTION_NONBLOCKING=true"
.Lu_claudecode: .asciz "CLAUDECODE"
.Lu_child: .asciz "CLAUDE_CODE_CHILD_SESSION"
.Lu_traceparent: .asciz "TRACEPARENT"
.Lu_tracestate: .asciz "TRACESTATE"
.Ls_claude: .asciz "claude"
.Lenv_dot: .asciz "env."
.Leq: .asciz " = "
.Ldump_env: .asciz "claude.env."
.Ldump_set: .asciz "=(set)\n"
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
