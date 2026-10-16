#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

// The editor keeps the Linux x86-64 ABI. musl supplies the ARM64 syscall ABI.
struct x86_stat {
    uint64_t dev, ino, nlink;
    uint32_t mode, uid, gid, pad;
    uint64_t rdev;
    int64_t size, blksize, blocks;
    struct timespec atim, mtim, ctim;
    int64_t reserved[3];
};
_Static_assert(sizeof(struct x86_stat) == 144, "x86 stat layout");

static int translate_stat(int fd, const char *path, void *dest, int follow) {
    struct stat st;
    int status = path ? (follow ? stat(path, &st) : lstat(path, &st)) : fstat(fd, &st);
    if (status < 0) return status;
    struct x86_stat *out = dest;
    memset(out, 0, sizeof(*out));
    out->dev = st.st_dev; out->ino = st.st_ino; out->nlink = st.st_nlink;
    out->mode = st.st_mode; out->uid = st.st_uid; out->gid = st.st_gid;
    out->rdev = st.st_rdev; out->size = st.st_size;
    out->blksize = st.st_blksize; out->blocks = st.st_blocks;
    out->atim = st.st_atim; out->mtim = st.st_mtim; out->ctim = st.st_ctim;
    return 0;
}

static int translate_sigaction(int sig, const uint64_t *act, uint64_t *old) {
    struct sigaction sa = {0}, previous;
    if (act) {
        sa.sa_handler = (void (*)(int))(uintptr_t)act[0];
        sa.sa_flags = act[1] & ~0x04000000u;
        memcpy(&sa.sa_mask, &act[3], 8);
    }
    int status = sigaction(sig, act ? &sa : NULL, old ? &previous : NULL);
    if (!status && old) {
        old[0] = (uintptr_t)previous.sa_handler;
        old[1] = previous.sa_flags; old[2] = 0;
        memcpy(&old[3], &previous.sa_mask, 8);
    }
    return status;
}

static long dispatch(long n, long a, long b, long c, long d, long e, long f) {
#define MAP(number, name) case number: return syscall(SYS_##name, a,b,c,d,e,f)
    switch (n) {
    MAP(0, read); MAP(1, write);
    case 2: return open((const char *)a, b, c);
    MAP(3, close);
    case 4: return translate_stat(0, (const char *)a, (void *)b, 1);
    case 5: return translate_stat(a, NULL, (void *)b, 0);
    case 6: return translate_stat(0, (const char *)a, (void *)b, 0);
    case 7: return poll((struct pollfd *)a, b, c);
    MAP(8, lseek); MAP(9, mmap); MAP(11, munmap);
    case 13: return translate_sigaction(a, (void *)b, (void *)c);
    MAP(16, ioctl);
    MAP(17, pread64); MAP(20, writev);
    case 21: return access((const char *)a, b);
    MAP(25, mremap); MAP(29, shmget); MAP(30, shmat); MAP(31, shmctl);
    case 33: return dup2(a, b);
    MAP(35, nanosleep);
    MAP(39, getpid); MAP(41, socket); MAP(42, connect); MAP(43, accept);
    MAP(46, sendmsg); MAP(47, recvmsg); MAP(49, bind); MAP(50, listen);
    case 58: return fork();
    MAP(59, execve); MAP(60, exit); MAP(61, wait4); MAP(62, kill);
    MAP(63, uname); MAP(67, shmdt); MAP(72, fcntl); MAP(74, fsync);
    MAP(77, ftruncate); MAP(79, getcwd); MAP(80, chdir);
    case 82: return rename((const char *)a, (const char *)b);
    case 83: return mkdir((const char *)a, b);
    case 84: return rmdir((const char *)a);
    case 87: return unlink((const char *)a);
    case 89: return readlink((const char *)a, (char *)b, c);
    case 90: return chmod((const char *)a, b);
    MAP(91, fchmod); MAP(112, setsid); MAP(217, getdents64);
    MAP(228, clock_gettime); MAP(231, exit_group);
    MAP(254, inotify_add_watch); MAP(255, inotify_rm_watch); MAP(257, openat);
    MAP(283, timerfd_create); MAP(286, timerfd_settime); MAP(288, accept4);
    MAP(293, pipe2); MAP(294, inotify_init1); MAP(319, memfd_create);
    MAP(436, close_range);
    default: errno = ENOSYS; return -1;
    }
#undef MAP
}

static int trace;
long rhun_linux_syscall(long n, long a, long b, long c, long d, long e, long f) {
    long result = dispatch(n, a,b,c,d,e,f);
    if (result == -1) result = -errno;
    if (trace && result < 0) fprintf(stderr, "syscall %ld: %ld\n", n, result);
    return result;
}

#ifndef RHUN_SYSCALL_ONLY
extern int rhun_arm64_main(void *stack);
int main(int argc, char **argv, char **envp) {
    size_t envc = 0;
    while (envp[envc]) ++envc;
    size_t size = 16u << 20, bytes = (argc + envc + 3) * sizeof(uintptr_t);
    if (bytes > size / 2) return 111;
    unsigned char *memory = malloc(size);
    if (!memory) return 111;
    uintptr_t *stack = (void *)(((uintptr_t)memory + size - bytes) & ~(uintptr_t)15);
    uintptr_t *next = stack;
    *next++ = argc;
    for (int i = 0; i < argc; ++i) *next++ = (uintptr_t)argv[i];
    *next++ = 0;
    for (size_t i = 0; i < envc; ++i) *next++ = (uintptr_t)envp[i];
    *next = 0;
    trace = getenv("RHUN_TRACE_SYSCALLS") != NULL;
    int result = rhun_arm64_main(stack);
    free(memory);
    return result;
}
#endif
