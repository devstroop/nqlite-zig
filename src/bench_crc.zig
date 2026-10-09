//! CRC-32 micro-bench: slice-by-8 vs PCLMULQDQ on a64 MB buffer, both
//! in-process (same allocation, back-to-back — no process noise).
//! Per-iteration samples are kept and reported as p50/p95/p99/max +
//! MB/s from the mean (issue #28).
//!
//! Run: `zig build bench-crc -Doptimize=ReleaseFast`
const std = @import("std");
const builtin = @import("builtin");
const nz = @import("nqlite_zig");
const crc32mod = nz.crc32;
const stats = @import("bench_stats.zig");

const SIZE: usize = 64 << 20; // ≈ the store file's section-CRC workload
const REPS: usize = 7;

fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn mbPerSec(mean_ms: f64) f64 {
    return @as(f64, SIZE) / (mean_ms / 1000.0) / 1_000_000.0;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const buf = try gpa.alloc(u8, SIZE);
    var s: u32 = 0x1234_5678;
    for (buf) |*b| {
        s = s *% 1_664_525 +% 1_013_904_223;
        b.* = @truncate(s >> 24);
    }

    var times: [REPS]u64 = undefined;
    var acc: u32 = 0;

    for (&times) |*t| {
        const t0 = nowNs();
        acc ^= crc32mod.crc32Slice8(buf);
        t.* = nowNs() - t0;
    }
    const slice8 = stats.Stats.from(&times);

    if (comptime (builtin.cpu.arch == .x86 or builtin.cpu.arch == .x86_64)) {
        if (!crc32mod.usePclmul()) {
            std.debug.print(
                "slice-by-8: median {d:.2} ms · p95 {d:.2} · p99 {d:.2} · max {d:.2} · mean {d:.2} · {d:.0} MB/s | simd: unavailable on this CPU\n",
                .{ slice8.median, slice8.p95, slice8.p99, slice8.max, slice8.mean, mbPerSec(slice8.mean) },
            );
            std.debug.print("checksum={x}\n", .{acc});
            return;
        }
        for (&times) |*t| {
            const t0 = nowNs();
            acc ^= crc32mod.crc32(buf); // dispatches to PCLMUL
            t.* = nowNs() - t0;
        }
        const simd = stats.Stats.from(&times);
        std.debug.print(
            "crc32 {d} MB × {d} reps: slice-by-8 median {d:.2} ms · p95 {d:.2} · p99 {d:.2} · max {d:.2} · {d:.0} MB/s | " ++
                "pclmulqdq median {d:.2} ms · p95 {d:.2} · p99 {d:.2} · max {d:.2} · {d:.0} MB/s | {d:.2}×\n",
            .{
                SIZE >> 20,
                REPS,
                slice8.median,
                slice8.p95,
                slice8.p99,
                slice8.max,
                mbPerSec(slice8.mean),
                simd.median,
                simd.p95,
                simd.p99,
                simd.max,
                mbPerSec(simd.mean),
                slice8.median / simd.median,
            },
        );
    } else {
        std.debug.print(
            "slice-by-8: median {d:.2} ms · p95 {d:.2} · p99 {d:.2} · max {d:.2} (non-x86)\n",
            .{ slice8.median, slice8.p95, slice8.p99, slice8.max },
        );
    }
    std.debug.print("checksum={x}\n", .{acc});
}
