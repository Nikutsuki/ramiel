const std = @import("std");

pub const DependencyOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    tracy: bool = false,
    devtools: bool = false,
    wayland: bool = false,
    install_runtime_to_default_step: bool = true,
};

pub const Runtime = struct {
    b: *std.Build,
    dep: *std.Build.Dependency,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    is_windows: bool,
    is_linux: bool,
    ffmpeg_bin_install: ?*std.Build.Step.InstallDir = null,
    shaderc_bin_install: ?*std.Build.Step.InstallDir = null,
    ffmpeg_linux_lib_dir: ?[]const u8 = null,
    shaderc_linux_lib_dir: ?[]const u8 = null,
    ffmpeg_linux_patchelf: ?*std.Build.Step = null,

    pub fn addRamielImport(self: Runtime, module: *std.Build.Module) void {
        module.addImport("ramiel", self.module);
    }

    pub fn bindRunEnvironment(self: Runtime, run_cmd: *std.Build.Step.Run) void {
        if (self.ffmpeg_linux_patchelf) |step| run_cmd.step.dependOn(step);
        const env = run_cmd.getEnvMap();
        if (self.is_windows) {
            var needs_install_bin = false;
            if (self.ffmpeg_bin_install) |install| {
                run_cmd.step.dependOn(&install.step);
                needs_install_bin = true;
            }
            if (self.shaderc_bin_install) |install| {
                run_cmd.step.dependOn(&install.step);
                needs_install_bin = true;
            }
            if (!needs_install_bin) return;

            const current_path = env.get("PATH") orelse "";
            const install_bin = self.b.getInstallPath(.bin, "");
            env.put(
                "PATH",
                self.b.fmt("{s}{c}{s}", .{ install_bin, std.fs.path.delimiter, current_path }),
            ) catch @panic("OOM");
        } else {
            var prefix: ?[]const u8 = null;
            if (self.ffmpeg_linux_lib_dir) |dir| prefix = appendPath(self.b, prefix, dir);
            if (self.shaderc_linux_lib_dir) |dir| prefix = appendPath(self.b, prefix, dir);
            const lib_prefix = prefix orelse return;
            const current_ld = env.get("LD_LIBRARY_PATH") orelse "";
            env.put(
                "LD_LIBRARY_PATH",
                self.b.fmt("{s}{c}{s}", .{ lib_prefix, std.fs.path.delimiter, current_ld }),
            ) catch @panic("OOM");
        }
    }

    pub fn dynamicLibraryBasename(self: Runtime, lib_name: []const u8) []const u8 {
        return if (self.is_windows)
            self.b.fmt("{s}.dll", .{lib_name})
        else
            self.b.fmt("lib{s}.so", .{lib_name});
    }

    pub fn addHotReloadableApp(self: Runtime, options: HotReloadableAppOptions) HotReloadableApp {
        const exe = self.b.addExecutable(.{
            .name = options.exe_name,
            .root_module = options.exe_root_module,
        });
        const install_exe = self.b.addInstallArtifact(exe, .{});
        if (options.install_to_default_step) self.b.getInstallStep().dependOn(&install_exe.step);
        if (self.ffmpeg_linux_patchelf) |step| install_exe.step.dependOn(step);

        const app_lib = self.b.addLibrary(.{
            .name = options.lib_name,
            .linkage = .dynamic,
            .root_module = options.app_lib_root_module,
        });
        const install_app_lib = self.b.addInstallArtifact(app_lib, .{});
        if (options.install_to_default_step) self.b.getInstallStep().dependOn(&install_app_lib.step);
        if (self.ffmpeg_linux_patchelf) |step| install_app_lib.step.dependOn(step);

        const host_exe = self.b.addExecutable(.{
            .name = options.host_name,
            .root_module = options.host_root_module,
        });
        const install_host = self.b.addInstallArtifact(host_exe, .{});
        if (options.install_to_default_step) self.b.getInstallStep().dependOn(&install_host.step);
        if (self.ffmpeg_linux_patchelf) |step| install_host.step.dependOn(step);

        const hot_lib_step = self.b.step(options.hot_lib_step_name, options.hot_lib_step_description);
        hot_lib_step.dependOn(&install_app_lib.step);

        const hot_step = self.b.step(options.hot_step_name, options.hot_step_description);
        hot_step.dependOn(&install_app_lib.step);
        hot_step.dependOn(&install_host.step);

        const run_exe = self.b.addRunArtifact(exe);
        run_exe.step.dependOn(&install_exe.step);
        self.bindRunEnvironment(run_exe);
        if (self.b.args) |args| run_exe.addArgs(args);

        const run_host = self.b.addRunArtifact(host_exe);
        run_host.step.dependOn(&install_app_lib.step);
        run_host.step.dependOn(&install_host.step);
        self.bindRunEnvironment(run_host);
        run_host.addArgs(&.{
            "--lib",
            self.b.getInstallPath(if (self.is_windows) .bin else .lib, self.dynamicLibraryBasename(options.lib_name)),
            "--build-target",
            options.hot_lib_step_name,
        });
        for (options.watch_dirs) |dir| {
            run_host.addArgs(&.{ "--watch", dir });
        }
        if (self.b.args) |args| run_host.addArgs(args);

        const run_step = self.b.step(options.run_step_name, options.run_step_description);
        run_step.dependOn(if (options.hot_reload_default) &run_host.step else &run_exe.step);

        const run_hot_step = self.b.step(options.run_hot_step_name, options.run_hot_step_description);
        run_hot_step.dependOn(&run_host.step);

        return .{
            .exe = exe,
            .app_lib = app_lib,
            .host_exe = host_exe,
            .install_app_lib = install_app_lib,
            .install_host = install_host,
            .run_exe = run_exe,
            .run_host = run_host,
            .hot_lib_step = hot_lib_step,
            .hot_step = hot_step,
            .run_step = run_step,
            .run_hot_step = run_hot_step,
        };
    }
};

pub const HotReloadableAppOptions = struct {
    exe_name: []const u8,
    exe_root_module: *std.Build.Module,
    lib_name: []const u8,
    app_lib_root_module: *std.Build.Module,
    host_name: []const u8,
    host_root_module: *std.Build.Module,
    install_to_default_step: bool = true,
    hot_reload_default: bool = false,
    watch_dirs: []const []const u8 = &.{"src"},
    hot_lib_step_name: []const u8 = "hot-lib",
    hot_lib_step_description: []const u8 = "Build the hot-reload app library only",
    hot_step_name: []const u8 = "hot",
    hot_step_description: []const u8 = "Build the hot-reload host and app library",
    run_step_name: []const u8 = "run",
    run_step_description: []const u8 = "Run the app",
    run_hot_step_name: []const u8 = "run-hot",
    run_hot_step_description: []const u8 = "Run the hot-reload host",
};

pub const HotReloadableApp = struct {
    exe: *std.Build.Step.Compile,
    app_lib: *std.Build.Step.Compile,
    host_exe: *std.Build.Step.Compile,
    install_app_lib: *std.Build.Step.InstallArtifact,
    install_host: *std.Build.Step.InstallArtifact,
    run_exe: *std.Build.Step.Run,
    run_host: *std.Build.Step.Run,
    hot_lib_step: *std.Build.Step,
    hot_step: *std.Build.Step,
    run_step: *std.Build.Step,
    run_hot_step: *std.Build.Step,
};

pub fn standardDependencyOptions(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) DependencyOptions {
    return .{
        .target = target,
        .optimize = optimize,
        .tracy = b.option(bool, "tracy", "Build Ramiel with Tracy memory allocation profiling.") orelse false,
        .devtools = b.option(bool, "devtools", "Enable Ramiel DevTools.") orelse false,
        .wayland = b.option(bool, "wayland", "Enable Ramiel native Wayland backend support.") orelse false,
    };
}

pub fn dependency(b: *std.Build, options: DependencyOptions) Runtime {
    const dep = b.dependency("ramiel", .{
        .target = options.target,
        .optimize = options.optimize,
        .tracy = options.tracy,
        .devtools = options.devtools,
        .wayland = options.wayland,
    });
    const is_windows = options.target.result.os.tag == .windows;
    const is_linux = options.target.result.os.tag == .linux;

    var runtime = Runtime{
        .b = b,
        .dep = dep,
        .module = dep.module("ramiel"),
        .target = options.target,
        .optimize = options.optimize,
        .is_windows = is_windows,
        .is_linux = is_linux,
    };

    if (is_windows) {
        runtime.ffmpeg_bin_install = installRuntimeDirIfExists(
            b,
            dep.builder.pathFromRoot("src/thirdparty/ffmpeg_windows_x64/bin"),
            options.install_runtime_to_default_step,
        );
        runtime.shaderc_bin_install = installRuntimeDirIfExists(
            b,
            b.pathJoin(&.{ shadercWindowsBasePath(b, dep), "bin" }),
            options.install_runtime_to_default_step,
        );
    } else if (is_linux) {
        runtime.ffmpeg_linux_lib_dir = dep.builder.pathFromRoot("src/thirdparty/ffmpeg_linux_x64/lib");
        runtime.shaderc_linux_lib_dir = dep.builder.pathFromRoot("src/thirdparty/shaderc_linux_x64/lib");
        runtime.ffmpeg_linux_patchelf = createFfmpegPatchelfStep(b, runtime.ffmpeg_linux_lib_dir.?);
    }

    return runtime;
}

pub fn createFfmpegPatchelfStep(b: *std.Build, lib_dir_abs: []const u8) ?*std.Build.Step {
    const io = b.graph.io;
    var dir = std.Io.Dir.openDirAbsolute(io, lib_dir_abs, .{ .iterate = true }) catch return null;
    defer dir.close(io);

    const group = b.step(
        "patch-ffmpeg-rpath",
        "Set RUNPATH=$ORIGIN on vendored ffmpeg .so files (Linux, idempotent).",
    );

    var iter = dir.iterate();
    var found_any = false;
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.indexOf(u8, entry.name, ".so") == null) continue;
        const file_abs = b.pathJoin(&.{ lib_dir_abs, entry.name });
        const cmd = b.addSystemCommand(&.{ "patchelf", "--set-rpath", "$ORIGIN", file_abs });
        group.dependOn(&cmd.step);
        found_any = true;
    }
    return if (found_any) group else null;
}

fn shadercWindowsBasePath(b: *std.Build, dep: *std.Build.Dependency) []const u8 {
    return b.graph.environ_map.get("VULKAN_SDK") orelse
        b.graph.environ_map.get("VK_SDK_PATH") orelse
        dep.builder.pathFromRoot("src/thirdparty/shaderc_windows_x64");
}

fn installRuntimeDirIfExists(
    b: *std.Build,
    source_dir_path: []const u8,
    install_to_default_step: bool,
) ?*std.Build.Step.InstallDir {
    if (std.fs.path.isAbsolute(source_dir_path)) {
        std.Io.Dir.accessAbsolute(b.graph.io, source_dir_path, .{}) catch return null;
    } else {
        std.Io.Dir.cwd().access(b.graph.io, source_dir_path, .{}) catch return null;
    }
    return installRuntimeDir(b, lazyPath(b, source_dir_path), install_to_default_step);
}

fn installRuntimeDir(
    b: *std.Build,
    source_dir: std.Build.LazyPath,
    install_to_default_step: bool,
) *std.Build.Step.InstallDir {
    const install = b.addInstallDirectory(.{
        .source_dir = source_dir,
        .install_dir = .bin,
        .install_subdir = "",
    });
    if (install_to_default_step) b.getInstallStep().dependOn(&install.step);
    return install;
}

fn lazyPath(b: *std.Build, path: []const u8) std.Build.LazyPath {
    return if (std.fs.path.isAbsolute(path)) .{ .cwd_relative = path } else b.path(path);
}

fn appendPath(b: *std.Build, prefix: ?[]const u8, path: []const u8) []const u8 {
    return if (prefix) |p|
        b.fmt("{s}{c}{s}", .{ p, std.fs.path.delimiter, path })
    else
        path;
}
