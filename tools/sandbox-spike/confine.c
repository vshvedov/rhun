// confine: throwaway launcher for the 0.18.0 confinement spike (gate 0).
// Applies what rhun's vfork child would apply before execve, then execs the target:
//   no_new_privs; Landlock (ABI >= 3) with --ro/--rw/--exec rules; --no-net via a user and
//   network namespace; --limits via prlimit. Exit codes: 70 "not confined" (a step failed),
//   71 usage, otherwise the target's. `confine probe` prints the kernel's Landlock ABI and
//   whether an unprivileged user namespace can be made.
// The production code is assembly; this exists to validate the sequence and the rule set.
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <poll.h>
#include <unistd.h>

#ifndef SYS_landlock_create_ruleset
#define SYS_landlock_create_ruleset 444
#define SYS_landlock_add_rule 445
#define SYS_landlock_restrict_self 446
#endif
#define LL_VERSION 1U
#define LL_RULE_PATH_BENEATH 1
#define FS_EXECUTE (1ULL << 0)
#define FS_WRITE_FILE (1ULL << 1)
#define FS_READ_FILE (1ULL << 2)
#define FS_READ_DIR (1ULL << 3)
#define FS_REMOVE_DIR (1ULL << 4)
#define FS_REMOVE_FILE (1ULL << 5)
#define FS_MAKE_CHAR (1ULL << 6)
#define FS_MAKE_DIR (1ULL << 7)
#define FS_MAKE_REG (1ULL << 8)
#define FS_MAKE_SOCK (1ULL << 9)
#define FS_MAKE_FIFO (1ULL << 10)
#define FS_MAKE_BLOCK (1ULL << 11)
#define FS_MAKE_SYM (1ULL << 12)
#define FS_REFER (1ULL << 13)     /* ABI 2 */
#define FS_TRUNCATE (1ULL << 14)  /* ABI 3 */
#define FS_IOCTL_DEV (1ULL << 15) /* ABI 5 */
#define NET_BIND_TCP (1ULL << 0)  /* ABI 4 */
#define NET_CONNECT_TCP (1ULL << 1)

struct ruleset_attr { unsigned long long handled_access_fs, handled_access_net, scoped; };
struct path_beneath { unsigned long long allowed_access; int parent_fd; } __attribute__((packed));

static int quiet;
static void note(const char *fmt, const char *a, int err) {
    if (quiet) return;
    fprintf(stderr, "confine: ");
    fprintf(stderr, fmt, a);
    if (err) fprintf(stderr, ": %s", strerror(err));
    fputc('\n', stderr);
}
static int fail(const char *what, int err) { note("%s", what, err); return 70; }

static int abi_version(void) {
    return (int)syscall(SYS_landlock_create_ruleset, NULL, 0, LL_VERSION);
}

static int write_file(const char *path, const char *s) {
    int fd = open(path, O_WRONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    ssize_t n = write(fd, s, strlen(s));
    int e = errno;
    close(fd);
    if (n < 0) { errno = e; return -1; }
    return 0;
}

// The user namespace maps our uid and gid to themselves so files stay ours and getuid() is sane.
static int no_net(void) {
    uid_t u = getuid(); gid_t g = getgid();
    if (unshare(CLONE_NEWUSER | CLONE_NEWNET) < 0) return fail("unshare(CLONE_NEWUSER|CLONE_NEWNET)", errno);
    char buf[64];
    if (write_file("/proc/self/setgroups", "deny") < 0) return fail("setgroups deny", errno);
    snprintf(buf, sizeof buf, "%u %u 1", u, u);
    if (write_file("/proc/self/uid_map", buf) < 0) return fail("uid_map", errno);
    snprintf(buf, sizeof buf, "%u %u 1", g, g);
    if (write_file("/proc/self/gid_map", buf) < 0) return fail("gid_map", errno);
    return 0;
}

// Landlock rejects directory-only rights (READ_DIR, MAKE_*, REMOVE_*, REFER) on a rule whose
// path is a file, so a file keeps only the rights that apply to files.
static int add_rule(int rs, const char *path, unsigned long long access, unsigned long long handled) {
    struct path_beneath pb = { .allowed_access = access & handled };
    pb.parent_fd = open(path, O_PATH | O_CLOEXEC);
    if (pb.parent_fd < 0) { note("rule path %s", path, errno); return -1; }
    struct stat st;
    if (fstat(pb.parent_fd, &st) == 0 && !S_ISDIR(st.st_mode))
        pb.allowed_access &= FS_READ_FILE | FS_WRITE_FILE | FS_EXECUTE | FS_TRUNCATE | FS_IOCTL_DEV;
    int r = (int)syscall(SYS_landlock_add_rule, rs, LL_RULE_PATH_BENEATH, &pb, 0);
    int e = errno;
    close(pb.parent_fd);
    if (r < 0) { note("add_rule %s", path, e); return -1; }
    return 0;
}

// elf_interp(path, buf, cap) -> 1 and the PT_INTERP path of an ELF64 file (its dynamic loader).
// execve needs LANDLOCK_ACCESS_FS_EXECUTE on the loader too, not only on the program: binfmt_elf
// opens the interpreter with open_exec, so a rule on the program alone gives EACCES for every
// dynamically linked binary. The spike's first run proved that on all five distros.
static int elf_interp(const char *path, char *buf, size_t cap) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    unsigned char eh[64];
    if (read(fd, eh, 64) != 64 || memcmp(eh, "\x7f" "ELF", 4) || eh[4] != 2) { close(fd); return 0; }
    unsigned long long phoff; unsigned short phentsize, phnum;
    memcpy(&phoff, eh + 32, 8); memcpy(&phentsize, eh + 54, 2); memcpy(&phnum, eh + 56, 2);
    int found = 0;
    for (int k = 0; k < phnum && !found; k++) {
        unsigned char ph[56];
        if (pread(fd, ph, 56, phoff + (unsigned long long)k * phentsize) != 56) break;
        unsigned int type; memcpy(&type, ph, 4);
        if (type != 3) continue; /* PT_INTERP */
        unsigned long long off, sz; memcpy(&off, ph + 8, 8); memcpy(&sz, ph + 32, 8);
        if (sz == 0 || sz >= cap) break;
        if (pread(fd, buf, sz, off) == (ssize_t)sz) { buf[sz] = 0; found = 1; }
    }
    close(fd);
    return found;
}

int main(int argc, char **argv) {
    if (argc >= 2 && !strcmp(argv[1], "probe")) {
        int abi = abi_version();
        if (abi < 0) printf("landlock=none (%s)\n", strerror(errno)); else printf("landlock=abi%d\n", abi);
        pid_t p = fork();
        if (p == 0) { quiet = 1; _exit(no_net() ? 1 : 0); }
        int st = 0; waitpid(p, &st, 0);
        printf("userns_netns=%s\n", (WIFEXITED(st) && WEXITSTATUS(st) == 0) ? "yes" : "no");
        int nnp = prctl(PR_GET_NO_NEW_PRIVS, 0, 0, 0, 0);
        printf("no_new_privs_now=%d\n", nnp);
        return 0;
    }
    if (argc >= 4 && !strcmp(argv[1], "nettest")) {
        int fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
        if (fd < 0) { printf("net=socket-failed %s\n", strerror(errno)); return 0; }
        struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons(atoi(argv[3])) };
        inet_pton(AF_INET, argv[2], &a.sin_addr);
        int r = connect(fd, (struct sockaddr *)&a, sizeof a);
        if (r < 0 && errno != EINPROGRESS) { printf("net=connect-failed %s\n", strerror(errno)); return 0; }
        struct pollfd pf = { .fd = fd, .events = POLLOUT };
        r = poll(&pf, 1, 3000);
        if (r == 0) { printf("net=timeout\n"); return 0; }
        int err = 0; socklen_t el = sizeof err; getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &el);
        printf("net=%s\n", err ? strerror(err) : "connected");
        return 0;
    }
    // options, then "--", then the target and its arguments
    const char *ro[64], *rw[64], *ex[64]; int nro = 0, nrw = 0, nex = 0;
    int want_no_net = 0, want_limits = 0, min_abi = 3, i = 1;
    for (; i < argc; i++) {
        if (!strcmp(argv[i], "--ro") && i + 1 < argc) ro[nro++] = argv[++i];
        else if (!strcmp(argv[i], "--rw") && i + 1 < argc) rw[nrw++] = argv[++i];
        else if (!strcmp(argv[i], "--exec") && i + 1 < argc) ex[nex++] = argv[++i];
        else if (!strcmp(argv[i], "--no-net")) want_no_net = 1;
        else if (!strcmp(argv[i], "--limits")) want_limits = 1;
        else if (!strcmp(argv[i], "--min-abi") && i + 1 < argc) min_abi = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--")) { i++; break; }
        else { fprintf(stderr, "usage: confine [--ro P]... [--rw P]... [--exec FILE]... [--no-net] [--limits] -- prog args\n"); return 71; }
    }
    if (i >= argc) return 71;

    // 1. no_new_privs: required by landlock_restrict_self without CAP_SYS_ADMIN, and right anyway
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) < 0) return fail("PR_SET_NO_NEW_PRIVS", errno);

    // 2. network: a fresh user and network namespace (only its own loopback inside)
    if (want_no_net) { int r = no_net(); if (r) return r; }

    // 3. Landlock
    int abi = abi_version();
    if (abi < min_abi) { char b[64]; snprintf(b, sizeof b, "landlock ABI %d < %d", abi, min_abi); return fail(b, abi < 0 ? errno : 0); }
    unsigned long long handled = FS_EXECUTE | FS_WRITE_FILE | FS_READ_FILE | FS_READ_DIR | FS_REMOVE_DIR | FS_REMOVE_FILE |
        FS_MAKE_CHAR | FS_MAKE_DIR | FS_MAKE_REG | FS_MAKE_SOCK | FS_MAKE_FIFO | FS_MAKE_BLOCK | FS_MAKE_SYM;
    if (abi >= 2) handled |= FS_REFER;
    if (abi >= 3) handled |= FS_TRUNCATE;
    if (abi >= 5) handled |= FS_IOCTL_DEV;
    struct ruleset_attr attr = { .handled_access_fs = handled };
    size_t attr_size = sizeof(unsigned long long);            /* ABI 1-3: only handled_access_fs */
    if (abi >= 4) { attr.handled_access_net = want_no_net ? (NET_BIND_TCP | NET_CONNECT_TCP) : 0; attr_size = 2 * sizeof(unsigned long long); }
    if (abi >= 6) attr_size = sizeof attr;                    /* scoped = 0 */
    int rs = (int)syscall(SYS_landlock_create_ruleset, &attr, attr_size, 0);
    if (rs < 0) return fail("landlock_create_ruleset", errno);
    unsigned long long RO = FS_READ_FILE | FS_READ_DIR;
    unsigned long long RW = RO | FS_WRITE_FILE | FS_TRUNCATE | FS_REMOVE_DIR | FS_REMOVE_FILE | FS_MAKE_DIR | FS_MAKE_REG |
        FS_MAKE_SYM | FS_MAKE_FIFO | FS_MAKE_SOCK | FS_REFER;
    for (int k = 0; k < nro; k++) if (add_rule(rs, ro[k], RO, handled)) return 70;
    for (int k = 0; k < nrw; k++) if (add_rule(rs, rw[k], RW, handled)) return 70;
    for (int k = 0; k < nex; k++) {
        if (add_rule(rs, ex[k], FS_READ_FILE | FS_EXECUTE, handled)) return 70;
        char interp[256];
        if (elf_interp(ex[k], interp, sizeof interp)) {
            if (!quiet && getenv("CONFINE_VERBOSE")) fprintf(stderr, "confine: %s needs loader %s\n", ex[k], interp);
            if (add_rule(rs, interp, FS_READ_FILE | FS_EXECUTE, handled)) return 70;
        }
    }
    if (syscall(SYS_landlock_restrict_self, rs, 0) < 0) return fail("landlock_restrict_self", errno);
    close(rs);

    // 4. resource limits (what rhun would set with prlimit on the child)
    // CONFINE_LIMITS selects which limits to try: letters a (RLIMIT_AS 4 GB), p (NPROC 256),
    // f (NOFILE 1024), c (CPU 600 s); default all four. The spike showed Go programs die under
    // RLIMIT_AS (the runtime reserves address space generously), see the spike note.
    if (want_limits) {
        const char *which = getenv("CONFINE_LIMITS"); if (!which) which = "apfc";
        struct rlimit r;
        if (strchr(which, 'a')) { r.rlim_cur = r.rlim_max = 4ULL << 30; setrlimit(RLIMIT_AS, &r); }
        if (strchr(which, 'p')) { r.rlim_cur = r.rlim_max = 256; setrlimit(RLIMIT_NPROC, &r); }
        if (strchr(which, 'f')) { r.rlim_cur = r.rlim_max = 1024; setrlimit(RLIMIT_NOFILE, &r); }
        if (strchr(which, 'c')) { r.rlim_cur = r.rlim_max = 600; setrlimit(RLIMIT_CPU, &r); }
    }

    execv(argv[i], argv + i);
    return fail(argv[i], errno);
}
