const std = @import("std");
const lib = @import("ramiel");

const core = @import("core.zig");
const env = @import("env.zig");
const updater = @import("update.zig");
const ui_root = @import("ui/root.zig");
const add_icon_svg = @embedFile("ui/icons/add.svg");
const theme = lib.theme;
const Theme = lib.Theme;
const Palette = lib.Palette;
const SemanticTokens = lib.SemanticTokens;

pub const tracy_impl = @import("tracy_impl");

pub fn main(init: std.process.Init) !void {
    var rt = lib.Runtime.init();
    defer rt.deinit();
    const allocator = rt.allocator();

    const io = init.io;

    const env_content = try std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, ".env", allocator, std.Io.Limit.limited64(64 * 1024));
    defer allocator.free(env_content);

    var env_map = std.StringHashMap([]const u8).init(allocator);
    defer {
        env.EnvParser.freeMapContents(allocator, &env_map);
        env_map.deinit();
    }

    try env.EnvParser.parse(allocator, env_content, &env_map);

    const token = env_map.get("OWO") orelse {
        std.debug.print("Fatal: DISCORD_TOKEN not found in .env file.\n", .{});
        return error.MissingDiscordToken;
    };

    var discord_client = try core.Discord.init(allocator, io, token);
    defer discord_client.deinit();

    const discord_theme = Theme.fromOklch(.{ .l = 0.55, .c = 0.15, .h = 275.0 }, .dark);

    var app = try core.App.init(
        allocator,
        io,
        .{ .title = "Discord Client (Ramiel)" },
        core.initAppState(allocator, &discord_client),
        updater.update,
    );

    app.ui.setTheme(discord_theme);
    defer app.deinit();
    defer core.deinitAppState(&app.state);

    app.tick_fn = updater.tick;

    app.state.font_data = try app.loadFont("JetBrains Mono", .{ .memory = lib.assets.getFontData(.jetbrains_mono) }, 32);
    try app.loadIconSvgFromMemory(
        @intFromEnum(core.IconIds.add),
        add_icon_svg,
        16,
        16,
        1.0,
    );

    app.state.app = &app;

    updater.startBootstrap(&app.state);
    try updater.startWebsocket(&app.state);
    try app.setRootBuilder(ui_root.build);
    try app.run();

    app.state.shutdown_flag.store(true, .release);

    if (app.state.ws_thread) |thread| {
        thread.join();
    }

    app.cancelAndAwaitFutures(.{
        &app.state.bootstrap_future,
        &app.state.messages_fetch_future,
        &app.state.channels_fetch_future,
        &app.state.send_message_future,
        &app.state.history_fetch_future,
    });
}
