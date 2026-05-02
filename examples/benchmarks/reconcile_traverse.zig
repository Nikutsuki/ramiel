const std = @import("std");
const zbench = @import("zbench");
const lib = @import("ramiel");

const Message = enum { noop };
const T = lib.For(Message);
const Node = T.Node;
const UIContext = T.UIContext;
const layout = lib.layout;
const bench_prefetch = lib.bench_prefetch;

const base_tree_depth: usize = 6;
const base_tree_width: usize = 7;
const timer_iterations: usize = 64;
const reconcile_batches: usize = 3;
const traversal_batches: usize = 8;
const layout_batches: usize = 12;
const noisy_path_budget_ns: u64 = 8 * std.time.ns_per_s;
const noisy_path_max_iterations: u16 = 512;

const DummyTextLayouter = struct {
    const Metric = struct {
        x: f32,
        y: f32,
        width: f32,
        height: f32,
        byte_offset: usize,
        byte_length: usize,
        render_x: f32,
        render_y: f32,
        render_w: f32,
        render_h: f32,
        uv_min: [2]f32,
        uv_max: [2]f32,
        is_visible: bool,
    };

    pub fn measureText(_: *DummyTextLayouter, _: std.mem.Allocator, _: anytype, text: []const u8, _: f32) struct {
        width: f32,
        height: f32,
        metrics: []Metric,
    } {
        return .{
            .width = @as(f32, @floatFromInt(text.len)) * 8.0,
            .height = 16.0,
            .metrics = &.{},
        };
    }
};

const BenchCase = enum {
    reconcile_baseline,
    reconcile_prefetch,
    traverse_baseline,
    traverse_prefetch,
    layout_baseline,
    layout_prefetch,
};

const ParamBench = struct {
    state: *BenchState,
    mode: BenchCase,

    pub fn run(self: *ParamBench, allocator: std.mem.Allocator) void {
        _ = allocator;
        switch (self.mode) {
            .reconcile_baseline => runReconcileBaseline(self.state),
            .reconcile_prefetch => runReconcilePrefetch(self.state),
            .traverse_baseline => runTraversalBaseline(self.state),
            .traverse_prefetch => runTraversalPrefetch(self.state),
            .layout_baseline => runLayoutBaseline(self.state),
            .layout_prefetch => runLayoutPrefetch(self.state),
        }
    }
};

const BenchState = struct {
    allocator: std.mem.Allocator,
    ctx: UIContext,
    desc_a: *Node,
    desc_b: *Node,
    traversal_root: *Node,
    traversal_root_prefetch: *Node,
    flip: bool = false,

    fn init(allocator: std.mem.Allocator) !BenchState {
        var ctx = try UIContext.init(allocator);
        const retained_root = try buildTree(allocator, base_tree_depth, base_tree_width, false);
        try ctx.mountRoot(retained_root);

        const desc_a = try buildTree(allocator, base_tree_depth, base_tree_width, false);
        const desc_b = try buildTree(allocator, base_tree_depth, base_tree_width, true);
        const traversal_root = try buildTree(allocator, base_tree_depth + 1, base_tree_width + 1, false);
        const traversal_root_prefetch = try buildTree(allocator, base_tree_depth + 1, base_tree_width + 1, true);

        warmupTraversal(traversal_root);
        warmupTraversal(traversal_root_prefetch);
        try ctx.reconcile(desc_a);
        try ctx.reconcile(desc_b);

        return .{
            .allocator = allocator,
            .ctx = ctx,
            .desc_a = desc_a,
            .desc_b = desc_b,
            .traversal_root = traversal_root,
            .traversal_root_prefetch = traversal_root_prefetch,
        };
    }

    fn deinit(self: *BenchState) void {
        self.ctx.deinit();
        self.desc_a.deinit();
        self.desc_b.deinit();
        self.traversal_root.deinit();
        self.traversal_root_prefetch.deinit();
    }

    fn nextDescriptor(self: *BenchState) *Node {
        self.flip = !self.flip;
        return if (self.flip) self.desc_a else self.desc_b;
    }
};

fn lessThanU64(_: void, lhs: u64, rhs: u64) bool {
    return lhs < rhs;
}

fn medianNs(samples: []u64) u64 {
    std.sort.heap(u64, samples, {}, lessThanU64);
    return samples[samples.len / 2];
}

fn rawMedianTimer(io: std.Io, allocator: std.mem.Allocator, iterations: usize, comptime runner: fn (*BenchState) void, state: *BenchState) !u64 {
    const samples = try allocator.alloc(u64, iterations);
    defer allocator.free(samples);

    for (samples, 0..) |*slot, i| {
        _ = i;
        const start = std.Io.Timestamp.now(io, .awake);
        runner(state);
        const stop = std.Io.Timestamp.now(io, .awake);
        const elapsed_signed = start.durationTo(stop).nanoseconds;
        slot.* = @as(u64, @intCast(@max(elapsed_signed, 0)));
    }
    return medianNs(samples);
}

fn buildTree(allocator: std.mem.Allocator, depth: usize, fanout: usize, variant: bool) !*Node {
    var next_id: u32 = 1;
    var prng_state: u64 = if (variant) 0x9E3779B97F4A7C15 else 0xD1B54A32D192ED03;
    return buildTreeRecursive(allocator, depth, fanout, variant, &next_id, &prng_state, 0);
}

fn mixRand(state: *u64) u64 {
    state.* +%= 0x9E3779B97F4A7C15;
    var z = state.*;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

fn chooseChildrenCount(level: usize, depth: usize, fanout: usize, rand: u64, variant: bool) usize {
    if (depth == 0) return 0;
    const taper = if (level < 2) fanout else fanout -| level;
    const base = @max(@as(usize, 1), taper);
    const jitter = @as(usize, @intCast(rand % @max(@as(u64, 2), @as(u64, @intCast(base + 2)))));
    var width = @min(fanout + 1, base + jitter);
    if ((rand & 0x7) == 0) width = @max(@as(usize, 1), width / 2);
    if (variant and (rand & 0x3) == 0x1) width +|= 1;
    return @max(@as(usize, 1), width);
}

fn buildTreeRecursive(
    allocator: std.mem.Allocator,
    depth: usize,
    fanout: usize,
    variant: bool,
    next_id: *u32,
    prng_state: *u64,
    level: usize,
) !*Node {
    const rnd = mixRand(prng_state);
    const node = try allocator.create(Node);
    node.* = Node.init();
    node.allocator = allocator;
    node.payload = .container;
    node.id = next_id.*;
    next_id.* += 1;

    const w = 56.0 + @as(f32, @floatFromInt(rnd % 320));
    const h = 18.0 + @as(f32, @floatFromInt((rnd >> 9) % 90));
    node.style.width = if ((rnd & 0x3) == 0) .{ .percent = 0.25 + @as(f32, @floatFromInt((rnd >> 16) % 60)) / 100.0 } else .{ .exact = w };
    node.style.height = if ((rnd & 0x5) == 0x1) .{ .Auto = {} } else .{ .exact = h };
    node.style.margin = .{
        .top = @as(f32, @floatFromInt((rnd >> 19) % 4)),
        .right = @as(f32, @floatFromInt((rnd >> 21) % 6)),
        .bottom = @as(f32, @floatFromInt((rnd >> 23) % 5)),
        .left = @as(f32, @floatFromInt((rnd >> 25) % 7)),
    };
    node.style.direction = if ((rnd & 0x1) == 0) .Row else .Column;
    node.style.flex_wrap = if ((rnd & 0x10) == 0) .NoWrap else .Wrap;
    node.style.gap = @as(f32, @floatFromInt((rnd >> 13) % 10));
    node.style.background_color = if (variant and (node.id.? % 3 == 0 or (rnd & 0x20) == 0x20))
        .{ 0.2, 0.25 + @as(f32, @floatFromInt((rnd >> 29) % 10)) / 50.0, 0.32, 1.0 }
    else
        .{ 0.1, 0.1 + @as(f32, @floatFromInt((rnd >> 27) % 8)) / 40.0, 0.1, 1.0 };

    if (depth == 0) return node;

    const child_count = chooseChildrenCount(level, depth, fanout, rnd, variant);
    var i: usize = 0;
    while (i < child_count) : (i += 1) {
        const child = try buildTreeRecursive(allocator, depth - 1, fanout, variant, next_id, prng_state, level + 1);
        try node.addChild(child);
    }
    return node;
}

fn warmupTraversal(node: *const Node) void {
    var sink: usize = 0;
    traverseBaseline(node, &sink);
}

fn traverseBaseline(node: *const Node, sink: *usize) void {
    if (node.id) |id| sink.* +%= id;
    for (node.children.items) |child| {
        traverseBaseline(child, sink);
    }
}

fn traversePrefetch(node: *const Node, sink: *usize) void {
    if (node.id) |id| sink.* +%= id;
    for (node.children.items, 0..) |child, i| {
        if (i + 1 < node.children.items.len) {
            @prefetch(node.children.items[i + 1], .{});
        }
        traversePrefetch(child, sink);
    }
}

fn runReconcileBaseline(state: *BenchState) void {
    bench_prefetch.setEnabled(false);
    var i: usize = 0;
    while (i < reconcile_batches) : (i += 1) {
        const desc = state.nextDescriptor();
        state.ctx.reconcile(desc) catch @panic("reconcile baseline failed");
    }
}

fn runReconcilePrefetch(state: *BenchState) void {
    bench_prefetch.setEnabled(true);
    defer bench_prefetch.setEnabled(false);
    var i: usize = 0;
    while (i < reconcile_batches) : (i += 1) {
        const desc = state.nextDescriptor();
        state.ctx.reconcile(desc) catch @panic("reconcile prefetch failed");
    }
}

fn runTraversalBaseline(state: *BenchState) void {
    var sink: usize = 0;
    var i: usize = 0;
    while (i < traversal_batches) : (i += 1) {
        traverseBaseline(state.traversal_root, &sink);
    }
    if (sink == 0) @panic("sink should be non-zero");
}

fn runTraversalPrefetch(state: *BenchState) void {
    var sink: usize = 0;
    var i: usize = 0;
    while (i < traversal_batches) : (i += 1) {
        traversePrefetch(state.traversal_root_prefetch, &sink);
    }
    if (sink == 0) @panic("sink should be non-zero");
}

fn runLayoutBaseline(state: *BenchState) void {
    bench_prefetch.setEnabled(false);
    var dummy: DummyTextLayouter = .{};
    var i: usize = 0;
    while (i < layout_batches) : (i += 1) {
        layout.measureNode(state.traversal_root, &dummy, 1920.0, 1080.0, true);
        layout.arrangeNode(state.traversal_root, 0.0, 0.0);
    }
    std.mem.doNotOptimizeAway(state.traversal_root.layout_result.width);
    std.mem.doNotOptimizeAway(state.traversal_root.layout_result.height);
}

fn runLayoutPrefetch(state: *BenchState) void {
    bench_prefetch.setEnabled(true);
    defer bench_prefetch.setEnabled(false);
    var dummy: DummyTextLayouter = .{};
    var i: usize = 0;
    while (i < layout_batches) : (i += 1) {
        layout.measureNode(state.traversal_root_prefetch, &dummy, 1920.0, 1080.0, true);
        layout.arrangeNode(state.traversal_root_prefetch, 0.0, 0.0);
    }
    std.mem.doNotOptimizeAway(state.traversal_root_prefetch.layout_result.width);
    std.mem.doNotOptimizeAway(state.traversal_root_prefetch.layout_result.height);
}

fn printCrossValidation(io: std.Io, allocator: std.mem.Allocator, state: *BenchState) !void {
    const med_reconcile_baseline = try rawMedianTimer(io, allocator, timer_iterations, runReconcileBaseline, state);
    const med_reconcile_prefetch = try rawMedianTimer(io, allocator, timer_iterations, runReconcilePrefetch, state);
    const med_traverse_baseline = try rawMedianTimer(io, allocator, timer_iterations, runTraversalBaseline, state);
    const med_traverse_prefetch = try rawMedianTimer(io, allocator, timer_iterations, runTraversalPrefetch, state);

    std.debug.print("\nraw_timer_median_ns iterations={d}\n", .{timer_iterations});
    std.debug.print("  reconcile_baseline={d}\n", .{med_reconcile_baseline});
    std.debug.print("  reconcile_prefetch={d}\n", .{med_reconcile_prefetch});
    std.debug.print("  traverse_baseline={d}\n", .{med_traverse_baseline});
    std.debug.print("  traverse_prefetch={d}\n", .{med_traverse_prefetch});
}

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var state = try BenchState.init(allocator);
    defer state.deinit();
    var io_threaded = std.Io.Threaded.init(allocator, .{});
    defer io_threaded.deinit();

    var bench = zbench.Benchmark.init(allocator, .{});
    defer bench.deinit();

    const reconcile_baseline = ParamBench{ .state = &state, .mode = .reconcile_baseline };
    const reconcile_prefetch = ParamBench{ .state = &state, .mode = .reconcile_prefetch };
    const traverse_baseline = ParamBench{ .state = &state, .mode = .traverse_baseline };
    const traverse_prefetch = ParamBench{ .state = &state, .mode = .traverse_prefetch };
    const layout_baseline = ParamBench{ .state = &state, .mode = .layout_baseline };
    const layout_prefetch = ParamBench{ .state = &state, .mode = .layout_prefetch };

    try bench.addParam("reconcile_baseline", &reconcile_baseline, .{
        .time_budget_ns = noisy_path_budget_ns,
        .max_iterations = noisy_path_max_iterations,
    });
    try bench.addParam("reconcile_prefetch", &reconcile_prefetch, .{
        .time_budget_ns = noisy_path_budget_ns,
        .max_iterations = noisy_path_max_iterations,
    });
    try bench.addParam("traverse_baseline", &traverse_baseline, .{
        .time_budget_ns = noisy_path_budget_ns,
        .max_iterations = noisy_path_max_iterations,
    });
    try bench.addParam("traverse_prefetch", &traverse_prefetch, .{
        .time_budget_ns = noisy_path_budget_ns,
        .max_iterations = noisy_path_max_iterations,
    });
    try bench.addParam("layout_baseline", &layout_baseline, .{});
    try bench.addParam("layout_prefetch", &layout_prefetch, .{});

    const stdout_file: std.Io.File = .stdout();
    const io = io_threaded.io();
    try bench.run(io, stdout_file);
    try printCrossValidation(io, allocator, &state);
}
