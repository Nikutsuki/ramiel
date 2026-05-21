# GPU Shaders

Run your own GLSL on the GPU. Shaders are compiled to SPIR-V **at runtime** (via
vendored libshaderc), so you pass source as a string or `@embedFile` a `.comp` /
`.frag` file — no build step.

Three entry points, all on `Application`:

| API | Shader stage | Use for |
|---|---|---|
| `createComputeCanvas` | compute | generate or edit an image on the GPU, displayed live |
| `runComputeFilter` | compute | one-shot pixels-in -> pixels-out (read result back to CPU) |
| `createShaderCanvas` | fragment | shadertoy-style backgrounds / visual effects |

The first and third return a `*Canvas`, displayed like any canvas:
`ux.canvas(.{ .target = canvas })`.

## Shared uniform ABI

Every shader binds the same uniform block. The host fills `resolution`, `time`
(seconds), `delta`, and `frame`; `user[8]` is yours to set from app code.

```glsl
layout(set = 0, binding = 1) uniform Uniforms {  // binding 0 for fragment shaders
    vec2 resolution;
    float time;
    float delta;
    uint frame;
    vec4 user[8];
} u;
```

Set `user[]` from the app: `canvas.setParam(index, .{ x, y, z, w })`.

## Compute canvas

A compute shader writes a storage image that the canvas samples. Bindings:
`image2D` (output) at `binding 0`, the uniform block at `binding 1`, and an
optional input `sampler2D` at `binding 2`.

```glsl
#version 450
layout(local_size_x = 8, local_size_y = 8) in;
layout(rgba8, set = 0, binding = 0) uniform image2D dst;
layout(set = 0, binding = 1) uniform Uniforms { vec2 resolution; float time; float delta; uint frame; vec4 user[8]; } u;
layout(set = 0, binding = 2) uniform sampler2D src;  // omit if no input

void main() {
    ivec2 p = ivec2(gl_GlobalInvocationID.xy);
    if (p.x >= int(u.resolution.x) || p.y >= int(u.resolution.y)) return;
    vec2 uv = (vec2(p) + 0.5) / u.resolution;
    imageStore(dst, p, vec4(uv, 0.5 + 0.5 * sin(u.time), 1.0));
}
```

```zig
const src = @embedFile("shaders/plasma.comp");
const canvas = try app.createComputeCanvas(640, 640, src, null);
// with an input image to transform:
const canvas2 = try app.createComputeCanvas(w, h, src, .{ .pixels = rgba, .width = w, .height = h });
```

Dispatch is `ceil(width/8) x ceil(height/8)`, so use `local_size_x = 8,
local_size_y = 8`. The compute runs every drawn frame; for animation keep the
frame loop painting (a `tick` returning `.repaint`).

`createComputeCanvasSpirv(width, height, spirv, input)` takes precompiled
`[]const u32` if you compiled elsewhere.

## One-shot compute filter

Synchronous pixels-in -> pixels-out. Uses the same compute ABI; runs the
shader once and copies the result back to CPU. Good for applying a GPU filter
to an existing image (see `examples/canvas_app`, the `gpu*` palette commands).

```zig
try app.runComputeFilter(glsl, width, height, input_pixels, output_pixels, &.{});
// params -> user[]: pass a slice of up to 8 vec4s
```

`input_pixels` and `output_pixels` are RGBA, `width * height * 4` bytes each.

## Fragment background

A fragment shader rendered into an offscreen texture, sampled by the canvas.
You write only the fragment shader; the library supplies the fullscreen-triangle
vertex shader. Bindings: uniform block at `binding 0`, optional input
`sampler2D` at `binding 1`. Output is `location 0`.

```glsl
#version 450
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 frag_color;
layout(set = 0, binding = 0) uniform Uniforms { vec2 resolution; float time; float delta; uint frame; vec4 user[8]; } u;

void main() {
    frag_color = vec4(0.5 + 0.5 * cos(u.time + uv.xyx + vec3(0, 2, 4)), 1.0);
}
```

```zig
const bg = try app.createShaderCanvas(1280, 720, @embedFile("shaders/swirl.frag"), null);
```

Layer UI over it with the canvas node's children:

```zig
ux.canvas(.{ .class = .{ tw.w_full, tw.h_full, tw.items_center, tw.justify_center },
    .target = bg, .children = &.{ try ux.text(.{ .content = "hi", .font = font }) } });
```

The canvas draws its texture centered at scale 1 (no stretch-to-fit), so for a
full-window background size the render target to the window and resize it when
the window changes:

```zig
fn tick(app: *App) lib.UpdateAction {
    const fb = app.getFramebufferSize();
    if (app.state.bg) |bg| app.resizeShaderCanvas(bg, @intCast(fb.width), @intCast(fb.height)) catch {};
    return .repaint;
}
```

`resizeShaderCanvas` is a no-op when the size is unchanged, so calling it every
frame is fine.

## Compiling directly

`ramiel.ShaderCompiler` wraps the runtime compiler if you want SPIR-V yourself:

```zig
var compiler = try ramiel.ShaderCompiler.init();
defer compiler.deinit();
var diagnostic: []u8 = &.{};
const spirv = compiler.compile(allocator, source, .compute, "name", &diagnostic) catch |err| {
    if (diagnostic.len > 0) std.log.err("{s}", .{diagnostic}); // free diagnostic when set
    return err;
};
defer allocator.free(spirv);
```

Stages: `.vertex`, `.fragment`, `.compute`. `compileFile(allocator, io, path,
stage, diagnostic)` reads and compiles a file. A compile error returns
`error.CompilationFailed` and, if you passed a non-null `diagnostic`, allocates
the human-readable message into it (you free it).

## Examples

- `examples/shader_canvas/` — auto-cycles compute filters over a procedural image
- `examples/shader_background/` — full-window animated fragment background, resizes with the window
- `examples/canvas_app/` — `gpugray` / `gpuinvert` / `gpuedge` / `gpuemboss` palette commands run GPU filters next to the CPU ones

## Notes

- libshaderc is vendored per platform under `src/thirdparty/shaderc_<platform>/`
  (headers committed, prebuilt binary gitignored), linked like the FFmpeg
  dependency. `run-*` targets put it on the runtime library path; `zig build
  test` needs `src/thirdparty/shaderc_linux_x64/lib` on `LD_LIBRARY_PATH`.
- Compute targets Vulkan 1.2 / SPIR-V 1.5.
- The compute-canvas input image is set at creation (static). For per-frame
  input, prefer `runComputeFilter`.
