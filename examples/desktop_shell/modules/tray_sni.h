#pragma once
#include <stddef.h>
#include <stdint.h>

#define TRAY_SNI_MAX_ITEMS 16
#define TRAY_SNI_MAX_MENU 24
#define TRAY_SNI_MAX_PIXMAP_BYTES (96 * 96 * 4)

typedef struct TraySniMenuItem {
    int32_t dbus_id;
    int8_t kind;          /* 0 = normal, 1 = separator */
    int8_t enabled;
    int8_t checked;
    int8_t has_toggle;
    char label[80];
} TraySniMenuItem;

typedef struct TraySniItem {
    uintptr_t id;
    int real;
    char title[96];
    char status[96];
    char service[128];
    char path[128];
    char menu_path[128];
    char icon_name[128];
    int32_t icon_pixmap_width;
    int32_t icon_pixmap_height;
    int32_t icon_pixmap_serial;
    int32_t menu_count;
    int32_t menu_revision;
    TraySniMenuItem menu[TRAY_SNI_MAX_MENU];
} TraySniItem;

typedef struct TraySniSnapshot {
    int watcher_ready;
    size_t item_count;
    TraySniItem items[TRAY_SNI_MAX_ITEMS];
} TraySniSnapshot;

void tray_sni_start(void);
int tray_sni_poll(TraySniSnapshot *out);
void tray_sni_activate(uintptr_t id);
void tray_sni_context_menu(uintptr_t id);

/* Copy the latest icon pixmap (RGBA8 byte order) into `out_buf`.
 * Returns 1 on success and writes width/height/serial. Returns 0 if the
 * item has no pixmap, the buffer is too small, or the id is unknown.
 * `serial` increments whenever the pixmap changes — callers should
 * compare it against their cached value to decide whether to re-upload. */
int tray_sni_get_pixmap(uintptr_t id, uint8_t *out_buf, size_t buf_len,
                        int32_t *out_width, int32_t *out_height,
                        int32_t *out_serial);

/* Send a dbusmenu "clicked" event to the given menu item. */
void tray_sni_menu_event(uintptr_t id, int32_t dbusmenu_id);
