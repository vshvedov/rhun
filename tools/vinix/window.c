#include <vinix_window.h>
#include "keyboard.h"
#include "clipboard.h"
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern uint64_t rhun_g_plat[13];
extern int rhun_g_dirty, rhun_g_quit, rhun_g_csd, rhun_g_key_base;
extern void rhun_nv_nop(void), rhun_nv_draw(void), rhun_nv_timeout(void);
extern void rhun_nv_flush(void), rhun_nv_title(void), rhun_nv_events(void);
extern void rhun_nv_clip_set(void), rhun_nv_clip_get(void);
extern void nv_watch_add(int, int, void (*)(void), void *);
extern void nv_watch_remove(int);
extern void nv_watch_set_events(int, int);
extern void nv_target(uint32_t *, int, int, int), nv_resize(int, int), nv_render(void);
extern void nv_motion(int, int), nv_button(int, int, int), nv_scroll(int, int, int);
extern void nv_focus(int), nv_key(int, int, int), nv_paste(const void *, size_t);
extern void nv_close_request(void);
extern void nv_toast(const char *);

static vinix_window *window;
static vinix_framebuffer framebuffer;
static struct nv_keyboard keyboard;
static int descriptor = -1;
static int connection_lost;
static struct nv_clipboard clipboard;
static char window_title[129] = "rhun";

static void fail(const vinix_window_error *error) {
    fprintf(stderr, "Vinix window: %s\n", error->message);
    rhun_g_quit = 1;
}
static void cleanup(void) {
    vinix_window_close(window);
    window = NULL;
    nv_clipboard_close(&clipboard);
}
static void watch_events(void) {
    nv_watch_set_events(descriptor, POLLIN | (vinix_window_wants_write(window) == 1 ? POLLOUT : 0));
}
static void target(void) {
    nv_target(framebuffer.pixels, framebuffer.width, framebuffer.height, framebuffer.stride / 4);
}
static void key(uint32_t symbol, uint32_t text, unsigned mods, uint32_t base) {
    nv_clipboard_cancel_paste(&clipboard);
    rhun_g_key_base = base;
    nv_key(symbol, text, mods);
    rhun_g_key_base = 0;
}
static void reopen(void) {
    // Vinix removes the window before delivering CLOSE. Keep the editor's
    // unsaved-file confirmation usable by recreating its native window.
    int width = framebuffer.width, height = framebuffer.height;
    connection_lost = 0;
    nv_watch_remove(descriptor);
    vinix_window_close(window);
    vinix_window_error error = {0};
    window = vinix_window_open(window_title, width, height, &error);
    if (!window) { fail(&error); return; }
    descriptor = vinix_window_event_fd(window);
    nv_watch_add(descriptor, POLLIN, rhun_nv_events, NULL);
    if (vinix_window_get_framebuffer(window, &framebuffer) < 0) { rhun_g_quit = 1; return; }
    memset(&keyboard, 0, sizeof(keyboard));
    target();
    nv_resize(framebuffer.width, framebuffer.height);
}
static void disconnected(void) {
    nv_clipboard_focus(&clipboard, 0);
    // The desktop can close its socket before its queued CLOSE is delivered.
    // EOF must follow the same unsaved-file confirmation path as CLOSE.
    nv_close_request();
    if (!rhun_g_quit) reopen();
}
void nv_events(void) {
    vinix_window_event event;
    vinix_window_error error = {0};
    int status;
    while ((status = vinix_window_next_event(window, &event, &error)) == 1) {
        switch (event.kind) {
        case VINIX_WINDOW_MOTION: nv_motion(event.x, event.y); break;
        case VINIX_WINDOW_BUTTON_DOWN: case VINIX_WINDOW_BUTTON_UP:
            if (event.kind == VINIX_WINDOW_BUTTON_DOWN) nv_clipboard_cancel_paste(&clipboard);
            nv_motion(event.x, event.y);
            nv_button(event.value, event.kind == VINIX_WINDOW_BUTTON_DOWN, keyboard.mods);
            break;
        case VINIX_WINDOW_KEYS: nv_keyboard_feed(&keyboard, event.payload, event.length, key); break;
        case VINIX_WINDOW_WHEEL: case VINIX_WINDOW_HORIZONTAL_WHEEL:
            nv_motion(event.x, event.y);
            nv_scroll(event.kind == VINIX_WINDOW_HORIZONTAL_WHEEL ? -event.value * 60 : 0,
                      event.kind == VINIX_WINDOW_WHEEL ? -event.value * 60 : 0, keyboard.mods);
            break;
        case VINIX_WINDOW_CONFIGURE:
            if (event.length) {
                if (vinix_window_get_framebuffer(window, &framebuffer) < 0) {
                    rhun_g_quit = 1; return;
                }
                // Rebind immediately so screenshots cannot retain the old mapping.
                target();
                nv_resize(framebuffer.width, framebuffer.height);
            }
            break;
        case VINIX_WINDOW_FOCUS:
            nv_clipboard_focus(&clipboard, event.value);
            if (!event.value) memset(&keyboard, 0, sizeof(keyboard));
            nv_focus(event.value); break;
        case VINIX_WINDOW_CLOSE:
            disconnected();
            return;
        }
        if (rhun_g_quit) break;
    }
    if (status < 0) { disconnected(); return; }
    watch_events();
}
void nv_flush(void) {
    if (connection_lost) { connection_lost = 0; disconnected(); return; }
    vinix_window_error error = {0};
    if (vinix_window_wait(window, 0, &error) < 0) { disconnected(); return; }
    nv_events();
    nv_clipboard_tick(&clipboard);
}
int nv_timeout(void) {
    if (rhun_g_dirty && vinix_window_frame_pending(window) == 0) return 0;
    return nv_clipboard_timeout(&clipboard);
}
void nv_draw(void) {
    if (connection_lost) return;
    if (vinix_window_frame_pending(window) != 0) return;
    target();
    rhun_g_dirty = 0;
    nv_render();
    vinix_window_error error = {0};
    if (vinix_window_present(window, &error) < 0) { connection_lost = 1; return; }
    watch_events();
}
void nv_title(const char *title) {
    char clean[129];
    size_t n = strnlen(title, 128);
    memcpy(clean, title, n);
    while (n && ((unsigned char)title[n] & 0xc0) == 0x80) --n;
    for (size_t i = 0; i < n; ++i) if ((unsigned char)clean[i] < 32 || clean[i] == 127) clean[i] = ' ';
    if (!n) { memcpy(clean, "rhun", 4); n = 4; }
    clean[n] = 0;
    memcpy(window_title, clean, n + 1);
    vinix_window_error error = {0};
    // A title can change inside app_render. Defer closing/recreating until
    // flush, so the quit path cannot free tabs during that render callback.
    if (vinix_window_set_title(window, clean, &error) < 0) { connection_lost = 1; return; }
    watch_events();
}
void nv_clip_set(const void *text, size_t length) {
    nv_clipboard_copy(&clipboard, text, length);
}
void nv_clip_get(void) { nv_clipboard_paste(&clipboard); }
void nv_open(const char *title) {
    vinix_window_error error = {0};
    if (vinix_window_api_version() != VINIX_WINDOW_API_VERSION) {
        fprintf(stderr, "Vinix window SDK version mismatch\n"); exit(1);
    }
    window = vinix_window_open(title, 1280, 800, &error);
    if (!window) { fail(&error); exit(1); }
    atexit(cleanup);
    nv_clipboard_init(&clipboard, NULL, nv_paste, nv_toast);
    if (vinix_window_get_framebuffer(window, &framebuffer) < 0 ||
        framebuffer.format != VINIX_WINDOW_FORMAT_XRGB8888) exit(1);
    for (unsigned i = 0; i < 13; ++i) rhun_g_plat[i] = (uintptr_t)rhun_nv_nop;
    rhun_g_plat[0] = (uintptr_t)rhun_nv_flush;
    rhun_g_plat[1] = (uintptr_t)rhun_nv_timeout;
    rhun_g_plat[3] = (uintptr_t)rhun_nv_draw;
    rhun_g_plat[5] = (uintptr_t)rhun_nv_clip_set;
    rhun_g_plat[6] = (uintptr_t)rhun_nv_clip_get;
    rhun_g_plat[11] = (uintptr_t)rhun_nv_title;
    rhun_g_csd = 0;
    snprintf(window_title, sizeof(window_title), "%s", title);
    descriptor = vinix_window_event_fd(window);
    nv_watch_add(descriptor, POLLIN, rhun_nv_events, NULL);
    target();
    nv_resize(framebuffer.width, framebuffer.height);
    nv_events();
}
