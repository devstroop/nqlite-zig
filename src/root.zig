//! By convention, root.zig is the root source file when making a package.
//!
//! M1 (format v4, spec/file-format.md §5): the format-v4 codec — IR types,
//! §5.7 payload encoding, §5.1–§5.6 container, and the golden-fixture gate
//! (`spec/fixtures/v4/`, the byte oracle vendored from devstroop/nqlite).
const std = @import("std");
const Io = std.Io;

pub const ir = @import("ir.zig");
pub const payload = @import("payload.zig");
pub const v4 = @import("v4.zig");
pub const crc32 = @import("crc32.zig");
// M2: the NQL front-end (lexer → parser → analyzer).
pub const lexer = @import("lexer.zig");
pub const parser = @import("parser.zig");
pub const analyzer = @import("analyzer.zig");
// M3: the deterministic in-memory engine.
pub const engine = @import("engine.zig");
pub const bm25 = @import("bm25.zig");
// M4: the line-protocol server (nql-server parity).
pub const storage = @import("storage.zig");
pub const server = @import("server.zig");
pub const cli = @import("cli.zig");

// Run every imported file's tests (zig runs tests of files reachable from
// the root module).
test {
    _ = @import("ir.zig");
    _ = @import("payload.zig");
    _ = @import("v4.zig");
    _ = @import("crc32.zig");
    _ = @import("fixtures.zig");
    _ = @import("lexer.zig");
    _ = @import("parser.zig");
    _ = @import("analyzer.zig");
    _ = @import("corpus.zig");
    _ = @import("engine.zig");
    _ = @import("bm25.zig");
    _ = @import("results.zig");
    _ = @import("server.zig");
    _ = @import("cli.zig");
}

/// This is a documentation comment to explain the `printAnotherMessage` function below.
///
/// Accepting an `Io.Writer` instance is a handy way to write reusable code.
pub fn printAnotherMessage(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("Run `zig build test` to run the tests.\n", .{});
}

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try std.testing.expect(add(3, 7) == 10);
}
