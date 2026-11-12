/* A stand-in input method for headless Sway (input-method-unstable-v2), which Sway relays to the
   focused client's text-input-v3. Prints "active" or "inactive" when the client enables or disables
   its text input. Each line on stdin is "preedit TEXT" (the composition, the cursor at its end) or
   "commit TEXT" (committed, ending the composition); "ok" follows once Sway has it. */
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wayland-client.h>

static const struct wl_interface *no_types[] = {NULL, NULL, NULL, NULL};
static const struct wl_message method_requests[] = {
    {"commit_string", "s", no_types}, {"set_preedit_string", "sii", no_types},
    {"delete_surrounding_text", "uu", no_types}, {"commit", "u", no_types},
};
static const struct wl_message method_events[] = {
    {"activate", "", no_types}, {"deactivate", "", no_types},
    {"surrounding_text", "suu", no_types}, {"text_change_cause", "u", no_types},
    {"content_type", "uu", no_types}, {"done", "", no_types}, {"unavailable", "", no_types},
};
static const struct wl_interface method_interface = {
    "zwp_input_method_v2", 1, 4, method_requests, 7, method_events,
};
static const struct wl_interface *manager_types[] = {&wl_seat_interface, &method_interface};
static const struct wl_message manager_requests[] = {
    {"get_input_method", "on", manager_types},
};
static const struct wl_interface manager_interface = {
    "zwp_input_method_manager_v2", 1, 1, manager_requests, 0, NULL,
};

static struct wl_seat *seat;
static struct wl_proxy *manager;
static uint32_t serial;          /* done events so far: each commit names it */
static int active, pending_active, announced = -1;

static void global(void *data, struct wl_registry *registry, uint32_t name,
                   const char *interface, uint32_t version) {
    if (!strcmp(interface, "wl_seat"))
        seat = wl_registry_bind(registry, name, &wl_seat_interface, 1);
    else if (!strcmp(interface, manager_interface.name))
        manager = wl_registry_bind(registry, name, &manager_interface, 1);
}
static void global_remove(void *data, struct wl_registry *registry, uint32_t name) {}
static const struct wl_registry_listener registry_listener = {
    .global = global, .global_remove = global_remove,
};

static void activate(void *data, struct wl_proxy *method) { pending_active = 1; }
static void deactivate(void *data, struct wl_proxy *method) { pending_active = 0; }
static void surrounding_text(void *data, struct wl_proxy *method, const char *text, uint32_t cursor,
                             uint32_t anchor) {}
static void text_change_cause(void *data, struct wl_proxy *method, uint32_t cause) {}
static void content_type(void *data, struct wl_proxy *method, uint32_t hint, uint32_t purpose) {}
static void done(void *data, struct wl_proxy *method) {
    serial++;
    active = pending_active;
    if (active != announced) {
        announced = active;
        printf(active ? "active\n" : "inactive\n");
        fflush(stdout);
    }
}
static void unavailable(void *data, struct wl_proxy *method) {
    fprintf(stderr, "another input method is running\n");
    exit(1);
}
static const struct {
    void (*activate)(void *, struct wl_proxy *);
    void (*deactivate)(void *, struct wl_proxy *);
    void (*surrounding_text)(void *, struct wl_proxy *, const char *, uint32_t, uint32_t);
    void (*text_change_cause)(void *, struct wl_proxy *, uint32_t);
    void (*content_type)(void *, struct wl_proxy *, uint32_t, uint32_t);
    void (*done)(void *, struct wl_proxy *);
    void (*unavailable)(void *, struct wl_proxy *);
} method_listener = {activate, deactivate, surrounding_text, text_change_cause, content_type, done,
                     unavailable};

int main(void) {
    struct wl_display *display = wl_display_connect(NULL);
    if (!display) {
        fprintf(stderr, "cannot connect to Wayland\n");
        return 1;
    }
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    wl_display_roundtrip(display);
    if (!seat || !manager) {
        fprintf(stderr, "no input method manager\n");
        return 1;
    }
    struct wl_proxy *method = wl_proxy_marshal_flags(manager, 0, &method_interface, 1, 0, seat, NULL);
    wl_proxy_add_listener(method, (void (**)(void))&method_listener, NULL);
    wl_display_roundtrip(display);
    printf("ready\n");
    fflush(stdout);
    char line[4096];
    struct pollfd fds[2] = {{wl_display_get_fd(display), POLLIN, 0}, {0, POLLIN, 0}};
    for (;;) {
        wl_display_flush(display);
        if (poll(fds, 2, -1) < 0)
            return 1;
        if (fds[0].revents & POLLIN) {
            if (wl_display_dispatch(display) < 0)
                return 1;
        }
        if (!(fds[1].revents & (POLLIN | POLLHUP)))
            continue;
        if (!fgets(line, sizeof line, stdin))
            break;
        line[strcspn(line, "\n")] = 0;
        if (!strncmp(line, "preedit ", 8)) {
            int length = (int)strlen(line + 8);
            wl_proxy_marshal_flags(method, 1, NULL, 1, 0, line + 8, length, length);
        } else if (!strncmp(line, "commit ", 7)) {
            wl_proxy_marshal_flags(method, 0, NULL, 1, 0, line + 7);
        } else {
            break;
        }
        wl_proxy_marshal_flags(method, 3, NULL, 1, 0, serial);
        wl_display_roundtrip(display);
        printf("ok\n");
        fflush(stdout);
    }
    wl_display_disconnect(display);
    return 0;
}
