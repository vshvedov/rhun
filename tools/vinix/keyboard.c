#include "keyboard.h"
#include <string.h>

static uint32_t keysym(uint32_t code, unsigned char final) {
    switch (final) {
    case 'A': return 0xff52; case 'B': return 0xff54;
    case 'C': return 0xff53; case 'D': return 0xff51;
    case 'H': return 0xff50; case 'F': return 0xff57;
    case 'E': return 0xff9d;
    case 'P': return 0xffbe; case 'Q': return 0xffbf; case 'S': return 0xffc1;
    case '~': {
        switch (code) {
        case 2: return 0xff63; case 3: return 0xffff;
        case 5: return 0xff55; case 6: return 0xff56;
        case 13: return 0xffc0; case 15: return 0xffc2;
        case 17: return 0xffc3; case 18: return 0xffc4;
        case 19: return 0xffc5; case 20: return 0xffc6;
        case 21: return 0xffc7; case 23: return 0xffc8; case 24: return 0xffc9;
        default: return 0;
        }
    }
    case 'u': break;
    default: return 0;
    }
    switch (code) {
    case 8: case 127: return 0xff08; case 9: return 0xff09;
    case 13: return 0xff0d; case 27: return 0xff1b;
    case 57414: return 0xff8d;
    case 57417: return 0xff96; case 57418: return 0xff98;
    case 57419: return 0xff97; case 57420: return 0xff99;
    case 57421: return 0xff9a; case 57422: return 0xff9b;
    case 57423: return 0xff95; case 57424: return 0xff9c;
    case 57425: return 0xff9e; case 57426: return 0xff9f;
    case 57410: return '/'; case 57411: return '*';
    case 57412: return '-'; case 57413: return '+'; case 57415: return '=';
    default:
        if (code >= 57399 && code <= 57408) return '0' + code - 57399;
        if (code == 57409) return '.';
        if (code >= 57364 && code <= 57398) return 0xffbe + code - 57364;
        if (code >= 57344 && code <= 63743) return 0;
        return code <= 0x10ffff ? (code > 255 ? 0x01000000 | code : code) : 0;
    }
}

static void decode(struct nv_keyboard *keyboard, nv_key_sink sink) {
    uint32_t params[3][128] = {{0}};
    unsigned counts[3] = {1, 0, 0}, group = 0, part = 0;
    for (size_t i = 2; i + 1 < keyboard->length; ++i) {
        unsigned char c = keyboard->sequence[i];
        if (c >= '0' && c <= '9') {
            uint32_t *n = &params[group][part];
            if (*n > (UINT32_MAX - (c - '0')) / 10) return;
            *n = *n * 10 + c - '0';
        } else if (c == ':') {
            if (++part == 128) return;
            counts[group] = part + 1;
        } else if (c == ';') {
            if (++group == 3) return;
            part = 0; counts[group] = 1;
        } else return;
    }
    unsigned kitty = params[1][0] ? params[1][0] - 1 : 0;
    keyboard->mods = ((kitty & 1) ? 1 : 0) | ((kitty & 4) ? 4 : 0)
                   | ((kitty & 2) ? 8 : 0) | ((kitty & 8) ? 64 : 0);
    if (params[1][1] == 3) return; // release updates modifiers, never inserts text
    uint32_t code = params[0][0];
    uint32_t base = counts[0] >= 3 && params[0][2] ? params[0][2] : code;
    if ((kitty & 1) && params[0][1]) code = params[0][1];
    uint32_t key = keysym(code, keyboard->sequence[keyboard->length - 1]);
    // Pure modifier events have no editor key. Associated text (key zero)
    // is accepted for composed input without a physical key identity.
    if (!key && code) return;
    uint32_t text = counts[2] ? params[2][0] : 0;
    if (keyboard->mods & (4 | 8 | 64)) text = 0;
    sink(key, text <= 0x10ffff ? text : 0, keyboard->mods, base);
    if (!(keyboard->mods & (4 | 8 | 64)))
        for (unsigned i = 1; i < counts[2]; ++i)
            if (params[2][i] <= 0x10ffff) sink(0, params[2][i], keyboard->mods, 0);
}

void nv_keyboard_feed(struct nv_keyboard *keyboard, const unsigned char *bytes,
                      size_t length, nv_key_sink sink) {
    for (size_t i = 0; i < length; ++i) {
        unsigned char c = bytes[i];
        if (c == 27) { keyboard->length = 1; keyboard->sequence[0] = c; continue; }
        if (!keyboard->length) continue;
        if (keyboard->length == 1 && c != '[') { keyboard->length = 0; continue; }
        if (keyboard->length == sizeof(keyboard->sequence)) { keyboard->length = 0; continue; }
        keyboard->sequence[keyboard->length++] = c;
        if (c >= 0x40 && c <= 0x7e && keyboard->length > 2) {
            decode(keyboard, sink);
            keyboard->length = 0;
        }
    }
}
