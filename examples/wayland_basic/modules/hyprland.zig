const std = @import("std");

pub const Workspace = struct {
    id: i32,
    name_buf: [64]u8 = .{0} ** 64,
    name_len: u8 = 0,
    windows: u32 = 0,
    active: bool = false,

    pub fn nameSlice(self: *const Workspace) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

pub const State = struct {
    workspaces: [10]Workspace = undefined,
    workspace_count: u8 = 0,
    active_workspace_id: i32 = 0,
    title_buf: [256]u8 = .{0} ** 256,
    title_len: u16 = 0,
    available: bool = false,

    pub fn activeTitle(self: *const State) []const u8 {
        return self.title_buf[0..self.title_len];
    }
};

var socket_path_buf: [256]u8 = undefined;
var socket_path: ?[]const u8 = null;
var event_path_buf: [256]u8 = undefined;
var event_path: ?[]const u8 = null;

fn getSocketPath(env: *std.process.Environ.Map) ?[]const u8 {
    if (socket_path) |p| return p;
    const runtime_dir = env.get("XDG_RUNTIME_DIR") orelse return null;
    const instance = env.get("HYPRLAND_INSTANCE_SIGNATURE") orelse return null;
    const path = std.fmt.bufPrint(&socket_path_buf, "{s}/hypr/{s}/.socket.sock", .{ runtime_dir, instance }) catch return null;
    socket_path = path;
    return path;
}

fn getEventPath(env: *std.process.Environ.Map) ?[]const u8 {
    if (event_path) |p| return p;
    const runtime_dir = env.get("XDG_RUNTIME_DIR") orelse return null;
    const instance = env.get("HYPRLAND_INSTANCE_SIGNATURE") orelse return null;
    const path = std.fmt.bufPrint(&event_path_buf, "{s}/hypr/{s}/.socket2.sock", .{ runtime_dir, instance }) catch return null;
    event_path = path;
    return path;
}

var cmd_buf: [8192]u8 = undefined;

fn ipcCommand(io: std.Io, path: []const u8, cmd: []const u8) ?[]const u8 {
    var address = std.Io.net.UnixAddress.init(path) catch return null;
    var stream = address.connect(io) catch return null;
    defer stream.close(io);

    var write_buf: [256]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    writer.interface.writeAll(cmd) catch return null;
    writer.interface.flush() catch return null;

    var read_buf: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    const response = reader.interface.allocRemaining(std.heap.page_allocator, .limited(cmd_buf.len)) catch return null;

    if (response.len == 0) {
        std.heap.page_allocator.free(response);
        return null;
    }
    const len = @min(response.len, cmd_buf.len);
    @memcpy(cmd_buf[0..len], response[0..len]);
    std.heap.page_allocator.free(response);
    return cmd_buf[0..len];
}

/// Fire-and-forget: send command, don't wait for response.
pub fn dispatch(io: std.Io, env: *std.process.Environ.Map, cmd: []const u8) void {
    const path = getSocketPath(env) orelse return;
    var address = std.Io.net.UnixAddress.init(path) catch return;
    var stream = address.connect(io) catch return;
    defer stream.close(io);
    var write_buf: [256]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    writer.interface.writeAll(cmd) catch return;
    writer.interface.flush() catch return;
}

/// Full poll via IPC commands (used for initial state).
pub fn poll(io: std.Io, env: *std.process.Environ.Map) State {
    var state = State{};
    const path = getSocketPath(env) orelse return state;

    if (ipcCommand(io, path, "j/activeworkspace")) |json| {
        state.active_workspace_id = findJsonInt(json, "\"id\":") orelse 0;
    }
    if (ipcCommand(io, path, "j/activewindow")) |json| {
        if (findJsonString(json, "\"title\":")) |title| {
            const len = @min(title.len, state.title_buf.len);
            @memcpy(state.title_buf[0..len], title[0..len]);
            state.title_len = @intCast(len);
        }
    }
    if (ipcCommand(io, path, "j/workspaces")) |json| {
        parseWorkspaces(&state, json);
    }

    if (state.workspace_count > 0) state.available = true;
    sortWorkspaces(&state);
    return state;
}

/// Subscribe to the Hyprland event socket. Blocks forever, calling `onEvent`
/// for each event. Intended to run in a dedicated thread.
pub fn eventLoop(io: std.Io, env: *std.process.Environ.Map, state: *State, ready: *std.atomic.Value(bool)) void {
    const path = getEventPath(env) orelse return;

    // Initial full poll
    state.* = poll(io, env);
    ready.store(true, .release);

    // Connect to event socket
    var address = std.Io.net.UnixAddress.init(path) catch return;
    var stream = address.connect(io) catch return;
    defer stream.close(io);

    var read_buf: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buf);

    while (true) {
        const line = reader.interface.takeDelimiter('\n') catch return;
        if (line == null) return;
        const event_line = line.?;

        if (std.mem.startsWith(u8, event_line, "workspace>>")) {
            const id_str = event_line["workspace>>".len..];
            const id = std.fmt.parseInt(i32, id_str, 10) catch continue;
            state.active_workspace_id = id;
            for (state.workspaces[0..state.workspace_count]) |*ws| {
                ws.active = (ws.id == id);
            }
            ready.store(true, .release);
        } else if (std.mem.startsWith(u8, event_line, "activewindow>>")) {
            // Format: activewindow>>class,title
            const rest = event_line["activewindow>>".len..];
            const comma = std.mem.indexOfScalar(u8, rest, ',');
            const title = if (comma) |c| rest[c + 1 ..] else rest;
            const len = @min(title.len, state.title_buf.len);
            @memcpy(state.title_buf[0..len], title[0..len]);
            state.title_len = @intCast(len);
            ready.store(true, .release);
        } else if (std.mem.startsWith(u8, event_line, "createworkspace>>")) {
            // Re-poll workspaces to get the full list
            const sock = getSocketPath(env) orelse continue;
            if (ipcCommand(io, sock, "j/workspaces")) |json| {
                parseWorkspaces(state, json);
                sortWorkspaces(state);
            }
            ready.store(true, .release);
        } else if (std.mem.startsWith(u8, event_line, "destroyworkspace>>")) {
            const sock = getSocketPath(env) orelse continue;
            if (ipcCommand(io, sock, "j/workspaces")) |json| {
                parseWorkspaces(state, json);
                sortWorkspaces(state);
            }
            ready.store(true, .release);
        } else if (std.mem.startsWith(u8, event_line, "openwindow>>") or
            std.mem.startsWith(u8, event_line, "closewindow>>") or
            std.mem.startsWith(u8, event_line, "movewindow>>"))
        {
            // Window count changed — re-poll workspaces
            const sock = getSocketPath(env) orelse continue;
            if (ipcCommand(io, sock, "j/workspaces")) |json| {
                parseWorkspaces(state, json);
                sortWorkspaces(state);
            }
            ready.store(true, .release);
        }
    }
}

fn parseWorkspaces(state: *State, json: []const u8) void {
    var count: u8 = 0;
    var search_pos: usize = 0;

    while (search_pos < json.len and count < 10) {
        const id_pos = std.mem.indexOf(u8, json[search_pos..], "\"id\":") orelse break;
        const abs_pos = search_pos + id_pos;
        const obj_end = std.mem.indexOf(u8, json[abs_pos..], "},{") orelse (json.len - abs_pos);
        const obj_slice = json[abs_pos .. abs_pos + obj_end];

        const id = findJsonInt(obj_slice, "\"id\":") orelse {
            search_pos = abs_pos + 5;
            continue;
        };

        if (id < 0) {
            search_pos = abs_pos + obj_end;
            continue;
        }

        var ws = Workspace{ .id = @intCast(id) };
        ws.active = (ws.id == state.active_workspace_id);

        if (findJsonString(obj_slice, "\"name\":")) |name| {
            const len = @min(name.len, ws.name_buf.len);
            @memcpy(ws.name_buf[0..len], name[0..len]);
            ws.name_len = @intCast(len);
        }

        if (findJsonInt(obj_slice, "\"windows\":")) |w| {
            ws.windows = if (w >= 0) @intCast(w) else 0;
        }

        state.workspaces[count] = ws;
        count += 1;
        search_pos = abs_pos + obj_end;
    }
    state.workspace_count = count;
}

fn sortWorkspaces(state: *State) void {
    std.mem.sort(Workspace, state.workspaces[0..state.workspace_count], {}, struct {
        fn lessThan(_: void, a: Workspace, b: Workspace) bool {
            return a.id < b.id;
        }
    }.lessThan);
}

fn findJsonInt(json: []const u8, key: []const u8) ?i32 {
    const idx = std.mem.indexOf(u8, json, key) orelse return null;
    var pos = idx + key.len;
    while (pos < json.len and (json[pos] == ' ' or json[pos] == '\t')) pos += 1;
    var neg = false;
    if (pos < json.len and json[pos] == '-') {
        neg = true;
        pos += 1;
    }
    if (pos >= json.len or !std.ascii.isDigit(json[pos])) return null;
    var val: i32 = 0;
    while (pos < json.len and std.ascii.isDigit(json[pos])) {
        val = val * 10 + @as(i32, json[pos] - '0');
        pos += 1;
    }
    return if (neg) -val else val;
}

fn findJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    const idx = std.mem.indexOf(u8, json, key) orelse return null;
    var pos = idx + key.len;
    while (pos < json.len and (json[pos] == ' ' or json[pos] == '\t')) pos += 1;
    if (pos >= json.len or json[pos] != '"') return null;
    pos += 1;
    const start = pos;
    while (pos < json.len and json[pos] != '"') {
        if (json[pos] == '\\') pos += 1;
        pos += 1;
    }
    return json[start..pos];
}
