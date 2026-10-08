//! CRC-32 (IEEE / ISO-HDLC, reflected poly 0xEDB88320) — the checksum of
//! spec/file-format.md §2's WAL frames and §5.1's section table
//! (the errata pins "CRC32 = §2's WAL CRC"). Matches Rust's `crc32fast`.
//!
//! Two paths, one output (bit-identical, cross-tested below):
//! - **slice-by-8** — always available (baseline, CI, non-x86);
//! - **PCLMULQDQ** — faithful port of crc32fast 1.5.2's
//!   `specialized/pclmulqdq.rs` (the128-bit SSE fold-by-4 path; their
//!   K-constants for the reflected IEEE poly), runtime-detected. Section
//!   CRCs cover whole store files at open (62 MB), so this is the lever
//!   on reopen latency.

const table = blk: {
    @setEvalBranchQuota(10_000);
    var t: [256]u32 = undefined;
    for (&t, 0..) |*slot, i| {
        var c: u32 = @intCast(i);
        var k: u32 = 0;
        while (k < 8) : (k += 1) {
            c = if (c & 1 != 0) 0xEDB88320 ^ (c >> 1) else c >> 1;
        }
        slot.* = c;
    }
    break :blk t;
};

/// Derived tables folding 8 bytes ahead:
/// `T[k][i] = (T[k-1][i] >> 8) ^ T[0][T[k-1][i] & 0xFF]`.
const table8: [8][256]u32 = blk: {
    @setEvalBranchQuota(1_000_000);
    var t: [8][256]u32 = undefined;
    t[0] = table;
    for (1..8) |k| {
        for (0..256) |i| {
            const prev = t[k - 1][i];
            t[k][i] = (prev >> 8) ^ t[0][prev & 0xFF];
        }
    }
    break :blk t;
};

/// Dispatch: the SIMD path on capable x86 (runtime-once cpuid), else
/// slice-by-8. The arch check is comptime so non-x86 builds never reference
/// the C symbol (it is only compiled on x86 — see build.zig).
pub fn crc32(data: []const u8) u32 {
    if (comptime (builtin.cpu.arch == .x86 or builtin.cpu.arch == .x86_64)) {
        if (data.len >= 16 and usePclmul()) return crc32Simd(data);
    }
    return crc32Slice8(data);
}

/// The always-available reference path (baseline, CI, non-x86 fallback).
pub fn crc32Slice8(data: []const u8) u32 {
    var h: u32 = 0xFFFF_FFFF;
    var i: usize = 0;
    // Two little-endian words (8 bytes) per iteration.
    while (data.len - i >= 8) {
        const a = std.mem.readInt(u32, data[i..][0..4], .little);
        const b = std.mem.readInt(u32, data[i + 4 ..][0..4], .little);
        h ^= a;
        h = table8[7][h & 0xFF] ^
            table8[6][(h >> 8) & 0xFF] ^
            table8[5][(h >> 16) & 0xFF] ^
            table8[4][(h >> 24) & 0xFF] ^
            table8[3][b & 0xFF] ^
            table8[2][(b >> 8) & 0xFF] ^
            table8[1][(b >> 16) & 0xFF] ^
            table8[0][(b >> 24) & 0xFF];
        i += 8;
    }
    for (data[i..]) |byte| {
        h = table[(h ^ byte) & 0xFF] ^ (h >> 8);
    }
    return ~h;
}

test "crc32 slice-by-8 matches the byte loop for every length" {
    // Cross-validate the fast path against the byte-at-a-time definition
    // for every length straddling the 8-byte boundary.
    const seed_bytes = "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    var n: usize = 0;
    while (n <= seed_bytes.len) : (n += 1) {
        const data = seed_bytes[0..n];
        var h: u32 = 0xFFFF_FFFF;
        for (data) |b| {
            h = table[(h ^ b) & 0xFF] ^ (h >> 8);
        }
        try std.testing.expectEqual(~h, crc32(data));
    }
}

test "crc32 known vectors" {
    // Standard check value (crc32("123456789")).
    try std.testing.expectEqual(@as(u32, 0xCBF4_3926), crc32("123456789"));
    try std.testing.expectEqual(@as(u32, 0x0000_0000), crc32(""));
    try std.testing.expectEqual(@as(u32, 0x414F_A339), crc32("The quick brown fox jumps over the lazy dog"));
}

// ---------------------------------------------------------------------------
// PCLMULQDQ path — the crc32fast1.5.2 `specialized/pclmulqdq.rs` algorithm,
// compiled from C (src/crc32_simd.c) so clang's per-function
// `target("pclmulqdq,...")` does what `#[target_feature]` does on the Rust
// side: instructions always encodable, execution runtime-gated by
// `usePclmul()` (zig's own asm encoder only assembles baseline features).
// ---------------------------------------------------------------------------

extern fn nql_crc32_simd(data: [*]const u8, len: usize) u32;

/// One-shot SIMD CRC — contract equals `crc32Slice8` (ladder test + the
/// fixture/WAL gates pin it). x86-only at the call site (comptime-dead on
/// other arches, so the symbol is never referenced there).
fn crc32Simd(data: []const u8) u32 {
    return nql_crc32_simd(data.ptr, data.len);
}

/// Runtime-once dispatch: leaf1 ECX bit1 = PCLMULQDQ (cpuid shape copied
/// from std/zig/system/x86.zig — no std re-export of that module).
pub var pclmul_cached: ?bool = null;
pub fn usePclmul() bool {
    if (pclmul_cached) |b| return b;
    var ok = false;
    if (builtin.cpu.arch == .x86 or builtin.cpu.arch == .x86_64) {
        var eax: u32 = undefined;
        var ebx: u32 = undefined;
        var ecx: u32 = undefined;
        var edx: u32 = undefined;
        asm volatile ("cpuid"
            : [_] "={eax}" (eax),
              [_] "={ebx}" (ebx),
              [_] "={ecx}" (ecx),
              [_] "={edx}" (edx),
            : [_] "{eax}" (@as(u32, 1)),
              [_] "{ecx}" (@as(u32, 0)),
        );
        ok = ecx & (1 << 1) != 0;
    }
    pclmul_cached = ok;
    return ok;
}

test "simd path matches slice-by-8 (crc32fast's length ladder + offsets)" {
    if (comptime !(builtin.cpu.arch == .x86 or builtin.cpu.arch == .x86_64)) return;
    if (!usePclmul()) {
        std.log.info("skip: no pclmulqdq on this CPU", .{});
        return;
    }
    // Their deterministic buffer (same LCG) + ladder + offsets.
    var data: [8200]u8 = undefined;
    var s: u32 = 0x1234_5678;
    for (&data) |*b| {
        s = s *% 1_664_525 +% 1_013_904_223;
        b.* = @truncate(s >> 24);
    }
    const lens = [_]usize{ 0, 1, 15, 16, 17, 63, 64, 127, 128, 129, 255, 256, 257, 511, 512, 513, 1023, 1024, 1025, 2047, 2048, 2049, 2175, 2176, 2303, 2304, 4096, 8192, 8199 };
    const offs = [_]usize{ 0, 1, 3, 7, 8, 15 };
    for (lens) |n| {
        for (offs) |o| {
            if (o + n > data.len) continue;
            const slice = data[o .. o + n];
            try std.testing.expectEqual(crc32Slice8(slice), crc32Simd(slice));
        }
    }
    // Also exercise the single-accumulator path (16..127) explicitly.
    var n: usize = 16;
    while (n < 128) : (n += 1) {
        try std.testing.expectEqual(crc32Slice8(data[0..n]), crc32Simd(data[0..n]));
    }
}

const std = @import("std");
const builtin = @import("builtin");
