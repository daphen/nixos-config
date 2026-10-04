#define _GNU_SOURCE
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>
#include "virtual-keyboard-client.h"

static struct wl_seat *seat;
static struct zwp_virtual_keyboard_manager_v1 *manager;

static void global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
    if (strcmp(interface, "wl_seat") == 0)
        seat = wl_registry_bind(registry, name, &wl_seat_interface, 1);
    if (strcmp(interface, "zwp_virtual_keyboard_manager_v1") == 0)
        manager = wl_registry_bind(registry, name, &zwp_virtual_keyboard_manager_v1_interface, 1);
}

static void removed(void *data, struct wl_registry *registry, uint32_t name) {}

static double now(void) {
    struct timespec time;
    clock_gettime(CLOCK_MONOTONIC, &time);
    return time.tv_sec + time.tv_nsec / 1e9;
}

int main(int argc, char **argv) {
    assert(argc >= 2);
    struct wl_display *display = wl_display_connect(NULL);
    assert(display);
    struct wl_registry *registry = wl_display_get_registry(display);
    const struct wl_registry_listener listener = {global, removed};
    wl_registry_add_listener(registry, &listener, NULL);
    assert(wl_display_roundtrip(display) >= 0);
    assert(seat && manager);
    struct zwp_virtual_keyboard_v1 *keyboard = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(manager, seat);
    struct xkb_context *context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    struct xkb_rule_names names = {.layout = "us"};
    struct xkb_keymap *keymap = xkb_keymap_new_from_names(context, &names, XKB_KEYMAP_COMPILE_NO_FLAGS);
    assert(keymap);
    char *text = xkb_keymap_get_as_string(keymap, XKB_KEYMAP_FORMAT_TEXT_V1);
    size_t length = strlen(text) + 1;
    int fd = memfd_create("canvas-focus-keymap", MFD_CLOEXEC);
    assert(fd >= 0 && write(fd, text, length) == length);
    zwp_virtual_keyboard_v1_keymap(keyboard, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, length);
    assert(wl_display_roundtrip(display) >= 0);
    close(fd);
    free(text);
    if (strcmp(argv[1], "--keys") == 0 || strcmp(argv[1], "--hold") == 0) {
        int hold = strcmp(argv[1], "--hold") == 0 ? atoi(argv[2]) : 0;
        assert(hold >= 0 && hold <= 10000);
        const char *names[] = {"comma", "esc", "left", "right", "up", "down", "home", "h", "j", "k", "l", "space", "x", "tab"};
        const int codes[] = {51, 1, 105, 106, 103, 108, 102, 35, 36, 37, 38, 57, 45, 15};
        const char *modifiers[] = {"ctrl", "shift", "super", "alt"};
        const char *modnames[] = {XKB_MOD_NAME_CTRL, XKB_MOD_NAME_SHIFT, XKB_MOD_NAME_LOGO, XKB_MOD_NAME_ALT};
        const int modcodes[] = {29, 42, 125, 56};
        for (int n = hold ? 3 : 2; n < argc; n++) {
            char *chord = strdup(argv[n]);
            uint32_t mask = 0;
            int code = 0, held[4] = {0};
            for (char *token = strtok(chord, "+"); token; token = strtok(NULL, "+")) {
                for (int k = 0; k < 14; k++)
                    if (strcmp(names[k], token) == 0) code = codes[k];
                for (int k = 0; k < 4; k++)
                    if (strcmp(modifiers[k], token) == 0) {
                        held[k] = 1;
                        mask |= 1 << xkb_keymap_mod_get_index(keymap, modnames[k]);
                        zwp_virtual_keyboard_v1_key(keyboard, (uint32_t)(now() * 1000), modcodes[k], 1);
                    }
            }
            free(chord);
            assert(code || mask);
            zwp_virtual_keyboard_v1_modifiers(keyboard, mask, 0, 0, 0);
            if (code)
                zwp_virtual_keyboard_v1_key(keyboard, (uint32_t)(now() * 1000), code, 1);
            assert(wl_display_roundtrip(display) >= 0);
            usleep(2000);
            if (code)
                zwp_virtual_keyboard_v1_key(keyboard, (uint32_t)(now() * 1000), code, 0);
            if (hold) {
                for (int k = 0; k < 4; k++)
                    if (k != 2 && held[k]) {
                        zwp_virtual_keyboard_v1_key(keyboard, (uint32_t)(now() * 1000), modcodes[k], 0);
                        held[k] = 0;
                        mask &= ~(1 << xkb_keymap_mod_get_index(keymap, modnames[k]));
                    }
                zwp_virtual_keyboard_v1_modifiers(keyboard, mask, 0, 0, 0);
            }
            assert(wl_display_roundtrip(display) >= 0);
            if (hold)
                usleep(hold * 1000);
            for (int k = 3; k >= 0; k--)
                if (held[k])
                    zwp_virtual_keyboard_v1_key(keyboard, (uint32_t)(now() * 1000), modcodes[k], 0);
            zwp_virtual_keyboard_v1_modifiers(keyboard, 0, 0, 0, 0);
            assert(wl_display_roundtrip(display) >= 0);
            usleep(150000);
        }
        goto done;
    }
    int interval = atoi(argv[1]);
    assert(interval > 0);
    zwp_virtual_keyboard_v1_key(keyboard, (uint32_t)(now() * 1000), 125, WL_KEYBOARD_KEY_STATE_PRESSED);
    zwp_virtual_keyboard_v1_modifiers(keyboard, 1 << xkb_keymap_mod_get_index(keymap, XKB_MOD_NAME_LOGO), 0, 0, 0);
    assert(wl_display_roundtrip(display) >= 0);
    usleep(200000);
    const int codes[] = {38, 36, 35, 37};
    const char *directions = "ljhk";
    for (int n = 0; n < 4; n++) {
        double sent = now();
        printf("KEY %.9f %c\n", sent, directions[n]);
        fflush(stdout);
        zwp_virtual_keyboard_v1_key(keyboard, (uint32_t)(sent * 1000), codes[n], WL_KEYBOARD_KEY_STATE_PRESSED);
        assert(wl_display_roundtrip(display) >= 0);
        usleep(2000);
        zwp_virtual_keyboard_v1_key(keyboard, (uint32_t)(now() * 1000), codes[n], WL_KEYBOARD_KEY_STATE_RELEASED);
        assert(wl_display_roundtrip(display) >= 0);
        usleep(interval * 1000);
    }
    usleep(1000000);
    zwp_virtual_keyboard_v1_key(keyboard, (uint32_t)(now() * 1000), 125, WL_KEYBOARD_KEY_STATE_RELEASED);
    zwp_virtual_keyboard_v1_modifiers(keyboard, 0, 0, 0, 0);
    assert(wl_display_roundtrip(display) >= 0);
done:
    zwp_virtual_keyboard_v1_destroy(keyboard);
    wl_display_flush(display);
    wl_display_disconnect(display);
    xkb_keymap_unref(keymap);
    xkb_context_unref(context);
}
