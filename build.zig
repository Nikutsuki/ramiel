const std = @import("std");
const wayland_build = @import("wayland");

pub const build_support = @import("build_support.zig");

fn applyWindowsCImportWorkarounds(root_module: *std.Build.Module) void {
    root_module.addCMacro("_FORTIFY_SOURCE", "0");
    root_module.addCMacro("__MINGW_FORTIFY_LEVEL", "0");
    root_module.addCMacro("__CRT__NO_INLINE", "1");
    root_module.addCMacro("__STDC_WANT_SECURE_LIB__", "0");
}

fn lazyPath(b: *std.Build, path: []const u8) std.Build.LazyPath {
    return if (std.fs.path.isAbsolute(path)) .{ .cwd_relative = path } else b.path(path);
}

fn pathExists(b: *std.Build, path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(b.graph.io, path, .{}) catch return false;
    } else {
        std.Io.Dir.cwd().access(b.graph.io, path, .{}) catch return false;
    }
    return true;
}

fn detectWayland(b: *std.Build) bool {
    var code: u8 = undefined;
    const out = b.runAllowFail(
        &.{ "pkg-config", "--exists", "wayland-client", "wayland-cursor", "xkbcommon" },
        &code,
        .ignore,
    ) catch return false;
    b.allocator.free(out);
    return code == 0;
}

const ExampleTarget = struct {
    name: []const u8,
    path: []const u8,
    requires_network: bool = false,
    requires_shell32: bool = false,
    requires_wayland: bool = false,
    /// With -Dhot-reload, also build <name>-host + libapp_<name>.so from the dir's
    /// host_main.zig + app_lib.zig.
    hot_reloadable: bool = false,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const is_windows = target.result.os.tag == .windows;
    const is_linux = target.result.os.tag == .linux;

    const tracy_enabled = b.option(bool, "tracy", "Build with Tracy memory allocation profiling.") orelse false;
    const devtools_enabled = b.option(bool, "devtools", "Enable DevTools.") orelse false;
    const requested_wayland = b.option(bool, "wayland", "Enable the native Wayland backend and Wayland-only examples (auto-detected on Linux when the Wayland dev libraries are present).") orelse (is_linux and detectWayland(b));
    const native_wayland_enabled = requested_wayland and is_linux;
    const hot_reload = b.option(bool, "hot-reload", "Build hot-reloadable examples as a swappable shared library + thin host.") orelse false;
    const ffmpeg_prebuilt = b.option(bool, "ffmpeg-prebuilt", "Fetch precompiled FFmpeg from the ffmpeg-ramiel release instead of building from source (default true).") orelse true;
    const build_options = b.addOptions();
    build_options.addOption(bool, "devtools", devtools_enabled);
    build_options.addOption(bool, "native_wayland", native_wayland_enabled);
    const build_options_module = build_options.createModule();
    var shaderc_bin_install: ?*std.Build.Step = null;

    // Dependencies
    const zglfw_dep = b.dependency("zglfw", .{ .target = target, .optimize = optimize });
    const glfw_c_dep = b.dependency("glfw_zig", .{ .target = target, .optimize = optimize });
    const harfbuzz_dep = b.dependency("harfbuzz", .{ .target = target, .optimize = optimize, .@"enable-freetype" = true });
    const freetype_dep = b.dependency("freetype", .{ .target = target, .optimize = optimize, .@"enable-libpng" = true });
    const msdfgen_dep = b.dependency("msdfgen", .{ .target = target, .optimize = optimize });
    const tracy_dep = b.dependency("tracy", .{ .target = target, .optimize = optimize });
    const nfd_dep = b.dependency("nfd", .{ .target = target, .optimize = optimize });
    const zig_wss = b.dependency("zig_wss", .{ .target = target, .optimize = optimize });
    const zbench_dep = b.dependency("zbench", .{ .target = target, .optimize = optimize });

    const vk_proto = b.addModule("vulkan-zig", .{ .root_source_file = b.path("src/vk.zig") });
    const nfd_mod = nfd_dep.module("nfd");
    const glfw_mod = zglfw_dep.module("glfw");
    const wss_mod = zig_wss.module("zig_wss");
    const tracy_impl_module = if (tracy_enabled) tracy_dep.module("tracy_impl_enabled") else tracy_dep.module("tracy_impl_disabled");

    // Wayland protocol scanner (Linux-only, for native Wayland examples/backend)
    const wayland_mod: ?*std.Build.Module = if (native_wayland_enabled) blk: {
        const scanner = wayland_build.Scanner.create(b, .{
            .wayland_xml = b.path("protocols/wayland.xml"),
        });

        scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
        scanner.addCustomProtocol(b.path("protocols/wlr-layer-shell-unstable-v1.xml"));

        scanner.generate("wl_compositor", 6);
        scanner.generate("wl_shm", 1);
        scanner.generate("wl_seat", 9);
        scanner.generate("wl_output", 4);
        scanner.generate("xdg_wm_base", 6);
        scanner.generate("zwlr_layer_shell_v1", 5);

        break :blk b.createModule(.{
            .root_source_file = scanner.result,
            .target = target,
            .optimize = optimize,
        });
    } else null;

    // Core Library Module
    const ramiel_mod = b.addModule("ramiel", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });

    if (is_windows) applyWindowsCImportWorkarounds(ramiel_mod);

    ramiel_mod.addImport("glfw", glfw_mod);
    ramiel_mod.addImport("vk", vk_proto);
    ramiel_mod.addImport("nfd", nfd_mod);
    ramiel_mod.addImport("tracy", tracy_dep.module("tracy"));
    ramiel_mod.addImport("tracy_impl", tracy_impl_module);
    ramiel_mod.addImport("build_options", build_options_module);
    if (wayland_mod) |wl_mod| {
        ramiel_mod.addImport("wayland", wl_mod);
        ramiel_mod.linkSystemLibrary("wayland-client", .{});
        ramiel_mod.linkSystemLibrary("wayland-cursor", .{});
        ramiel_mod.linkSystemLibrary("xkbcommon", .{});
    }

    ramiel_mod.linkLibrary(glfw_c_dep.artifact("glfw"));
    ramiel_mod.linkLibrary(harfbuzz_dep.artifact("harfbuzz"));
    ramiel_mod.linkLibrary(freetype_dep.artifact("freetype"));

    if (is_windows) {
        ramiel_mod.linkSystemLibrary("user32", .{});
        ramiel_mod.linkSystemLibrary("dwmapi", .{});
        ramiel_mod.linkSystemLibrary("d3d11", .{});
        ramiel_mod.linkSystemLibrary("dxgi", .{});
        ramiel_mod.linkSystemLibrary("dcomp", .{});
        ramiel_mod.addCSourceFile(.{
            .file = b.path("src/window/dxgi_overlay.cpp"),
            .flags = &[_][]const u8{"-std=c++17"},
        });
    }

    // Third-party Includes & Sources
    ramiel_mod.addSystemIncludePath(b.path("src/thirdparty/vma"));
    ramiel_mod.addCSourceFile(.{ .file = b.path("src/thirdparty/vma/vma.cpp"), .flags = &[_][]const u8{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });

    ramiel_mod.addSystemIncludePath(b.path("src/thirdparty/stb_image"));
    ramiel_mod.addCSourceFile(.{ .file = b.path("src/thirdparty/stb_image/stb_image.cpp"), .flags = &[_][]const u8{ "-std=c++17", "-fno-sanitize=alignment" } });

    ramiel_mod.addSystemIncludePath(b.path("src/thirdparty/nanosvg"));
    ramiel_mod.addCSourceFile(.{ .file = b.path("src/thirdparty/nanosvg/nanosvg_impl.c"), .flags = &[_][]const u8{"-std=c99"} });

    ramiel_mod.addSystemIncludePath(b.path("src/thirdparty/miniaudio"));
    ramiel_mod.addCSourceFile(.{ .file = b.path("src/thirdparty/miniaudio/miniaudio_impl.c"), .flags = &[_][]const u8{ "-std=c99", "-O3", "-fno-sanitize=undefined" } });

    const ffmpeg_dep = b.dependency("ffmpeg", .{ .prebuilt = ffmpeg_prebuilt });
    ramiel_mod.addSystemIncludePath(ffmpeg_dep.namedLazyPath("include"));
    ramiel_mod.addObjectFile(ffmpeg_dep.namedLazyPath("libavformat"));
    ramiel_mod.addObjectFile(ffmpeg_dep.namedLazyPath("libavcodec"));
    ramiel_mod.addObjectFile(ffmpeg_dep.namedLazyPath("libdav1d"));
    ramiel_mod.addObjectFile(ffmpeg_dep.namedLazyPath("libswresample"));
    ramiel_mod.addObjectFile(ffmpeg_dep.namedLazyPath("libavutil"));

    const shaderc_base_path = switch (target.result.os.tag) {
        .windows => b.option([]const u8, "shaderc-sdk", "Path to a Shaderc/Vulkan SDK root on Windows (defaults to VULKAN_SDK or VK_SDK_PATH).") orelse
            b.graph.environ_map.get("VULKAN_SDK") orelse
            b.graph.environ_map.get("VK_SDK_PATH") orelse
            "src/thirdparty/shaderc_windows_x64",
        .linux => "src/thirdparty/shaderc_linux_x64",
        else => @panic("Unsupported OS for libshaderc integration"),
    };
    ramiel_mod.addSystemIncludePath(lazyPath(b, b.pathJoin(&.{ shaderc_base_path, "include" })));
    ramiel_mod.addLibraryPath(lazyPath(b, b.pathJoin(&.{ shaderc_base_path, "lib" })));
    ramiel_mod.linkSystemLibrary("shaderc_shared", .{ .use_pkg_config = .no });

    switch (target.result.os.tag) {
        .macos => {
            ramiel_mod.linkFramework("CoreAudio", .{});
            ramiel_mod.linkFramework("AudioToolbox", .{});
            ramiel_mod.linkFramework("CoreFoundation", .{});
        },
        .linux => {
            ramiel_mod.linkSystemLibrary("pthread", .{});
            ramiel_mod.linkSystemLibrary("m", .{});
            ramiel_mod.linkSystemLibrary("dl", .{});
            const install_shaderc_lib = b.addInstallDirectory(.{
                .source_dir = lazyPath(b, b.pathJoin(&.{ shaderc_base_path, "lib" })),
                .install_dir = .lib,
                .install_subdir = "",
            });
            b.getInstallStep().dependOn(&install_shaderc_lib.step);
        },
        .windows => {
            ramiel_mod.linkSystemLibrary("bcrypt", .{});
            ramiel_mod.linkSystemLibrary("secur32", .{});
            ramiel_mod.linkSystemLibrary("ws2_32", .{});

            const shaderc_dll_path = b.pathJoin(&.{ shaderc_base_path, "bin", "shaderc_shared.dll" });
            if (pathExists(b, shaderc_dll_path)) {
                const install_shaderc_dll = b.addInstallBinFile(lazyPath(b, shaderc_dll_path), "shaderc_shared.dll");
                b.getInstallStep().dependOn(&install_shaderc_dll.step);
                shaderc_bin_install = &install_shaderc_dll.step;
            }
        },
        else => {},
    }

    const bindRunEnvironment = struct {
        fn apply(
            builder: *std.Build,
            run_cmd: *std.Build.Step.Run,
            shaderc_install: ?*std.Build.Step,
            is_win: bool,
        ) void {
            if (is_win) {
                const step = shaderc_install orelse return;
                run_cmd.step.dependOn(step);

                const env = run_cmd.getEnvMap();
                const current_path = env.get("PATH") orelse "";
                const install_bin = builder.getInstallPath(.bin, "");
                env.put(
                    "PATH",
                    builder.fmt("{s}{c}{s}", .{ install_bin, std.fs.path.delimiter, current_path }),
                ) catch @panic("OOM");
            } else {
                const env = run_cmd.getEnvMap();
                const current_ld = env.get("LD_LIBRARY_PATH") orelse "";
                const shaderc_lib = builder.pathJoin(&.{"src/thirdparty/shaderc_linux_x64/lib"});
                env.put(
                    "LD_LIBRARY_PATH",
                    builder.fmt("{s}{c}{s}", .{ shaderc_lib, std.fs.path.delimiter, current_ld }),
                ) catch @panic("OOM");
            }
        }
    }.apply;

    // MSDFGen Integration
    const msdf_flags = &[_][]const u8{ "-std=c++17", "-DMSDFGEN_USE_CPP11", "-DMSDFGEN_PUBLIC=", "-DMSDFGEN_EXT_PUBLIC=", "-DMSDFGEN_EXTENSIONS", "-DMSDFGEN_DISABLE_SVG", "-DMSDFGEN_DISABLE_PNG" };
    ramiel_mod.addSystemIncludePath(msdfgen_dep.path(""));

    const msdf_core_sources = [_][]const u8{
        "core/contour-combiners.cpp",    "core/Contour.cpp",               "core/convergent-curve-ordering.cpp",
        "core/DistanceMapping.cpp",      "core/edge-coloring.cpp",         "core/edge-segments.cpp",
        "core/edge-selectors.cpp",       "core/EdgeHolder.cpp",            "core/equation-solver.cpp",
        "core/export-svg.cpp",           "core/msdf-error-correction.cpp", "core/MSDFErrorCorrection.cpp",
        "core/msdfgen.cpp",              "core/Projection.cpp",            "core/rasterization.cpp",
        "core/render-sdf.cpp",           "core/save-bmp.cpp",              "core/save-fl32.cpp",
        "core/save-rgba.cpp",            "core/save-tiff.cpp",             "core/Scanline.cpp",
        "core/sdf-error-estimation.cpp", "core/shape-description.cpp",     "core/Shape.cpp",
    };
    for (msdf_core_sources) |src| ramiel_mod.addCSourceFile(.{ .file = msdfgen_dep.path(src), .flags = msdf_flags });
    ramiel_mod.addCSourceFile(.{ .file = msdfgen_dep.path("ext/import-font.cpp"), .flags = msdf_flags });
    ramiel_mod.addCSourceFile(.{ .file = b.path("src/renderer/font/msdf_bridge.cpp"), .flags = msdf_flags });

    // Shader Compilation
    const shader_compile_step = b.step("shaders", "Compile Vulkan shaders");
    const shaders = [_]struct { input: []const u8, output: []const u8 }{
        .{ .input = "shader.vert", .output = "vert.spv" },
        .{ .input = "shader.frag", .output = "frag.spv" },
        .{ .input = "kawase.vert", .output = "kawase.vert.spv" },
        .{ .input = "kawase.frag", .output = "kawase.frag.spv" },
        .{ .input = "video.frag", .output = "video.frag.spv" },
    };
    for (shaders) |shader| {
        const cmd = b.addSystemCommand(&.{ "glslc", b.fmt("src/renderer/vulkan/shaders/{s}", .{shader.input}), "-o", b.fmt("src/renderer/vulkan/shaders/{s}", .{shader.output}) });
        cmd.addFileInput(b.path(b.fmt("src/renderer/vulkan/shaders/{s}", .{shader.input})));
        shader_compile_step.dependOn(&cmd.step);
    }

    // Shared Executable Configuration Logic
    const bindExecutableConfig = struct {
        fn apply(
            exe: *std.Build.Step.Compile,
            base_mod: *std.Build.Module,
            opt: struct {
                nfd: *std.Build.Module,
                glfw: *std.Build.Module,
                tracy: *std.Build.Module,
                tracy_impl: *std.Build.Module,
                wss: *std.Build.Module,
                build_options: *std.Build.Module,
                wayland: ?*std.Build.Module = null,
                is_win: bool,
                net: bool,
                shell: bool,
            },
        ) void {
            const m = exe.root_module;
            m.addImport("ramiel", base_mod);
            m.addImport("glfw", opt.glfw);
            m.addImport("nfd", opt.nfd);
            m.addImport("tracy", opt.tracy);
            m.addImport("tracy_impl", opt.tracy_impl);
            m.addImport("build_options", opt.build_options);

            if (opt.wayland) |wl_mod| {
                m.addImport("wayland", wl_mod);
                m.linkSystemLibrary("wayland-client", .{});
                m.linkSystemLibrary("wayland-cursor", .{});
                m.linkSystemLibrary("gio-2.0", .{});
            }

            if (opt.is_win) applyWindowsCImportWorkarounds(m);

            if (opt.net) {
                m.addImport("wss", opt.wss);
                if (opt.is_win) {
                    m.addIncludePath(.{ .cwd_relative = "C:/msys64/ucrt64/include" });

                    m.linkSystemLibrary("ws2_32", .{});
                    m.linkSystemLibrary("crypt32", .{});

                    // Link OpenSSL explicitly by absolute path to avoid search collisions
                    m.addObjectFile(.{ .cwd_relative = "C:/msys64/ucrt64/lib/libssl.dll.a" });
                    m.addObjectFile(.{ .cwd_relative = "C:/msys64/ucrt64/lib/libcrypto.dll.a" });
                } else {
                    m.linkSystemLibrary("ssl", .{});
                    m.linkSystemLibrary("crypto", .{});
                }
            }

            if (opt.shell and opt.is_win) {
                m.linkSystemLibrary("shell32", .{});
            }
        }
    }.apply;

    // Base Check Step
    const check_step = b.step("check", "Check project compilation for editor diagnostics");

    // Base Library Executable
    const main_exe = b.addExecutable(.{
        .name = "ramiel",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize }),
    });
    main_exe.step.dependOn(shader_compile_step);
    bindExecutableConfig(main_exe, ramiel_mod, .{ .nfd = nfd_mod, .glfw = glfw_mod, .tracy = tracy_dep.module("tracy"), .tracy_impl = tracy_impl_module, .wss = wss_mod, .build_options = build_options_module, .is_win = is_windows, .net = false, .shell = false });
    b.installArtifact(main_exe);

    const run_cmd = b.addRunArtifact(main_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    bindRunEnvironment(b, run_cmd, shaderc_bin_install, is_windows);
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run the app").dependOn(&run_cmd.step);

    const main_exe_check = b.addExecutable(.{
        .name = "ramiel_check",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize }),
    });
    main_exe_check.step.dependOn(shader_compile_step);
    bindExecutableConfig(main_exe_check, ramiel_mod, .{ .nfd = nfd_mod, .glfw = glfw_mod, .tracy = tracy_dep.module("tracy"), .tracy_impl = tracy_impl_module, .wss = wss_mod, .build_options = build_options_module, .is_win = is_windows, .net = false, .shell = false });
    check_step.dependOn(&main_exe_check.step);

    // Target Generation
    const examples = [_]ExampleTarget{
        .{ .name = "discord_client", .path = "examples/discord_client/main.zig", .requires_network = true },
        .{ .name = "box_sizing", .path = "examples/box_sizing/main.zig" },
        .{ .name = "animation", .path = "examples/animation/main.zig" },
        .{ .name = "overlay", .path = "examples/overlay/main.zig", .requires_shell32 = true },
        .{ .name = "canvas_app", .path = "examples/canvas_app/main.zig" },
        .{ .name = "shader_canvas", .path = "examples/shader_canvas/main.zig" },
        .{ .name = "shader_background", .path = "examples/shader_background/main.zig" },
        .{ .name = "pointer_capture", .path = "examples/pointer_capture/main.zig", .hot_reloadable = true },
        .{ .name = "managed", .path = "examples/managed/main.zig", .hot_reloadable = true },
        .{ .name = "components_showcase", .path = "examples/components_showcase/main.zig" },
        .{ .name = "video_player", .path = "examples/video_player/main.zig" },
        .{ .name = "tree", .path = "examples/tree/main.zig" },
        .{ .name = "file_explorer", .path = "examples/file_explorer/main.zig" },
        .{ .name = "plot", .path = "examples/plot/main.zig" },
        .{ .name = "audio_player", .path = "examples/audio_player/main.zig" },
        .{ .name = "typography", .path = "examples/typography/main.zig" },
        .{ .name = "desktop_shell", .path = "examples/desktop_shell/main.zig", .requires_wayland = true },
    };

    for (examples) |ex| {
        if (ex.requires_wayland and !native_wayland_enabled) continue;

        // Compile Check Step (ZLS Diagnostics)
        const ex_check = b.addExecutable(.{
            .name = b.fmt("{s}_check", .{ex.name}),
            .root_module = b.createModule(.{ .root_source_file = b.path(ex.path), .target = target, .optimize = optimize }),
        });
        ex_check.step.dependOn(shader_compile_step);
        const wl_mod: ?*std.Build.Module = if (ex.requires_wayland) wayland_mod else null;
        bindExecutableConfig(ex_check, ramiel_mod, .{ .nfd = nfd_mod, .glfw = glfw_mod, .tracy = tracy_dep.module("tracy"), .tracy_impl = tracy_impl_module, .wss = wss_mod, .build_options = build_options_module, .wayland = wl_mod, .is_win = is_windows, .net = ex.requires_network, .shell = ex.requires_shell32 });
        if (std.mem.eql(u8, ex.name, "desktop_shell")) {
            ex_check.root_module.addCSourceFile(.{ .file = b.path("examples/desktop_shell/modules/tray_sni.c"), .flags = &.{"-std=c99"} });
        }
        check_step.dependOn(&ex_check.step);

        // Standard Artifact Step
        const ex_exe = b.addExecutable(.{
            .name = ex.name,
            .root_module = b.createModule(.{ .root_source_file = b.path(ex.path), .target = target, .optimize = optimize, .link_libc = ex.requires_wayland }),
        });
        ex_exe.step.dependOn(shader_compile_step);
        bindExecutableConfig(ex_exe, ramiel_mod, .{ .nfd = nfd_mod, .glfw = glfw_mod, .tracy = tracy_dep.module("tracy"), .tracy_impl = tracy_impl_module, .wss = wss_mod, .build_options = build_options_module, .wayland = wl_mod, .is_win = is_windows, .net = ex.requires_network, .shell = ex.requires_shell32 });
        if (std.mem.eql(u8, ex.name, "desktop_shell")) {
            ex_exe.root_module.addCSourceFile(.{ .file = b.path("examples/desktop_shell/modules/tray_sni.c"), .flags = &.{"-std=c99"} });
        }
        b.installArtifact(ex_exe);

        const kebab = std.mem.replaceOwned(u8, b.allocator, ex.name, "_", "-") catch @panic("OOM");
        if (!(hot_reload and ex.hot_reloadable)) {
            const run_ex_cmd = b.addRunArtifact(ex_exe);
            bindRunEnvironment(b, run_ex_cmd, shaderc_bin_install, is_windows);
            if (b.args) |args| run_ex_cmd.addArgs(args);
            b.step(b.fmt("run-{s}", .{kebab}), b.fmt("Run the {s} example", .{ex.name})).dependOn(&run_ex_cmd.step);
        }

        if (hot_reload and ex.hot_reloadable) {
            const ex_dir = std.fs.path.dirname(ex.path).?;
            const lib_name = b.fmt("app_{s}", .{ex.name});

            const app_lib = b.addLibrary(.{
                .name = lib_name,
                .linkage = .dynamic,
                .root_module = b.createModule(.{
                    .root_source_file = b.path(b.fmt("{s}/app_lib.zig", .{ex_dir})),
                    .target = target,
                    .optimize = optimize,
                    .link_libc = true,
                }),
            });
            app_lib.step.dependOn(shader_compile_step);
            bindExecutableConfig(app_lib, ramiel_mod, .{ .nfd = nfd_mod, .glfw = glfw_mod, .tracy = tracy_dep.module("tracy"), .tracy_impl = tracy_impl_module, .wss = wss_mod, .build_options = build_options_module, .wayland = wl_mod, .is_win = is_windows, .net = ex.requires_network, .shell = ex.requires_shell32 });
            const install_app_lib = b.addInstallArtifact(app_lib, .{});
            b.getInstallStep().dependOn(&install_app_lib.step);

            const host_exe = b.addExecutable(.{
                .name = b.fmt("{s}-host", .{ex.name}),
                .root_module = b.createModule(.{
                    .root_source_file = b.path(b.fmt("{s}/host_main.zig", .{ex_dir})),
                    .target = target,
                    .optimize = optimize,
                    .link_libc = ex.requires_wayland,
                }),
            });
            host_exe.step.dependOn(shader_compile_step);
            bindExecutableConfig(host_exe, ramiel_mod, .{ .nfd = nfd_mod, .glfw = glfw_mod, .tracy = tracy_dep.module("tracy"), .tracy_impl = tracy_impl_module, .wss = wss_mod, .build_options = build_options_module, .wayland = wl_mod, .is_win = is_windows, .net = ex.requires_network, .shell = ex.requires_shell32 });
            const install_host = b.addInstallArtifact(host_exe, .{});
            b.getInstallStep().dependOn(&install_host.step);

            const lib_basename = if (is_windows)
                b.fmt("{s}.dll", .{lib_name})
            else
                b.fmt("lib{s}.so", .{lib_name});

            const hot_target = b.fmt("hot-{s}", .{kebab});
            const hot_lib_target = b.fmt("hot-{s}-lib", .{kebab});

            const build_lib_step = b.step(
                hot_lib_target,
                b.fmt("Build the {s} hot-reload lib only", .{ex.name}),
            );
            build_lib_step.dependOn(&install_app_lib.step);

            const build_host_step = b.step(
                hot_target,
                b.fmt("Build the {s} hot-reload host + lib", .{ex.name}),
            );
            build_host_step.dependOn(&install_app_lib.step);
            build_host_step.dependOn(&install_host.step);

            const run_host = b.addRunArtifact(host_exe);
            run_host.step.dependOn(&install_app_lib.step);
            run_host.step.dependOn(&install_host.step);
            bindRunEnvironment(b, run_host, shaderc_bin_install, is_windows);
            run_host.addArgs(&.{
                "--lib",          b.getInstallPath(if (is_windows) .bin else .lib, lib_basename),
                "--watch",        ex_dir,
                "--build-target", hot_lib_target,
            });
            if (b.args) |args| run_host.addArgs(args);
            b.step(
                b.fmt("run-{s}", .{kebab}),
                b.fmt("Run the {s} example with hot reload", .{ex.name}),
            ).dependOn(&run_host.step);
            b.step(
                b.fmt("run-{s}-host", .{kebab}),
                b.fmt("Run the {s} hot-reload host", .{ex.name}),
            ).dependOn(&run_host.step);
        }
    }

    // Isolated microbenchmark target(s).
    const reconcile_traverse_bench = b.addExecutable(.{
        .name = "reconcile_traverse_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/benchmarks/reconcile_traverse.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    reconcile_traverse_bench.root_module.addImport("zbench", zbench_dep.module("zbench"));
    reconcile_traverse_bench.root_module.addImport("ramiel", ramiel_mod);

    const run_bench = b.addRunArtifact(reconcile_traverse_bench);
    if (b.args) |args| run_bench.addArgs(args);

    const bench_step = b.step("bench", "Run microbenchmarks");
    bench_step.dependOn(&run_bench.step);

    // Testing
    const mod_tests = b.addTest(.{ .root_module = ramiel_mod });
    mod_tests.step.dependOn(shader_compile_step);
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{ .root_module = main_exe.root_module });
    exe_tests.step.dependOn(shader_compile_step);
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
