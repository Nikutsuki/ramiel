const std = @import("std");

fn applyWindowsCImportWorkarounds(root_module: *std.Build.Module) void {
    root_module.addCMacro("_FORTIFY_SOURCE", "0");
    root_module.addCMacro("__MINGW_FORTIFY_LEVEL", "0");
    root_module.addCMacro("__CRT__NO_INLINE", "1");
    root_module.addCMacro("__STDC_WANT_SECURE_LIB__", "0");
}

const ExampleTarget = struct {
    name: []const u8,
    path: []const u8,
    requires_network: bool = false,
    requires_shell32: bool = false,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const is_windows = target.result.os.tag == .windows;

    const tracy_enabled = b.option(bool, "tracy", "Build with Tracy memory allocation profiling.") orelse false;
    const devtools_enabled = b.option(bool, "devtools", "Enable DevTools overlay on startup.") orelse false;
    const build_options = b.addOptions();
    build_options.addOption(bool, "devtools", devtools_enabled);
    const build_options_module = build_options.createModule();

    // Dependencies
    const zglfw_dep = b.dependency("zglfw", .{ .target = target, .optimize = optimize });
    const glfw_c_dep = b.dependency("glfw_zig", .{ .target = target, .optimize = optimize });
    const harfbuzz_dep = b.dependency("harfbuzz", .{ .target = target, .optimize = optimize, .@"enable-freetype" = true });
    const freetype_dep = b.dependency("freetype", .{ .target = target, .optimize = optimize });
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

    // Core Library Module
    const mod_2d = b.addModule("ramiel", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });

    if (is_windows) applyWindowsCImportWorkarounds(mod_2d);

    mod_2d.addImport("glfw", glfw_mod);
    mod_2d.addImport("vk", vk_proto);
    mod_2d.addImport("nfd", nfd_mod);
    mod_2d.addImport("tracy", tracy_dep.module("tracy"));
    mod_2d.addImport("tracy_impl", tracy_impl_module);
    mod_2d.addImport("build_options", build_options_module);

    mod_2d.linkLibrary(glfw_c_dep.artifact("glfw"));
    mod_2d.linkLibrary(harfbuzz_dep.artifact("harfbuzz"));
    mod_2d.linkLibrary(freetype_dep.artifact("freetype"));

    if (is_windows) {
        mod_2d.linkSystemLibrary("user32", .{});
        mod_2d.linkSystemLibrary("dwmapi", .{});
        mod_2d.linkSystemLibrary("d3d11", .{});
        mod_2d.linkSystemLibrary("dxgi", .{});
        mod_2d.linkSystemLibrary("dcomp", .{});
        mod_2d.addCSourceFile(.{
            .file = b.path("src/window/dxgi_overlay.cpp"),
            .flags = &[_][]const u8{"-std=c++17"},
        });
    }

    // Third-party Includes & Sources
    mod_2d.addSystemIncludePath(b.path("src/thirdparty/vma"));
    mod_2d.addCSourceFile(.{ .file = b.path("src/thirdparty/vma/vma.cpp"), .flags = &[_][]const u8{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } });

    mod_2d.addSystemIncludePath(b.path("src/thirdparty/stb_image"));
    mod_2d.addCSourceFile(.{ .file = b.path("src/thirdparty/stb_image/stb_image.cpp"), .flags = &[_][]const u8{ "-std=c++17", "-fno-sanitize=alignment" } });

    mod_2d.addSystemIncludePath(b.path("src/thirdparty/nanosvg"));
    mod_2d.addCSourceFile(.{ .file = b.path("src/thirdparty/nanosvg/nanosvg_impl.c"), .flags = &[_][]const u8{"-std=c99"} });

    mod_2d.addSystemIncludePath(b.path("src/thirdparty/miniaudio"));
    mod_2d.addCSourceFile(.{ .file = b.path("src/thirdparty/miniaudio/miniaudio_impl.c"), .flags = &[_][]const u8{ "-std=c99", "-O3", "-fno-sanitize=undefined" } });

    // FFmpeg Integration
    const ffmpeg_base_path = switch (target.result.os.tag) {
        .windows => "src/thirdparty/ffmpeg_windows_x64",
        .linux => "src/thirdparty/ffmpeg_linux_x64",
        else => @panic("Unsupported OS for FFmpeg integration"),
    };
    mod_2d.addSystemIncludePath(b.path(b.fmt("{s}/include", .{ffmpeg_base_path})));
    mod_2d.addLibraryPath(b.path(b.fmt("{s}/lib", .{ffmpeg_base_path})));
    mod_2d.linkSystemLibrary("avcodec", .{ .use_pkg_config = .no });
    mod_2d.linkSystemLibrary("avformat", .{ .use_pkg_config = .no });
    mod_2d.linkSystemLibrary("avutil", .{ .use_pkg_config = .no });
    mod_2d.linkSystemLibrary("swresample", .{ .use_pkg_config = .no });

    switch (target.result.os.tag) {
        .macos => {
            mod_2d.linkFramework("CoreAudio", .{});
            mod_2d.linkFramework("AudioToolbox", .{});
            mod_2d.linkFramework("CoreFoundation", .{});
        },
        .linux => {
            mod_2d.linkSystemLibrary("pthread", .{});
            mod_2d.linkSystemLibrary("m", .{});
            mod_2d.linkSystemLibrary("dl", .{});
        },
        .windows => {
            mod_2d.linkSystemLibrary("bcrypt", .{});
            mod_2d.linkSystemLibrary("secur32", .{});
            mod_2d.linkSystemLibrary("ws2_32", .{});
            b.installDirectory(.{
                .source_dir = b.path(b.fmt("{s}/bin", .{ffmpeg_base_path})),
                .install_dir = .bin,
                .install_subdir = "",
            });
        },
        else => {},
    }

    // MSDFGen Integration
    const msdf_flags = &[_][]const u8{ "-std=c++17", "-DMSDFGEN_USE_CPP11", "-DMSDFGEN_PUBLIC=", "-DMSDFGEN_EXT_PUBLIC=", "-DMSDFGEN_EXTENSIONS", "-DMSDFGEN_DISABLE_SVG", "-DMSDFGEN_DISABLE_PNG" };
    mod_2d.addSystemIncludePath(msdfgen_dep.path(""));

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
    for (msdf_core_sources) |src| mod_2d.addCSourceFile(.{ .file = msdfgen_dep.path(src), .flags = msdf_flags });
    mod_2d.addCSourceFile(.{ .file = msdfgen_dep.path("ext/import-font.cpp"), .flags = msdf_flags });
    mod_2d.addCSourceFile(.{ .file = b.path("src/renderer/font/msdf_bridge.cpp"), .flags = msdf_flags });

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
    bindExecutableConfig(main_exe, mod_2d, .{ .nfd = nfd_mod, .glfw = glfw_mod, .tracy = tracy_dep.module("tracy"), .tracy_impl = tracy_impl_module, .wss = wss_mod, .build_options = build_options_module, .is_win = is_windows, .net = false, .shell = false });
    b.installArtifact(main_exe);

    const run_cmd = b.addRunArtifact(main_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run the app").dependOn(&run_cmd.step);

    const main_exe_check = b.addExecutable(.{
        .name = "ramiel_check",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize }),
    });
    main_exe_check.step.dependOn(shader_compile_step);
    bindExecutableConfig(main_exe_check, mod_2d, .{ .nfd = nfd_mod, .glfw = glfw_mod, .tracy = tracy_dep.module("tracy"), .tracy_impl = tracy_impl_module, .wss = wss_mod, .build_options = build_options_module, .is_win = is_windows, .net = false, .shell = false });
    check_step.dependOn(&main_exe_check.step);

    // Target Generation
    const examples = [_]ExampleTarget{
        .{ .name = "discord_client", .path = "examples/discord_client/main.zig", .requires_network = true },
        .{ .name = "box_sizing", .path = "examples/box_sizing/main.zig" },
        .{ .name = "animation", .path = "examples/animation/main.zig" },
        .{ .name = "overlay", .path = "examples/overlay/main.zig", .requires_shell32 = true },
        .{ .name = "canvas_app", .path = "examples/canvas_app/main.zig" },
        .{ .name = "pointer_capture", .path = "examples/pointer_capture/main.zig" },
        .{ .name = "components_showcase", .path = "examples/components_showcase/main.zig" },
        .{ .name = "video_player", .path = "examples/video_player/main.zig" },
        .{ .name = "tree", .path = "examples/tree/main.zig" },
        .{ .name = "file_explorer", .path = "examples/file_explorer/main.zig" },
        .{ .name = "plot", .path = "examples/plot/main.zig" },
        .{ .name = "audio_player", .path = "examples/audio_player/main.zig" },
    };

    for (examples) |ex| {
        // Compile Check Step (ZLS Diagnostics)
        const ex_check = b.addExecutable(.{
            .name = b.fmt("{s}_check", .{ex.name}),
            .root_module = b.createModule(.{ .root_source_file = b.path(ex.path), .target = target, .optimize = optimize }),
        });
        ex_check.step.dependOn(shader_compile_step);
        bindExecutableConfig(ex_check, mod_2d, .{ .nfd = nfd_mod, .glfw = glfw_mod, .tracy = tracy_dep.module("tracy"), .tracy_impl = tracy_impl_module, .wss = wss_mod, .build_options = build_options_module, .is_win = is_windows, .net = ex.requires_network, .shell = ex.requires_shell32 });
        check_step.dependOn(&ex_check.step);

        // Standard Artifact Step
        const ex_exe = b.addExecutable(.{
            .name = ex.name,
            .root_module = b.createModule(.{ .root_source_file = b.path(ex.path), .target = target, .optimize = optimize }),
        });
        ex_exe.step.dependOn(shader_compile_step);
        bindExecutableConfig(ex_exe, mod_2d, .{ .nfd = nfd_mod, .glfw = glfw_mod, .tracy = tracy_dep.module("tracy"), .tracy_impl = tracy_impl_module, .wss = wss_mod, .build_options = build_options_module, .is_win = is_windows, .net = ex.requires_network, .shell = ex.requires_shell32 });
        b.installArtifact(ex_exe);

        const run_ex_cmd = b.addRunArtifact(ex_exe);
        b.step(b.fmt("run-{s}", .{std.mem.replaceOwned(u8, b.allocator, ex.name, "_", "-") catch @panic("OOM")}), b.fmt("Run the {s} example", .{ex.name})).dependOn(&run_ex_cmd.step);
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
    reconcile_traverse_bench.root_module.addImport("ramiel", mod_2d);

    const run_bench = b.addRunArtifact(reconcile_traverse_bench);
    if (b.args) |args| run_bench.addArgs(args);

    const bench_step = b.step("bench", "Run microbenchmarks");
    bench_step.dependOn(&run_bench.step);

    // Testing
    const mod_tests = b.addTest(.{ .root_module = mod_2d });
    mod_tests.step.dependOn(shader_compile_step);
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{ .root_module = main_exe.root_module });
    exe_tests.step.dependOn(shader_compile_step);
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
