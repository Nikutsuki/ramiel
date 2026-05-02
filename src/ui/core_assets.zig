const IconRegistry = @import("../renderer/icon/registry.zig").IconRegistry;
const CoreIcons = @import("components/video_player.zig").CoreIcons;
const TreeCoreIcons = @import("components/tree.zig").CoreIcons;

const play_svg = @embedFile("../assets/icons/play_arrow.svg");
const pause_svg = @embedFile("../assets/icons/pause.svg");
const volume_svg = @embedFile("../assets/icons/volume.svg");
const volume_off_svg = @embedFile("../assets/icons/volume_off.svg");
const arrow_dropdown_svg = @embedFile("../assets/icons/arrow_dropdown.svg");

pub fn initCoreIcons(registry: *IconRegistry) !void {
    const default_width: u32 = 64;
    const default_height: u32 = 64;
    const default_scale: f32 = 1.0;

    try registry.loadStaticSvgFromMemory(
        CoreIcons.Play,
        play_svg,
        default_width,
        default_height,
        default_scale,
    );

    try registry.loadStaticSvgFromMemory(
        CoreIcons.Pause,
        pause_svg,
        default_width,
        default_height,
        default_scale,
    );

    try registry.loadStaticSvgFromMemory(
        CoreIcons.Volume,
        volume_svg,
        default_width,
        default_height,
        default_scale,
    );

    try registry.loadStaticSvgFromMemory(
        CoreIcons.VolumeOff,
        volume_off_svg,
        default_width,
        default_height,
        default_scale,
    );

    try registry.loadStaticSvgFromMemory(
        TreeCoreIcons.ArrowDropdown,
        arrow_dropdown_svg,
        default_width,
        default_height,
        default_scale,
    );
}
