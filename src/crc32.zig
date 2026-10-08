//! CRC-32 (IEEE / ISO-HDLC, reflected poly 0xEDB88320) — the checksum of
//! spec/file-format.md §2's WAL frames and §5.1's section table
//! (the errata pins "CRC32 = §2's WAL CRC"). Matches Rust's `crc32fast`.
//!
//! Slice-by-8 over the standard byte table: section CRCs cover whole
//! store files at open (62 MB ≈ 250 ms byte-at-a-time ≈ 30 ms here), so
//! the slow loop dominated reopen latency. Same algorithm — bit-identical
//! output, proven by the vectors below + the golden-fixture/WAL gates.

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

pub fn crc32(data: []const u8) u32 {
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

const std = @import("std");
