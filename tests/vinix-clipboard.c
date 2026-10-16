#define _GNU_SOURCE
#include "../tools/vinix/clipboard.h"
#include <assert.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

static char directory[] = "/tmp/rhun-clipboard-XXXXXX", path[108];
static const char text[] = "native clipboard: café 🙂\nsecond line\twith tab";
static unsigned pastes, errors;
static char pasted[NV_CLIPBOARD_LIMIT];
static size_t pasted_length;
static void paste(const void *p, size_t length) {
    assert(length <= sizeof(pasted)); memcpy(pasted, p, length); pasted_length = length; ++pastes;
}
static void error(const char *message) { assert(message && *message); ++errors; }
static void exact(int fd, void *p, size_t length) {
    size_t at = 0;
    while (at < length) { ssize_t n = read(fd, (char *)p + at, length - at); assert(n > 0); at += n; }
}
static char *request(int listener) {
    int fd = accept(listener, NULL, NULL); assert(fd >= 0);
    unsigned char header[4]; exact(fd, header, 4);
    size_t length = (unsigned)header[0] | (unsigned)header[1] << 8 | (unsigned)header[2] << 16 | (unsigned)header[3] << 24;
    assert(length && length < 256 * 1024);
    char *message = malloc(length + 16); assert(message);
    // Reserve the descriptor in the prefix so each reply uses the same peer.
    memcpy(message, &fd, sizeof(fd)); exact(fd, message + 8, length); message[8 + length] = 0;
    return message;
}
static void answer(char *message, const char *value, int fragmented) {
    int fd; memcpy(&fd, message, sizeof(fd)); size_t length = strlen(value);
    unsigned char header[4] = {length, length >> 8, length >> 16, length >> 24};
    for (unsigned i = 0; i < 4; ++i) { assert(write(fd, &header[i], 1) == 1); if (fragmented) usleep(1000); }
    for (size_t at = 0; at < length;) {
        size_t take = fragmented ? 1 : length - at;
        assert(write(fd, value + at, take) == (ssize_t)take); at += take;
        if (fragmented) usleep(500);
    }
    close(fd); free(message);
}
static int listener(void) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0); assert(fd >= 0);
    unlink(path);
    struct sockaddr_un a = {.sun_family = AF_UNIX}; strcpy(a.sun_path, path);
    assert(!bind(fd, (void *)&a, sizeof(a)) && !listen(fd, 8)); return fd;
}
static void settle(struct nv_clipboard *c) {
    for (unsigned i = 0; i < 3000 && c->state; ++i) { nv_clipboard_tick(c); usleep(1000); }
    assert(!c->state && c->fd == -1 && !c->rx && !c->tx);
}
static void child_ok(pid_t child) { int status; assert(waitpid(child, &status, 0) == child); assert(WIFEXITED(status) && !WEXITSTATUS(status)); }
static void init(struct nv_clipboard *c) { nv_clipboard_init(c, path, paste, error); nv_clipboard_focus(c, 1); }
static void round_trip(void) {
    int fd = listener(); pid_t child = fork(); assert(child >= 0);
    if (!child) {
        char *m = request(fd); assert(!strncmp(m + 8, "clipboard.offer\t0\t0\t", 20));
        assert(strlen(m + 8) == 20 + NV_CLIPBOARD_LIMIT * 2);
        for (size_t i = 28; i < 28 + NV_CLIPBOARD_LIMIT * 2; i += 2) assert(m[i] == '6' && m[i + 1] == '1');
        answer(m, "ok", 1);
        m = request(fd); assert(!strcmp(m + 8, "clipboard.request")); answer(m, "ok", 1);
        m = request(fd); assert(!strcmp(m + 8, "exchange.take")); answer(m, "empty", 1);
        m = request(fd); assert(!strcmp(m + 8, "exchange.take")); answer(m, "token\t42", 1);
        m = request(fd); assert(!strcmp(m + 8, "clipboard.read\t3432"));
        char value[sizeof(text) * 2 + 8]; strcpy(value, "data\t0\t");
        const char *hex = "0123456789abcdef";
        for (size_t i = 0; i < sizeof(text) - 1; ++i) { value[7 + i * 2] = hex[(unsigned char)text[i] >> 4]; value[8 + i * 2] = hex[text[i] & 15]; }
        value[7 + (sizeof(text) - 1) * 2] = 0;
        answer(m, value, 1); close(fd); _exit(0);
    }
    close(fd); struct nv_clipboard c; init(&c);
    char large[NV_CLIPBOARD_LIMIT]; memset(large, 'a', sizeof(large));
    nv_clipboard_copy(&c, large, sizeof(large)); settle(&c); assert(!errors);
    nv_clipboard_paste(&c); settle(&c); assert(pastes == 1 && !errors);
    assert(pasted_length == sizeof(text) - 1 && !memcmp(pasted, text, pasted_length));
    child_ok(child);
}
static void rejected_reply(const char *value, int oversize) {
    int fd = listener(); pid_t child = fork(); assert(child >= 0);
    if (!child) {
        char *m = request(fd);
        if (oversize) {
            int peer; memcpy(&peer, m, sizeof(peer)); unsigned char h[4] = {0xff, 0xff, 0xff, 0x7f};
            assert(write(peer, h, 4) == 4); close(peer); free(m);
        } else answer(m, value, 1);
        close(fd); _exit(0);
    }
    close(fd); struct nv_clipboard c; init(&c); unsigned before = errors;
    nv_clipboard_paste(&c); settle(&c); assert(errors == before + 1 && pastes == 1); child_ok(child);
}
static void cancelled(void) {
    int fd = listener(); pid_t child = fork(); assert(child >= 0);
    if (!child) { char *m = request(fd); answer(m, "ok", 1); close(fd); _exit(0); }
    close(fd); struct nv_clipboard c; init(&c); nv_clipboard_paste(&c);
    for (unsigned i = 0; i < 500 && c.fd >= 0; ++i) { nv_clipboard_tick(&c); usleep(1000); }
    assert(c.state && c.fd == -1);
    nv_clipboard_cancel_paste(&c); assert(!c.state && pastes == 1); child_ok(child);
    nv_clipboard_focus(&c, 0); nv_clipboard_paste(&c); assert(!c.state);
}
static void invalid_paste(const char *token, const char *value) {
    int fd = listener(); pid_t child = fork(); assert(child >= 0);
    if (!child) {
        char *m = request(fd); answer(m, "ok", 1);
        m = request(fd); answer(m, token, 1);
        if (value) { m = request(fd); answer(m, value, 1); }
        close(fd); _exit(0);
    }
    close(fd); struct nv_clipboard c; init(&c); unsigned before = errors;
    nv_clipboard_paste(&c); settle(&c); assert(errors == before + 1 && pastes == 1); child_ok(child);
}
int main(void) {
    alarm(20); signal(SIGPIPE, SIG_IGN); assert(mkdtemp(directory));
    snprintf(path, sizeof(path), "%s/broker", directory);
    round_trip(); cancelled(); rejected_reply("error\t64656e696564", 0); rejected_reply("unexpected", 0); rejected_reply("", 1);
    invalid_paste("token\t9223372036854775808", NULL);
    invalid_paste("token\t0", NULL);
    invalid_paste("token\t42", "data\t0\t610062");
    invalid_paste("token\t42", "data\t0\t61zz");
    invalid_paste("token\t42", "data\t0\t6");
    invalid_paste("token\t42", "data\t1\t6869");
    struct nv_clipboard c; init(&c); unsigned before = errors;
    char large[NV_CLIPBOARD_LIMIT + 1]; memset(large, 'a', sizeof(large));
    nv_clipboard_copy(&c, large, sizeof(large)); nv_clipboard_copy(&c, "a\0b", 3);
    assert(errors == before + 2 && !c.state);
    nv_clipboard_paste(&c); c.deadline = 0; nv_clipboard_tick(&c); assert(!c.state && errors == before + 3);
    nv_clipboard_close(&c); unlink(path); assert(!rmdir(directory));
    puts("Vinix clipboard broker client passed");
}
