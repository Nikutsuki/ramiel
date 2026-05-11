//! Material Symbols (outlined) shipped with the example. Loaded once in setup.
//! Reference via `IconId` and `comp.icon` with `intrinsic_size = .{24, 24}`.

const std = @import("std");
const lib = @import("ramiel");

pub const IconId = enum(u32) {
    play,
    pause,
    stop,
    next,
    prev,
    shuffle,
    settings,
    back,
    import,
    plus,
    trash,
    tag,
    add_to_playlist,
    spectrum,
    groups,
    tags,
    volume,
    edit,
    close,
    search,
    more,
};

const SVG_PLAY = @embedFile("icons/play.svg");
const SVG_PAUSE = @embedFile("icons/pause.svg");
const SVG_STOP = @embedFile("icons/stop.svg");
const SVG_NEXT = @embedFile("icons/next.svg");
const SVG_PREV = @embedFile("icons/prev.svg");
const SVG_SHUFFLE = @embedFile("icons/shuffle.svg");
const SVG_SETTINGS = @embedFile("icons/settings.svg");
const SVG_BACK = @embedFile("icons/back.svg");
const SVG_IMPORT = @embedFile("icons/import.svg");
const SVG_PLUS = @embedFile("icons/plus.svg");
const SVG_TRASH = @embedFile("icons/trash.svg");
const SVG_TAG = @embedFile("icons/tag.svg");
const SVG_ADD_TO_PLAYLIST = @embedFile("icons/add-to-playlist.svg");
const SVG_SPECTRUM = @embedFile("icons/spectrum.svg");
const SVG_GROUPS = @embedFile("icons/groups.svg");
const SVG_TAGS = @embedFile("icons/tags.svg");
const SVG_VOLUME = @embedFile("icons/volume.svg");
const SVG_EDIT = @embedFile("icons/edit.svg");
const SVG_CLOSE = @embedFile("icons/close.svg");
const SVG_SEARCH = @embedFile("icons/search.svg");
const SVG_MORE = @embedFile("icons/more.svg");

pub fn loadAll(app: anytype) !void {
    const pairs = [_]struct { id: IconId, bytes: []const u8 }{
        .{ .id = .play, .bytes = SVG_PLAY },
        .{ .id = .pause, .bytes = SVG_PAUSE },
        .{ .id = .stop, .bytes = SVG_STOP },
        .{ .id = .next, .bytes = SVG_NEXT },
        .{ .id = .prev, .bytes = SVG_PREV },
        .{ .id = .shuffle, .bytes = SVG_SHUFFLE },
        .{ .id = .settings, .bytes = SVG_SETTINGS },
        .{ .id = .back, .bytes = SVG_BACK },
        .{ .id = .import, .bytes = SVG_IMPORT },
        .{ .id = .plus, .bytes = SVG_PLUS },
        .{ .id = .trash, .bytes = SVG_TRASH },
        .{ .id = .tag, .bytes = SVG_TAG },
        .{ .id = .add_to_playlist, .bytes = SVG_ADD_TO_PLAYLIST },
        .{ .id = .spectrum, .bytes = SVG_SPECTRUM },
        .{ .id = .groups, .bytes = SVG_GROUPS },
        .{ .id = .tags, .bytes = SVG_TAGS },
        .{ .id = .volume, .bytes = SVG_VOLUME },
        .{ .id = .edit, .bytes = SVG_EDIT },
        .{ .id = .close, .bytes = SVG_CLOSE },
        .{ .id = .search, .bytes = SVG_SEARCH },
        .{ .id = .more, .bytes = SVG_MORE },
    };
    inline for (pairs) |p| {
        try app.loadIconSvgFromMemory(@intFromEnum(p.id), p.bytes, 24, 24, 1.0);
    }
}

