const std = @import("std");

const c = @cImport({
    @cInclude("/home/nikutsuki/Projects/ramiel/examples/desktop_shell/modules/tray_sni.h");
});

pub const Icon = enum {
    network,
    messages,
    updates,
    app,
};

pub const MenuAction = union(enum) {
    none,
    network_settings,
    disconnect_network,
    toggle_quiet,
    open_messages,
    check_updates,
    open_update_settings,
    activate_item: usize,
    context_menu_item: usize,
    dbusmenu_click: DbusMenuClick,
};

pub const DbusMenuClick = struct {
    item_id: usize,
    dbus_id: i32,
};

pub const MenuItemKind = enum {
    normal,
    separator,
};

pub const MenuItem = struct {
    kind: MenuItemKind = .normal,
    label_buf: [80]u8 = [_]u8{0} ** 80,
    label_len: u8 = 0,
    enabled: bool = true,
    checked: bool = false,
    has_toggle: bool = false,
    action: MenuAction = .none,

    pub fn label(self: *const MenuItem) []const u8 {
        return self.label_buf[0..self.label_len];
    }

    pub fn withLabel(label_str: []const u8) MenuItem {
        var out: MenuItem = .{};
        out.setLabel(label_str);
        return out;
    }

    pub fn setLabel(self: *MenuItem, src: []const u8) void {
        const n = @min(self.label_buf.len, src.len);
        @memcpy(self.label_buf[0..n], src[0..n]);
        if (n < self.label_buf.len) self.label_buf[n] = 0;
        self.label_len = @intCast(n);
    }
};

pub const MAX_MENU_ITEMS = c.TRAY_SNI_MAX_MENU;

pub const Item = struct {
    id: usize = 0,
    icon: Icon = .network,
    title_buf: [96]u8 = [_]u8{0} ** 96,
    title_len: usize = 0,
    status_buf: [96]u8 = [_]u8{0} ** 96,
    status_len: usize = 0,
    service_buf: [128]u8 = [_]u8{0} ** 128,
    service_len: usize = 0,
    path_buf: [128]u8 = [_]u8{0} ** 128,
    path_len: usize = 0,
    menu_path_buf: [128]u8 = [_]u8{0} ** 128,
    menu_path_len: usize = 0,
    icon_name_buf: [128]u8 = [_]u8{0} ** 128,
    icon_name_len: usize = 0,
    icon_id: u32 = 0,
    tex_id: u32 = 0,
    tex_serial: i32 = 0,
    pixmap_width: i32 = 0,
    pixmap_height: i32 = 0,
    pixmap_serial: i32 = 0,
    real: bool = false,
    menu: [MAX_MENU_ITEMS]MenuItem = [_]MenuItem{.{}} ** MAX_MENU_ITEMS,
    menu_count: usize = 0,

    pub fn title(self: *const Item) []const u8 {
        return self.title_buf[0..self.title_len];
    }

    pub fn status(self: *const Item) []const u8 {
        return self.status_buf[0..self.status_len];
    }

    pub fn service(self: *const Item) []const u8 {
        return self.service_buf[0..self.service_len];
    }

    pub fn path(self: *const Item) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    pub fn menuPath(self: *const Item) []const u8 {
        return self.menu_path_buf[0..self.menu_path_len];
    }

    pub fn iconName(self: *const Item) []const u8 {
        return self.icon_name_buf[0..self.icon_name_len];
    }

    pub fn menuItems(self: *const Item) []const MenuItem {
        return self.menu[0..self.menu_count];
    }
};

pub const State = struct {
    available: bool = true,
    real_watcher: bool = false,
    quiet_mode: bool = false,
    updates_available: bool = true,
    items: [16]Item = [_]Item{.{}} ** 16,
    item_count: usize = 0,

    pub fn itemSlice(self: *const State) []const Item {
        return self.items[0..self.item_count];
    }

    pub fn itemById(self: *const State, id: usize) ?*const Item {
        for (self.itemSlice()) |*item| {
            if (item.id == id) return item;
        }
        return null;
    }

    pub fn applyAction(self: *State, action: MenuAction) void {
        switch (action) {
            .toggle_quiet => self.quiet_mode = !self.quiet_mode,
            .check_updates => self.updates_available = false,
            .activate_item => |id| activate(id),
            .context_menu_item => |id| contextMenu(id),
            .dbusmenu_click => |ev| menuEvent(ev.item_id, ev.dbus_id),
            else => {},
        }
        self.refreshDynamicLabels();
    }

    fn refreshDynamicLabels(self: *State) void {
        for (self.items[0..self.item_count]) |*item| {
            if (item.real) continue;
            switch (item.icon) {
                .messages => {
                    setText(&item.status_buf, &item.status_len, if (self.quiet_mode) "Quiet mode" else "Notifications on");
                    if (item.menu_count > 1) item.menu[1].checked = self.quiet_mode;
                },
                .updates => {
                    setText(&item.status_buf, &item.status_len, if (self.updates_available) "Updates available" else "System current");
                    setText(&item.title_buf, &item.title_len, if (self.updates_available) "Updates" else "Updated");
                },
                .network, .app => {},
            }
        }
    }
};

pub fn start() void {
    c.tray_sni_start();
}

pub fn poll() ?State {
    var snap: c.TraySniSnapshot = undefined;
    if (c.tray_sni_poll(&snap) == 0) return null;

    var state: State = .{ .available = true, .real_watcher = snap.watcher_ready != 0 };
    state.item_count = @min(@as(usize, @intCast(snap.item_count)), state.items.len);
    for (state.items[0..state.item_count], 0..) |*item, i| {
        const src = snap.items[i];
        item.* = .{ .id = @intCast(src.id), .icon = .app, .real = src.real != 0 };
        copyZ(&item.title_buf, &item.title_len, &src.title);
        if (item.title_len == 0) copyZ(&item.title_buf, &item.title_len, &src.service);
        copyZ(&item.status_buf, &item.status_len, &src.status);
        copyZ(&item.service_buf, &item.service_len, &src.service);
        copyZ(&item.path_buf, &item.path_len, &src.path);
        copyZ(&item.menu_path_buf, &item.menu_path_len, &src.menu_path);
        copyZ(&item.icon_name_buf, &item.icon_name_len, &src.icon_name);
        item.pixmap_width = src.icon_pixmap_width;
        item.pixmap_height = src.icon_pixmap_height;
        item.pixmap_serial = src.icon_pixmap_serial;

        const src_menu_count: usize = @intCast(src.menu_count);
        const menu_count = @min(src_menu_count, item.menu.len);
        item.menu_count = menu_count;
        for (item.menu[0..menu_count], 0..) |*dst, j| {
            const m = src.menu[j];
            dst.* = .{
                .kind = if (m.kind == 1) .separator else .normal,
                .enabled = m.enabled != 0,
                .checked = m.checked != 0,
                .has_toggle = m.has_toggle != 0,
                .action = .{ .dbusmenu_click = .{ .item_id = item.id, .dbus_id = m.dbus_id } },
            };
            dst.setLabel(sliceCString(&m.label));
        }

        // Electron tray icons (Discord/Vesktop, Slack, …) don't expose a
        // dbusmenu — only the legacy SNI Activate/ContextMenu callbacks.
        // Synthesize a two-entry fallback so the popup isn't empty.
        if (item.real and item.menu_count == 0) {
            item.menu[0] = .{ .action = .{ .activate_item = item.id } };
            item.menu[0].setLabel("Activate");
            item.menu[1] = .{ .action = .{ .context_menu_item = item.id } };
            item.menu[1].setLabel("Show menu");
            item.menu_count = 2;
        }
    }
    return state;
}

pub fn activate(id: usize) void {
    c.tray_sni_activate(@intCast(id));
}

pub fn contextMenu(id: usize) void {
    c.tray_sni_context_menu(@intCast(id));
}

pub fn menuEvent(id: usize, dbus_id: i32) void {
    c.tray_sni_menu_event(@intCast(id), dbus_id);
}

pub fn fetchPixmap(item_id: usize, buf: []u8) ?struct { width: u32, height: u32, serial: i32 } {
    var w: i32 = 0;
    var h: i32 = 0;
    var serial: i32 = 0;
    const ok = c.tray_sni_get_pixmap(
        @intCast(item_id),
        buf.ptr,
        buf.len,
        &w,
        &h,
        &serial,
    );
    if (ok == 0) return null;
    if (w <= 0 or h <= 0) return null;
    return .{ .width = @intCast(w), .height = @intCast(h), .serial = serial };
}

pub fn demoState() State {
    var state: State = .{};
    state.item_count = 3;
    fillDemoItem(&state.items[0], 1, .network, "Network", "Wi-Fi connected", &.{
        .{ .label = "Wi-Fi connected", .enabled = false },
        .{ .label = "Network settings", .action = .network_settings },
        .{ .kind = .separator },
        .{ .label = "Disconnect", .action = .disconnect_network },
    });
    fillDemoItem(&state.items[1], 2, .messages, "Messages", "Notifications on", &.{
        .{ .label = "Open notifications", .action = .open_messages },
        .{ .label = "Quiet mode", .checked = false, .has_toggle = true, .action = .toggle_quiet },
        .{ .kind = .separator },
        .{ .label = "Notification settings", .action = .open_messages },
    });
    fillDemoItem(&state.items[2], 3, .updates, "Updates", "Updates available", &.{
        .{ .label = "Check for updates", .action = .check_updates },
        .{ .kind = .separator },
        .{ .label = "Update settings", .action = .open_update_settings },
    });
    return state;
}

const DemoMenuItem = struct {
    kind: MenuItemKind = .normal,
    label: []const u8 = "",
    enabled: bool = true,
    checked: bool = false,
    has_toggle: bool = false,
    action: MenuAction = .none,
};

fn fillDemoItem(item: *Item, id: usize, icon: Icon, title: []const u8, status: []const u8, items: []const DemoMenuItem) void {
    item.* = .{ .id = id, .icon = icon, .menu_count = items.len };
    setText(&item.title_buf, &item.title_len, title);
    setText(&item.status_buf, &item.status_len, status);
    for (items, 0..) |menu_item, i| {
        item.menu[i] = .{
            .kind = menu_item.kind,
            .enabled = menu_item.enabled,
            .checked = menu_item.checked,
            .has_toggle = menu_item.has_toggle,
            .action = menu_item.action,
        };
        item.menu[i].setLabel(menu_item.label);
    }
}

fn copyZ(buf: anytype, len: *usize, src: anytype) void {
    var n: usize = 0;
    while (n < buf.len and n < src.len and src[n] != 0) : (n += 1) {}
    @memcpy(buf[0..n], src[0..n]);
    if (n < buf.len) buf[n] = 0;
    len.* = n;
}

fn setText(buf: anytype, len: *usize, text: []const u8) void {
    const n = @min(buf.len, text.len);
    @memcpy(buf[0..n], text[0..n]);
    if (n < buf.len) buf[n] = 0;
    len.* = n;
}

fn sliceCString(src: anytype) []const u8 {
    var n: usize = 0;
    while (n < src.len and src[n] != 0) : (n += 1) {}
    return src[0..n];
}
