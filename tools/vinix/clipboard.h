#ifndef RHUN_VINIX_CLIPBOARD_H
#define RHUN_VINIX_CLIPBOARD_H
#include <stddef.h>
#include <stdint.h>

#define NV_CLIPBOARD_LIMIT 65536u
struct nv_clipboard {
    int fd, state, connecting, focused;
    uint64_t deadline, retry_at;
    size_t sent, received, wanted, tx_length;
    unsigned char header[4], *tx, *rx;
    char path[108];
    void (*paste)(const void *, size_t);
    void (*error)(const char *);
};
void nv_clipboard_init(struct nv_clipboard *, const char *socket_path,
                       void (*paste)(const void *, size_t), void (*error)(const char *));
void nv_clipboard_copy(struct nv_clipboard *, const void *, size_t);
void nv_clipboard_paste(struct nv_clipboard *);
void nv_clipboard_tick(struct nv_clipboard *);
int nv_clipboard_timeout(const struct nv_clipboard *);
void nv_clipboard_cancel_paste(struct nv_clipboard *);
void nv_clipboard_focus(struct nv_clipboard *, int);
void nv_clipboard_close(struct nv_clipboard *);
#endif
