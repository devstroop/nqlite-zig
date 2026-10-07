//! Payload encoding — spec/file-format.md §5.7 (normative), the dialect
//! "exactly as today's reference implementation" (postcard):
//!
//! - uleb128 for unsigned lengths/counts/enum tags (≤10 bytes for u64);
//! - zigzag + uleb128 for signed integers;
//! - bool = 1 byte; Option = 0x00/0x01 then the value;
//! - f32/f64 little-endian (bit-exact: NaN payloads and -0.0 survive);
//! - strings: uleb128 byte length + raw UTF-8;
//! - Vec/Arr: uleb128 count + elements; Doc/maps: uleb128 count + (k, v),
//!   byte-wise key order (file order on decode — ADR-001: no maps);
//! - structs: fields in declaration order, no length prefix.
//!
//! Where the prose is ambiguous, the golden fixtures are the oracle.

const std = @import("std");
const ir = @import("ir.zig");

pub const WriteError = std.mem.Allocator.Error;
pub const ReadError = error{
    Truncated,
    Utf8Invalid,
    UlebOverflow,
    UnknownTag,
    InvalidValue,
    IdMismatch,
    Trailing,
    OutOfMemory,
};

// ---------------------------------------------------------------------------
// Writer
// ---------------------------------------------------------------------------

pub const Writer = struct {
    list: std.ArrayList(u8),
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) Writer {
        return .{ .list = std.ArrayList(u8).empty, .gpa = gpa };
    }

    pub fn deinit(self: *Writer) void {
        self.list.deinit(self.gpa);
    }

    pub fn bytes(self: *const Writer) []const u8 {
        return self.list.items;
    }

    pub fn intoSlice(self: *Writer) ![]u8 {
        return self.list.toOwnedSlice(self.gpa);
    }

    pub fn raw(self: *Writer, s: []const u8) WriteError!void {
        try self.list.appendSlice(self.gpa, s);
    }

    pub fn byte(self: *Writer, b: u8) WriteError!void {
        try self.list.append(self.gpa, b);
    }

    pub fn uleb(self: *Writer, x: u64) WriteError!void {
        var v = x;
        while (true) {
            const b: u8 = @truncate(v & 0x7f);
            v >>= 7;
            if (v == 0) return self.byte(b);
            try self.byte(b | 0x80);
        }
    }

    pub fn u64le(self: *Writer, v: u64) WriteError!void {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, v, .little);
        return self.raw(&buf);
    }

    pub fn u32le(self: *Writer, v: u32) WriteError!void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, v, .little);
        return self.raw(&buf);
    }

    pub fn i64le(self: *Writer, v: i64) WriteError!void {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(i64, &buf, v, .little);
        return self.raw(&buf);
    }

    pub fn i64zig(self: *Writer, v: i64) WriteError!void {
        // Zigzag: (n << 1) ^ (n >> 63) — ARITHMETIC shift on i64 (a logical
        // shift would encode -1 as all-ones instead of 1).
        const n: u64 = @bitCast((v << 1) ^ (v >> 63));
        return self.uleb(n);
    }

    pub fn f32le(self: *Writer, v: f32) WriteError!void {
        return self.u32le(@bitCast(v));
    }

    pub fn f64le(self: *Writer, v: f64) WriteError!void {
        return self.u64le(@bitCast(v));
    }

    pub fn boolb(self: *Writer, v: bool) WriteError!void {
        return self.byte(@intFromBool(v));
    }

    pub fn str(self: *Writer, s: []const u8) WriteError!void {
        try self.uleb(s.len);
        return self.raw(s);
    }

    pub fn optUsize(self: *Writer, o: ?usize) WriteError!void {
        if (o) |v| {
            try self.byte(1);
            return self.uleb(v);
        }
        return self.byte(0);
    }

    pub fn optI64(self: *Writer, o: ?i64) WriteError!void {
        if (o) |v| {
            try self.byte(1);
            return self.i64zig(v);
        }
        return self.byte(0);
    }

    pub fn optF32(self: *Writer, o: ?f32) WriteError!void {
        if (o) |v| {
            try self.byte(1);
            return self.f32le(v);
        }
        return self.byte(0);
    }

    pub fn recordId(self: *Writer, rid: ir.RecordId) WriteError!void {
        try self.str(rid.table);
        switch (rid.id) {
            .num => |n| {
                try self.uleb(0);
                try self.uleb(n);
            },
            .str => |s| {
                try self.uleb(1);
                try self.str(s);
            },
        }
    }

    pub fn doc(self: *Writer, entries: []const ir.DocEntry) WriteError!void {
        try self.uleb(entries.len);
        for (entries) |e| {
            try self.str(e.key);
            try self.value(e.value);
        }
    }

    pub fn value(self: *Writer, v: ir.Value) WriteError!void {
        switch (v) {
            .null => try self.uleb(0),
            .bool => |b| {
                try self.uleb(1);
                try self.boolb(b);
            },
            .int => |i| {
                try self.uleb(2);
                try self.i64zig(i);
            },
            .float => |f| {
                try self.uleb(3);
                try self.f64le(f);
            },
            .str => |s| {
                try self.uleb(4);
                try self.str(s);
            },
            .doc => |entries| {
                try self.uleb(5);
                try self.doc(entries);
            },
            .arr => |items| {
                try self.uleb(6);
                try self.uleb(items.len);
                for (items) |it| try self.value(it);
            },
            .vector => |dims| {
                try self.uleb(7);
                try self.uleb(dims.len);
                for (dims) |f| try self.f32le(f);
            },
            .ref => |rid| {
                try self.uleb(8);
                try self.recordId(rid);
            },
        }
    }

    pub fn record(self: *Writer, r: ir.Record) WriteError!void {
        try self.recordId(r.id);
        try self.doc(r.body);
        if (r.embedding) |emb| {
            try self.byte(1);
            try self.uleb(emb.len);
            for (emb) |f| try self.f32le(f);
        } else try self.byte(0);
        try self.i64zig(r.created_at);
    }

    pub fn relationEdge(self: *Writer, e: ir.RelationEdge) WriteError!void {
        try self.recordId(e.from);
        try self.str(e.name);
        try self.recordId(e.to);
        try self.i64zig(e.created_at);
        try self.optF32(e.weight);
        try self.doc(e.props);
    }

    pub fn cmpOp(self: *Writer, op: ir.CmpOp) WriteError!void {
        return self.uleb(@backingInt(op));
    }

    pub fn filter(self: *Writer, f: ir.Filter) WriteError!void {
        switch (f) {
            .field_equals => |x| {
                try self.uleb(0);
                try self.str(x.field);
                try self.value(x.value);
            },
            .has_embedding => try self.uleb(1),
            .bm25 => |x| {
                try self.uleb(2);
                try self.str(x.field);
                try self.str(x.query);
                try self.optUsize(x.k);
            },
            .field_cmp => |x| {
                try self.uleb(3);
                try self.str(x.field);
                try self.cmpOp(x.op);
                try self.value(x.value);
            },
            .field_in => |x| {
                try self.uleb(4);
                try self.str(x.field);
                try self.uleb(x.values.len);
                for (x.values) |v| try self.value(v);
            },
            .field_between => |x| {
                try self.uleb(5);
                try self.str(x.field);
                try self.value(x.lo);
                try self.value(x.hi);
            },
            .and_filter => |items| {
                try self.uleb(6);
                try self.uleb(items.len);
                for (items) |it| try self.filter(it);
            },
        }
    }

    fn optFilter(self: *Writer, o: ?ir.Filter) WriteError!void {
        if (o) |f| {
            try self.byte(1);
            return self.filter(f);
        }
        return self.byte(0);
    }

    fn optKnn(self: *Writer, o: ?ir.Knn) WriteError!void {
        if (o) |k| {
            try self.byte(1);
            try self.uleb(k.query.len);
            for (k.query) |f| try self.f32le(f);
            try self.uleb(k.k);
        } else try self.byte(0);
    }

    fn optOrder(self: *Writer, o: ?ir.Order) WriteError!void {
        if (o) |ord| {
            try self.byte(1);
            switch (ord) {
                .similarity => try self.uleb(0),
                .salience => try self.uleb(1),
                .score => try self.uleb(2),
                .votes => try self.uleb(3),
                .feedback => try self.uleb(4),
                .recency => try self.uleb(5),
                .salience_weighted => |w| {
                    try self.uleb(6);
                    for (w) |f| try self.f32le(f);
                },
                .field => |x| {
                    try self.uleb(7);
                    try self.str(x.key);
                    try self.boolb(x.desc);
                },
            }
        } else try self.byte(0);
    }

    fn optFields(self: *Writer, o: ?[]const []const u8) WriteError!void {
        if (o) |fields| {
            try self.byte(1);
            try self.uleb(fields.len);
            for (fields) |f| try self.str(f);
        } else try self.byte(0);
    }

    fn optAggregate(self: *Writer, o: ?ir.Aggregate) WriteError!void {
        if (o) |agg| {
            try self.byte(1);
            switch (agg) {
                .count_star => try self.uleb(0),
            }
        } else try self.byte(0);
    }

    pub fn select(self: *Writer, s: ir.Select) WriteError!void {
        try self.str(s.table);
        try self.optKnn(s.knn);
        try self.optFilter(s.filter);
        try self.optOrder(s.order);
        try self.optUsize(s.limit);
        try self.optI64(s.as_of);
        try self.optFields(s.fields);
        try self.optUsize(s.offset);
        try self.optAggregate(s.aggregate);
    }

    pub fn matchPath(self: *Writer, p: ir.MatchPath) WriteError!void {
        try self.recordId(p.start);
        try self.uleb(p.steps.len);
        for (p.steps) |step| {
            try self.uleb(@backingInt(step.direction));
            try self.str(step.name);
            try self.optFilter(step.edge_props);
        }
        try self.optI64(p.as_of);
    }

    fn snapStore(self: *Writer, s: ir.SnapStore) WriteError!void {
        // records: BTreeMap<RecordId, Record> — map form (key + value).
        try self.uleb(s.records.len);
        for (s.records) |r| {
            try self.recordId(r.id);
            try self.record(r);
        }
        try self.uleb(s.edges.len);
        for (s.edges) |e| try self.relationEdge(e);
        try self.uleb(s.vector_dims.len);
        for (s.vector_dims) |d| {
            try self.str(d.name);
            try self.uleb(d.dim);
        }
        try self.i64zig(s.clock);
        try self.historyVec(s.history);
        try self.uleb(s.memories.len);
        for (s.memories) |m| {
            try self.str(m.name);
            try self.snapStore(m.store);
        }
    }

    fn snapMemories(self: *Writer, mems: []const ir.SnapMemory) WriteError!void {
        try self.uleb(mems.len);
        for (mems) |m| {
            try self.str(m.name);
            try self.snapStore(m.store);
        }
    }

    fn snapshotState(self: *Writer, st: ir.SnapshotState) WriteError!void {
        try self.uleb(st.records.len);
        for (st.records) |r| {
            try self.recordId(r.id);
            try self.record(r);
        }
        try self.uleb(st.edges.len);
        for (st.edges) |e| try self.relationEdge(e);
        try self.uleb(st.vector_dims.len);
        for (st.vector_dims) |d| {
            try self.str(d.name);
            try self.uleb(d.dim);
        }
        try self.i64zig(st.clock);
        try self.snapMemories(st.memories);
        try self.uleb(st.tables.len);
        for (st.tables) |t| {
            try self.str(t.name);
            try self.optUsize(t.vector_dim);
        }
    }

    /// `Vec<(i64, Statement)>` — the history form (§5.6 tail / snapshot).
    pub fn historyVec(self: *Writer, h: []const ir.HistoryEntry) WriteError!void {
        try self.uleb(h.len);
        for (h) |entry| {
            try self.i64zig(entry.ts);
            try self.statement(entry.stmt);
        }
    }

    pub fn statement(self: *Writer, s: ir.Statement) WriteError!void {
        switch (s) {
            .create_table => |c| {
                try self.uleb(0);
                try self.str(c.table);
                try self.optUsize(c.vector_dim);
            },
            .insert => |r| {
                try self.uleb(1);
                try self.record(r);
            },
            .relate => |e| {
                try self.uleb(2);
                try self.relationEdge(e);
            },
            .select => |x| {
                try self.uleb(3);
                try self.select(x);
            },
            .match_path => |p| {
                try self.uleb(4);
                try self.matchPath(p);
            },
            .closure => |p| {
                try self.uleb(5);
                try self.matchPath(p);
            },
            .forget => |f| {
                try self.uleb(6);
                try self.recordId(f.id);
            },
            .memory => |m| {
                try self.uleb(7);
                try self.str(m.name);
            },
            .context_reset => try self.uleb(8),
            .match_count => |p| {
                try self.uleb(9);
                try self.matchPath(p);
            },
            .prune_history => try self.uleb(10),
            .snapshot => |st| {
                try self.uleb(11);
                try self.snapshotState(st);
            },
            .history_since => |ts| {
                try self.uleb(12);
                try self.i64zig(ts);
            },
        }
    }
};

// ---------------------------------------------------------------------------
// Reader (borrows the input buffer; allocations from the caller's arena)
// ---------------------------------------------------------------------------

pub const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn init(bytes: []const u8) Reader {
        return .{ .bytes = bytes };
    }

    pub fn take(self: *Reader, n: usize) ReadError![]const u8 {
        if (self.pos + n > self.bytes.len) return error.Truncated;
        const s = self.bytes[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }

    pub fn byte(self: *Reader) ReadError!u8 {
        const s = try self.take(1);
        return s[0];
    }

    pub fn uleb(self: *Reader) ReadError!u64 {
        var out: u64 = 0;
        var shift: u7 = 0;
        var i: usize = 0;
        while (i < 10) : (i += 1) {
            const b = try self.byte();
            if (i == 9 and b > 1) return error.UlebOverflow;
            out |= @as(u64, b & 0x7f) << @as(u6, @intCast(shift));
            if (b & 0x80 == 0) return out;
            shift += 7;
        }
        return error.UlebOverflow;
    }

    pub fn u64le(self: *Reader) ReadError!u64 {
        const s = try self.take(8);
        return std.mem.readInt(u64, s[0..8], .little);
    }

    pub fn u32le(self: *Reader) ReadError!u32 {
        const s = try self.take(4);
        return std.mem.readInt(u32, s[0..4], .little);
    }

    pub fn i64le(self: *Reader) ReadError!i64 {
        const s = try self.take(8);
        return std.mem.readInt(i64, s[0..8], .little);
    }

    pub fn i64zig(self: *Reader) ReadError!i64 {
        const n = try self.uleb();
        const mask: u64 = ~@as(u64, 0) *% (n & 1);
        return @bitCast((n >> 1) ^ mask);
    }

    pub fn f32le(self: *Reader) ReadError!f32 {
        return @bitCast(try self.u32le());
    }

    pub fn f64le(self: *Reader) ReadError!f64 {
        return @bitCast(try self.u64le());
    }

    pub fn boolb(self: *Reader) ReadError!bool {
        const b = try self.byte();
        return switch (b) {
            0 => false,
            1 => true,
            else => error.InvalidValue, // postcard rejects non-0/1 bools loudly
        };
    }

    pub fn str(self: *Reader) ReadError![]const u8 {
        const len = try self.uleb();
        if (len > std.math.maxInt(usize)) return error.UlebOverflow;
        const s = try self.take(@intCast(len));
        if (!std.unicode.utf8ValidateSlice(s)) return error.Utf8Invalid;
        return s;
    }

    pub fn optUsize(self: *Reader) ReadError!?usize {
        return switch (try self.byte()) {
            0 => null,
            1 => @intCast(try self.uleb()),
            else => error.InvalidValue,
        };
    }

    pub fn optI64(self: *Reader) ReadError!?i64 {
        return switch (try self.byte()) {
            0 => null,
            1 => try self.i64zig(),
            else => error.InvalidValue,
        };
    }

    pub fn optF32(self: *Reader) ReadError!?f32 {
        return switch (try self.byte()) {
            0 => null,
            1 => try self.f32le(),
            else => error.InvalidValue,
        };
    }

    pub fn recordId(self: *Reader) ReadError!ir.RecordId {
        const table = try self.str();
        const tag = try self.uleb();
        return switch (tag) {
            0 => .{ .table = table, .id = .{ .num = try self.uleb() } },
            1 => .{ .table = table, .id = .{ .str = try self.str() } },
            else => error.UnknownTag,
        };
    }

    pub fn docInto(self: *Reader, gpa: std.mem.Allocator) ReadError![]ir.DocEntry {
        const n = try self.uleb();
        const entries = try gpa.alloc(ir.DocEntry, std.math.cast(usize, n) orelse return error.UlebOverflow);
        for (entries) |*e| {
            e.* = .{ .key = try self.str(), .value = try self.value(gpa) };
        }
        return entries;
    }

    pub fn value(self: *Reader, gpa: std.mem.Allocator) ReadError!ir.Value {
        const tag = try self.uleb();
        return switch (tag) {
            0 => .null,
            1 => .{ .bool = try self.boolb() },
            2 => .{ .int = try self.i64zig() },
            3 => .{ .float = try self.f64le() },
            4 => .{ .str = try self.str() },
            5 => .{ .doc = try self.docInto(gpa) },
            6 => blk: {
                const n = try self.uleb();
                const items = try gpa.alloc(ir.Value, std.math.cast(usize, n) orelse return error.UlebOverflow);
                for (items) |*it| it.* = try self.value(gpa);
                break :blk .{ .arr = items };
            },
            7 => blk: {
                const n = try self.uleb();
                const dims = try gpa.alloc(f32, std.math.cast(usize, n) orelse return error.UlebOverflow);
                for (dims) |*f| f.* = try self.f32le();
                break :blk .{ .vector = dims };
            },
            8 => .{ .ref = try self.recordId() },
            else => error.UnknownTag,
        };
    }

    pub fn record(self: *Reader, gpa: std.mem.Allocator) ReadError!ir.Record {
        const id = try self.recordId();
        const body = try self.docInto(gpa);
        const embedding = switch (try self.byte()) {
            0 => null,
            1 => blk: {
                const n = try self.uleb();
                const dims = try gpa.alloc(f32, std.math.cast(usize, n) orelse return error.UlebOverflow);
                for (dims) |*f| f.* = try self.f32le();
                break :blk dims;
            },
            else => return error.UlebOverflow,
        };
        return .{
            .id = id,
            .body = body,
            .embedding = embedding,
            .created_at = try self.i64zig(),
        };
    }

    pub fn relationEdge(self: *Reader, gpa: std.mem.Allocator) ReadError!ir.RelationEdge {
        return .{
            .from = try self.recordId(),
            .name = try self.str(),
            .to = try self.recordId(),
            .created_at = try self.i64zig(),
            .weight = try self.optF32(),
            .props = try self.docInto(gpa),
        };
    }

    pub fn filter(self: *Reader, gpa: std.mem.Allocator) ReadError!ir.Filter {
        const tag = try self.uleb();
        return switch (tag) {
            0 => .{ .field_equals = .{ .field = try self.str(), .value = try self.value(gpa) } },
            1 => .has_embedding,
            2 => .{ .bm25 = .{
                .field = try self.str(),
                .query = try self.str(),
                .k = try self.optUsize(),
            } },
            3 => .{ .field_cmp = .{
                .field = try self.str(),
                .op = try self.cmpOp(),
                .value = try self.value(gpa),
            } },
            4 => blk: {
                const field = try self.str();
                const n = try self.uleb();
                const values = try gpa.alloc(ir.Value, std.math.cast(usize, n) orelse return error.UlebOverflow);
                for (values) |*v| v.* = try self.value(gpa);
                break :blk .{ .field_in = .{ .field = field, .values = values } };
            },
            5 => .{ .field_between = .{
                .field = try self.str(),
                .lo = try self.value(gpa),
                .hi = try self.value(gpa),
            } },
            6 => blk: {
                const n = try self.uleb();
                const items = try gpa.alloc(ir.Filter, std.math.cast(usize, n) orelse return error.UlebOverflow);
                for (items) |*it| it.* = try self.filter(gpa);
                break :blk .{ .and_filter = items };
            },
            else => error.UnknownTag,
        };
    }

    fn cmpOp(self: *Reader) ReadError!ir.CmpOp {
        return switch (try self.uleb()) {
            0 => .ne,
            1 => .lt,
            2 => .le,
            3 => .gt,
            4 => .ge,
            else => error.UnknownTag,
        };
    }

    fn optFilter(self: *Reader, gpa: std.mem.Allocator) ReadError!?ir.Filter {
        return switch (try self.byte()) {
            0 => null,
            1 => try self.filter(gpa),
            else => error.UlebOverflow,
        };
    }

    pub fn selectInto(self: *Reader, gpa: std.mem.Allocator) ReadError!ir.Select {
        const table = try self.str();
        const knn: ?ir.Knn = switch (try self.byte()) {
            0 => null,
            1 => blk: {
                const n = try self.uleb();
                const query = try gpa.alloc(f32, std.math.cast(usize, n) orelse return error.UlebOverflow);
                for (query) |*f| f.* = try self.f32le();
                break :blk .{ .query = query, .k = @intCast(try self.uleb()) };
            },
            else => return error.UlebOverflow,
        };
        const fil: ?ir.Filter = switch (try self.byte()) {
            0 => null,
            1 => try self.filter(gpa),
            else => return error.InvalidValue,
        };
        const ord: ?ir.Order = switch (try self.byte()) {
            0 => null,
            1 => try self.order(),
            else => return error.UlebOverflow,
        };
        const limit = try self.optUsize();
        const as_of = try self.optI64();
        const fields: ?[]const []const u8 = switch (try self.byte()) {
            0 => null,
            1 => blk: {
                const n = try self.uleb();
                const list = try gpa.alloc([]const u8, std.math.cast(usize, n) orelse return error.UlebOverflow);
                for (list) |*f| f.* = try self.str();
                break :blk list;
            },
            else => return error.UlebOverflow,
        };
        const offset = try self.optUsize();
        const aggregate: ?ir.Aggregate = switch (try self.byte()) {
            0 => null,
            1 => switch (try self.uleb()) {
                0 => .count_star,
                else => return error.UnknownTag,
            },
            else => return error.UlebOverflow,
        };
        return .{
            .table = table,
            .knn = knn,
            .filter = fil,
            .order = ord,
            .limit = limit,
            .as_of = as_of,
            .fields = fields,
            .offset = offset,
            .aggregate = aggregate,
        };
    }

    fn order(self: *Reader) ReadError!ir.Order {
        const tag = try self.uleb();
        return switch (tag) {
            0 => .similarity,
            1 => .salience,
            2 => .score,
            3 => .votes,
            4 => .feedback,
            5 => .recency,
            6 => blk: {
                var w: [4]f32 = undefined;
                for (&w) |*f| f.* = try self.f32le();
                break :blk .{ .salience_weighted = w };
            },
            7 => .{ .field = .{ .key = try self.str(), .desc = try self.boolb() } },
            else => error.UnknownTag,
        };
    }

    pub fn matchPathInto(self: *Reader, gpa: std.mem.Allocator) ReadError!ir.MatchPath {
        const start = try self.recordId();
        const n = try self.uleb();
        const steps = try gpa.alloc(ir.MatchStep, std.math.cast(usize, n) orelse return error.UlebOverflow);
        for (steps) |*step| {
            const direction: ir.MatchDirection = switch (try self.uleb()) {
                0 => .out,
                1 => .in,
                else => return error.UnknownTag,
            };
            step.* = .{
                .direction = direction,
                .name = try self.str(),
                .edge_props = try self.optFilter(gpa),
            };
        }
        return .{ .start = start, .steps = steps, .as_of = try self.optI64() };
    }

    fn snapStoreInto(self: *Reader, gpa: std.mem.Allocator) ReadError!ir.SnapStore {
        const records = try self.recordMapInto(gpa);
        const n_e = try self.uleb();
        const edges = try gpa.alloc(ir.RelationEdge, std.math.cast(usize, n_e) orelse return error.UlebOverflow);
        for (edges) |*e| e.* = try self.relationEdge(gpa);
        const n_d = try self.uleb();
        const dims = try gpa.alloc(ir.DimEntry, std.math.cast(usize, n_d) orelse return error.UlebOverflow);
        for (dims) |*d| d.* = .{ .name = try self.str(), .dim = @intCast(try self.uleb()) };
        const clock = try self.i64zig();
        const history = try self.historyVecInto(gpa);
        const n_m = try self.uleb();
        const memories = try gpa.alloc(ir.SnapMemory, std.math.cast(usize, n_m) orelse return error.UlebOverflow);
        for (memories) |*m| m.* = .{ .name = try self.str(), .store = try self.snapStoreInto(gpa) };
        return .{
            .records = records,
            .edges = edges,
            .vector_dims = dims,
            .clock = clock,
            .history = history,
            .memories = memories,
        };
    }

    fn recordMapInto(self: *Reader, gpa: std.mem.Allocator) ReadError![]const ir.Record {
        const n = try self.uleb();
        const records = try gpa.alloc(ir.Record, std.math.cast(usize, n) orelse return error.UlebOverflow);
        for (records) |*r| {
            const key = try self.recordId(); // map key (BTreeMap)
            r.* = try self.record(gpa);
            // The value repeats the id — postcard round-trips both; trust the
            // key (BTreeMap key order is canonical) and require agreement.
            if (!recordIdEql(key, r.id)) return error.IdMismatch;
        }
        return records;
    }

    pub fn historyVecInto(self: *Reader, gpa: std.mem.Allocator) ReadError![]const ir.HistoryEntry {
        const n = try self.uleb();
        const entries = try gpa.alloc(ir.HistoryEntry, std.math.cast(usize, n) orelse return error.UlebOverflow);
        for (entries) |*e| e.* = .{ .ts = try self.i64zig(), .stmt = try self.statement(gpa) };
        return entries;
    }

    pub fn statement(self: *Reader, gpa: std.mem.Allocator) ReadError!ir.Statement {
        const tag = try self.uleb();
        return switch (tag) {
            0 => .{ .create_table = .{ .table = try self.str(), .vector_dim = try self.optUsize() } },
            1 => .{ .insert = try self.record(gpa) },
            2 => .{ .relate = try self.relationEdge(gpa) },
            3 => .{ .select = try self.selectInto(gpa) },
            4 => .{ .match_path = try self.matchPathInto(gpa) },
            5 => .{ .closure = try self.matchPathInto(gpa) },
            6 => .{ .forget = .{ .id = try self.recordId() } },
            7 => .{ .memory = .{ .name = try self.str() } },
            8 => .context_reset,
            9 => .{ .match_count = try self.matchPathInto(gpa) },
            10 => .prune_history,
            11 => .{ .snapshot = try self.snapshotStateInto(gpa) },
            12 => .{ .history_since = try self.i64zig() },
            else => error.UnknownTag,
        };
    }

    fn snapshotStateInto(self: *Reader, gpa: std.mem.Allocator) ReadError!ir.SnapshotState {
        const records = try self.recordMapInto(gpa);
        const n_e = try self.uleb();
        const edges = try gpa.alloc(ir.RelationEdge, std.math.cast(usize, n_e) orelse return error.UlebOverflow);
        for (edges) |*e| e.* = try self.relationEdge(gpa);
        const n_d = try self.uleb();
        const dims = try gpa.alloc(ir.DimEntry, std.math.cast(usize, n_d) orelse return error.UlebOverflow);
        for (dims) |*d| d.* = .{ .name = try self.str(), .dim = @intCast(try self.uleb()) };
        const clock = try self.i64zig();
        const n_m = try self.uleb();
        const memories = try gpa.alloc(ir.SnapMemory, std.math.cast(usize, n_m) orelse return error.UlebOverflow);
        for (memories) |*m| m.* = .{ .name = try self.str(), .store = try self.snapStoreInto(gpa) };
        const n_t = try self.uleb();
        const tables = try gpa.alloc(ir.TableEntry, std.math.cast(usize, n_t) orelse return error.UlebOverflow);
        for (tables) |*t| t.* = .{ .name = try self.str(), .vector_dim = try self.optUsize() };
        return .{
            .records = records,
            .edges = edges,
            .vector_dims = dims,
            .clock = clock,
            .memories = memories,
            .tables = tables,
        };
    }
};

fn recordIdEql(a: ir.RecordId, b: ir.RecordId) bool {
    if (!std.mem.eql(u8, a.table, b.table)) return false;
    return switch (a.id) {
        .num => |x| switch (b.id) {
            .num => |y| x == y,
            .str => false,
        },
        .str => |x| switch (b.id) {
            .num => false,
            .str => |y| std.mem.eql(u8, x, y),
        },
    };
}

test "uleb128 / zigzag vectors" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var w = Writer.init(gpa);
    defer w.deinit();
    try w.uleb(0);
    try w.uleb(127);
    try w.uleb(128);
    try w.uleb(300);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x7f, 0x80, 0x01, 0xac, 0x02 }, w.bytes());

    var w2 = Writer.init(gpa);
    defer w2.deinit();
    try w2.i64zig(0);
    try w2.i64zig(-1);
    try w2.i64zig(1);
    try w2.i64zig(-2);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x01, 0x02, 0x03 }, w2.bytes());

    var r = Reader.init(w2.bytes());
    try std.testing.expectEqual(@as(i64, 0), try r.i64zig());
    try std.testing.expectEqual(@as(i64, -1), try r.i64zig());
    try std.testing.expectEqual(@as(i64, 1), try r.i64zig());
    try std.testing.expectEqual(@as(i64, -2), try r.i64zig());
}
