// Host test for the native backend's Kitty keyboard decoder.
#include "../tools/vinix/keyboard.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

struct press { uint32_t key, text, mods, base; };
static struct press received[32];
static unsigned count;
static void key(uint32_t symbol, uint32_t text, unsigned mods, uint32_t base) {
    assert(count < 32);
    received[count++] = (struct press){symbol, text, mods, base};
}
static void feed(struct nv_keyboard *kb, const char *s) {
    nv_keyboard_feed(kb, (const unsigned char *)s, strlen(s), key);
}
int main(void) {
    struct nv_keyboard kb = {0};
    feed(&kb, "\033[97:65:97;2:1;65u\033[97;1:3u");
    assert(count == 1 && received[0].key == 'A' && received[0].text == 'A');
    assert(received[0].mods == 1 && received[0].base == 'a');
    feed(&kb, "\033[115;5:1u\033[1;6:2A\033[9;1:1u\033[13;1:1u");
    assert(count == 5 && received[1].key == 's' && received[1].mods == 4);
    assert(received[2].key == 0xff52 && received[2].mods == 5);
    assert(received[3].key == 0xff09 && received[4].key == 0xff0d);
    // The transport can split keyboard records at any byte boundary.
    const char *unicode = "\033[233;1:1;233u\033[0;1:1;955:128578u";
    for (size_t i = 0; unicode[i]; ++i)
        nv_keyboard_feed(&kb, (const unsigned char *)&unicode[i], 1, key);
    assert(count == 8 && received[5].text == 233);
    assert(received[6].text == 955 && received[7].text == 128578);
    feed(&kb, "\033[57442;5:1u\033[57442;1:3u\033[3;1:1~\033[57414;1:1u");
    assert(count == 10 && kb.mods == 0);
    assert(received[8].key == 0xffff && received[9].key == 0xff8d);
    feed(&kb, "\033[999999999999999999999u\033[1;1;1;1u\033[97;1:1;97u");
    assert(count == 11 && received[10].text == 'a');
    feed(&kb, "\033[955;1:1;955u");
    assert(count == 12 && received[11].key == 0x010003bb && received[11].text == 955);
    puts("Vinix keyboard decoder passed");
}
