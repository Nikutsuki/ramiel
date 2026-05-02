//! Standard composite widgets and the zero-cost `Builder` proxy over `UIContext`.

const UIContext = @import("../context.zig").UIContext;
const Node = @import("../node.zig").Node;

const slider_impl = @import("slider.zig");
const checkbox_impl = @import("checkbox.zig");
const radio_impl = @import("radio.zig");
const radio_group_impl = @import("radio_group.zig");
const checkbox_group_impl = @import("checkbox_group.zig");
const dropdown_impl = @import("dropdown.zig");
const color_picker_impl = @import("color_picker.zig");
const icon_impl = @import("icon.zig");
const id_impl = @import("id.zig");
const video_impl = @import("video.zig");
const video_player_impl = @import("video_player.zig");
const animated_media_impl = @import("animated_media.zig");
const virtual_list_impl = @import("virtual_list.zig");
const tree_impl = @import("tree.zig");
const plot_impl = @import("plot.zig");
pub const tree = tree_impl;
pub const plot = plot_impl;

pub const VideoPlayback = @import("../../video/playback.zig").VideoPlayback;
pub const Style = @import("../layout.zig").Style;

pub const SliderDescriptor = slider_impl.SliderDescriptor;
pub const SliderParams = slider_impl.SliderParams;
pub const SliderSlot = slider_impl.SliderSlot;
pub const CheckboxParams = checkbox_impl.CheckboxParams;
pub const CheckboxBoxStyle = checkbox_impl.BoxStyle;
pub const RadioParams = radio_impl.RadioParams;
pub const RadioRingStyle = radio_impl.RingStyle;
pub const RadioDotStyle = radio_impl.DotStyle;
pub const RadioGroupDescriptor = radio_group_impl.RadioGroupDescriptor;
pub const RadioGroupContext = radio_group_impl.RadioGroupContext;
pub const CheckboxGroupDescriptor = checkbox_group_impl.CheckboxGroupDescriptor;
pub const CheckboxGroupContext = checkbox_group_impl.CheckboxGroupContext;
pub const DropdownParams = dropdown_impl.DropdownParams;
pub const DropdownTriggerStyle = dropdown_impl.TriggerStyle;
pub const DropdownMenuStyle = dropdown_impl.MenuStyle;
pub const DropdownItemStyle = dropdown_impl.ItemStyle;
pub const ColorPickerDescriptor = color_picker_impl.ColorPickerDescriptor;
pub const IconDescriptor = icon_impl.IconDescriptor;
pub const ColorPickerContext = color_picker_impl.ColorPickerContext;
pub const VideoPlayerDescriptor = video_player_impl.VideoPlayerDescriptor;
pub const VideoPlayerContext = video_player_impl.VideoPlayerContext;
pub const AnimatedMediaDescriptor = animated_media_impl.AnimatedMediaDescriptor;
pub const AnimatedMediaContext = animated_media_impl.AnimatedMediaContext;
pub const VirtualListDescriptor = virtual_list_impl.VirtualListDescriptor;
pub const VirtualListContext = virtual_list_impl.VirtualListContext;
pub const VirtualListState = virtual_list_impl.VirtualListState;
pub const VirtualListAxis = virtual_list_impl.Axis;
pub const TreeDescriptor = tree_impl.TreeDescriptor;
pub const TreeContext = tree_impl.TreeContext;
pub const TreeItem = tree_impl.TreeItem;
pub const TreeDropPosition = tree_impl.DropPosition;
pub const TreeCoreIcons = tree_impl.CoreIcons;
pub const TreeMessage = tree_impl.TreeMessage;
pub const PlotDescriptor = plot_impl.PlotDescriptor;
pub const PlotContext = plot_impl.PlotContext;
pub const PlotState = plot_impl.PlotState;
pub const PlotSeries = plot_impl.PlotSeries;
pub const PlotMsg = plot_impl.PlotMsg;
pub const applyPlotMsg = plot_impl.applyPlotMsg;
pub const collectTopLevelSelectedIds = tree_impl.collectTopLevelSelectedIds;
pub const applyTreeDrop = tree_impl.applyDrop;
pub const virtualListItemNodeId = virtual_list_impl.itemNodeId;
pub const applyVirtualListScrollDelta = virtual_list_impl.applyScrollDelta;
pub const scrollVirtualListToEnd = virtual_list_impl.scrollToEnd;
pub const updateColorPickerPlaneTexture = color_picker_impl.updatePlaneTexture;
pub const deriveChildId = id_impl.deriveChildId;

pub fn Builder(comptime MessageT: type) type {
    return struct {
        ui: *UIContext(MessageT),

        const Self = @This();

        pub inline fn slider(self: Self, params: SliderParams(MessageT)) !*Node(MessageT) {
            return slider_impl.build(MessageT, self.ui, params);
        }

        pub inline fn checkbox(self: Self, params: CheckboxParams(MessageT)) !*Node(MessageT) {
            return checkbox_impl.build(MessageT, self.ui, params);
        }

        pub inline fn radio(self: Self, params: RadioParams(MessageT)) !*Node(MessageT) {
            return radio_impl.build(MessageT, self.ui, params);
        }

        pub inline fn radioGroup(self: Self, logic: RadioGroupContext(MessageT), visuals: RadioGroupDescriptor) !*Node(MessageT) {
            return radio_group_impl.build(MessageT, self.ui, logic, visuals);
        }

        pub inline fn checkboxGroup(self: Self, logic: CheckboxGroupContext(MessageT), visuals: CheckboxGroupDescriptor) !*Node(MessageT) {
            return checkbox_group_impl.build(MessageT, self.ui, logic, visuals);
        }

        pub inline fn dropdown(self: Self, params: DropdownParams(MessageT)) !*Node(MessageT) {
            return dropdown_impl.build(MessageT, self.ui, params);
        }

        pub inline fn colorPicker(self: Self, logic: ColorPickerContext(MessageT), visuals: ColorPickerDescriptor) !*Node(MessageT) {
            return color_picker_impl.build(MessageT, self.ui, logic, visuals);
        }

        pub inline fn icon(self: Self, desc: IconDescriptor) !*Node(MessageT) {
            return icon_impl.build(MessageT, self.ui, desc);
        }

        pub inline fn video(self: Self, playback: *const VideoPlayback, style: Style) !*Node(MessageT) {
            return video_impl.build(MessageT, self.ui, playback, style);
        }

        pub inline fn videoPlayer(self: Self, desc: VideoPlayerDescriptor, logic: VideoPlayerContext(MessageT)) !*Node(MessageT) {
            return video_player_impl.build(MessageT, self.ui, desc, logic);
        }

        pub inline fn animatedMedia(self: Self, playback: *VideoPlayback, desc: AnimatedMediaDescriptor, logic: AnimatedMediaContext(MessageT)) !*Node(MessageT) {
            return animated_media_impl.build(MessageT, self.ui, playback, desc, logic);
        }

        pub inline fn virtualList(self: Self, logic: VirtualListContext(MessageT), desc: VirtualListDescriptor) !*Node(MessageT) {
            return virtual_list_impl.build(MessageT, self.ui, logic, desc);
        }

        pub inline fn tree(self: Self, logic: TreeContext(MessageT), visuals: TreeDescriptor) !*Node(MessageT) {
            return tree_impl.build(MessageT, self.ui, logic, visuals);
        }

        pub inline fn plot(self: Self, logic: PlotContext(MessageT), visuals: PlotDescriptor) !*Node(MessageT) {
            return plot_impl.build(MessageT, self.ui, logic, visuals);
        }

        pub inline fn treeFromSource(
            self: Self,
            comptime ItemT: type,
            state: *const tree_impl.TreeState([]const u8),
            root_items: []const ItemT,
            logic: tree_impl.TreeSourceLogic(MessageT),
            visuals: TreeDescriptor,
        ) !*Node(MessageT) {
            return tree_impl.buildFromSource(MessageT, ItemT, self.ui, state, root_items, logic, visuals);
        }
    };
}
