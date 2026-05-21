const std = @import("std");

const c = @cImport({
    @cInclude("shaderc/shaderc.h");
});

pub const Stage = enum {
    vertex,
    fragment,
    compute,

    fn kind(self: Stage) c.shaderc_shader_kind {
        return switch (self) {
            .vertex => c.shaderc_glsl_vertex_shader,
            .fragment => c.shaderc_glsl_fragment_shader,
            .compute => c.shaderc_glsl_compute_shader,
        };
    }
};

pub const Error = error{
    CompilerInitFailed,
    CompilationFailed,
    OutOfMemory,
};

pub const Compiler = struct {
    handle: c.shaderc_compiler_t,

    pub fn init() Error!Compiler {
        const handle = c.shaderc_compiler_initialize() orelse return error.CompilerInitFailed;
        return .{ .handle = handle };
    }

    pub fn deinit(self: *Compiler) void {
        c.shaderc_compiler_release(self.handle);
        self.handle = null;
    }

    pub fn compile(
        self: *Compiler,
        allocator: std.mem.Allocator,
        source: []const u8,
        stage: Stage,
        name: []const u8,
        diagnostic: ?*[]u8,
    ) Error![]u32 {
        const options = c.shaderc_compile_options_initialize();
        defer c.shaderc_compile_options_release(options);
        c.shaderc_compile_options_set_source_language(options, c.shaderc_source_language_glsl);
        c.shaderc_compile_options_set_target_env(options, c.shaderc_target_env_vulkan, c.shaderc_env_version_vulkan_1_2);
        c.shaderc_compile_options_set_target_spirv(options, c.shaderc_spirv_version_1_5);
        c.shaderc_compile_options_set_optimization_level(options, c.shaderc_optimization_level_performance);

        const name_z = try allocator.dupeZ(u8, name);
        defer allocator.free(name_z);

        const result = c.shaderc_compile_into_spv(
            self.handle,
            source.ptr,
            source.len,
            stage.kind(),
            name_z.ptr,
            "main",
            options,
        );
        defer c.shaderc_result_release(result);

        if (c.shaderc_result_get_compilation_status(result) != c.shaderc_compilation_status_success) {
            if (diagnostic) |out| {
                const msg = c.shaderc_result_get_error_message(result);
                out.* = try allocator.dupe(u8, std.mem.span(msg));
            }
            return error.CompilationFailed;
        }

        const byte_len = c.shaderc_result_get_length(result);
        const bytes = c.shaderc_result_get_bytes(result);
        const words = try allocator.alloc(u32, byte_len / 4);
        @memcpy(std.mem.sliceAsBytes(words), bytes[0..byte_len]);
        return words;
    }

    pub fn compileFile(
        self: *Compiler,
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
        stage: Stage,
        diagnostic: ?*[]u8,
    ) (Error || std.Io.Dir.ReadFileAllocError)![]u32 {
        const source = try std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, path, allocator, .limited(8 * 1024 * 1024));
        defer allocator.free(source);
        return self.compile(allocator, source, stage, path, diagnostic);
    }
};

test "compile a trivial compute shader" {
    var compiler = try Compiler.init();
    defer compiler.deinit();

    const src =
        \\#version 450
        \\layout(local_size_x = 1) in;
        \\void main() {}
    ;
    const spirv = try compiler.compile(std.testing.allocator, src, .compute, "test.comp", null);
    defer std.testing.allocator.free(spirv);
    try std.testing.expect(spirv.len > 0);
    try std.testing.expectEqual(@as(u32, 0x07230203), spirv[0]);
}

test "compilation error surfaces diagnostic" {
    var compiler = try Compiler.init();
    defer compiler.deinit();

    var diag: []u8 = &.{};
    const bad = "#version 450\nthis is not glsl";
    const result = compiler.compile(std.testing.allocator, bad, .fragment, "bad.frag", &diag);
    try std.testing.expectError(error.CompilationFailed, result);
    defer std.testing.allocator.free(diag);
    try std.testing.expect(diag.len > 0);
}
