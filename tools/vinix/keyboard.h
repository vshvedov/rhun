#ifndef RHUN_VINIX_KEYBOARD_H
#define RHUN_VINIX_KEYBOARD_H
#include <stddef.h>
#include <stdint.h>
struct nv_keyboard {
    unsigned char sequence[4096];
    size_t length;
    unsigned mods;
};
typedef void (*nv_key_sink)(uint32_t key, uint32_t text, unsigned mods, uint32_t base);
void nv_keyboard_feed(struct nv_keyboard *, const unsigned char *, size_t, nv_key_sink);
#endif
