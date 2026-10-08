//! CRC-32 micro-bench: slice-by-8 vs PCLMULQDQ on a64 MB buffer, both
//! in-process (same allocation, back-to-back — no process noise).
//!
//! Run: `zig build bench-crc -Doptimize=ReleaseFast`
const std = @import("std");
const builtin = @import("builtin");
const nz = @import("nqlite_zig");
const crc32mod = nz.crc32;

const SIZE: usize = 64 << 20; // ≈ the store file's section-CRC workload
const REPS: usize = 7;

fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn medianMs(times: []u64) f64 {
    var t = times;
    var i: usize = 1;
    while (i < t.len) : (i += 1) {
        var j = i;
        while (j > 0 and t[j] < t[j - 1]) : (j -= 1)
            std.mem.swap(u64, &t[j], &t[j - 1]);
    }
    return @as(f64, @floatFromInt(t[t.len / 2])) / 1_000_000.0;
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
    const slice8 = medianMs(&times);

    if (comptime (builtin.cpu.arch == .x86 or builtin.cpu.arch == .x86_64)) {
        if (!crc32mod.usePclmul()) {
            std.debug.print(
                "slice-by-8: {d:.1} ms ({d:.0} MB/s) | simd: unavailable on this CPU\n",
                .{ slice8, @as(f64, SIZE) / (slice8 / 1000.0) / 1_000_000.0 },
            );
            std.debug.print("checksum={x}\n", .{acc});
            return;
        }
        for (&times) |*t| {
            const t0 = nowNs();
            acc ^= crc32mod.crc32(buf); // dispatches to PCLMUL
            t.* = nowNs() - t0;
        }
        const simd = medianMs(&times);
        std.debug.print(
            "crc32 {d} MB × {d} reps: slice-by-8 {d:.2} ms ({d:.0} MB/s) | " ++
                "pclmulqdq {d:.2} ms ({d:.0} MB/s) | {d:.2}×\n",
            .{
                SIZE >> 20,    REPS,
                slice8,        @as(f64, SIZE) / (slice8 / 1000.0) / 1_000_000.0,
                simd,          @as(f64, SIZE) / (simd / 1000.0) / 1_000_000.0,
                slice8 / simd,
            },
        );
    } else {
        std.debug.print("slice-by-8: {d:.2} ms (non-x86)\n", .{slice8});
    }
    std.debug.print("checksum={x}\n", .{acc});
}
