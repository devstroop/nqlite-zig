//! Response-formatting micro-bench: `formatResult` over N synthesized
//! rows, median of R reps — in-process (external process timing on this
//! box swings ±2× under the neighbour workload; BENCHMARKING.md cites
//! this method).
//!
//! Run: `zig build bench-format -Doptimize=ReleaseFast`
const std = @import("std");
const nz = @import("nqlite_zig");
const engine = nz.engine;
const ir = nz.ir;
const server = nz.server;

const N: usize = 100_000;
const REPS: usize = 7;

fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    // Probe-shaped rows (`SELECT topic FROM doc`): numeric id + one static
    // string field; scores vary, including an exact4dp tie (0.03125).
    const topics = [_][]const u8{ "alpha", "beta", "gamma", "delta" };
    const entries = try gpa.alloc(ir.DocEntry, N);
    for (entries, 0..) |*e, i| {
        e.* = .{ .key = "topic", .value = .{ .str = topics[i % topics.len] } };
    }
    const rows = try gpa.alloc(engine.Row, N);
    for (rows, 0..) |*r, i| {
        r.* = .{
            .record = .{
                .id = .{ .table = "doc", .id = .{ .num = i } },
                .body = entries[i .. i + 1],
                .embedding = null,
                .created_at = 0,
            },
            .score = if (i % 7 == 0)
                @as(f32, 0.03125)
            else
                @as(f32, @floatFromInt(i % 9973)) / 10000.0,
        };
    }
    const res = engine.QueryResult{ .kind = .{ .select = "doc" }, .rows = rows };

    var times: [REPS]u64 = undefined;
    var line_len: usize = 0;
    for (&times) |*t| {
        const t0 = nowNs();
        const line = try server.formatResult(gpa, res);
        t.* = nowNs() - t0;
        line_len = line.len;
    }
    // Insertion sort (REPS items — no std.sort API risk).
    var i: usize = 1;
    while (i < REPS) : (i += 1) {
        var j = i;
        while (j > 0 and times[j] < times[j - 1]) : (j -= 1)
            std.mem.swap(u64, &times[j], &times[j - 1]);
    }
    const med = times[REPS / 2];
    std.debug.print(
        "formatResult {d} rows × {d} reps: median {d:.2} ms (line = {d} bytes)\n",
        .{ N, REPS, @as(f64, @floatFromInt(med)) / 1_000_000.0, line_len },
    );
}
