#include "tray_sni.h"
#include <gio/gio.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Set RAMIEL_TRAY_DEBUG=1 to print dbusmenu/SNI activity to stderr. */
static int debug_enabled(void) {
    static int cached = -1;
    if (cached < 0) {
        const char *env = getenv("RAMIEL_TRAY_DEBUG");
        cached = (env && env[0] && env[0] != '0') ? 1 : 0;
    }
    return cached;
}
#define TRAY_LOG(fmt, ...) do { if (debug_enabled()) fprintf(stderr, "[tray] " fmt "\n", ##__VA_ARGS__); } while (0)

static const char *WATCHER_PATH = "/StatusNotifierWatcher";
static const char *WATCHER_IFACE = "org.kde.StatusNotifierWatcher";
static const char *ITEM_IFACE = "org.kde.StatusNotifierItem";
static const char *PROPS_IFACE = "org.freedesktop.DBus.Properties";
static const char *DBUSMENU_IFACE = "com.canonical.dbusmenu";

static const char introspection_xml[] =
    "<node>"
    "  <interface name='org.kde.StatusNotifierWatcher'>"
    "    <method name='RegisterStatusNotifierItem'><arg type='s' name='service' direction='in'/></method>"
    "    <method name='RegisterStatusNotifierHost'><arg type='s' name='service' direction='in'/></method>"
    "    <property name='RegisteredStatusNotifierItems' type='as' access='read'/>"
    "    <property name='IsStatusNotifierHostRegistered' type='b' access='read'/>"
    "    <property name='ProtocolVersion' type='i' access='read'/>"
    "    <signal name='StatusNotifierItemRegistered'><arg type='s' name='service'/></signal>"
    "    <signal name='StatusNotifierItemUnregistered'><arg type='s' name='service'/></signal>"
    "    <signal name='StatusNotifierHostRegistered'/>"
    "  </interface>"
    "</node>";

typedef struct PixmapStore {
    int32_t width;
    int32_t height;
    int32_t serial;
    uint8_t *bytes; /* RGBA8 byte order, malloc'd, NULL if empty */
} PixmapStore;

static GMutex lock;
static int started = 0;
static int dirty = 0;
static int watcher_ready = 0;
static uintptr_t next_id = 1000;
static GDBusConnection *connection = NULL;
static GDBusNodeInfo *node_info = NULL;
static GMainLoop *loop = NULL;
static TraySniSnapshot snapshot = {0};
static PixmapStore pixmaps[TRAY_SNI_MAX_ITEMS] = {0};

static void copy_str(char *dst, size_t dst_len, const char *src) {
    if (!dst || dst_len == 0) return;
    if (!src) src = "";
    g_strlcpy(dst, src, dst_len);
}

static int find_index_locked(const char *service, const char *path) {
    for (size_t i = 0; i < snapshot.item_count; ++i) {
        TraySniItem *item = &snapshot.items[i];
        if (item->real && strcmp(item->service, service) == 0 && strcmp(item->path, path) == 0)
            return (int)i;
    }
    return -1;
}

static int find_index_by_id_locked(uintptr_t id) {
    for (size_t i = 0; i < snapshot.item_count; ++i) {
        if (snapshot.items[i].real && snapshot.items[i].id == id) return (int)i;
    }
    return -1;
}

static void read_string(GVariant *dict, const char *key, char *dst, size_t dst_len) {
    const char *value = NULL;
    if (g_variant_lookup(dict, key, "&s", &value) && value) copy_str(dst, dst_len, value);
}

/* Extract the human-readable title from a ToolTip variant.
 *   ToolTip signature: (sa(iiay)ss) — icon name, pixmaps, title, description. */
static void read_tooltip_title(GVariant *dict, char *dst, size_t dst_len) {
    GVariant *tip = g_variant_lookup_value(dict, "ToolTip", G_VARIANT_TYPE("(sa(iiay)ss)"));
    if (!tip) return;
    const char *title = NULL;
    g_variant_get_child(tip, 2, "&s", &title);
    if (title && title[0]) copy_str(dst, dst_len, title);
    g_variant_unref(tip);
}

/* Select the best pixmap (largest with side <= 96, falling back to largest)
 * from an a(iiay) variant and convert ARGB32 network byte order to RGBA8. */
static void update_pixmap(int index, GVariant *pixmaps_variant) {
    if (!pixmaps_variant) return;

    GVariantIter iter;
    g_variant_iter_init(&iter, pixmaps_variant);
    int best_w = 0, best_h = 0;
    GVariant *best_bytes = NULL;
    int best_score = -1;

    int32_t w = 0, h = 0;
    GVariant *bytes = NULL;
    while (g_variant_iter_loop(&iter, "(ii@ay)", &w, &h, &bytes)) {
        if (w <= 0 || h <= 0 || !bytes) continue;
        if (w * h * 4 != (int)g_variant_get_size(bytes)) continue;
        int side = (w > h) ? w : h;
        int score;
        if (side <= 96) {
            score = side; /* prefer biggest under cap */
        } else {
            score = -side; /* prefer smallest over cap */
        }
        if (score > best_score) {
            best_score = score;
            best_w = w;
            best_h = h;
            if (best_bytes) g_variant_unref(best_bytes);
            best_bytes = g_variant_ref(bytes);
        }
    }

    if (!best_bytes) return;

    gsize size = 0;
    const uint8_t *src = (const uint8_t *)g_variant_get_fixed_array(best_bytes, &size, 1);
    if (!src || size != (gsize)(best_w * best_h * 4)) {
        g_variant_unref(best_bytes);
        return;
    }

    uint8_t *dst = (uint8_t *)g_malloc((size_t)size);
    for (gsize i = 0; i < size; i += 4) {
        /* ARGB32 network (big-endian) → bytes are [A][R][G][B] in memory.
         * Convert to RGBA8 byte order: [R][G][B][A]. */
        dst[i + 0] = src[i + 1];
        dst[i + 1] = src[i + 2];
        dst[i + 2] = src[i + 3];
        dst[i + 3] = src[i + 0];
    }

    PixmapStore *ps = &pixmaps[index];
    if (ps->bytes) g_free(ps->bytes);
    ps->bytes = dst;
    ps->width = best_w;
    ps->height = best_h;
    ps->serial += 1;

    snapshot.items[index].icon_pixmap_width = best_w;
    snapshot.items[index].icon_pixmap_height = best_h;
    snapshot.items[index].icon_pixmap_serial = ps->serial;

    g_variant_unref(best_bytes);
}

static void clear_menu_locked(int index) {
    TraySniItem *item = &snapshot.items[index];
    item->menu_count = 0;
    memset(item->menu, 0, sizeof(item->menu));
}

/* `tuple` must be a GVariant of type "(ia{sv}av)" — dbusmenu's per-item
 * layout tuple. Appends one menu entry to the item if visible. */
static void parse_menu_tuple(GVariant *tuple, TraySniItem *item) {
    if (item->menu_count >= TRAY_SNI_MAX_MENU) return;

    int32_t id = 0;
    GVariant *props = NULL;
    GVariant *children = NULL;
    g_variant_get(tuple, "(i@a{sv}@av)", &id, &props, &children);

    const char *label = NULL;
    const char *type = NULL;
    const char *toggle_type = NULL;
    gboolean enabled = TRUE;
    gboolean visible = TRUE;
    int32_t toggle_state = 0;
    g_variant_lookup(props, "label", "&s", &label);
    g_variant_lookup(props, "type", "&s", &type);
    g_variant_lookup(props, "enabled", "b", &enabled);
    g_variant_lookup(props, "visible", "b", &visible);
    g_variant_lookup(props, "toggle-type", "&s", &toggle_type);
    g_variant_lookup(props, "toggle-state", "i", &toggle_state);

    TRAY_LOG("  item id=%d label='%s' type='%s' enabled=%d visible=%d toggle='%s' state=%d",
             id, label ? label : "", type ? type : "", enabled, visible,
             toggle_type ? toggle_type : "", toggle_state);

    if (visible) {
        TraySniMenuItem *out = &item->menu[item->menu_count++];
        memset(out, 0, sizeof(*out));
        out->dbus_id = id;
        out->enabled = enabled ? 1 : 0;

        if (type && strcmp(type, "separator") == 0) {
            out->kind = 1;
        } else if (label) {
            /* dbusmenu accelerator: "_" precedes the accelerator char; "__"
             * is a literal underscore. Strip the markers for display. */
            size_t out_pos = 0;
            for (size_t i = 0; label[i] != 0 && out_pos < sizeof(out->label) - 1; ++i) {
                if (label[i] == '_') {
                    if (label[i + 1] == '_') {
                        out->label[out_pos++] = '_';
                        i += 1;
                    }
                    continue;
                }
                out->label[out_pos++] = label[i];
            }
            out->label[out_pos] = 0;
        }

        if (toggle_type && toggle_type[0]) {
            out->has_toggle = 1;
            out->checked = (toggle_state == 1) ? 1 : 0;
        }
    }

    g_variant_unref(props);
    if (children) g_variant_unref(children);
}

/* Read top-level dbusmenu items for the given item. Caller must hold the
 * lock; this function temporarily releases it for the synchronous DBus call
 * and re-acquires before returning. */
static void refresh_menu_locked(int index) {
    if (!connection) return;

    char service[128];
    char item_path[128];
    char menu_path[128];
    copy_str(service, sizeof(service), snapshot.items[index].service);
    copy_str(item_path, sizeof(item_path), snapshot.items[index].path);
    copy_str(menu_path, sizeof(menu_path), snapshot.items[index].menu_path);
    if (!menu_path[0]) {
        clear_menu_locked(index);
        return;
    }

    g_mutex_unlock(&lock);

    /* Many apps (Chrome/Electron/Qt) build their menu lazily and only
     * populate it after `AboutToShow` (or "opened" Event) is received.
     * Best-effort: call both before GetLayout and ignore failures. */
    GError *atsErr = NULL;
    GVariant *ats = g_dbus_connection_call_sync(
        connection, service, menu_path, DBUSMENU_IFACE, "AboutToShow",
        g_variant_new("(i)", 0), G_VARIANT_TYPE("(b)"),
        G_DBUS_CALL_FLAGS_NONE, 1500, NULL, &atsErr);
    if (atsErr) {
        TRAY_LOG("AboutToShow(%s%s) failed: %s", service, menu_path, atsErr->message);
        g_error_free(atsErr);
    } else {
        gboolean need_update = FALSE;
        if (ats) g_variant_get(ats, "(b)", &need_update);
        TRAY_LOG("AboutToShow(%s%s) ok need_update=%d", service, menu_path, need_update);
    }
    if (ats) g_variant_unref(ats);

    GError *evErr = NULL;
    GVariant *evRes = g_dbus_connection_call_sync(
        connection, service, menu_path, DBUSMENU_IFACE, "Event",
        g_variant_new("(isvu)", 0, "opened", g_variant_new_string(""),
                      (guint32)(g_get_real_time() / 1000)),
        NULL, G_DBUS_CALL_FLAGS_NO_AUTO_START, 1500, NULL, &evErr);
    if (evRes) g_variant_unref(evRes);
    if (evErr) {
        TRAY_LOG("Event(opened) failed: %s", evErr->message);
        g_error_free(evErr);
    }

    const char *no_props[] = { NULL };
    GVariant *params = g_variant_new("(ii^as)", 0, -1, no_props);
    GError *error = NULL;
    GVariant *result = g_dbus_connection_call_sync(
        connection, service, menu_path, DBUSMENU_IFACE, "GetLayout", params,
        G_VARIANT_TYPE("(u(ia{sv}av))"),
        G_DBUS_CALL_FLAGS_NONE, 1500, NULL, &error);
    g_mutex_lock(&lock);

    if (error) {
        TRAY_LOG("GetLayout(%s%s) failed: %s", service, menu_path, error->message);
        g_error_free(error);
        return;
    }
    if (!result) {
        TRAY_LOG("GetLayout(%s%s) returned NULL", service, menu_path);
        return;
    }

    uint32_t revision = 0;
    GVariant *root = NULL;
    g_variant_get(result, "(u@(ia{sv}av))", &revision, &root);

    int32_t root_id = 0;
    GVariant *root_props = NULL;
    GVariant *children = NULL;
    g_variant_get(root, "(i@a{sv}@av)", &root_id, &root_props, &children);

    gsize n_children = children ? g_variant_n_children(children) : 0;
    TRAY_LOG("GetLayout(%s%s) ok rev=%u root_id=%d children=%zu",
             service, menu_path, revision, root_id, n_children);

    int idx = find_index_locked(service, item_path);
    if (idx >= 0 && children) {
        TraySniItem *item = &snapshot.items[idx];
        item->menu_revision = (int32_t)revision;
        item->menu_count = 0;
        memset(item->menu, 0, sizeof(item->menu));

        GVariantIter iter;
        g_variant_iter_init(&iter, children);
        GVariant *element = NULL;
        while ((element = g_variant_iter_next_value(&iter)) != NULL) {
            GVariant *tuple = g_variant_get_variant(element);
            if (tuple) {
                parse_menu_tuple(tuple, item);
                g_variant_unref(tuple);
            }
            g_variant_unref(element);
        }
    }

    if (root_props) g_variant_unref(root_props);
    if (children) g_variant_unref(children);
    if (root) g_variant_unref(root);
    g_variant_unref(result);
}

static void refresh_item(const char *service, const char *path) {
    if (!connection) return;
    GError *error = NULL;
    GVariant *result = g_dbus_connection_call_sync(
        connection,
        service,
        path,
        PROPS_IFACE,
        "GetAll",
        g_variant_new("(s)", ITEM_IFACE),
        NULL,
        G_DBUS_CALL_FLAGS_NONE,
        1000,
        NULL,
        &error);
    if (error) {
        g_error_free(error);
        return;
    }
    if (!result) return;
    GVariant *dict = g_variant_get_child_value(result, 0);
    if (!dict) {
        g_variant_unref(result);
        return;
    }

    g_mutex_lock(&lock);
    int idx = find_index_locked(service, path);
    if (idx >= 0) {
        TraySniItem *item = &snapshot.items[idx];
        char tooltip_title[96] = {0};
        read_tooltip_title(dict, tooltip_title, sizeof(tooltip_title));
        read_string(dict, "Title", item->title, sizeof(item->title));
        if (item->title[0] == 0 && tooltip_title[0])
            copy_str(item->title, sizeof(item->title), tooltip_title);
        if (item->title[0] == 0) read_string(dict, "Id", item->title, sizeof(item->title));
        read_string(dict, "Status", item->status, sizeof(item->status));
        read_string(dict, "IconName", item->icon_name, sizeof(item->icon_name));
        read_string(dict, "Menu", item->menu_path, sizeof(item->menu_path));

        GVariant *pixmaps_v = g_variant_lookup_value(dict, "IconPixmap", G_VARIANT_TYPE("a(iiay)"));
        if (pixmaps_v) {
            update_pixmap(idx, pixmaps_v);
            g_variant_unref(pixmaps_v);
        }

        TRAY_LOG("refresh_item %s%s title='%s' menu_path='%s'",
                 service, path, item->title, item->menu_path);

        if (item->menu_path[0]) refresh_menu_locked(idx);

        dirty = 1;
    }
    g_mutex_unlock(&lock);

    g_variant_unref(dict);
    g_variant_unref(result);
}

static gboolean refresh_timer(gpointer user_data) {
    (void)user_data;
    char services[TRAY_SNI_MAX_ITEMS][128];
    char paths[TRAY_SNI_MAX_ITEMS][128];
    size_t count = 0;

    g_mutex_lock(&lock);
    for (size_t i = 0; i < snapshot.item_count && count < TRAY_SNI_MAX_ITEMS; ++i) {
        if (!snapshot.items[i].real) continue;
        copy_str(services[count], sizeof(services[count]), snapshot.items[i].service);
        copy_str(paths[count], sizeof(paths[count]), snapshot.items[i].path);
        count++;
    }
    g_mutex_unlock(&lock);

    for (size_t i = 0; i < count; ++i) refresh_item(services[i], paths[i]);
    return G_SOURCE_CONTINUE;
}

static void register_item(GDBusConnection *conn, const char *sender, const char *arg) {
    const char *service = (arg && arg[0] == '/') ? sender : arg;
    const char *path = (arg && arg[0] == '/') ? arg : "/StatusNotifierItem";
    if (!service || !path) return;

    uintptr_t id = 0;
    g_mutex_lock(&lock);
    int idx = find_index_locked(service, path);
    if (idx < 0 && snapshot.item_count < TRAY_SNI_MAX_ITEMS) {
        idx = (int)snapshot.item_count;
        TraySniItem *item = &snapshot.items[snapshot.item_count++];
        memset(item, 0, sizeof(*item));
        item->id = next_id++;
        item->real = 1;
        copy_str(item->service, sizeof(item->service), service);
        copy_str(item->path, sizeof(item->path), path);
        copy_str(item->title, sizeof(item->title), service);
        copy_str(item->status, sizeof(item->status), "Registered");
    }
    if (idx >= 0) id = snapshot.items[idx].id;
    dirty = 1;
    g_mutex_unlock(&lock);

    refresh_item(service, path);
    g_dbus_connection_emit_signal(conn, NULL, WATCHER_PATH, WATCHER_IFACE, "StatusNotifierItemRegistered", g_variant_new("(s)", service), NULL);
    (void)id;
}

static void handle_method_call(GDBusConnection *conn, const gchar *sender, const gchar *object_path, const gchar *interface_name, const gchar *method_name, GVariant *parameters, GDBusMethodInvocation *invocation, gpointer user_data) {
    (void)object_path;
    (void)interface_name;
    (void)user_data;
    if (g_strcmp0(method_name, "RegisterStatusNotifierItem") == 0) {
        const char *service = NULL;
        g_variant_get(parameters, "(&s)", &service);
        register_item(conn, sender, service);
        g_dbus_method_invocation_return_value(invocation, g_variant_new("()"));
        return;
    }
    if (g_strcmp0(method_name, "RegisterStatusNotifierHost") == 0) {
        g_dbus_method_invocation_return_value(invocation, g_variant_new("()"));
        return;
    }
    g_dbus_method_invocation_return_value(invocation, g_variant_new("()"));
}

static GVariant *handle_get_property(GDBusConnection *conn, const gchar *sender, const gchar *object_path, const gchar *interface_name, const gchar *property_name, GError **error, gpointer user_data) {
    (void)conn; (void)sender; (void)object_path; (void)interface_name; (void)error; (void)user_data;
    if (g_strcmp0(property_name, "RegisteredStatusNotifierItems") == 0) {
        GVariantBuilder builder;
        g_variant_builder_init(&builder, G_VARIANT_TYPE("as"));
        g_mutex_lock(&lock);
        for (size_t i = 0; i < snapshot.item_count; ++i) {
            TraySniItem *item = &snapshot.items[i];
            if (!item->real) continue;
            char name[260];
            g_snprintf(name, sizeof(name), "%s%s", item->service, item->path);
            g_variant_builder_add(&builder, "s", name);
        }
        g_mutex_unlock(&lock);
        return g_variant_builder_end(&builder);
    }
    if (g_strcmp0(property_name, "IsStatusNotifierHostRegistered") == 0) return g_variant_new_boolean(TRUE);
    if (g_strcmp0(property_name, "ProtocolVersion") == 0) return g_variant_new_int32(0);
    return NULL;
}

static const GDBusInterfaceVTable vtable = { handle_method_call, handle_get_property, NULL };

static void on_bus_acquired(GDBusConnection *conn, const gchar *name, gpointer user_data) {
    (void)name; (void)user_data;
    connection = conn;
    GError *error = NULL;
    guint id = g_dbus_connection_register_object(conn, WATCHER_PATH, node_info->interfaces[0], &vtable, NULL, NULL, &error);
    if (error) {
        g_error_free(error);
        return;
    }
    (void)id;
    g_timeout_add_seconds(2, refresh_timer, NULL);
    g_mutex_lock(&lock);
    watcher_ready = 1;
    snapshot.watcher_ready = 1;
    dirty = 1;
    g_mutex_unlock(&lock);
}

static void on_name_acquired(GDBusConnection *conn, const gchar *name, gpointer user_data) {
    (void)name; (void)user_data;
    g_dbus_connection_emit_signal(conn, NULL, WATCHER_PATH, WATCHER_IFACE, "StatusNotifierHostRegistered", g_variant_new("()"), NULL);
}

static void on_name_lost(GDBusConnection *conn, const gchar *name, gpointer user_data) {
    (void)conn; (void)name; (void)user_data;
    g_mutex_lock(&lock);
    watcher_ready = 0;
    snapshot.watcher_ready = 0;
    dirty = 1;
    g_mutex_unlock(&lock);
}

static gpointer tray_thread(gpointer user_data) {
    (void)user_data;
    GError *error = NULL;
    node_info = g_dbus_node_info_new_for_xml(introspection_xml, &error);
    if (error) {
        g_error_free(error);
        return NULL;
    }
    loop = g_main_loop_new(NULL, FALSE);
    g_bus_own_name(G_BUS_TYPE_SESSION, "org.kde.StatusNotifierWatcher", G_BUS_NAME_OWNER_FLAGS_NONE, on_bus_acquired, on_name_acquired, on_name_lost, NULL, NULL);
    g_main_loop_run(loop);
    return NULL;
}

void tray_sni_start(void) {
    g_mutex_lock(&lock);
    if (started) {
        g_mutex_unlock(&lock);
        return;
    }
    started = 1;
    g_mutex_unlock(&lock);
    g_thread_new("ramiel-tray-sni", tray_thread, NULL);
}

int tray_sni_poll(TraySniSnapshot *out) {
    if (!out) return 0;
    g_mutex_lock(&lock);
    if (!dirty) {
        g_mutex_unlock(&lock);
        return 0;
    }
    snapshot.watcher_ready = watcher_ready;
    memcpy(out, &snapshot, sizeof(snapshot));
    dirty = 0;
    g_mutex_unlock(&lock);
    return 1;
}

int tray_sni_get_pixmap(uintptr_t id, uint8_t *out_buf, size_t buf_len,
                        int32_t *out_width, int32_t *out_height,
                        int32_t *out_serial) {
    if (!out_buf || !out_width || !out_height || !out_serial) return 0;
    g_mutex_lock(&lock);
    int idx = find_index_by_id_locked(id);
    if (idx < 0) {
        g_mutex_unlock(&lock);
        return 0;
    }
    PixmapStore *ps = &pixmaps[idx];
    if (!ps->bytes || ps->width <= 0 || ps->height <= 0) {
        g_mutex_unlock(&lock);
        return 0;
    }
    size_t needed = (size_t)(ps->width * ps->height * 4);
    if (buf_len < needed) {
        g_mutex_unlock(&lock);
        return 0;
    }
    memcpy(out_buf, ps->bytes, needed);
    *out_width = ps->width;
    *out_height = ps->height;
    *out_serial = ps->serial;
    g_mutex_unlock(&lock);
    return 1;
}

static void call_item(uintptr_t id, const char *method) {
    if (!connection) return;
    char service[128];
    char path[128];
    g_mutex_lock(&lock);
    int idx = find_index_by_id_locked(id);
    if (idx < 0) {
        g_mutex_unlock(&lock);
        return;
    }
    copy_str(service, sizeof(service), snapshot.items[idx].service);
    copy_str(path, sizeof(path), snapshot.items[idx].path);
    g_mutex_unlock(&lock);

    GError *error = NULL;
    GVariant *result = g_dbus_connection_call_sync(connection, service, path, ITEM_IFACE, method, g_variant_new("(ii)", 0, 0), NULL, G_DBUS_CALL_FLAGS_NONE, 1000, NULL, &error);
    if (error) g_error_free(error);
    if (result) g_variant_unref(result);
}

void tray_sni_activate(uintptr_t id) {
    call_item(id, "Activate");
}

void tray_sni_context_menu(uintptr_t id) {
    call_item(id, "ContextMenu");
}

void tray_sni_menu_event(uintptr_t id, int32_t dbusmenu_id) {
    if (!connection) return;
    char service[128];
    char menu_path[128];
    g_mutex_lock(&lock);
    int idx = find_index_by_id_locked(id);
    if (idx < 0) {
        g_mutex_unlock(&lock);
        return;
    }
    copy_str(service, sizeof(service), snapshot.items[idx].service);
    copy_str(menu_path, sizeof(menu_path), snapshot.items[idx].menu_path);
    g_mutex_unlock(&lock);
    if (!menu_path[0]) return;

    GVariant *data = g_variant_new_string("");
    GVariant *params = g_variant_new(
        "(isvu)", dbusmenu_id, "clicked", data, (guint32)(g_get_real_time() / 1000));
    GError *error = NULL;
    GVariant *result = g_dbus_connection_call_sync(
        connection, service, menu_path, DBUSMENU_IFACE, "Event", params, NULL,
        G_DBUS_CALL_FLAGS_NONE, 1000, NULL, &error);
    if (error) g_error_free(error);
    if (result) g_variant_unref(result);
}
