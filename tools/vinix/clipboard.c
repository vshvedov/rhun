#define _GNU_SOURCE
#include "clipboard.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

// Vinix's broker authenticates the Unix peer, promotes copy offers after a
// recent focused gesture, and grants a single-use token for explicit paste.
enum { IDLE, OFFER, REQUEST, TAKE, READ, RETRY };
#define PACKET_LIMIT (NV_CLIPBOARD_LIMIT * 2 + 64)
static const char digits[] = "0123456789abcdef";
static uint64_t now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
static void drop_socket(struct nv_clipboard *c) {
    if (c->fd >= 0) close(c->fd);
    c->fd = -1;
    free(c->tx); free(c->rx);
    c->tx = c->rx = NULL;
    c->sent = c->received = c->wanted = c->tx_length = 0;
    c->connecting = 0;
}
void nv_clipboard_close(struct nv_clipboard *c) { drop_socket(c); c->state = IDLE; }
static void fail(struct nv_clipboard *c, const char *message) {
    nv_clipboard_close(c);
    if (c->focused && c->error) c->error(message);
}
static int private_directory(const char *path) {
    char parent[108];
    snprintf(parent, sizeof(parent), "%s", path);
    char *slash = strrchr(parent, '/');
    if (!slash || slash == parent) return 0;
    *slash = 0;
    struct stat st;
    return !lstat(parent, &st) && S_ISDIR(st.st_mode) && st.st_uid == geteuid()
        && !(st.st_mode & 077);
}
static int peer_is_user(int fd) {
#ifdef __APPLE__
    uid_t uid; gid_t gid;
    return !getpeereid(fd, &uid, &gid) && uid == geteuid();
#else
    struct ucred peer;
    socklen_t size = sizeof(peer);
    return !getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &peer, &size)
        && size == sizeof(peer) && peer.uid == geteuid();
#endif
}
static void command(struct nv_clipboard *c, int state, const char *message, size_t length) {
    drop_socket(c);
    c->state = state;
    if (!private_directory(c->path)) { fail(c, "Clipboard service is unavailable."); return; }
    c->tx = malloc(length + 4);
    if (!c->tx) { fail(c, "Could not allocate clipboard data."); return; }
    for (unsigned i = 0; i < 4; ++i) c->tx[i] = length >> (i * 8);
    memcpy(c->tx + 4, message, length); c->tx_length = length + 4;
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    memcpy(address.sun_path, c->path, strlen(c->path) + 1);
    c->fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (c->fd < 0 || fcntl(c->fd, F_SETFD, FD_CLOEXEC) < 0 ||
        fcntl(c->fd, F_SETFL, O_NONBLOCK) < 0) { fail(c, "Clipboard service is unavailable."); return; }
#ifdef __APPLE__
    int option = 1;
    setsockopt(c->fd, SOL_SOCKET, SO_NOSIGPIPE, &option, sizeof(option));
#endif
    if (connect(c->fd, (void *)&address, sizeof(address)) < 0) {
        if (errno != EINPROGRESS) { fail(c, "Clipboard service is unavailable."); return; }
        c->connecting = 1;
    } else if (!peer_is_user(c->fd)) fail(c, "Clipboard service identity could not be verified.");
}
void nv_clipboard_init(struct nv_clipboard *c, const char *path,
                       void (*paste)(const void *, size_t), void (*error)(const char *)) {
    memset(c, 0, sizeof(*c)); c->fd = -1; c->paste = paste; c->error = error;
    if (path) {
        if (strlen(path) < sizeof(c->path)) memcpy(c->path, path, strlen(path) + 1);
    } else {
        const char *base = getenv("VINIX_SESSION_RUNTIME");
        int length = snprintf(c->path, sizeof(c->path), "%s/vinix-session.%u/broker",
                              base ? base : "/run", (unsigned)geteuid());
        if (length < 0 || (size_t)length >= sizeof(c->path)) c->path[0] = 0;
    }
}
void nv_clipboard_focus(struct nv_clipboard *c, int focused) {
    c->focused = focused;
    if (!focused) nv_clipboard_close(c);
}
void nv_clipboard_cancel_paste(struct nv_clipboard *c) {
    if (c->state != OFFER) nv_clipboard_close(c);
}
void nv_clipboard_copy(struct nv_clipboard *c, const void *text, size_t length) {
    if (!c->focused || !length) return;
    if (length > NV_CLIPBOARD_LIMIT || memchr(text, 0, length)) {
        fail(c, "Clipboard sharing supports text up to 64 KiB without NUL bytes."); return;
    }
    const char prefix[] = "clipboard.offer\t0\t0\t";
    size_t start = sizeof(prefix) - 1;
    char *request = malloc(start + length * 2);
    if (!request) { fail(c, "Could not allocate clipboard data."); return; }
    memcpy(request, prefix, start);
    const unsigned char *bytes = text;
    for (size_t i = 0; i < length; ++i) {
        request[start + i * 2] = digits[bytes[i] >> 4];
        request[start + i * 2 + 1] = digits[bytes[i] & 15];
    }
    c->deadline = now() + 1500;
    command(c, OFFER, request, start + length * 2);
    free(request);
    nv_clipboard_tick(c);
}
void nv_clipboard_paste(struct nv_clipboard *c) {
    if (!c->focused) return;
    c->deadline = now() + 1500;
    command(c, REQUEST, "clipboard.request", 17);
}
static int nibble(unsigned char b) {
    if (b >= '0' && b <= '9') return b - '0';
    if (b >= 'a' && b <= 'f') return b - 'a' + 10;
    return -1;
}
static void reply(struct nv_clipboard *c) {
    char *message = (char *)c->rx;
    size_t length = c->wanted;
    if (length >= 6 && !memcmp(message, "error\t", 6)) {
        fail(c, "Clipboard request was denied."); return;
    }
    if (c->state == OFFER && length == 2 && !memcmp(message, "ok", 2)) {
        nv_clipboard_close(c); return;
    }
    if ((c->state == REQUEST && length == 2 && !memcmp(message, "ok", 2)) ||
        (c->state == TAKE && length == 5 && !memcmp(message, "empty", 5))) {
        drop_socket(c); c->state = RETRY; c->retry_at = now() + 20; return;
    }
    if (c->state == TAKE && length > 6 && length <= 25 && !memcmp(message, "token\t", 6)) {
        uint64_t token = 0;
        for (size_t i = 6; i < length; ++i) {
            unsigned char b = message[i];
            if (b < '0' || b > '9' || token > (INT64_MAX - (b - '0')) / 10u) {
                fail(c, "Clipboard service returned invalid data."); return;
            }
            token = token * 10 + b - '0';
        }
        if (!token) { fail(c, "Clipboard service returned invalid data."); return; }
        char request[80], number[24];
        int n = snprintf(number, sizeof(number), "%llu", (unsigned long long)token);
        memcpy(request, "clipboard.read\t", 15);
        for (int i = 0; i < n; ++i) {
            request[15 + i * 2] = digits[(unsigned char)number[i] >> 4];
            request[16 + i * 2] = digits[number[i] & 15];
        }
        command(c, READ, request, 15 + n * 2); return;
    }
    if (c->state == READ && length >= 7 && !memcmp(message, "data\t0\t", 7)) {
        size_t encoded = length - 7;
        if (!encoded || encoded % 2 || encoded / 2 > NV_CLIPBOARD_LIMIT) {
            fail(c, "Clipboard service returned invalid data."); return;
        }
        // Decode in place. The callback borrows these bytes only for this call.
        for (size_t i = 0; i < encoded / 2; ++i) {
            int a = nibble(message[7 + i * 2]), b = nibble(message[8 + i * 2]);
            if (a < 0 || b < 0 || !(a || b)) { fail(c, "Clipboard service returned invalid data."); return; }
            message[i] = a * 16 + b;
        }
        if (c->focused && c->paste) c->paste(message, encoded / 2);
        nv_clipboard_close(c); return;
    }
    fail(c, c->state == READ ? "The clipboard does not contain plain text." : "Clipboard service returned invalid data.");
}
void nv_clipboard_tick(struct nv_clipboard *c) {
    if (c->state == IDLE) return;
    if (now() >= c->deadline) { fail(c, "Clipboard is empty or unavailable."); return; }
    if (c->state == RETRY) {
        if (now() >= c->retry_at) command(c, TAKE, "exchange.take", 13);
        return;
    }
    struct pollfd p = {.fd = c->fd, .events = POLLIN | (c->sent < c->tx_length ? POLLOUT : 0)};
    if (poll(&p, 1, 0) <= 0) return;
    if (c->connecting && (p.revents & (POLLOUT | POLLERR | POLLHUP))) {
        int error = 0; socklen_t length = sizeof(error);
        if (getsockopt(c->fd, SOL_SOCKET, SO_ERROR, &error, &length) || error || !peer_is_user(c->fd)) {
            fail(c, "Clipboard service is unavailable."); return;
        }
        c->connecting = 0;
    }
    if (p.revents & POLLOUT) {
#ifdef __APPLE__
        int flags = 0;
#else
        int flags = MSG_NOSIGNAL;
#endif
        ssize_t n = send(c->fd, c->tx + c->sent, c->tx_length - c->sent, flags);
        if (n > 0) c->sent += n;
        else if (!n || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) {
            fail(c, "Clipboard service disconnected."); return;
        }
    }
    if (p.revents & (POLLIN | POLLHUP | POLLERR | POLLNVAL)) {
        // A complete record can arrive alongside hangup. Read it before EOF.
        while (1) {
            unsigned char *buffer = c->rx ? c->rx : c->header;
            size_t length = c->rx ? c->wanted : 4;
            ssize_t n = recv(c->fd, buffer + c->received, length - c->received, 0);
            if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) return;
            if (n <= 0) { fail(c, "Clipboard service disconnected."); return; }
            c->received += n;
            if (c->received != length) continue;
            if (c->rx) { reply(c); return; }
            c->wanted = (uint32_t)c->header[0] | (uint32_t)c->header[1] << 8
                      | (uint32_t)c->header[2] << 16 | (uint32_t)c->header[3] << 24;
            if (!c->wanted || c->wanted > PACKET_LIMIT) { fail(c, "Clipboard service returned invalid data."); return; }
            c->rx = malloc(c->wanted);
            if (!c->rx) { fail(c, "Could not allocate clipboard data."); return; }
            c->received = 0;
        }
    }
}
int nv_clipboard_timeout(const struct nv_clipboard *c) { return c->state == IDLE ? -1 : 20; }
