//! M3 golden-results gate — `spec/fixtures/engine/results.json` (the Rust
//! engine is the execution oracle: nqlite/tests/m3_results.rs).
//!
//! Per case: join `setup` + `query` → M2 parser → M2 analyzer → M3 engine,
//! then compare:
//! - `results[i].rows_hex` **bit-for-bit** (`uleb128(len)` + per row
//!   `postcard(Record)` + `f32` LE score) — the authoritative byte gate;
//! - `results[i].rows` structurally (serde's externally-tagged JSON with
//!   sorted record keys — deep-equal, order-insensitive for objects);
//! - `kind` strings, and `error` variants for failing cases.

const std = @import("std");
const ir = @import("ir.zig");
const payload = @import("payload.zig");
const parser = @import("parser.zig");
const analyzer = @import("analyzer.zig");
const engine = @import("engine.zig");

fn readFile(gpa: std.mem.Allocator, name: []const u8) ![]const u8 {
    const io = std.testing.io;
    var tmp: [2][768]u8 = undefined;
    var cands: [2][]const u8 = undefined;
    var n: usize = 0;
    if (std.fs.path.dirname(@src().file)) |d| {
        cands[n] = try std.fmt.bufPrint(&tmp[n], "{s}/../spec/fixtures/engine/{s}", .{ d, name });
        n += 1;
    }
    cands[n] = try std.fmt.bufPrint(&tmp[n], "spec/fixtures/engine/{s}", .{name});
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

/// rows_hex: `uleb128(len)` + per row `postcard(Record)` + f32 LE score.
fn rowsHex(gpa: std.mem.Allocator, rows: []const engine.Row) ![]const u8 {
    var w = payload.Writer.init(gpa);
    defer w.deinit();
    try w.uleb(rows.len);
    for (rows) |row| {
        try w.record(row.record);
        try w.u32le(@bitCast(row.score));
    }
    return hex(gpa, w.bytes());
}

// ---------------------------------------------------------------------------
// Record → serde JSON (to_value ⇒ BTreeMap ⇒ sorted keys everywhere)
// ---------------------------------------------------------------------------

fn jsonStr(gpa: std.mem.Allocator, s: []const u8) !std.json.Value {
    return .{ .string = try gpa.dupe(u8, s) };
}

fn jsonObject(_: std.mem.Allocator) !std.json.ObjectMap {
    return std.json.ObjectMap.empty;
}

fn put(map: *std.json.ObjectMap, gpa: std.mem.Allocator, k: []const u8, v: std.json.Value) !void {
    try map.put(gpa, k, v);
}

fn jsonArr(gpa: std.mem.Allocator, items: []const std.json.Value) !std.json.Value {
    var list = std.json.Array.init(gpa);
    for (items) |v| try list.append(v);
    return .{ .array = list };
}

fn recordJson(gpa: std.mem.Allocator, rec: ir.Record) !std.json.Value {
    // serde to_value: struct → Map ⇒ keys SORTED: body, created_at, embedding, id.
    var m = try jsonObject(gpa);
    var body = try jsonObject(gpa);
    for (rec.body) |e| try put(&body, gpa, e.key, try valueJson(gpa, e.value));
    try put(&m, gpa, "body", .{ .object = body });
    try put(&m, gpa, "created_at", .{ .integer = rec.created_at });
    if (rec.embedding) |emb| {
        const arr = try gpa.alloc(std.json.Value, emb.len);
        for (emb, 0..) |f, i| arr[i] = .{ .float = @as(f64, f) };
        try put(&m, gpa, "embedding", try jsonArr(gpa, arr));
    } else {
        try put(&m, gpa, "embedding", .null);
    }
    try put(&m, gpa, "id", try recordIdJson(gpa, rec.id));
    return .{ .object = m };
}

fn recordIdJson(gpa: std.mem.Allocator, rid: ir.RecordId) !std.json.Value {
    // RecordId struct → sorted keys: id, table.
    var m = try jsonObject(gpa);
    var idv = try jsonObject(gpa);
    switch (rid.id) {
        .num => |n| try put(&idv, gpa, "Num", .{ .integer = @intCast(n) }),
        .str => |s| try put(&idv, gpa, "Str", try jsonStr(gpa, s)),
    }
    try put(&m, gpa, "id", .{ .object = idv });
    try put(&m, gpa, "table", try jsonStr(gpa, rid.table));
    return .{ .object = m };
}

fn valueJson(gpa: std.mem.Allocator, v: ir.Value) !std.json.Value {
    switch (v) {
        // Value::Null is a unit variant ⇒ serde_json emits the STRING "Null".
        .null => return try jsonStr(gpa, "Null"),
        .bool => |b| return tagged: {
            var m = try jsonObject(gpa);
            try put(&m, gpa, "Bool", .{ .bool = b });
            break :tagged .{ .object = m };
        },
        .int => |n| return tagged: {
            var m = try jsonObject(gpa);
            try put(&m, gpa, "Int", .{ .integer = n });
            break :tagged .{ .object = m };
        },
        .float => |f| return tagged: {
            var m = try jsonObject(gpa);
            try put(&m, gpa, "Float", .{ .float = f });
            break :tagged .{ .object = m };
        },
        .str => |s| return tagged: {
            var m = try jsonObject(gpa);
            try put(&m, gpa, "Str", try jsonStr(gpa, s));
            break :tagged .{ .object = m };
        },
        .doc => |entries| return tagged: {
            var inner = try jsonObject(gpa);
            for (entries) |e| try put(&inner, gpa, e.key, try valueJson(gpa, e.value));
            var m = try jsonObject(gpa);
            try put(&m, gpa, "Doc", .{ .object = inner });
            break :tagged .{ .object = m };
        },
        .arr => |items| return tagged: {
            const arr = try gpa.alloc(std.json.Value, items.len);
            for (items, 0..) |it, i| arr[i] = try valueJson(gpa, it);
            var m = try jsonObject(gpa);
            try put(&m, gpa, "Arr", try jsonArr(gpa, arr));
            break :tagged .{ .object = m };
        },
        .vector => |dims| return tagged: {
            const arr = try gpa.alloc(std.json.Value, dims.len);
            for (dims, 0..) |f, i| arr[i] = .{ .float = @as(f64, f) };
            var m = try jsonObject(gpa);
            try put(&m, gpa, "Vector", try jsonArr(gpa, arr));
            break :tagged .{ .object = m };
        },
        .ref => |rid| return tagged: {
            var m = try jsonObject(gpa);
            try put(&m, gpa, "Ref", try recordIdJson(gpa, rid));
            break :tagged .{ .object = m };
        },
    }
}

// ---------------------------------------------------------------------------
// Deep-equal over std.json.Value (objects order-insensitive, arrays ordered)
// ---------------------------------------------------------------------------

fn jsonEql(a: std.json.Value, b: std.json.Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) {
        // Integer/float: only compare when both are numeric — the fixture's
        // widened f32 scores arrive as floats exactly.
        return false;
    }
    switch (a) {
        .null => return true,
        .bool => |x| return x == b.bool,
        .integer => |x| return x == b.integer,
        .float => |x| return x == b.float,
        .number_string => |x| return std.mem.eql(u8, x, b.number_string),
        .string => |x| return std.mem.eql(u8, x, b.string),
        .array => |x| {
            const y = b.array;
            if (x.items.len != y.items.len) return false;
            for (x.items, y.items) |xa, ya| {
                if (!jsonEql(xa, ya)) return false;
            }
            return true;
        },
        .object => |x| {
            const y = b.object;
            if (x.count() != y.count()) return false;
            var it = x.iterator();
            while (it.next()) |e| {
                const other = y.get(e.key_ptr.*) orelse return false;
                if (!jsonEql(e.value_ptr.*, other)) return false;
            }
            return true;
        },
    }
}

fn fail(comptime fmt: []const u8, args: anytype) error{TestUnexpectedResult} {
    std.debug.print(fmt ++ "\n", args);
    return error.TestUnexpectedResult;
}

test "engine results match the Rust oracle" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const text = try readFile(gpa, "results.json");
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, text, .{});
    defer parsed.deinit();
    const cases = parsed.value.object.get("cases").?.array.items;

    var checked: usize = 0;
    for (cases) |case| {
        const name = case.object.get("name").?.string;
        const setup = case.object.get("setup").?.array.items;
        const query = case.object.get("query").?.string;
        const wants_error = case.object.get("error");

        // Join setup + query into one program (one analyzer context, as the
        // Rust oracle does).
        var src: std.ArrayList(u8) = .empty;
        for (setup) |s| {
            try src.appendSlice(gpa, s.string);
            try src.append(gpa, '\n');
        }
        try src.appendSlice(gpa, query);

        const outcome = try parser.parse(gpa, src.items);
        if (outcome != .ok) {
            return fail("case {s}: unexpected parse failure {s}:{d}:{d} {s}", .{
                name, @tagName(outcome.err.kind), outcome.err.line, outcome.err.col, outcome.err.message,
            });
        }

        const analyzed = try analyzer.analyze(gpa, outcome.ok);
        if (analyzed == .err) {
            const want = wants_error orelse
                return fail("case {s}: unexpected analysis error {s}", .{ name, analyzed.err.variant });
            if (!std.mem.eql(u8, want.string, analyzed.err.variant)) {
                return fail("case {s}: analysis error want={s} got={s}", .{ name, want.string, analyzed.err.variant });
            }
            checked += 1;
            continue;
        }

        var store = engine.EngineStore.init(gpa);
        const results = engine.executePlan(&store, analyzed.ok) catch |e| {
            const want = wants_error orelse
                return fail("case {s}: unexpected engine error {s}", .{ name, engine.errorVariant(e) });
            if (!std.mem.eql(u8, want.string, engine.errorVariant(e))) {
                return fail("case {s}: engine error want={s} got={s}", .{ name, want.string, engine.errorVariant(e) });
            }
            checked += 1;
            continue;
        };
        if (wants_error) |w| {
            return fail("case {s}: expected error {s}, got results", .{ name, w.string });
        }

        const want_results = case.object.get("results").?.array.items;
        if (want_results.len != results.len) {
            return fail("case {s}: results len want={d} got={d}", .{ name, want_results.len, results.len });
        }
        for (results, 0..) |res, i| {
            const wr = want_results[i];
            const kind: []const u8 = switch (res.kind) {
                .select => "select",
                .match_ => "match",
                .closure => "closure",
                .history => "history",
            };
            const wkind = wr.object.get("kind").?.string;
            if (!std.mem.eql(u8, wkind, kind)) {
                return fail("case {s}[{d}]: kind want={s} got={s}", .{ name, i, wkind, kind });
            }
            // Byte gate: rows_hex.
            const got_hex = try rowsHex(gpa, res.rows);
            const want_hex = wr.object.get("rows_hex").?.string;
            if (!std.mem.eql(u8, want_hex, got_hex)) {
                return fail("case {s}[{d}]: rows_hex\n  want {s}\n  got  {s}", .{ name, i, want_hex, got_hex });
            }
            // Structural gate: rows ([{record, score}]).
            const want_rows = wr.object.get("rows").?.array.items;
            if (want_rows.len != res.rows.len) {
                return fail("case {s}[{d}]: rows len want={d} got={d}", .{ name, i, want_rows.len, res.rows.len });
            }
            for (res.rows, 0..) |row, j| {
                var rm = try jsonObject(gpa);
                try put(&rm, gpa, "record", try recordJson(gpa, row.record));
                try put(&rm, gpa, "score", .{ .float = @as(f64, row.score) });
                if (!jsonEql(.{ .object = rm }, want_rows[j])) {
                    return fail("case {s}[{d}].rows[{d}]: structural mismatch (want {s})", .{
                        name, i, j, try std.json.Stringify.valueAlloc(gpa, want_rows[j], .{}),
                    });
                }
            }
        }
        checked += 1;
    }
    try std.testing.expect(checked >= 30);
}
