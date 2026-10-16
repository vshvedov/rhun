// Exercise frame ownership, resize remapping and fd interests without a VM.
#include <vinix_window.h>
#include "../tools/vinix/clipboard.h"
#include <assert.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

uint64_t rhun_g_plat[13];
int rhun_g_dirty, rhun_g_quit, rhun_g_csd, rhun_g_key_base;
void rhun_nv_nop(void) {} void rhun_nv_draw(void) {} void rhun_nv_timeout(void) {}
void rhun_nv_flush(void) {} void rhun_nv_title(void) {} void rhun_nv_events(void) {}
void rhun_nv_clip_set(void) {} void rhun_nv_clip_get(void) {}
static uint32_t first[64 * 64], second[80 * 64], *target_pixels;
static vinix_framebuffer fb = { first, 64, 64, 64 * 4, VINIX_WINDOW_FORMAT_XRGB8888 };
static vinix_window_event queue[8];
static unsigned queued, taken, draws, presents, interests;
static int pending, output, refuse_close, eof, send_error;
static uint32_t last_key, last_text, last_mods, last_base;
uint32_t vinix_window_api_version(void) { return VINIX_WINDOW_API_VERSION; }
vinix_window *vinix_window_open(const char *title, int32_t w, int32_t h, vinix_window_error *e) {
    (void)title; (void)w; (void)h; (void)e; pending = 0; return (void *)&fb;
}
void vinix_window_close(vinix_window *w) { (void)w; }
int32_t vinix_window_event_fd(vinix_window *w) { (void)w; return 42; }
int32_t vinix_window_get_framebuffer(vinix_window *w, vinix_framebuffer *out) { (void)w; *out = fb; return 0; }
int32_t vinix_window_frame_pending(vinix_window *w) { (void)w; return pending; }
int32_t vinix_window_wants_write(vinix_window *w) { (void)w; return output; }
int32_t vinix_window_present(vinix_window *w, vinix_window_error *e) {
    if (send_error) { send_error = 0; return -1; }
    (void)w; (void)e; assert(!pending); pending = 1; ++presents; return 0;
}
int32_t vinix_window_set_title(vinix_window *w, const char *s, vinix_window_error *e) {
    (void)w; (void)e; assert(strlen(s) <= 128); output = 1; return 0;
}
int32_t vinix_window_wait(vinix_window *w, int32_t timeout, vinix_window_error *e) {
    (void)w; (void)e; assert(timeout == 0); output = 0; return 0;
}
int32_t vinix_window_next_event(vinix_window *w, vinix_window_event *out, vinix_window_error *e) {
    (void)w; (void)e;
    if (eof) { eof = 0; return -1; }
    if (taken == queued) return 0;
    *out = queue[taken++];
    if (out->kind == VINIX_WINDOW_FRAME_DONE) pending = 0;
    if (out->kind == VINIX_WINDOW_CONFIGURE && out->length) {
        fb.pixels = second; fb.width = 80; fb.stride = 80 * 4;
    }
    return 1;
}
void nv_watch_add(int fd, int events, void (*handler)(void), void *context) {
    assert(fd == 42 && events == POLLIN && handler == rhun_nv_events && context == NULL);
}
void nv_watch_set_events(int fd, int events) { assert(fd == 42); interests = events; }
void nv_watch_remove(int fd) { assert(fd == 42); }
void nv_target(uint32_t *p, int w, int h, int stride) {
    assert(w == (p == first ? 64 : 80) && h == 64 && stride == w); target_pixels = p;
}
void nv_resize(int w, int h) { assert(w == 64 || w == 80); assert(h == 64); rhun_g_dirty = 1; }
void nv_render(void) { assert(!pending); target_pixels[0] = ++draws; }
void nv_motion(int x, int y) { (void)x; (void)y; }
void nv_button(int b, int down, int mods) { (void)b; (void)down; (void)mods; }
void nv_scroll(int x, int y, int mods) { (void)x; (void)y; (void)mods; }
void nv_focus(int focused) { (void)focused; }
void nv_key(int symbol, int text, int mods) {
    last_key = symbol; last_text = text; last_mods = mods; last_base = rhun_g_key_base;
}
void nv_paste(const void *p, size_t n) { assert(n == 3 && memcmp(p, "a\0b", 3) == 0); }
void nv_toast(const char *message) { (void)message; }
void nv_clipboard_init(struct nv_clipboard *c, const char *path, void (*paste)(const void *, size_t), void (*error)(const char *)) {
    (void)path; memset(c, 0, sizeof(*c)); c->paste = paste; c->error = error;
}
void nv_clipboard_close(struct nv_clipboard *c) { (void)c; }
void nv_clipboard_focus(struct nv_clipboard *c, int focused) { c->focused = focused; if (!focused) c->state = 0; }
void nv_clipboard_cancel_paste(struct nv_clipboard *c) { c->state = 0; }
void nv_clipboard_tick(struct nv_clipboard *c) { (void)c; }
int nv_clipboard_timeout(const struct nv_clipboard *c) { return c->state ? 20 : -1; }
void nv_clipboard_copy(struct nv_clipboard *c, const void *p, size_t length) { (void)c; (void)p; (void)length; }
void nv_clipboard_paste(struct nv_clipboard *c) { c->state = 1; }
void nv_close_request(void) { rhun_g_quit = !refuse_close; }
extern void nv_open(const char *), nv_draw(void), nv_events(void), nv_flush(void), nv_title(const char *);
extern void nv_clip_set(const void *, size_t), nv_clip_get(void);
extern int nv_timeout(void);
int main(void) {
    nv_open("rhun"); assert(!rhun_g_csd && nv_timeout() == 0);
    nv_draw(); assert(draws == 1 && presents == 1 && first[0] == 1);
    rhun_g_dirty = 1; nv_draw(); assert(draws == 1 && nv_timeout() == -1);
    queue[queued++] = (vinix_window_event){.kind = VINIX_WINDOW_CONFIGURE, .length = 1};
    nv_events(); assert(target_pixels == second && pending && rhun_g_dirty);
    nv_draw(); assert(draws == 1 && second[0] == 0);
    queue[queued++] = (vinix_window_event){.kind = VINIX_WINDOW_FRAME_DONE};
    nv_events(); assert(nv_timeout() == 0); nv_draw();
    assert(draws == 2 && second[0] == 2 && first[0] == 1);
    nv_title("project"); assert(interests & POLLOUT);
    nv_flush(); assert(interests == POLLIN);
    const char keys[] = "\033[115;5:1u";
    queue[queued] = (vinix_window_event){.kind = VINIX_WINDOW_KEYS, .length = sizeof(keys) - 1};
    memcpy(queue[queued++].payload, keys, sizeof(keys) - 1);
    nv_events(); assert(last_key == 's' && !last_text && last_mods == 4 && last_base == 's');
    assert(rhun_g_key_base == 0);
    nv_clip_get(); assert(nv_timeout() == 20);
    queue[queued++] = (vinix_window_event){.kind = VINIX_WINDOW_FOCUS, .value = 0}; nv_events();
    assert(nv_timeout() == -1);
    refuse_close = 1;
    queue[queued++] = (vinix_window_event){.kind = VINIX_WINDOW_CLOSE};
    nv_events(); assert(!rhun_g_quit && !pending && rhun_g_dirty);
    nv_draw(); assert(draws == 3);
    eof = 1;
    nv_events(); assert(!rhun_g_quit && !pending && rhun_g_dirty);
    nv_draw(); assert(draws == 4);
    queue[queued++] = (vinix_window_event){.kind = VINIX_WINDOW_FRAME_DONE}; nv_events();
    send_error = 1; nv_draw(); assert(draws == 5 && !rhun_g_quit);
    nv_flush(); assert(!rhun_g_quit && !pending && rhun_g_dirty);
    refuse_close = 0;
    queue[queued++] = (vinix_window_event){.kind = VINIX_WINDOW_CLOSE};
    nv_events(); assert(rhun_g_quit);
    puts("Vinix window backend passed");
}
