//! MCP stdio server — port of `nql-mcp` (rmcp SDK replaced by a small
//! hand-rolled JSON-RPC loop; zero external deps).
//!
//! Wire contract (oracle: `capture_mcp_oracle.py` → `mcp_schemas.zig`):
//! newline-delimited JSON-RPC2.0 — `initialize` / `notifications/initialized`
//! / `tools/list` (8 tools, alphabetical, verbatim descriptions+schemas) /
//! `tools/call`; tool texts are **serde_json `to_string_pretty` shaped**
//! (2-space indent, `": "` separators, map keys in sorted order — matching
//! the reference's `BTreeMap` emission), mutations answer `OK`, engine
//! failures answer `ERR {message}`, results answer `ERR …`-free JSON.
//! `--db PATH` shares `cli.Session`'s Database path (WAL duties included).

const std = @import("std");
const Io = std.Io;
const cli = @import("cli.zig");
const engine = @import("engine.zig");
const ir = @import("ir.zig");
const parser = @import("parser.zig");
const schemas = @import("mcp_schemas.zig");
const server = @import("server.zig");

pub const BANNER = "nql-mcp: serving nqlite over MCP stdio";

// ---------------------------------------------------------------------------
// Minimal JSON value + serde_json-compatible emitters
// ---------------------------------------------------------------------------

const KV = struct { key: []const u8, val: Json };

const Json = union(enum) {
    null,
    bool: bool,
    int: i64,
    f64v: f64,
    str: []const u8,
    arr: []const Json,
    obj: []const KV, // insertion order IS the output order (we insert sorted)
};

fn emitString(out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    try out.append(gpa, '"');
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        switch (c) {
            '"' => try out.appendSlice(gpa, "\\\""),
            '\\' => try out.appendSlice(gpa, "\\\\"),
            '\n' => try out.appendSlice(gpa, "\\n"),
            '\r' => try out.appendSlice(gpa, "\\r"),
            '\t' => try out.appendSlice(gpa, "\\t"),
            0x08 => try out.appendSlice(gpa, "\\b"),
            0x0c => try out.appendSlice(gpa, "\\f"),
            else => {
                if (c < 0x20) {
                    var ubuf: [8]u8 = undefined;
                    const us = std.fmt.bufPrint(&ubuf, "\\u{x:0>4}", .{c}) catch unreachable;
                    try out.appendSlice(gpa, us);
                } else {
                    try out.append(gpa, c);
                }
            },
        }
        i += 1;
    }
    try out.append(gpa, '"');
}

/// serde/ryu always renders integral floats with a decimal point (`0.0`,
/// never `0`); zig's `{d}` may omit it — normalize.
fn emitFloat(out: *std.ArrayList(u8), gpa: std.mem.Allocator, x: f64) !void {
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{x}) catch unreachable;
    try out.appendSlice(gpa, s);
    if (std.mem.indexOfAny(u8, s, ".eE") == null) try out.appendSlice(gpa, ".0");
}

fn emitCompact(out: *std.ArrayList(u8), gpa: std.mem.Allocator, v: Json) !void {
    switch (v) {
        .null => try out.appendSlice(gpa, "null"),
        .bool => |b| try out.appendSlice(gpa, if (b) "true" else "false"),
        .int => |n| try out.appendSlice(gpa, try std.fmt.allocPrint(gpa, "{d}", .{n})),
        .f64v => |f| try emitFloat(out, gpa, f),
        .str => |s| try emitString(out, gpa, s),
        .arr => |items| {
            try out.append(gpa, '[');
            for (items, 0..) |it, i| {
                if (i > 0) try out.append(gpa, ',');
                try emitCompact(out, gpa, it);
            }
            try out.append(gpa, ']');
        },
        .obj => |kvs| {
            try out.append(gpa, '{');
            for (kvs, 0..) |kv, i| {
                if (i > 0) try out.append(gpa, ',');
                try emitString(out, gpa, kv.key);
                try out.append(gpa, ':');
                try emitCompact(out, gpa, kv.val);
            }
            try out.append(gpa, '}');
        },
    }
}

/// serde_json::to_string_pretty:2-space indent, `": "`, entries on their
/// own lines, empty containers compact (`[]` / `{}`).
fn emitPretty(out: *std.ArrayList(u8), gpa: std.mem.Allocator, v: Json, depth: usize) !void {
    switch (v) {
        .arr => |items| {
            if (items.len == 0) return out.appendSlice(gpa, "[]");
            try out.append(gpa, '[');
            for (items, 0..) |it, i| {
                try out.append(gpa, '\n');
                try out.appendNTimes(gpa, ' ', (depth + 1) * 2);
                try emitPretty(out, gpa, it, depth + 1);
                if (i + 1 < items.len) try out.append(gpa, ',');
            }
            try out.append(gpa, '\n');
            try out.appendNTimes(gpa, ' ', depth * 2);
            try out.append(gpa, ']');
        },
        .obj => |kvs| {
            if (kvs.len == 0) return out.appendSlice(gpa, "{}");
            try out.append(gpa, '{');
            for (kvs, 0..) |kv, i| {
                try out.append(gpa, '\n');
                try out.appendNTimes(gpa, ' ', (depth + 1) * 2);
                try emitString(out, gpa, kv.key);
                try out.appendSlice(gpa, ": ");
                try emitPretty(out, gpa, kv.val, depth + 1);
                if (i + 1 < kvs.len) try out.append(gpa, ',');
            }
            try out.append(gpa, '\n');
            try out.appendNTimes(gpa, ' ', depth * 2);
            try out.append(gpa, '}');
        },
        else => try emitCompact(out, gpa, v),
    }
}

fn prettyText(gpa: std.mem.Allocator, v: Json) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try emitPretty(&out, gpa, v, 0);
    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// std.json (input) → our Json / ir.Value (BTreeMap key order, matching the
// reference's serde_json Value → nql path)
// ---------------------------------------------------------------------------

fn fromStd(gpa: std.mem.Allocator, v: std.json.Value) !Json {
    switch (v) {
        .null => return .null,
        .bool => |b| return .{ .bool = b },
        .integer => |n| return .{ .int = n },
        .float => |f| return .{ .f64v = f },
        .number_string => |s| {
            if (std.fmt.parseInt(i64, s, 10)) |n| return .{ .int = n } else |_| {}
            if (std.fmt.parseFloat(f64, s)) |f| return .{ .f64v = f } else |_| {}
            return .{ .str = s };
        },
        .string => |s| return .{ .str = s },
        .array => |list| {
            var items: std.ArrayList(Json) = .empty;
            try items.ensureTotalCapacity(gpa, list.items.len);
            for (list.items) |it| try items.append(gpa, try fromStd(gpa, it));
            return .{ .arr = try items.toOwnedSlice(gpa) };
        },
        .object => |map| {
            const ks = map.keys();
            const vs = map.values();
            var kvs: std.ArrayList(KV) = .empty;
            try kvs.ensureTotalCapacity(gpa, ks.len);
            for (ks, vs) |k, v2| try kvs.append(gpa, .{ .key = k, .val = try fromStd(gpa, v2) });
            return .{ .obj = try kvs.toOwnedSlice(gpa) };
        },
    }
}

fn lessThanKey(_: void, a: ir.DocEntry, b: ir.DocEntry) bool {
    return std.mem.lessThan(u8, a.key, b.key);
}

fn jsonToIr(gpa: std.mem.Allocator, v: std.json.Value) !ir.Value {
    switch (v) {
        .null => return .null,
        .bool => |b| return .{ .bool = b },
        .integer => |n| return .{ .int = n },
        .float => |f| return .{ .float = f },
        .string => |s| return .{ .str = s },
        .number_string => |s| {
            if (std.fmt.parseInt(i64, s, 10)) |n| return .{ .int = n } else |_| {}
            if (std.fmt.parseFloat(f64, s)) |f| return .{ .float = f } else |_| {}
            return .{ .str = s };
        },
        .array => |list| {
            var vals: std.ArrayList(ir.Value) = .empty;
            for (list.items) |it| try vals.append(gpa, try jsonToIr(gpa, it));
            return .{ .arr = try vals.toOwnedSlice(gpa) };
        },
        .object => |map| {
            const ks = map.keys();
            const vs = map.values();
            var entries: std.ArrayList(ir.DocEntry) = .empty;
            for (ks, vs) |k, v2| {
                try entries.append(gpa, .{ .key = k, .value = try jsonToIr(gpa, v2) });
            }
            // serde_json → nql converts objects through a BTreeMap: sorted.
            std.sort.heap(ir.DocEntry, entries.items, {}, lessThanKey);
            return .{ .doc = try entries.toOwnedSlice(gpa) };
        },
    }
}

fn jsonToDoc(gpa: std.mem.Allocator, v: std.json.Value) !?[]const ir.DocEntry {
    const val = try jsonToIr(gpa, v);
    return switch (val) {
        .doc => |entries| entries,
        else => null,
    };
}

fn irToJson(gpa: std.mem.Allocator, val: ir.Value) !Json {
    switch (val) {
        .null => return .null,
        .bool => |b| return .{ .bool = b },
        .int => |n| return .{ .int = n },
        .float => |f| return .{ .f64v = f },
        .str => |s| return .{ .str = s },
        .doc => |entries| {
            var kvs: std.ArrayList(KV) = .empty;
            for (entries) |e| try kvs.append(gpa, .{ .key = e.key, .val = try irToJson(gpa, e.value) });
            return .{ .obj = try kvs.toOwnedSlice(gpa) };
        },
        .arr => |vs| {
            var items: std.ArrayList(Json) = .empty;
            for (vs) |v2| try items.append(gpa, try irToJson(gpa, v2));
            return .{ .arr = try items.toOwnedSlice(gpa) };
        },
        .vector => |xs| {
            var items: std.ArrayList(Json) = .empty;
            for (xs) |x| try items.append(gpa, .{ .f64v = @as(f64, x) });
            return .{ .arr = try items.toOwnedSlice(gpa) };
        },
        .ref => |rid| return .{ .str = try ir.recordIdDisplay(gpa, rid) },
    }
}

// ---------------------------------------------------------------------------
// Results → response JSON (reference: `value_to_json`, BTreeMap key order)
// ---------------------------------------------------------------------------

fn rowToJson(gpa: std.mem.Allocator, row: engine.Row) !Json {
    // sorted key order: body < id < score (heap: the Json borrows this)
    const kvs = try gpa.alloc(KV, 3);
    kvs[0] = .{ .key = "body", .val = try irToJson(gpa, .{ .doc = row.record.body }) };
    kvs[1] = .{ .key = "id", .val = .{ .str = try ir.recordIdDisplay(gpa, row.record.id) } };
    kvs[2] = .{ .key = "score", .val = .{ .f64v = @as(f64, row.score) } };
    return .{ .obj = kvs };
}

fn rowsArrJson(gpa: std.mem.Allocator, rows: []const engine.Row) !Json {
    var items: std.ArrayList(Json) = .empty;
    for (rows) |row| try items.append(gpa, try rowToJson(gpa, row));
    return .{ .arr = try items.toOwnedSlice(gpa) };
}

fn rowsObjJson(gpa: std.mem.Allocator, res: engine.QueryResult) !Json {
    const kvs = try gpa.alloc(KV, 1);
    kvs[0] = .{ .key = "rows", .val = try rowsArrJson(gpa, res.rows) };
    return .{ .obj = kvs };
}

/// Reference `run_nql` kind labels: `MATCH {start}` with NO hops (unlike the
/// line protocol's fmtPathLabel) — `SELECT aud`, `MATCH aud:1`, …
fn kindLabel(gpa: std.mem.Allocator, res: engine.QueryResult) ![]const u8 {
    return switch (res.kind) {
        .select => |table| std.fmt.allocPrint(gpa, "SELECT {s}", .{table}),
        .match_ => |path| blk: {
            const start = try ir.recordIdDisplay(gpa, path.start);
            break :blk try std.fmt.allocPrint(gpa, "MATCH {s}", .{start});
        },
        .closure => |path| blk: {
            const start = try ir.recordIdDisplay(gpa, path.start);
            break :blk try std.fmt.allocPrint(gpa, "CLOSURE {s}", .{start});
        },
        .history => |since| std.fmt.allocPrint(gpa, "HISTORY SINCE {d}", .{since}),
    };
}

/// execute_nql payload: pretty JSON array of `{kind, rows}` (keys sorted).
fn resultsJson(gpa: std.mem.Allocator, results: []const engine.QueryResult) !Json {
    var items: std.ArrayList(Json) = .empty;
    for (results) |res| {
        const kvs = try gpa.alloc(KV, 2);
        kvs[0] = .{ .key = "kind", .val = .{ .str = try kindLabel(gpa, res) } };
        kvs[1] = .{ .key = "rows", .val = try rowsArrJson(gpa, res.rows) };
        try items.append(gpa, .{ .obj = kvs });
    }
    return .{ .arr = try items.toOwnedSlice(gpa) };
}

// ---------------------------------------------------------------------------
// Argument helpers (rmcp deserializes; missing required fields are schema
// errors the harness never triggers — "missing required field `k`" mirrors
// serde's wording family)
// ---------------------------------------------------------------------------

fn argGet(args: ?std.json.Value, key: []const u8) ?std.json.Value {
    const a = args orelse return null;
    if (a != .object) return null;
    return a.object.get(key);
}

fn argStr(args: ?std.json.Value, key: []const u8) ?[]const u8 {
    const v = argGet(args, key) orelse return null;
    return if (v == .string) v.string else null;
}

fn argInt(args: ?std.json.Value, key: []const u8) ?i64 {
    const v = argGet(args, key) orelse return null;
    return if (v == .integer) v.integer else null;
}

fn argUsize(args: ?std.json.Value, key: []const u8) ?usize {
    const v = argInt(args, key) orelse return null;
    return if (v >= 0) @as(usize, @intCast(v)) else null;
}

fn argF32(args: ?std.json.Value, key: []const u8) ?f32 {
    const v = argGet(args, key) orelse return null;
    return switch (v) {
        .integer => |n| @as(f32, @floatFromInt(n)),
        .float => |f| @as(f32, @floatCast(f)),
        else => null,
    };
}

fn missing(gpa: std.mem.Allocator, key: []const u8) ![]const u8 {
    return std.fmt.allocPrint(gpa, "missing required field `{s}`", .{key});
}

// ---------------------------------------------------------------------------
// Reference-exact validation messages
// ---------------------------------------------------------------------------

fn ridErrMsg(gpa: std.mem.Allocator, s: []const u8) ![]const u8 {
    return std.fmt.allocPrint(gpa, "invalid record id `{s}` (expected table:id)", .{s});
}

const StepParse = union(enum) {
    ok: []const ir.MatchStep,
    err: []const u8,
};

/// Reference `parse_steps` — exact messages and order of checks.
fn parseSteps(gpa: std.mem.Allocator, v: ?std.json.Value) !StepParse {
    const steps_v = v orelse return .{ .err = try std.fmt.allocPrint(gpa, "steps must be a JSON array", .{}) };
    if (steps_v != .array) return .{ .err = try std.fmt.allocPrint(gpa, "steps must be a JSON array", .{}) };
    if (steps_v.array.items.len == 0) return .{ .err = try std.fmt.allocPrint(gpa, "steps must contain at least one hop", .{}) };
    var list: std.ArrayList(ir.MatchStep) = .empty;
    for (steps_v.array.items) |sv| {
        if (sv != .object) return .{ .err = try std.fmt.allocPrint(gpa, "step missing `direction`", .{}) };
        const dir_v = sv.object.get("direction") orelse
            return .{ .err = try std.fmt.allocPrint(gpa, "step missing `direction`", .{}) };
        if (dir_v != .string) return .{ .err = try std.fmt.allocPrint(gpa, "step missing `direction`", .{}) };
        const dir: ir.MatchDirection = if (std.mem.eql(u8, dir_v.string, "out"))
            .out
        else if (std.mem.eql(u8, dir_v.string, "in"))
            .in
        else
            return .{ .err = try std.fmt.allocPrint(
                gpa,
                "direction must be \"out\" or \"in\", got `{s}`",
                .{dir_v.string},
            ) };
        const name_v = sv.object.get("name") orelse
            return .{ .err = try std.fmt.allocPrint(gpa, "step missing `name`", .{}) };
        if (name_v != .string) return .{ .err = try std.fmt.allocPrint(gpa, "step missing `name`", .{}) };
        var name = name_v.string;
        while (name.len > 0 and name[0] == ':') name = name[1..]; // trim_start_matches(':')
        var edge_props: ?ir.Filter = null;
        if (sv.object.get("where")) |w| {
            if (w == .object) {
                const f_v = w.object.get("field") orelse
                    return .{ .err = try std.fmt.allocPrint(gpa, "where missing `field`", .{}) };
                if (f_v != .string) return .{ .err = try std.fmt.allocPrint(gpa, "where missing `field`", .{}) };
                const val_v = w.object.get("value") orelse
                    return .{ .err = try std.fmt.allocPrint(gpa, "where missing `value`", .{}) };
                edge_props = .{ .field_equals = .{
                    .field = f_v.string,
                    .value = try jsonToIr(gpa, val_v),
                } };
            }
        }
        try list.append(gpa, .{ .direction = dir, .name = name, .edge_props = edge_props });
    }
    return .{ .ok = try list.toOwnedSlice(gpa) };
}

// ---------------------------------------------------------------------------
// Mutation / query execution (shared `Session.execPlan` path)
// ---------------------------------------------------------------------------

fn execStmt(gpa: std.mem.Allocator, sess: *cli.Session, stmt: ir.Statement) ![]const u8 {
    switch (try sess.execPlan(&.{stmt})) {
        .ok => return try std.fmt.allocPrint(gpa, "OK", .{}),
        .exec_err => |m| return std.fmt.allocPrint(gpa, "ERR {s}", .{m}),
        .wal_err => |m| return m,
    }
}

fn execQuery(gpa: std.mem.Allocator, sess: *cli.Session, plan: []const ir.Statement) ![]const u8 {
    switch (try sess.execPlan(plan)) {
        .ok => |results| {
            if (results.len == 0) return try std.fmt.allocPrint(gpa, "{{}}", .{});
            return prettyText(gpa, try rowsObjJson(gpa, results[0]));
        },
        .exec_err => |m| return std.fmt.allocPrint(gpa, "ERR {s}", .{m}),
        .wal_err => |m| return m,
    }
}

// ---------------------------------------------------------------------------
// The8 tools
// ---------------------------------------------------------------------------

fn hExecuteNql(gpa: std.mem.Allocator, sess: *cli.Session, args: ?std.json.Value) ![]const u8 {
    const program = argStr(args, "program") orelse return missing(gpa, "program");
    const outcome = parser.parse(gpa, program) catch return error.OutOfMemory;
    if (outcome == .err) {
        const f = outcome.err;
        const prefix: []const u8 = switch (f.kind) {
            .lex => "lex",
            .parse => "parse",
        };
        return std.fmt.allocPrint(
            gpa,
            "{s} error at {d}:{d}: {s}",
            .{ prefix, f.line, f.col, f.message },
        );
    }
    switch (try sess.execPlan(outcome.ok)) {
        .ok => |results| return prettyText(gpa, try resultsJson(gpa, results)),
        .exec_err => |m| return std.fmt.allocPrint(gpa, "ERR {s}", .{m}),
        .wal_err => |m| return m,
    }
}

fn hSelect(gpa: std.mem.Allocator, sess: *cli.Session, args: ?std.json.Value) ![]const u8 {
    const table = argStr(args, "table") orelse return missing(gpa, "table");

    var knn: ?ir.Knn = null;
    if (argGet(args, "query")) |qv| {
        if (qv != .array) return std.fmt.allocPrint(gpa, "embedding must be a JSON array of numbers", .{});
        var vec: std.ArrayList(f32) = .empty;
        for (qv.array.items) |ev| {
            const x: f32 = switch (ev) {
                .integer => |n| @as(f32, @floatFromInt(n)),
                .float => |f| @as(f32, @floatCast(f)),
                else => return std.fmt.allocPrint(gpa, "embedding entries must be numbers", .{}),
            };
            try vec.append(gpa, x);
        }
        var k: usize = 10;
        if (argInt(args, "k")) |k0| k = if (k0 <= 0) 1 else @as(usize, @intCast(k0));
        knn = .{ .query = try vec.toOwnedSlice(gpa), .k = k };
    }

    var filter: ?ir.Filter = null;
    if (argStr(args, "field")) |fld| {
        if (argGet(args, "value")) |vv| {
            filter = .{ .field_equals = .{ .field = fld, .value = try jsonToIr(gpa, vv) } };
        }
    }

    var order: ?ir.Order = null;
    if (argStr(args, "order_by")) |o_raw| {
        var lc_buf: [64]u8 = undefined;
        if (o_raw.len > lc_buf.len) return std.fmt.allocPrint(gpa, "ERR unknown ORDER BY `{s}`", .{o_raw});
        const lc = std.ascii.lowerString(&lc_buf, o_raw);
        order = if (std.mem.eql(u8, lc, "similarity"))
            .similarity
        else if (std.mem.eql(u8, lc, "salience"))
            .salience
        else if (std.mem.eql(u8, lc, "score"))
            .score
        else if (std.mem.eql(u8, lc, "votes"))
            .votes
        else if (std.mem.eql(u8, lc, "feedback"))
            .feedback
        else if (std.mem.eql(u8, lc, "recency"))
            .recency
        else
            return std.fmt.allocPrint(gpa, "ERR unknown ORDER BY `{s}`", .{o_raw});
    }

    const limit = argUsize(args, "limit");
    const as_of = argInt(args, "as_of");

    var plan: std.ArrayList(ir.Statement) = .empty;
    if (argStr(args, "memory")) |mem_name| {
        try plan.append(gpa, .{ .memory = .{ .name = mem_name } });
    }
    try plan.append(gpa, .{ .select = .{
        .table = table,
        .knn = knn,
        .filter = filter,
        .order = order,
        .limit = limit,
        .as_of = as_of,
        .fields = null,
        .offset = null,
        .aggregate = null,
    } });
    return execQuery(gpa, sess, plan.items);
}

fn hCreateTable(gpa: std.mem.Allocator, sess: *cli.Session, args: ?std.json.Value) ![]const u8 {
    const table = argStr(args, "table") orelse return missing(gpa, "table");
    const vector_dim = argUsize(args, "vector_dim");
    return execStmt(gpa, sess, .{ .create_table = .{ .table = table, .vector_dim = vector_dim } });
}

fn hInsert(gpa: std.mem.Allocator, sess: *cli.Session, args: ?std.json.Value) ![]const u8 {
    const id_s = argStr(args, "id") orelse return missing(gpa, "id");
    const rid = ir.recordIdParse(id_s) orelse return ridErrMsg(gpa, id_s);
    const body_v = argGet(args, "body") orelse return missing(gpa, "body");
    const body = (try jsonToDoc(gpa, body_v)) orelse
        return std.fmt.allocPrint(gpa, "body must be a JSON object", .{});
    var embedding: ?[]const f32 = null;
    if (argGet(args, "embedding")) |ev| {
        if (ev != .array) return std.fmt.allocPrint(gpa, "embedding must be a JSON array of numbers", .{});
        var vec: std.ArrayList(f32) = .empty;
        for (ev.array.items) |e| {
            const x: f32 = switch (e) {
                .integer => |n| @as(f32, @floatFromInt(n)),
                .float => |f| @as(f32, @floatCast(f)),
                else => return std.fmt.allocPrint(gpa, "embedding entries must be numbers", .{}),
            };
            try vec.append(gpa, x);
        }
        embedding = try vec.toOwnedSlice(gpa);
    }
    return execStmt(gpa, sess, .{
        .insert = .{
            .id = rid,
            .body = body,
            .embedding = embedding,
            .created_at = 0, // engine stamps the logical clock
        },
    });
}

fn hRelate(gpa: std.mem.Allocator, sess: *cli.Session, args: ?std.json.Value) ![]const u8 {
    const from_s = argStr(args, "from") orelse return missing(gpa, "from");
    const from = ir.recordIdParse(from_s) orelse return ridErrMsg(gpa, from_s);
    const to_s = argStr(args, "to") orelse return missing(gpa, "to");
    const to = ir.recordIdParse(to_s) orelse return ridErrMsg(gpa, to_s);
    const name_raw = argStr(args, "name") orelse return missing(gpa, "name");
    var name = name_raw;
    while (name.len > 0 and name[0] == ':') name = name[1..];
    const weight = argF32(args, "weight");
    var props: []const ir.DocEntry = &.{};
    if (argGet(args, "props")) |pv| {
        props = (try jsonToDoc(gpa, pv)) orelse
            return std.fmt.allocPrint(gpa, "props must be a JSON object", .{});
    }
    return execStmt(gpa, sess, .{ .relate = .{
        .from = from,
        .name = name,
        .to = to,
        .created_at = 0,
        .weight = weight,
        .props = props,
    } });
}

fn hForget(gpa: std.mem.Allocator, sess: *cli.Session, args: ?std.json.Value) ![]const u8 {
    const id_s = argStr(args, "id") orelse return missing(gpa, "id");
    const rid = ir.recordIdParse(id_s) orelse return ridErrMsg(gpa, id_s);
    return execStmt(gpa, sess, .{ .forget = .{ .id = rid } });
}

fn hMatch(gpa: std.mem.Allocator, sess: *cli.Session, args: ?std.json.Value, comptime is_closure: bool) ![]const u8 {
    const start_s = argStr(args, "start") orelse return missing(gpa, "start");
    const start = ir.recordIdParse(start_s) orelse return ridErrMsg(gpa, start_s);
    const steps_parse = try parseSteps(gpa, argGet(args, "steps"));
    const steps = switch (steps_parse) {
        .err => |e| return e,
        .ok => |s| s,
    };
    const as_of = argInt(args, "as_of");
    const mp = ir.MatchPath{ .start = start, .steps = steps, .as_of = as_of };
    const stmt: ir.Statement = if (is_closure) .{ .closure = mp } else .{ .match_path = mp };
    return execQuery(gpa, sess, &.{stmt});
}

fn toolCall(gpa: std.mem.Allocator, sess: *cli.Session, name: []const u8, args: ?std.json.Value) ![]const u8 {
    if (std.mem.eql(u8, name, "execute_nql")) return hExecuteNql(gpa, sess, args);
    if (std.mem.eql(u8, name, "select")) return hSelect(gpa, sess, args);
    if (std.mem.eql(u8, name, "create_table")) return hCreateTable(gpa, sess, args);
    if (std.mem.eql(u8, name, "insert_record")) return hInsert(gpa, sess, args);
    if (std.mem.eql(u8, name, "relate")) return hRelate(gpa, sess, args);
    if (std.mem.eql(u8, name, "forget")) return hForget(gpa, sess, args);
    if (std.mem.eql(u8, name, "match_path")) return hMatch(gpa, sess, args, false);
    if (std.mem.eql(u8, name, "closure")) return hMatch(gpa, sess, args, true);
    return std.fmt.allocPrint(gpa, "unknown tool `{s}`", .{name});
}

// ---------------------------------------------------------------------------
// JSON-RPC framing
// ---------------------------------------------------------------------------

fn envelope(gpa: std.mem.Allocator, id: Json, result: Json) ![]const u8 {
    const kvs = [_]KV{
        .{ .key = "jsonrpc", .val = .{ .str = "2.0" } },
        .{ .key = "id", .val = id },
        .{ .key = "result", .val = result },
    };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try emitCompact(&out, gpa, .{ .obj = &kvs });
    return out.toOwnedSlice(gpa);
}

fn envelopeErr(gpa: std.mem.Allocator, id: Json, code: i64, message: []const u8) ![]const u8 {
    const err_kvs = [_]KV{
        .{ .key = "code", .val = .{ .int = code } },
        .{ .key = "message", .val = .{ .str = message } },
    };
    const kvs = [_]KV{
        .{ .key = "jsonrpc", .val = .{ .str = "2.0" } },
        .{ .key = "id", .val = id },
        .{ .key = "error", .val = .{ .obj = &err_kvs } },
    };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try emitCompact(&out, gpa, .{ .obj = &kvs });
    return out.toOwnedSlice(gpa);
}

fn descFor(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "closure")) return schemas.DESC_CLOSURE;
    if (std.mem.eql(u8, name, "create_table")) return schemas.DESC_CREATE_TABLE;
    if (std.mem.eql(u8, name, "execute_nql")) return schemas.DESC_EXECUTE_NQL;
    if (std.mem.eql(u8, name, "forget")) return schemas.DESC_FORGET;
    if (std.mem.eql(u8, name, "insert_record")) return schemas.DESC_INSERT_RECORD;
    if (std.mem.eql(u8, name, "match_path")) return schemas.DESC_MATCH_PATH;
    if (std.mem.eql(u8, name, "relate")) return schemas.DESC_RELATE;
    if (std.mem.eql(u8, name, "select")) return schemas.DESC_SELECT;
    unreachable;
}

fn schemaFor(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "closure")) return schemas.SCHEMA_CLOSURE;
    if (std.mem.eql(u8, name, "create_table")) return schemas.SCHEMA_CREATE_TABLE;
    if (std.mem.eql(u8, name, "execute_nql")) return schemas.SCHEMA_EXECUTE_NQL;
    if (std.mem.eql(u8, name, "forget")) return schemas.SCHEMA_FORGET;
    if (std.mem.eql(u8, name, "insert_record")) return schemas.SCHEMA_INSERT_RECORD;
    if (std.mem.eql(u8, name, "match_path")) return schemas.SCHEMA_MATCH_PATH;
    if (std.mem.eql(u8, name, "relate")) return schemas.SCHEMA_RELATE;
    if (std.mem.eql(u8, name, "select")) return schemas.SCHEMA_SELECT;
    unreachable;
}

fn toolsList(gpa: std.mem.Allocator) !Json {
    var tools: std.ArrayList(Json) = .empty;
    for (&schemas.TOOL_ORDER) |name_ptr| {
        const name = name_ptr;
        var kvs: std.ArrayList(KV) = .empty;
        try kvs.append(gpa, .{ .key = "name", .val = .{ .str = name } });
        try kvs.append(gpa, .{ .key = "description", .val = .{ .str = descFor(name) } });
        // The schema consts are static — parsed strings borrow them (safe
        // after deinit) and emit back byte-identically (tested).
        var p = std.json.parseFromSlice(std.json.Value, gpa, schemaFor(name), .{}) catch
            return error.OutOfMemory;
        defer p.deinit();
        try kvs.append(gpa, .{ .key = "inputSchema", .val = try fromStd(gpa, p.value) });
        try tools.append(gpa, .{ .obj = try kvs.toOwnedSlice(gpa) });
    }
    const root = try gpa.alloc(KV, 1);
    root[0] = .{ .key = "tools", .val = .{ .arr = try tools.toOwnedSlice(gpa) } };
    return .{ .obj = root };
}

/// One JSON-RPC message → response text (null = notification / no reply).
pub fn handleLine(gpa: std.mem.Allocator, sess: *cli.Session, line: []const u8) !?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return null;
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, trimmed, .{}) catch return null;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return null;
    const method_v = root.object.get("method") orelse return null;
    if (method_v != .string) return null;
    const m = method_v.string;
    const id_v = root.object.get("id") orelse return null; // notification
    const id = try fromStd(gpa, id_v);

    if (std.mem.eql(u8, m, "initialize")) {
        var p = std.json.parseFromSlice(std.json.Value, gpa, schemas.INITIALIZE_RESULT, .{}) catch
            return error.OutOfMemory;
        defer p.deinit();
        return try envelope(gpa, id, try fromStd(gpa, p.value));
    }
    if (std.mem.eql(u8, m, "notifications/initialized"))
        return try envelope(gpa, id, .null);
    if (std.mem.eql(u8, m, "ping")) {
        const empty = [_]KV{};
        return try envelope(gpa, id, .{ .obj = &empty });
    }
    if (std.mem.eql(u8, m, "tools/list"))
        return try envelope(gpa, id, try toolsList(gpa));
    if (std.mem.eql(u8, m, "tools/call")) {
        const params = root.object.get("params") orelse
            return try envelopeErr(gpa, id, -32602, "Invalid params");
        if (params != .object) return try envelopeErr(gpa, id, -32602, "Invalid params");
        const name_v = params.object.get("name") orelse
            return try envelopeErr(gpa, id, -32602, "Invalid params");
        if (name_v != .string) return try envelopeErr(gpa, id, -32602, "Invalid params");
        const args = params.object.get("arguments"); // optional (schema errors
        // surface as tool text; the harness always sends valid arguments)
        const text = try toolCall(gpa, sess, name_v.string, args);
        const item = [_]KV{
            .{ .key = "type", .val = .{ .str = "text" } },
            .{ .key = "text", .val = .{ .str = text } },
        };
        const content = [_]Json{.{ .obj = &item }};
        const result = [_]KV{
            .{ .key = "content", .val = .{ .arr = &content } },
            .{ .key = "isError", .val = .{ .bool = false } },
        };
        return try envelope(gpa, id, .{ .obj = &result });
    }
    return try envelopeErr(gpa, id, -32601, "Method not found");
}

// ---------------------------------------------------------------------------
// stdio driver (`--mcp`)
// ---------------------------------------------------------------------------

pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *Io.Writer,
    db_path: ?[]const u8,
) !void {
    var sess_out: std.ArrayList(u8) = .empty;
    defer sess_out.deinit(gpa);
    var sess: cli.Session = if (db_path) |p|
        cli.Session.open(gpa, io, &sess_out, p) catch |e| {
            std.debug.print("error: {s}\n", .{@errorName(e)});
            std.process.exit(1);
        }
    else
        cli.Session.new(gpa, io, &sess_out);

    std.debug.print("{s}\n", .{BANNER});

    var in_buf: [1 << 20]u8 = undefined;
    var stdin_file_reader = Io.File.stdin().reader(io, &in_buf);
    const stdin_reader = &stdin_file_reader.interface;
    while (true) {
        const raw = stdin_reader.takeDelimiterInclusive('\n') catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
        if (try handleLine(gpa, &sess, raw)) |resp| {
            try out.writeAll(resp);
            try out.writeAll("\n");
            try out.flush();
        }
    }
    try out.flush();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn mustHandle(gpa: std.mem.Allocator, sess: *cli.Session, line: []const u8) ![]const u8 {
    return (try handleLine(gpa, sess, line)) orelse return error.NoResponse;
}

fn toolText(gpa: std.mem.Allocator, resp: []const u8) ![]const u8 {
    var p = try std.json.parseFromSlice(std.json.Value, gpa, resp, .{});
    defer p.deinit();
    const result = p.value.object.get("result") orelse return error.NoResult;
    const content = result.object.get("content") orelse return error.NoContent;
    const item = content.array.items[0];
    const t = item.object.get("text") orelse return error.NoText;
    return std.fmt.allocPrint(gpa, "{s}", .{t.string});
}

test "initialize replies with the verbatim rmcp result" {
    var gpa_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer gpa_arena.deinit();
    const gpa = gpa_arena.allocator();
    var buf: std.ArrayList(u8) = .empty;
    var sess = cli.Session.new(gpa, std.testing.io, &buf);
    const resp = try mustHandle(gpa, &sess, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}");
    const expected = try std.fmt.allocPrint(
        gpa,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{s}}}",
        .{schemas.INITIALIZE_RESULT},
    );
    try testing.expectEqualStrings(expected, resp);
}

test "tools/list:8 alphabetical, verbatim schemas, select exposes as_of+memory" {
    var gpa_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer gpa_arena.deinit();
    const gpa = gpa_arena.allocator();
    var buf: std.ArrayList(u8) = .empty;
    var sess = cli.Session.new(gpa, std.testing.io, &buf);
    const resp = try mustHandle(gpa, &sess, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}");
    var p = try std.json.parseFromSlice(std.json.Value, gpa, resp, .{});
    defer p.deinit();
    const tools = p.value.object.get("result").?.object.get("tools").?.array.items;
    try testing.expectEqual(@as(usize, 8), tools.len);
    for (tools, 0..) |tool, i| {
        const want = schemas.TOOL_ORDER[i];
        try testing.expectEqualStrings(want, tool.object.get("name").?.string);
        try testing.expectEqualStrings(descFor(want), tool.object.get("description").?.string);
        // inputSchema round-trips byte-identically (compact canonical form).
        const schema_j = try fromStd(gpa, tool.object.get("inputSchema").?);
        var out: std.ArrayList(u8) = .empty;
        try emitCompact(&out, gpa, schema_j);
        try testing.expectEqualStrings(schemaFor(want), out.items);
    }
    // select schema exposes as_of + memory and requires table/value/query.
    var select_schema = try std.json.parseFromSlice(
        std.json.Value,
        gpa,
        schemas.SCHEMA_SELECT,
        .{},
    );
    defer select_schema.deinit();
    const props = select_schema.value.object.get("properties").?;
    _ = props.object.get("as_of") orelse return error.MissingAsOf;
    _ = props.object.get("memory") orelse return error.MissingMemory;
    const required = select_schema.value.object.get("required").?.array.items;
    try testing.expectEqual(@as(usize, 3), required.len);
    try testing.expectEqualStrings("table", required[0].string);
    try testing.expectEqualStrings("value", required[1].string);
    try testing.expectEqualStrings("query", required[2].string);
}

test "golden flow: create + insert + execute_nql + select match the oracle" {
    var gpa_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer gpa_arena.deinit();
    const gpa = gpa_arena.allocator();
    var buf: std.ArrayList(u8) = .empty;
    var sess = cli.Session.new(gpa, std.testing.io, &buf);

    const r_create = try mustHandle(gpa, &sess, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"create_table\",\"arguments\":{\"table\":\"aud\"}}}");
    try testing.expectEqualStrings("OK", try toolText(gpa, r_create));

    const r_insert = try mustHandle(gpa, &sess, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"insert_record\",\"arguments\":{\"id\":\"aud:1\",\"body\":{\"text\":\"v1\"}}}}");
    try testing.expectEqualStrings("OK", try toolText(gpa, r_insert));

    const r_nql = try mustHandle(gpa, &sess, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"execute_nql\",\"arguments\":{\"program\":\"SELECT * FROM aud;\"}}}");
    try testing.expectEqualStrings(schemas.EXECUTE_NQL_GOLDEN, try toolText(gpa, r_nql));

    const r_select = try mustHandle(gpa, &sess, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"select\",\"arguments\":{\"table\":\"aud\"}}}");
    try testing.expectEqualStrings(schemas.SELECT_GOLDEN, try toolText(gpa, r_select));

    // determinism: identical call → identical bytes (same id)
    const r_select2 = try mustHandle(gpa, &sess, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"select\",\"arguments\":{\"table\":\"aud\"}}}");
    try testing.expectEqualStrings(r_select, r_select2);
}

test "validation messages, ERR passthrough, -32601" {
    var gpa_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer gpa_arena.deinit();
    const gpa = gpa_arena.allocator();
    var buf: std.ArrayList(u8) = .empty;
    var sess = cli.Session.new(gpa, std.testing.io, &buf);

    // program parse failure → reference nql::Error Display (no prefix)
    const r_bad = try mustHandle(gpa, &sess, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"execute_nql\",\"arguments\":{\"program\":\"SELEC aud\"}}}");
    try testing.expect(std.mem.startsWith(u8, try toolText(gpa, r_bad), "lex error at") or
        std.mem.startsWith(u8, try toolText(gpa, r_bad), "parse error at"));

    // engine failure → `ERR {message}` (sort key absent on a real row)
    _ = try mustHandle(gpa, &sess, "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"tools/call\",\"params\":{\"name\":\"create_table\",\"arguments\":{\"table\":\"aud\"}}}");
    _ = try mustHandle(gpa, &sess, "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"tools/call\",\"params\":{\"name\":\"insert_record\",\"arguments\":{\"id\":\"aud:1\",\"body\":{\"text\":\"v1\"}}}}");
    const r_sel = try mustHandle(gpa, &sess, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"execute_nql\",\"arguments\":{\"program\":\"SELECT * FROM aud ORDER BY bogus;\"}}}");
    try testing.expect(std.mem.startsWith(u8, try toolText(gpa, r_sel), "ERR "));

    // reference ORDER BY error (tool path)
    const r_ord = try mustHandle(gpa, &sess, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"select\",\"arguments\":{\"table\":\"aud\",\"order_by\":\"bogus\"}}}");
    try testing.expectEqualStrings("ERR unknown ORDER BY `bogus`", try toolText(gpa, r_ord));

    // record id validation
    const r_rid = try mustHandle(gpa, &sess, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"forget\",\"arguments\":{\"id\":\"nope\"}}}");
    try testing.expectEqualStrings(
        "invalid record id `nope` (expected table:id)",
        try toolText(gpa, r_rid),
    );

    // steps validation
    const r_steps = try mustHandle(gpa, &sess, "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"match_path\",\"arguments\":{\"start\":\"aud:1\",\"steps\":[]}}}");
    try testing.expectEqualStrings("steps must contain at least one hop", try toolText(gpa, r_steps));

    // unknown method → -32601
    const r_m = try mustHandle(gpa, &sess, "{\"jsonrpc\":\"2.0\",\"id\":99,\"method\":\"no/such\"}");
    try testing.expect(std.mem.indexOf(u8, r_m, "-32601") != null);

    // notification (no id) → no response
    try testing.expect((try handleLine(gpa, &sess, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}")) == null);
}

test "recordIdParse mirrors RecordId::parse" {
    try testing.expect(ir.recordIdParse("aud:1").?.id == .num);
    try testing.expectEqual(@as(u64, 1), ir.recordIdParse("aud:1").?.id.num);
    try testing.expectEqual(@as(u64, 7), ir.recordIdParse("aud:007").?.id.num);
    const s = ir.recordIdParse("aud:abc").?.id;
    try testing.expect(s == .str);
    try testing.expectEqualStrings("abc", s.str);
    const ov = ir.recordIdParse("aud:18446744073709551616").?.id;
    try testing.expect(ov == .str); // u64 overflow → string, like Rust
    try testing.expect(ir.recordIdParse("nope") == null);
    try testing.expect(ir.recordIdParse(":1") == null);
    try testing.expect(ir.recordIdParse("t:") == null);
    const neg = ir.recordIdParse("t:-1").?.id;
    try testing.expect(neg == .str);
}
