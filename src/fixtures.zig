//! Golden-fixture gate — `spec/fixtures/v4/` (the byte oracle vendored from
//! devstroop/nqlite, §5.7: "Where prose is ambiguous, the golden fixtures
//! are the oracle").
//!
//! Gates:
//! 1. every committed `.nql` decodes and re-encodes **byte-identically**;
//! 2. `manifest.json`'s section tables (offsets/len/crc32) match ours;
//! 3. `statements.json`: every Statement tag hex-round-trips, and the JSON
//!    twin maps to the same bytes (semantic pin: variant names, field
//!    names, tag numbers);
//! 4. the §5.1 loud-failure suite (every malformed container rejected);
//! 5. canonical RecordId ordering (`007` < `10` < `2` as BYTES, Num < Str).

const std = @import("std");
const ir = @import("ir.zig");
const payload = @import("payload.zig");
const v4 = @import("v4.zig");
const crc32mod = @import("crc32.zig");

const FIXTURES = [_][]const u8{ "empty.nql", "plain.nql", "rich.nql", "pruned.nql" };

fn readFixture(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    const io = std.testing.io;
    var b1: [768]u8 = undefined;
    var b2: [768]u8 = undefined;
    var cands: [2][]const u8 = undefined;
    var n: usize = 0;
    // Candidate 1: relative to this source file (repo layout).
    if (std.fs.path.dirname(@src().file)) |d| {
        cands[n] = try std.fmt.bufPrint(&b1, "{s}/../spec/fixtures/v4/{s}", .{ d, name });
        n += 1;
    }
    // Candidate 2: relative to cwd (the build root, when run from it).
    cands[n] = try std.fmt.bufPrint(&b2, "spec/fixtures/v4/{s}", .{name});
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

fn readFixtureText(gpa: std.mem.Allocator, name: []const u8) ![]const u8 {
    return readFixture(gpa, name);
}

// decode → encode → byte-exact, for every fixture (the M1 gate).
test "fixtures round-trip byte-exact" {
    for (FIXTURES) |name| {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const gpa = arena.allocator();

        const bytes = try readFixture(gpa, name);
        const store = try v4.decode(bytes, gpa);
        const again = try v4.encode(store, gpa);
        try std.testing.expectEqualSlices(u8, bytes, again);
    }
}

test "empty fixture layout is pinned (§5.1 arithmetic)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const bytes = try readFixture(gpa, "empty.nql");
    try std.testing.expectEqual(@as(usize, 144), bytes.len);
    const dir = try v4.parseDir(bytes);
    defer std.heap.page_allocator.free(dir);
    try std.testing.expectEqual(@as(usize, 3), dir.len);
    try std.testing.expectEqual(@as(u32, 1), dir[0].tag);
    try std.testing.expectEqual(@as(u64, 120), dir[0].off);
    try std.testing.expectEqual(@as(u64, 8), dir[0].len);
    try std.testing.expectEqual(@as(u32, 2), dir[1].tag);
    try std.testing.expectEqual(@as(u64, 128), dir[1].off);
    try std.testing.expectEqual(@as(u32, 7), dir[2].tag);
    try std.testing.expectEqual(@as(u64, 136), dir[2].off);
}

// Canonical RecordId order (§5.4): table bytes → `Num` < `Str` → value /
// bytes — digit-first string ids sort as strings, never numerically.
test "canonical record order" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const mk = struct {
        fn rec(id: ir.Id) ir.Record {
            return .{ .id = .{ .table = "a", .id = id }, .body = &[_]ir.DocEntry{}, .embedding = null, .created_at = 1 };
        }
    }.rec;
    const store = ir.Store{
        .tables = &[_]ir.TableEntry{ .{ .name = "a", .vector_dim = null }, .{ .name = "b", .vector_dim = null } },
        .records = &[_]ir.Record{
            mk(.{ .num = 1 }),
            mk(.{ .num = 5 }),
            mk(.{ .str = "007" }),
            mk(.{ .str = "10" }),
            mk(.{ .str = "2" }),
            .{ .id = .{ .table = "b", .id = .{ .num = 0 } }, .body = &[_]ir.DocEntry{}, .embedding = null, .created_at = 1 },
        },
        .edges = &[_]ir.RelationEdge{},
        .clock = 1,
        .history = &[_]ir.HistoryEntry{},
        .memories = &[_]ir.Memory{},
    };
    const bytes = try v4.encode(store, gpa);
    const dec = try v4.decode(bytes, gpa);
    try std.testing.expectEqual(@as(usize, 6), dec.records.len);
    const expect_ids = [_]ir.Id{
        .{ .num = 1 }, .{ .num = 5 }, .{ .str = "007" }, .{ .str = "10" }, .{ .str = "2" }, .{ .num = 0 },
    };
    const expect_tables = [_][]const u8{ "a", "a", "a", "a", "a", "b" };
    for (expect_ids, expect_tables, 0..) |want_id, want_table, i| {
        try std.testing.expectEqualStrings(want_table, dec.records[i].id.table);
        try std.testing.expect(idEql(want_id, dec.records[i].id.id));
    }
    // And re-encode is byte-exact.
    const again = try v4.encode(dec, gpa);
    try std.testing.expectEqualSlices(u8, bytes, again);
}

fn idEql(a: ir.Id, b: ir.Id) bool {
    return switch (a) {
        .num => |x| switch (b) {
            .num => |y| x == y,
            .str => false,
        },
        .str => |x| switch (b) {
            .num => false,
            .str => |y| std.mem.eql(u8, x, y),
        },
    };
}

// ---------------------------------------------------------------------------
// manifest.json — independent section-table expectations
// ---------------------------------------------------------------------------

test "manifest matches our parse" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const text = try readFixtureText(gpa, "manifest.json");
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, text, .{});
    // arena owns everything; keep parsed alive for the scope regardless.
    defer parsed.deinit();
    const fixtures = parsed.value.object.get("fixtures").?;

    for (fixtures.array.items) |entry| {
        const file = entry.object.get("file").?.string;
        const want_bytes: usize = @intCast(entry.object.get("bytes").?.integer);
        const bytes = try readFixture(gpa, file);
        try std.testing.expectEqual(want_bytes, bytes.len);
        const dir = try v4.parseDir(bytes);
        defer std.heap.page_allocator.free(dir);

        const sections = entry.object.get("sections").?.array.items;
        try std.testing.expectEqual(dir.len, sections.len);
        for (sections, 0..) |want, i| {
            try std.testing.expectEqual(@as(u32, @intCast(want.object.get("tag").?.integer)), dir[i].tag);
            try std.testing.expectEqual(@as(u64, @intCast(want.object.get("offset").?.integer)), dir[i].off);
            try std.testing.expectEqual(@as(u64, @intCast(want.object.get("len").?.integer)), dir[i].len);
            try std.testing.expectEqual(@as(u32, @intCast(want.object.get("crc32").?.integer)), dir[i].crc);
        }
    }
}

// ---------------------------------------------------------------------------
// statements.json — hex round-trip + JSON-semantic twin
// ---------------------------------------------------------------------------

fn hexDecode(gpa: std.mem.Allocator, h: []const u8) ![]u8 {
    const out = try gpa.alloc(u8, h.len / 2);
    _ = try std.fmt.hexToBytes(out, h);
    return out;
}

fn expectedTag(name: []const u8) u32 {
    const names = [_]struct { n: []const u8, t: u32 }{
        .{ .n = "CreateTable", .t = 0 },   .{ .n = "Insert", .t = 1 },
        .{ .n = "Relate", .t = 2 },        .{ .n = "Select", .t = 3 },
        .{ .n = "Match", .t = 4 },         .{ .n = "Closure", .t = 5 },
        .{ .n = "Forget", .t = 6 },        .{ .n = "Memory", .t = 7 },
        .{ .n = "ContextReset", .t = 8 },  .{ .n = "MatchCount", .t = 9 },
        .{ .n = "PruneHistory", .t = 10 }, .{ .n = "Snapshot", .t = 11 },
        .{ .n = "HistorySince", .t = 12 },
    };
    for (names) |e| if (std.mem.eql(u8, e.n, name)) return e.t;
    return 0xFFFF;
}

test "statements.json oracle" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const text = try readFixture(gpa, "statements.json");
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, text, .{});
    defer parsed.deinit();

    var seen: u32 = 0;
    for (parsed.value.array.items) |entry| {
        const name = entry.object.get("name").?.string;
        const tag: u32 = @intCast(entry.object.get("tag").?.integer);
        try std.testing.expectEqual(expectedTag(name), tag);
        seen |= @as(u32, 1) << @intCast(tag);

        const hexed = entry.object.get("hex").?.string;
        const hex_bytes = try hexDecode(gpa, hexed);

        // Layer 1: hex → Statement → hex (codec stability, all 13 tags).
        var r = payload.Reader.init(hex_bytes);
        const stmt = try r.statement(gpa);
        try std.testing.expectEqual(hex_bytes.len, r.pos);
        var w = payload.Writer.init(gpa);
        defer w.deinit();
        try w.statement(stmt);
        try std.testing.expectEqualSlices(u8, hex_bytes, w.bytes());
        try std.testing.expectEqual(tag, @as(u32, @backingInt(std.meta.activeTag(stmt))));

        // Layer 2: JSON twin → Statement → hex (semantic pin). Snapshot's
        // json is null by design (RecordId map keys are not JSON-representable).
        const jv = entry.object.get("json").?;
        if (jv != .null) {
            const stmt2 = try jsonToStatement(jv, gpa);
            var w2 = payload.Writer.init(gpa);
            defer w2.deinit();
            try w2.statement(stmt2);
            try std.testing.expectEqualSlices(u8, hex_bytes, w2.bytes());
        }
    }
    try std.testing.expectEqual(@as(u32, 0b1_1111_1111_1111), seen);
}

// ---------------------------------------------------------------------------
// JSON (serde externally-tagged) → IR
// ---------------------------------------------------------------------------

const JErr = error{ BadJson, OutOfMemory };

fn jstr(v: std.json.Value) JErr![]const u8 {
    return switch (v) {
        .string => |s| s,
        else => error.BadJson,
    };
}

fn jint(v: std.json.Value) JErr!i64 {
    return switch (v) {
        .integer => |i| i,
        else => error.BadJson,
    };
}

fn jusize(v: std.json.Value) JErr!usize {
    const i = try jint(v);
    if (i < 0) return error.BadJson;
    return @intCast(i);
}

fn jf64(v: std.json.Value) JErr!f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        .number_string => |s| std.fmt.parseFloat(f64, s) catch error.BadJson,
        else => error.BadJson,
    };
}

fn jf32(v: std.json.Value) JErr!f32 {
    return @floatCast(try jf64(v));
}

fn jopt(v: std.json.Value) ?std.json.Value {
    return if (v == .null) null else v;
}

fn jreq(v: std.json.Value, key: []const u8) JErr!std.json.Value {
    const o = switch (v) {
        .object => |obj| obj,
        else => return error.BadJson,
    };
    if (o.get(key)) |val| return val;
    return error.BadJson;
}

fn jsonToRecordId(v: std.json.Value) JErr!ir.RecordId {
    const table = try jstr(try jreq(v, "table"));
    const idv = try jreq(v, "id");
    const t = try jtaggedNoAlloc(idv);
    if (std.mem.eql(u8, t.name, "Num")) return .{ .table = table, .id = .{ .num = @intCast(try jint(t.payload)) } };
    if (std.mem.eql(u8, t.name, "Str")) return .{ .table = table, .id = .{ .str = try jstr(t.payload) } };
    return error.BadJson;
}

/// Tagged view without allocation (key borrowed from the parsed document).
fn jtaggedNoAlloc(v: std.json.Value) JErr!struct { name: []const u8, payload: std.json.Value } {
    const o = switch (v) {
        .object => |obj| obj,
        else => return error.BadJson,
    };
    var it = o.iterator();
    const e = it.next() orelse return error.BadJson;
    return .{ .name = e.key_ptr.*, .payload = e.value_ptr.* };
}

fn jsonToValue(v: std.json.Value, gpa: std.mem.Allocator) JErr!ir.Value {
    switch (v) {
        .string => |s| {
            if (std.mem.eql(u8, s, "Null")) return .null;
            return error.BadJson;
        },
        else => {},
    }
    const t = try jtaggedNoAlloc(v);
    if (std.mem.eql(u8, t.name, "Bool")) return .{ .bool = switch (t.payload) {
        .bool => |b| b,
        else => return error.BadJson,
    } };
    if (std.mem.eql(u8, t.name, "Int")) return .{ .int = try jint(t.payload) };
    if (std.mem.eql(u8, t.name, "Float")) return .{ .float = try jf64(t.payload) };
    if (std.mem.eql(u8, t.name, "Str")) return .{ .str = try jstr(t.payload) };
    if (std.mem.eql(u8, t.name, "Doc")) return .{ .doc = try jsonToDoc(t.payload, gpa) };
    if (std.mem.eql(u8, t.name, "Arr")) {
        const items = try gpa.alloc(ir.Value, t.payload.array.items.len);
        for (t.payload.array.items, 0..) |item, i| items[i] = try jsonToValue(item, gpa);
        return .{ .arr = items };
    }
    if (std.mem.eql(u8, t.name, "Vector")) {
        const dims = try gpa.alloc(f32, t.payload.array.items.len);
        for (t.payload.array.items, 0..) |item, i| dims[i] = try jf32(item);
        return .{ .vector = dims };
    }
    if (std.mem.eql(u8, t.name, "Ref")) return .{ .ref = try jsonToRecordId(t.payload) };
    return error.BadJson;
}

fn jsonToDoc(v: std.json.Value, gpa: std.mem.Allocator) JErr![]const ir.DocEntry {
    const o = switch (v) {
        .object => |obj| obj,
        else => return error.BadJson,
    };
    const entries = try gpa.alloc(ir.DocEntry, o.count());
    var i: usize = 0;
    // Insertion order = serde's BTree (byte-sorted) document order.
    var it = o.iterator();
    var prev: ?[]const u8 = null;
    while (it.next()) |e| : (i += 1) {
        if (prev) |p| {
            if (std.mem.order(u8, p, e.key_ptr.*) != .lt) return error.BadJson;
        }
        prev = e.key_ptr.*;
        entries[i] = .{ .key = e.key_ptr.*, .value = try jsonToValue(e.value_ptr.*, gpa) };
    }
    return entries;
}

fn jsonToRecord(v: std.json.Value, gpa: std.mem.Allocator) JErr!ir.Record {
    return .{
        .id = try jsonToRecordId(try jreq(v, "id")),
        .body = try jsonToDoc(try jreq(v, "body"), gpa),
        .embedding = blk: {
            const e = jopt(try jreq(v, "embedding")) orelse break :blk null;
            const dims = try gpa.alloc(f32, e.array.items.len);
            for (e.array.items, 0..) |item, i| dims[i] = try jf32(item);
            break :blk dims;
        },
        .created_at = try jint(try jreq(v, "created_at")),
    };
}

fn jsonToEdge(v: std.json.Value, gpa: std.mem.Allocator) JErr!ir.RelationEdge {
    return .{
        .from = try jsonToRecordId(try jreq(v, "from")),
        .name = try jstr(try jreq(v, "name")),
        .to = try jsonToRecordId(try jreq(v, "to")),
        .created_at = try jint(try jreq(v, "created_at")),
        .weight = blk: {
            const w = jopt(try jreq(v, "weight")) orelse break :blk null;
            break :blk try jf32(w);
        },
        .props = try jsonToDoc(try jreq(v, "props"), gpa),
    };
}

fn jsonToFilter(v: std.json.Value, gpa: std.mem.Allocator) JErr!ir.Filter {
    switch (v) {
        .string => |s| {
            if (std.mem.eql(u8, s, "HasEmbedding")) return .has_embedding;
            return error.BadJson;
        },
        else => {},
    }
    const t = try jtaggedNoAlloc(v);
    if (std.mem.eql(u8, t.name, "FieldEquals")) {
        const p = t.payload;
        return .{ .field_equals = .{ .field = try jstr(try jreq(p, "field")), .value = try jsonToValue(try jreq(p, "value"), gpa) } };
    }
    if (std.mem.eql(u8, t.name, "Bm25")) {
        const p = t.payload;
        return .{ .bm25 = .{
            .field = try jstr(try jreq(p, "field")),
            .query = try jstr(try jreq(p, "query")),
            .k = blk: {
                const k = jopt(try jreq(p, "k")) orelse break :blk null;
                break :blk try jusize(k);
            },
        } };
    }
    if (std.mem.eql(u8, t.name, "FieldCmp")) {
        const p = t.payload;
        return .{ .field_cmp = .{
            .field = try jstr(try jreq(p, "field")),
            .op = try jsonToCmpOp(try jreq(p, "op")),
            .value = try jsonToValue(try jreq(p, "value"), gpa),
        } };
    }
    if (std.mem.eql(u8, t.name, "FieldIn")) {
        const p = t.payload;
        const arr = (try jreq(p, "values")).array.items;
        const values = try gpa.alloc(ir.Value, arr.len);
        for (arr, 0..) |item, i| values[i] = try jsonToValue(item, gpa);
        return .{ .field_in = .{ .field = try jstr(try jreq(p, "field")), .values = values } };
    }
    if (std.mem.eql(u8, t.name, "FieldBetween")) {
        const p = t.payload;
        return .{ .field_between = .{
            .field = try jstr(try jreq(p, "field")),
            .lo = try jsonToValue(try jreq(p, "lo"), gpa),
            .hi = try jsonToValue(try jreq(p, "hi"), gpa),
        } };
    }
    if (std.mem.eql(u8, t.name, "And")) {
        const arr = t.payload.array.items;
        const items = try gpa.alloc(ir.Filter, arr.len);
        for (arr, 0..) |item, i| items[i] = try jsonToFilter(item, gpa);
        return .{ .and_filter = items };
    }
    return error.BadJson;
}

fn jsonToCmpOp(v: std.json.Value) JErr!ir.CmpOp {
    const s = try jstr(v);
    if (std.mem.eql(u8, s, "Ne")) return .ne;
    if (std.mem.eql(u8, s, "Lt")) return .lt;
    if (std.mem.eql(u8, s, "Le")) return .le;
    if (std.mem.eql(u8, s, "Gt")) return .gt;
    if (std.mem.eql(u8, s, "Ge")) return .ge;
    return error.BadJson;
}

fn jsonToOrder(v: std.json.Value, gpa: std.mem.Allocator) JErr!ir.Order {
    switch (v) {
        .string => |s| {
            if (std.mem.eql(u8, s, "Similarity")) return .similarity;
            if (std.mem.eql(u8, s, "Salience")) return .salience;
            if (std.mem.eql(u8, s, "Score")) return .score;
            if (std.mem.eql(u8, s, "Votes")) return .votes;
            if (std.mem.eql(u8, s, "Feedback")) return .feedback;
            if (std.mem.eql(u8, s, "Recency")) return .recency;
            return error.BadJson;
        },
        else => {},
    }
    const t = try jtaggedNoAlloc(v);
    if (std.mem.eql(u8, t.name, "SalienceWeighted")) {
        const arr = t.payload.array.items;
        if (arr.len != 4) return error.BadJson;
        var w: [4]f32 = undefined;
        for (arr, 0..) |item, i| w[i] = try jf32(item);
        return .{ .salience_weighted = w };
    }
    if (std.mem.eql(u8, t.name, "Field")) {
        return .{ .field = .{
            .key = try jstr(try jreq(t.payload, "key")),
            .desc = switch (try jreq(t.payload, "desc")) {
                .bool => |b| b,
                else => return error.BadJson,
            },
        } };
    }
    _ = gpa;
    return error.BadJson;
}

fn jsonToMatchPath(v: std.json.Value, gpa: std.mem.Allocator) JErr!ir.MatchPath {
    const steps_raw = (try jreq(v, "steps")).array.items;
    const steps = try gpa.alloc(ir.MatchStep, steps_raw.len);
    for (steps_raw, 0..) |sv, i| {
        const direction: ir.MatchDirection = blk: {
            const s = try jstr(try jreq(sv, "direction"));
            if (std.mem.eql(u8, s, "Out")) break :blk .out;
            if (std.mem.eql(u8, s, "In")) break :blk .in;
            return error.BadJson;
        };
        const edge_props = blk: {
            const e = jopt(try jreq(sv, "edge_props")) orelse break :blk null;
            break :blk try jsonToFilter(e, gpa);
        };
        steps[i] = .{
            .direction = direction,
            .name = try jstr(try jreq(sv, "name")),
            .edge_props = edge_props,
        };
    }
    const as_of = blk: {
        const a = jopt(try jreq(v, "as_of")) orelse break :blk null;
        break :blk try jint(a);
    };
    return .{ .start = try jsonToRecordId(try jreq(v, "start")), .steps = steps, .as_of = as_of };
}

fn jsonToStatement(v: std.json.Value, gpa: std.mem.Allocator) JErr!ir.Statement {
    switch (v) {
        .string => |s| {
            if (std.mem.eql(u8, s, "ContextReset")) return .context_reset;
            if (std.mem.eql(u8, s, "PruneHistory")) return .prune_history;
            return error.BadJson;
        },
        else => {},
    }
    const t = try jtaggedNoAlloc(v);
    if (std.mem.eql(u8, t.name, "CreateTable")) {
        const dim = blk: {
            const d = jopt(try jreq(t.payload, "vector_dim")) orelse break :blk null;
            break :blk try jusize(d);
        };
        return .{ .create_table = .{ .table = try jstr(try jreq(t.payload, "table")), .vector_dim = dim } };
    }
    if (std.mem.eql(u8, t.name, "Insert")) return .{ .insert = try jsonToRecord(t.payload, gpa) };
    if (std.mem.eql(u8, t.name, "Relate")) return .{ .relate = try jsonToEdge(t.payload, gpa) };
    if (std.mem.eql(u8, t.name, "Select")) return .{ .select = try jsonToSelect(t.payload, gpa) };
    if (std.mem.eql(u8, t.name, "Match")) return .{ .match_path = try jsonToMatchPath(t.payload, gpa) };
    if (std.mem.eql(u8, t.name, "Closure")) return .{ .closure = try jsonToMatchPath(t.payload, gpa) };
    if (std.mem.eql(u8, t.name, "MatchCount")) return .{ .match_count = try jsonToMatchPath(t.payload, gpa) };
    if (std.mem.eql(u8, t.name, "Forget")) return .{ .forget = .{ .id = try jsonToRecordId(try jreq(t.payload, "id")) } };
    if (std.mem.eql(u8, t.name, "Memory")) return .{ .memory = .{ .name = try jstr(try jreq(t.payload, "name")) } };
    if (std.mem.eql(u8, t.name, "HistorySince")) return .{ .history_since = try jint(t.payload) };
    return error.BadJson;
}

fn jsonToSelect(v: std.json.Value, gpa: std.mem.Allocator) JErr!ir.Select {
    const knn: ?ir.Knn = blk: {
        const k = jopt(try jreq(v, "knn")) orelse break :blk null;
        const qraw = (try jreq(k, "query")).array.items;
        const query = try gpa.alloc(f32, qraw.len);
        for (qraw, 0..) |item, i| query[i] = try jf32(item);
        break :blk .{ .query = query, .k = try jusize(try jreq(k, "k")) };
    };
    const filter = blk: {
        const f = jopt(try jreq(v, "filter")) orelse break :blk null;
        break :blk try jsonToFilter(f, gpa);
    };
    const order = blk: {
        const o = jopt(try jreq(v, "order")) orelse break :blk null;
        break :blk try jsonToOrder(o, gpa);
    };
    const limit = blk: {
        const l = jopt(try jreq(v, "limit")) orelse break :blk null;
        break :blk try jusize(l);
    };
    const as_of = blk: {
        const a = jopt(try jreq(v, "as_of")) orelse break :blk null;
        break :blk try jint(a);
    };
    const fields = blk: {
        const f = jopt(try jreq(v, "fields")) orelse break :blk null;
        const raw = f.array.items;
        const list = try gpa.alloc([]const u8, raw.len);
        for (raw, 0..) |item, i| list[i] = try jstr(item);
        break :blk list;
    };
    const offset = blk: {
        const o = jopt(try jreq(v, "offset")) orelse break :blk null;
        break :blk try jusize(o);
    };
    const aggregate = blk: {
        const a = jopt(try jreq(v, "aggregate")) orelse break :blk null;
        const s = try jstr(a);
        if (!std.mem.eql(u8, s, "CountStar")) return error.BadJson;
        break :blk ir.Aggregate.count_star;
    };
    return .{
        .table = try jstr(try jreq(v, "table")),
        .knn = knn,
        .filter = filter,
        .order = order,
        .limit = limit,
        .as_of = as_of,
        .fields = fields,
        .offset = offset,
        .aggregate = aggregate,
    };
}

// ---------------------------------------------------------------------------
// §5.1 loud-failure suite
// ---------------------------------------------------------------------------

fn fixCrc(buf: []u8, dir: []const v4.DirEnt, tag: u32) void {
    for (dir, 0..) |e, i| {
        if (e.tag == tag) {
            const c = crc32mod.crc32(buf[e.off .. e.off + e.len]);
            const field = 24 + 32 * i + 24;
            std.mem.writeInt(u32, buf[field .. field + 4][0..4], c, .little);
            return;
        }
    }
}

test "reader rejects malformed containers" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const base = try readFixture(gpa, "plain.nql");
    const dir = try v4.parseDir(base);
    defer std.heap.page_allocator.free(dir);
    const recs_e: v4.DirEnt = for (dir) |e| {
        if (e.tag == 2) break e;
    } else unreachable;

    // bad magic
    {
        const b = try gpa.dupe(u8, base);
        b[0] ^= 0x01;
        try std.testing.expectError(error.BadMagic, v4.decode(b, gpa));
    }
    // version 5
    {
        const b = try gpa.dupe(u8, base);
        std.mem.writeInt(u32, b[8..12], 5, .little);
        try std.testing.expectError(error.BadVersion, v4.decode(b, gpa));
    }
    // flags != 0
    {
        const b = try gpa.dupe(u8, base);
        b[12] = 1;
        try std.testing.expectError(error.BadFlags, v4.decode(b, gpa));
    }
    // truncated section table
    {
        const b = try gpa.dupe(u8, base);
        try std.testing.expectError(error.Truncated, v4.decode(b[0..30], gpa));
    }
    // CRC mismatch (last payload byte flipped)
    {
        const b = try gpa.dupe(u8, base);
        b[b.len - 1] ^= 0xff;
        try std.testing.expectError(error.CrcMismatch, v4.decode(b, gpa));
    }
    // required section missing: 2-entry directory, CLOCK dropped
    {
        var b: std.ArrayList(u8) = .empty;
        defer b.deinit(gpa);
        try b.appendSlice(gpa, base[0..16]);
        try b.appendSlice(gpa, &[_]u8{ 2, 0, 0, 0 }); // u32 LE = 2
        try b.appendSlice(gpa, base[20..24]);
        try b.appendSlice(gpa, base[24..88]);
        try b.appendNTimes(gpa, 0, dir[0].off - b.items.len);
        try b.appendSlice(gpa, base[dir[0].off .. dir[1].off + dir[1].len]);
        try std.testing.expectError(error.RequiredMissing, v4.decode(b.items, gpa));
    }
    // unknown tag
    {
        const b = try gpa.dupe(u8, base);
        std.mem.writeInt(u32, b[24..28], 9, .little);
        try std.testing.expectError(error.UnknownTag, v4.decode(b, gpa));
    }
    // duplicate / non-ascending tag
    {
        const b = try gpa.dupe(u8, base);
        std.mem.writeInt(u32, b[56..60], 1, .little);
        try std.testing.expectError(error.NotAscending, v4.decode(b, gpa));
    }
    // out-of-bounds length (last entry's len field)
    {
        const b = try gpa.dupe(u8, base);
        const last = dir.len - 1;
        const field: usize = 24 + 32 * last + 16;
        std.mem.writeInt(u64, b[field .. field + 8][0..8], @as(u64, 1) << 40, .little);
        try std.testing.expectError(error.OutOfBounds, v4.decode(b, gpa));
    }
    // semantic: table_idx beyond TABLES (CRC repaired to reach the check)
    {
        const b = try gpa.dupe(u8, base);
        std.mem.writeInt(u32, b[recs_e.off + 8 ..][0..4], 9, .little);
        fixCrc(b, dir, 2);
        try std.testing.expectError(error.TableIdxRange, v4.decode(b, gpa));
    }
    // semantic: string id without a STRINGS section
    {
        const b = try gpa.dupe(u8, base);
        b[recs_e.off + 12] = 1; // id_kind = 1
        fixCrc(b, dir, 2);
        try std.testing.expectError(error.StringIdBeforeHeap, v4.decode(b, gpa));
    }
}
