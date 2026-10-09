//! Ingest micro-bench: `executePlan([insert])` only (no parser) over
//! N records in three id orders — ascending (append), reverse (worst-case
//! memmove), and sequential string ids (lexicographic interleaving, the
//! E08/probe shape). Exposes whether the sorted-insert cost is actually
//! quadratic and how big it is at100k. Each (size, order) runs REPS
//! fresh-store iterations; the kept samples report p50/p95/p99/max +
//! rows/s (issue #28) — same in-process method, fuller output.
//!
//! Run: `zig build bench-ingest -Doptimize=ReleaseFast`
const std = @import("std");
const nz = @import("nqlite_zig");
const engine = nz.engine;
const ir = nz.ir;
const stats = @import("bench_stats.zig");

const SIZES = [_]usize{ 20_000, 50_000, 100_000 };
const REPS: usize = 7;

fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

const Order = enum { asc, reverse, lex };

/// Pre-build N records (body + embedding are shared/static — this bench
/// times the ENGINE insert, not allocation).
fn buildStmts(gpa: std.mem.Allocator, n: usize, order: Order) ![]ir.Statement {
    const topics = [_][]const u8{ "alpha", "beta", "gamma", "delta" };
    const entries = try gpa.alloc(ir.DocEntry, n);
    for (entries, 0..) |*e, i| {
        e.* = .{ .key = "topic", .value = .{ .str = topics[i % 4] } };
    }
    const embed = try gpa.alloc(f32, 64);
    for (embed, 0..) |*f, i| f.* = @as(f32, @floatFromInt(i % 97)) / 97.0;
    const stmts = try gpa.alloc(ir.Statement, n);
    for (stmts, 0..) |*s, i| {
        // Id chosen by ORDER: asc/reverse insert numeric ids in that order;
        // `lex` inserts sequential string ids (d0, d1, … d99999) whose
        // LEXICOGRAPHIC order interleaves — the probe/E08 shape.
        const id: ir.RecordId = switch (order) {
            .asc => .{ .table = "doc", .id = .{ .num = i } },
            .reverse => .{ .table = "doc", .id = .{ .num = n - i } },
            .lex => blk: {
                var buf: [24]u8 = undefined;
                const name = std.fmt.bufPrint(&buf, "d{d}", .{i}) catch unreachable;
                break :blk .{ .table = "doc", .id = .{ .str = gpa.dupe(u8, name) catch unreachable } };
            },
        };
        s.* = .{ .insert = .{
            .id = id,
            .body = entries[i .. i + 1],
            .embedding = embed,
            .created_at = 0,
        } };
    }
    return stmts;
}

fn benchOne(gpa: std.mem.Allocator, n: usize, order: Order) !void {
    const stmts = try buildStmts(gpa, n, order);
    // REPS fresh-store iterations — the kept per-iteration samples (issue #28).
    var insert_samples: [REPS]u64 = undefined;
    var flush_samples: [REPS]u64 = undefined;
    for (&insert_samples, 0..) |*t, rep| {
        var store = engine.EngineStore.init(gpa);
        try store.tables.append(gpa, .{ .name = "doc", .vector_dim = 64 });
        const t0 = nowNs();
        for (stmts) |s| {
            _ = try engine.executePlan(&store, &.{s});
        }
        t.* = nowNs() - t0;
        // The deferred design moves sorting to the reader seam — time it too.
        const t1 = nowNs();
        try store.flushDeep();
        flush_samples[rep] = nowNs() - t1;
    }
    const ins = stats.Stats.from(&insert_samples);
    const fl = stats.Stats.from(&flush_samples);
    std.debug.print(
        "{s:<8} n={d:>7}: insert median {d:>8.2} ms · p95 {d:>7.2} · p99 {d:>7.2} · max {d:>7.2} · mean {d:>7.2} ({d:>6.1} µs/row) · {d:>6.1} K rows/s | flush median {d:>7.2} ms | total {d:>8.2} ms\n",
        .{
            @tagName(order),
            n,
            ins.median,
            ins.p95,
            ins.p99,
            ins.max,
            ins.mean,
            ins.median * 1000.0 / @as(f64, @floatFromInt(n)),
            ins.ratePerSec(@floatFromInt(n)) / 1000.0,
            fl.median,
            ins.median + fl.median,
        },
    );
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    for (SIZES) |n| {
        try benchOne(gpa, n, .asc);
        try benchOne(gpa, n, .reverse);
        try benchOne(gpa, n, .lex);
    }
}
