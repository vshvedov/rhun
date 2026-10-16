#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <unistd.h>

extern long rhun_linux_syscall(long, long, long, long, long, long, long);
#define CALL(n,a,b,c,d) rhun_linux_syscall(n,(long)(a),(long)(b),(long)(c),(long)(d),0,0)

int main(void) {
    int pipefd[2];
    assert(pipe(pipefd) == 0);
    struct iovec vectors[] = {{"pixel",5},{"-header",7}};
    assert(CALL(20,pipefd[1],vectors,2,0) == 12);
    struct pollfd ready = {pipefd[0], POLLIN, 0};
    assert(CALL(7,&ready,1,0,0) == 1 && (ready.revents & POLLIN));
    char text[16] = {0};
    assert(CALL(0,pipefd[0],text,12,0) == 12);
    assert(!strcmp(text,"pixel-header"));
    close(pipefd[0]); close(pipefd[1]);

    char path[] = "/tmp/rhun-abi-XXXXXX";
    int fd = mkstemp(path);
    assert(fd >= 0 && write(fd,"abcdef",6) == 6);
    memset(text,0,sizeof(text));
    assert(CALL(17,fd,text,2,2) == 2 && !strcmp(text,"cd"));
    assert(lseek(fd,0,SEEK_CUR) == 6);
    union {uint64_t alignment; unsigned char bytes[144];} statbuf;
    memset(&statbuf,0xa5,sizeof(statbuf));
    assert(CALL(5,fd,&statbuf,0,0) == 0);
    uint32_t mode;
    int64_t size;
    memcpy(&mode,statbuf.bytes+24,4);
    memcpy(&size,statbuf.bytes+48,8);
    assert(S_ISREG(mode) && size == 6);
    close(fd); unlink(path);
    assert(CALL(0,-1,text,1,0) == -EBADF);
    assert(CALL(999,0,0,0,0) == -ENOSYS);
    puts("ok: writev, poll, pread, x86 stat layout, negative errno");
    return 0;
}
