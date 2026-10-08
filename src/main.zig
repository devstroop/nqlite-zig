const std = @import("std");
const Io = std.Io;

const nqlite_zig = @import("nqlite_zig");

/// nqlite line-protocol server (`--stdio`): one nql program per line in,
/// one response out — byte-identical to nql-server's stdio mode.
///
/// `--db <path>` (or `-d`) serves a persistent single-file store: lock,
/// v4 load + WAL replay on open; per-plan WAL frames (+ #109 ContextReset)
/// and threshold checkpoints while running. TCP mode (the reference's
/// default) is not implemented yet.
pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var want_stdio = false;
    var db_path: ?[]const u8 = null;
    var script_path: ?[]const u8 = null;
    var bad_arg = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (i == 0) continue; // argv[0] (the reference's rest-pattern `_`)
        const a = args[i];
        if (std.mem.eql(u8, a, "--stdio")) {
            want_stdio = true;
        } else if (std.mem.eql(u8, a, "--db") or std.mem.eql(u8, a, "-d")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: --db needs a path\n", .{});
                std.process.exit(1);
            }
            db_path = args[i];
        } else if (std.mem.eql(u8, a, "--script") or std.mem.eql(u8, a, "-s")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("{s}\n", .{nqlite_zig.cli.USAGE});
                std.process.exit(1);
            }
            script_path = args[i];
        } else {
            bad_arg = true;
        }
    }

    // Shared stdout writer (one response flushed per unit by each mode).
    var out_buf: [1 << 16]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), io, &out_buf);
    const out = &stdout.interface;

    if (!want_stdio) {
        if (bad_arg) {
            std.debug.print("{s}\n", .{nqlite_zig.cli.USAGE});
            std.process.exit(1);
        }
        // CLI modes: `--script FILE` or the interactive REPL (`--db` optional)
        // — byte-contract with nql-cli (src/cli.zig).
        try nqlite_zig.cli.run(arena, io, out, .{
            .db_path = db_path,
            .script_path = script_path,
        });
        return;
    }

    var server = if (db_path) |p|
        nqlite_zig.server.Server.open(arena, io, p) catch |e| {
            // Same `error: …` + exit 1 convention as nql-server (issue #84).
            std.debug.print("error: {s}\n", .{@errorName(e)});
            std.process.exit(1);
        }
    else
        nqlite_zig.server.Server.init(arena, io);

    // 1 MiB line buffer — corpus programs are far smaller; a longer line is
    // a protocol violation we refuse rather than silently truncate.
    var in_buf: [1 << 20]u8 = undefined;
    var stdin_file_reader = Io.File.stdin().reader(io, &in_buf);
    const stdin_reader = &stdin_file_reader.interface;

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
