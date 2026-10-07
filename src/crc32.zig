//! CRC-32 (IEEE / ISO-HDLC, reflected poly 0xEDB88320) — the checksum of
//! spec/file-format.md §2's WAL frames and §5.1's section table
//! (the errata pins "CRC32 = §2's WAL CRC"). Matches Rust's `crc32fast`.

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

pub fn crc32(data: []const u8) u32 {
    var h: u32 = 0xFFFF_FFFF;
    for (data) |b| {
        h = table[(h ^ @as(u32, b)) & 0xFF] ^ (h >> 8);
    }
    return ~h;
}

test "crc32 known vectors" {
    // Standard check value (crc32("123456789")).
    try std.testing.expectEqual(@as(u32, 0xCBF4_3926), crc32("123456789"));
    try std.testing.expectEqual(@as(u32, 0x0000_0000), crc32(""));
    try std.testing.expectEqual(@as(u32, 0x414F_A339), crc32("The quick brown fox jumps over the lazy dog"));
}

const std = @import("std");
