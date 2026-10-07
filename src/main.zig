const std = @import("std");
const Io = std.Io;

const nqlite_zig = @import("nqlite_zig");

/// nqlite line-protocol server (`--stdio`): one nql program per line in,
/// one response out — byte-identical to nql-server's stdio mode.
///
/// TODO(M6): `--db <path>` persistence (the E01–E05 harness drives the Rust
/// CLI for persistence cases; the server is only ever spawned with --stdio).
/// TODO(M4): TCP mode (default in the reference) — not needed by the harness.
pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var want_stdio = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--stdio")) want_stdio = true;
    }
    if (!want_stdio) {
        std.debug.print("nqlite_zig: only --stdio is implemented so far (M4)\n", .{});
        return error.UnsupportedMode;
    }

    var server = nqlite_zig.server.Server.init(arena);

    // 1 MiB line buffer — corpus programs are far smaller; a longer line is
    // a protocol violation we refuse rather than silently truncate.
    var in_buf: [1 << 20]u8 = undefined;
    var stdin_file_reader = Io.File.stdin().reader(io, &in_buf);
    const stdin_reader = &stdin_file_reader.interface;
    var out_buf: [1 << 16]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), io, &out_buf);
    const out = &stdout.interface;

    while (true) {
        const raw = stdin_reader.takeDelimiterInclusive('\n') catch |e| switch (e) {
            error.EndOfStream => break, // EOF (Ctrl-D): clean exit
            else => return e,
        };
        const resp = server.handleLine(raw);
        try out.writeAll(resp);
        try out.writeAll("\n");
        try out.flush(); // one response, flushed per line (reference behavior)
    }
    try out.flush();
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz example" {
    try std.testing.fuzz({}, testOne, .{});
}

fn testOne(context: void, smith: *std.testing.Smith) !void {
    _ = context;
    // Try command `zig build test --fuzz -Doptimize=ReleaseFast` to see if it manages to fail this test case!

    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    while (!smith.eos()) switch (smith.value(enum { add_data, dup_data })) {
        .add_data => {
            const slice = try list.addManyAsSlice(gpa, smith.value(u4));
            smith.bytes(slice);
        },
        .dup_data => {
            if (list.items.len == 0) continue;
            if (list.items.len > std.math.maxInt(u32)) return error.SkipZigTest;
            const len = smith.valueRangeAtMost(u32, 1, @min(32, list.items.len));
            const off = smith.valueRangeAtMost(u32, 0, @intCast(list.items.len - len));
            try list.appendSlice(gpa, list.items[off..][0..len]);
            try std.testing.expectEqualSlices(
                u8,
                list.items[off..][0..len],
                list.items[list.items.len - len ..],
            );
        },
    };
}
