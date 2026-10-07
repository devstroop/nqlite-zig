//! M2 corpus gate — `spec/fixtures/nql/corpus.json` (the Rust front-end
//! is the oracle: nql/tests/parser_corpus.rs).
//!
//! Per case:
//! 1. lex/parse → same `kind` + 1-based `line`/`col`, or
//! 2. parse OK → each statement encodes to the golden `hex` bit-for-bit
//!    (via the M1 §5.7 codec), and
//! 3. analyzer → golden `analyzed_hex` / `error.variant`.

const std = @import("std");
const ir = @import("ir.zig");
const payload = @import("payload.zig");
const parser = @import("parser.zig");
const analyzer = @import("analyzer.zig");

fn readFile(gpa: std.mem.Allocator, name: []const u8) ![]const u8 {
    const io = std.testing.io;
    var tmp: [2][768]u8 = undefined;
    var cands: [2][]const u8 = undefined;
    var n: usize = 0;
    if (std.fs.path.dirname(@src().file)) |d| {
        cands[n] = try std.fmt.bufPrint(&tmp[n], "{s}/../spec/fixtures/nql/{s}", .{ d, name });
        n += 1;
    }
    cands[n] = try std.fmt.bufPrint(&tmp[n], "spec/fixtures/nql/{s}", .{name});
    n += 1;
    for (cands[0..n]) |path| {
        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch continue;
        defer file.close(io);
        const st = try file.stat(io);
        const bytes = try gpa.alloc(u8, st.size);
        const got = try file.readPositionalAll(io, bytes, 0);
        return bytes[0..got];
    }
    return error.FileNotFound;
}

fn hex(gpa: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const out = try gpa.alloc(u8, bytes.len * 2);
    const digits = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = digits[b >> 4];
        out[i * 2 + 1] = digits[b & 0xf];
    }
    return out;
}

fn encodeHex(gpa: std.mem.Allocator, stmt: ir.Statement) ![]const u8 {
    var w = payload.Writer.init(gpa);
    defer w.deinit();
    try w.statement(stmt);
    return hex(gpa, w.bytes());
}

test "corpus: parse + analyze matches the Rust oracle" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const text = try readFile(gpa, "corpus.json");
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, text, .{});
    defer parsed.deinit();
    const cases = parsed.value.object.get("cases").?.array.items;

    var checked: usize = 0;
    for (cases) |case| {
        const name = case.object.get("name").?.string;
        const mode = case.object.get("mode").?.string;
        const source = case.object.get("source").?.string;
        const ok = case.object.get("ok").?.bool;

        const outcome = if (std.mem.eql(u8, mode, "statement"))
            try parser.parseStatement(gpa, source)
        else
            try parser.parse(gpa, source);

        if (!ok) {
            const errv = case.object.get("error").?;
            const kind = errv.object.get("kind").?.string;
            if (std.mem.eql(u8, kind, "analysis")) {
                // Parse must SUCCEED first (and match hex), then analysis
                // must fail with the golden variant.
                if (outcome != .ok) {
                    std.debug.print("case {s}: expected analysis failure, but parse failed: {s}:{d}:{d} {s}\n", .{
                        name,
                        @tagName(outcome.err.kind),
                        outcome.err.line,
                        outcome.err.col,
                        outcome.err.message,
                    });
                    return error.TestUnexpectedResult;
                }
                try checkHex(gpa, name, case, outcome.ok);
                const res = try analyzer.analyze(gpa, outcome.ok);
                if (res != .err) {
                    std.debug.print("case {s}: expected analysis error, got success\n", .{name});
                    return error.TestUnexpectedResult;
                }
                const want = errv.object.get("variant").?.string;
                if (!std.mem.eql(u8, want, res.err.variant)) {
                    std.debug.print("case {s}: variant want={s} got={s}\n", .{ name, want, res.err.variant });
                    return error.TestUnexpectedResult;
                }
            } else {
                // lex/parse failure: kind + position must match exactly.
                if (outcome != .err) {
                    std.debug.print("case {s}: expected {s} failure, parse succeeded\n", .{ name, kind });
                    return error.TestUnexpectedResult;
                }
                const want_kind: []const u8 = @tagName(outcome.err.kind);
                const want_line: i64 = @intCast(outcome.err.line);
                const want_col: i64 = @intCast(outcome.err.col);
                const e_line = errv.object.get("line").?.integer;
                const e_col = errv.object.get("col").?.integer;
                if (!std.mem.eql(u8, want_kind, kind) or want_line != e_line or want_col != e_col) {
                    std.debug.print(
                        "case {s}: want {s} {d}:{d}, got {s} {d}:{d} ({s})\n",
                        .{ name, kind, e_line, e_col, want_kind, want_line, want_col, outcome.err.message },
                    );
                    return error.TestUnexpectedResult;
                }
            }
        } else {
            if (outcome != .ok) {
                std.debug.print("case {s}: unexpected {s} failure {d}:{d} {s}\n", .{
                    name,
                    @tagName(outcome.err.kind),
                    outcome.err.line,
                    outcome.err.col,
                    outcome.err.message,
                });
                return error.TestUnexpectedResult;
            }
            try checkHex(gpa, name, case, outcome.ok);
            const res = try analyzer.analyze(gpa, outcome.ok);
            if (res != .ok) {
                std.debug.print("case {s}: unexpected analysis failure: {s}\n", .{ name, res.err.variant });
                return error.TestUnexpectedResult;
            }
            // analyzed_hex golden (enrichment may differ from raw hex).
            const want_hex = case.object.get("analyzed_hex").?.array.items;
            if (want_hex.len != res.ok.len) {
                std.debug.print("case {s}: analyzed len want={d} got={d}\n", .{ name, want_hex.len, res.ok.len });
                return error.TestUnexpectedResult;
            }
            for (res.ok, 0..) |stmt, i| {
                const got = try encodeHex(gpa, stmt);
                const want = want_hex[i].string;
                if (!std.mem.eql(u8, want, got)) {
                    std.debug.print("case {s}: analyzed_hex[{d}] want={s} got={s}\n", .{ name, i, want, got });
                    return error.TestUnexpectedResult;
                }
            }
        }
        checked += 1;
    }
    try std.testing.expect(checked >= 70);
}

fn checkHex(gpa: std.mem.Allocator, name: []const u8, case: std.json.Value, plan: []const ir.Statement) !void {
    const want_hex = case.object.get("hex").?;
    if (want_hex.array.items.len != plan.len) {
        std.debug.print("case {s}: hex len want={d} got={d}\n", .{ name, want_hex.array.items.len, plan.len });
        return error.TestUnexpectedResult;
    }
    for (plan, 0..) |stmt, i| {
        const got = try encodeHex(gpa, stmt);
        const want = want_hex.array.items[i].string;
        if (!std.mem.eql(u8, want, got)) {
            std.debug.print("case {s}: hex[{d}] want={s} got={s}\n", .{ name, i, want, got });
            return error.TestUnexpectedResult;
        }
    }
}
