//! Engine select-path micro-bench: `executePlan` over a synthesized100k
//! store — three shapes (star / projection / filter) — to attribute the
//! "full-scan + response" row honestly (formatting is measured separately
//! by `bench-format`; external process timing on this box is noise-bound).
//!
//! Run: `zig build bench-query -Doptimize=ReleaseFast`
const std = @import("std");
const nz = @import("nqlite_zig");
const engine = nz.engine;
const ir = nz.ir;

const N: usize = 100_000;
const REPS: usize = 7;

fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn buildStore(gpa: std.mem.Allocator) !engine.EngineStore {
    var store = engine.EngineStore.init(gpa);
    try store.tables.append(gpa, .{ .name = "doc", .vector_dim = null });
    const topics = [_][]const u8{ "alpha", "beta", "gamma", "delta" };
    const entries = try gpa.alloc(ir.DocEntry, N);
    for (entries, 0..) |*e, i| {
        e.* = .{ .key = "topic", .value = .{ .str = topics[i % topics.len] } };
    }
    for (0..N) |i| {
        try store.records.append(gpa, .{
            .id = .{ .table = "doc", .id = .{ .num = i } },
            .body = entries[i .. i + 1],
            .embedding = null,
            .created_at = 1,
        });
    }
    return store;
}

fn benchOne(
    store: *engine.EngineStore,
    label: []const u8,
    stmt: ir.Statement,
) !void {
    const plan = [_]ir.Statement{stmt};
    var times: [REPS]u64 = undefined;
    var rows: usize = 0;
    for (&times) |*t| {
        const t0 = nowNs();
        const results = try engine.executePlan(store, &plan);
        t.* = nowNs() - t0;
        rows = results[0].rows.len;
    }
    var i: usize = 1;
    while (i < REPS) : (i += 1) {
        var j = i;
        while (j > 0 and times[j] < times[j - 1]) : (j -= 1)
            std.mem.swap(u64, &times[j], &times[j - 1]);
    }
    const med = times[REPS / 2];
    std.debug.print(
        "{s:<12} median {d:>8.2} ms  (rows={d})\n",
        .{ label, @as(f64, @floatFromInt(med)) / 1_000_000.0, rows },
    );
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var store = try buildStore(gpa);

    const star = ir.Statement{ .select = .{
        .table = "doc",
        .knn = null,
        .filter = null,
        .order = null,
        .limit = null,
        .as_of = null,
        .fields = null,
        .offset = null,
        .aggregate = null,
    } };
    const proj = ir.Statement{ .select = .{
        .table = "doc",
        .knn = null,
        .filter = null,
        .order = null,
        .limit = null,
        .as_of = null,
        .fields = &.{"topic"},
        .offset = null,
        .aggregate = null,
    } };
    const filt = ir.Statement{ .select = .{
        .table = "doc",
        .knn = null,
        .filter = .{ .field_equals = .{ .field = "topic", .value = .{ .str = "gamma" } } },
        .order = null,
        .limit = null,
        .as_of = null,
        .fields = null,
        .offset = null,
        .aggregate = null,
    } };

    try benchOne(&store, "star", star);
    try benchOne(&store, "projection", proj);
    try benchOne(&store, "filter", filt);
}
