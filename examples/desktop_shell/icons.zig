//! Material Symbols SVG assets for the Wayland top bar example.
//! Keep icon artwork in standalone files like the other examples, then embed it here.

pub const volume_high = @embedFile("icons/volume-high.svg");
pub const volume_mute = @embedFile("icons/volume-mute.svg");
pub const volume_low = @embedFile("icons/volume-low.svg");
pub const battery_full = @embedFile("icons/battery-full.svg");
pub const battery_charging = @embedFile("icons/battery-charging.svg");
pub const battery_low = @embedFile("icons/battery-low.svg");

// Power menu actions.
pub const power_lock = @embedFile("icons/power-lock.svg");
pub const power_suspend = @embedFile("icons/power-suspend.svg");
pub const power_logout = @embedFile("icons/power-logout.svg");
pub const power_reboot = @embedFile("icons/power-reboot.svg");
pub const power_shutdown = @embedFile("icons/power-shutdown.svg");

// Panel accents.
pub const net_wifi = @embedFile("icons/net-wifi.svg");
pub const panel_tune = @embedFile("icons/panel-tune.svg");
pub const launcher = @embedFile("icons/launcher.svg");
