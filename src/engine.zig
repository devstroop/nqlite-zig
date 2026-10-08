//! Deterministic in-memory engine (spec/nql.md §2) — port of
//! `nqlite/src/engine.rs` (M3 scope: CREATE/INSERT/RELATE/FORGET/SELECT
//! with every field predicate, exact kNN, BM25/hybrid, all score orders,
//! COUNT/projection/paging; MATCH/CLOSURE/temporal land with M7).
//!
//! Determinism rules honored here: records iterate in canonical RecordId
//! order (the BTreeMap contract), ties always break by ascending RecordId,
//! all arithmetic is f32 (bit-parity with the Rust oracle), and there is
//! no wall-clock or randomness anywhere.

const std = @import("std");
const ir = @import("ir.zig");
const bm25mod = @import("bm25.zig");

pub const EngineError = error{
    OutOfMemory,
    EmbeddingDimMismatch,
    UnknownSortField,
    MemoryWithoutContext,
    HistoryPruned,
    NotImplemented,
};

/// Rich failure detail (Rust `Display` text) — set on the store at the
/// failure site so the line server can emit byte-exact `ERR` lines.
pub const EngineFail = struct {
    variant: []const u8,
    message: []const u8,
};

/// Corpus-facing error names (mirror the Rust `Error` discriminants).
pub fn errorVariant(e: EngineError) []const u8 {
    if (e == error.EmbeddingDimMismatch) return "EmbeddingDimMismatch";
    if (e == error.UnknownSortField) return "UnknownSortField";
    if (e == error.MemoryWithoutContext) return "MemoryWithoutContext";
    if (e == error.HistoryPruned) return "HistoryPruned";
    return "Internal";
}

pub const QueryKind = union(enum) {
    select: []const u8, // table name
    match_: ir.MatchPath,
    closure: ir.MatchPath,
    history: i64, // `HISTORY SINCE <since>` cutoff (issue #118)
};

pub const Row = struct {
    record: ir.Record,
    score: f32,
};

pub const QueryResult = struct {
    kind: QueryKind,
    rows: []const Row,
};

/// A scored candidate (kNN similarity / BM25 / hybrid input).
const Scored = struct { id: ir.RecordId, s: f32 };

// ---------------------------------------------------------------------------
// Store (mutable engine state; canonical record order by construction)
// ---------------------------------------------------------------------------

pub const EngineStore = struct {
    gpa: std.mem.Allocator,
    records: std.ArrayList(ir.Record) = .empty, // sorted by RecordId
    edges: std.ArrayList(ir.RelationEdge) = .empty, // append order
    tables: std.ArrayList(ir.TableEntry) = .empty, // name -> dim (upserted)
    clock: i64 = 0,
    history: std.ArrayList(ir.HistoryEntry) = .empty,
    memories: std.ArrayList(Memory) = .empty,
    /// Bumped whenever `records` changes — keys the BM25 index cache.
    mut_version: u64 = 0,
    /// Cached BM25 index over a whole table (only built from the
    /// top-level `.bm25` arm, where the filter never prunes and
    /// candidates == the table's records); invalidated by `mut_version`.
    bm25_cache: ?Bm25Cache = null,
    /// Last rich failure (cleared per server line by the caller).
    err: ?EngineFail = null,

    const Bm25Cache = struct {
        table: []const u8,
        field: []const u8,
        version: u64,
        index: bm25mod.Bm25Index,
    };

    /// A named memory partition (root-level, like the reference engine).
    pub const Memory = struct {
        name: []const u8,
        store: EngineStore,
    };

    pub fn init(gpa: std.mem.Allocator) EngineStore {
        return .{ .gpa = gpa };
    }

    fn findIndex(self: *const EngineStore, id: ir.RecordId) ?usize {
        var lo: usize = 0;
        var hi: usize = self.records.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const c = cmpRecordId(self.records.items[mid].id, id);
            if (c == .lt) lo = mid + 1 else hi = mid;
        }
        if (lo < self.records.items.len and ir.recordIdEql(self.records.items[lo].id, id))
            return lo;
        return null;
    }

    /// BTreeMap::insert semantics: replace in place, else sorted insert.
    pub fn insert(self: *EngineStore, rec: ir.Record) !void {
        self.mut_version +%= 1;
        if (self.findIndex(rec.id)) |i| {
            self.records.items[i] = rec;
            return;
        }
        var lo: usize = 0;
        var hi: usize = self.records.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (ir.RecordId.less(self.records.items[mid].id, rec.id)) lo = mid + 1 else hi = mid;
        }
        try self.records.insert(self.gpa, lo, rec);
    }

    pub fn remove(self: *EngineStore, id: ir.RecordId) void {
        self.mut_version +%= 1;
        if (self.findIndex(id)) |i| {
            _ = self.records.orderedRemove(i);
        }
    }

    pub fn logMutation(self: *EngineStore, stmt: ir.Statement) !void {
        self.clock += 1;
        try self.history.append(self.gpa, .{ .ts = self.clock, .stmt = stmt });
    }

    pub fn dimOf(self: *const EngineStore, table: []const u8) ?usize {
        for (self.tables.items) |t| {
            if (std.mem.eql(u8, t.name, table)) return t.vector_dim;
        }
        return null;
    }

    fn upsertTable(self: *EngineStore, name: []const u8, dim: ?usize) !void {
        for (self.tables.items) |*t| {
            if (std.mem.eql(u8, t.name, name)) {
                t.vector_dim = dim;
                return;
            }
        }
        try self.tables.append(self.gpa, .{ .name = name, .vector_dim = dim });
    }

    fn memorySlot(self: *EngineStore, name: []const u8) !usize {
        for (self.memories.items, 0..) |m, i| {
            if (std.mem.eql(u8, m.name, name)) return i;
        }
        try self.memories.append(self.gpa, .{ .name = name, .store = EngineStore.init(self.gpa) });
        return self.memories.items.len - 1;
    }

    fn memoryMut(self: *EngineStore, name: []const u8) !*EngineStore {
        const i = try self.memorySlot(name);
        return &self.memories.items[i].store;
    }
};

fn cmpRecordId(a: ir.RecordId, b: ir.RecordId) std.math.Order {
    if (ir.RecordId.less(a, b)) return .lt;
    if (ir.RecordId.less(b, a)) return .gt;
    return .eq;
}

// ---------------------------------------------------------------------------
// Value total order (nql_ir::Value::cmp_total — issue #93 / spec §2.3)
// ---------------------------------------------------------------------------

fn valueRank(v: ir.Value) u8 {
    return switch (v) {
        .null => 0,
        .bool => 1,
        .int, .float => 2,
        .str => 3,
        .arr => 4,
        .doc => 5,
        .vector => 6,
        .ref => 7,
    };
}

/// IEEE total order for f64 (Rust f64::total_cmp semantics): NaN after every
/// number, same-bit NaNs equal, numeric equality short-circuits (-0.0 == 0.0).
fn totalOrdF64(a: f64, b: f64) std.math.Order {
    if (a == b) return .eq; // catches -0.0 == 0.0
    if (std.math.isNan(a) and std.math.isNan(b)) {
        const ab: u64 = @bitCast(a);
        const bb: u64 = @bitCast(b);
        return if (ab < bb) .lt else if (ab > bb) .gt else .eq;
    }
    if (std.math.isNan(a)) return .gt;
    if (std.math.isNan(b)) return .lt;
    return if (a < b) .lt else .gt;
}

fn totalOrdF32(a: f32, b: f32) std.math.Order {
    if (a == b) return .eq;
    if (std.math.isNan(a) and std.math.isNan(b)) {
        const ab: u32 = @bitCast(a);
        const bb: u32 = @bitCast(b);
        return if (ab < bb) .lt else if (ab > bb) .gt else .eq;
    }
    if (std.math.isNan(a)) return .gt;
    if (std.math.isNan(b)) return .lt;
    return if (a < b) .lt else .gt;
}

/// Exact i64-vs-f64 comparison (never rounds the int through f64).
fn cmpIntFloat(a: i64, b: f64) std.math.Order {
    if (std.math.isNan(b)) return .lt;
    const max_i: f64 = @floatFromInt(std.math.maxInt(i64));
    const min_i: f64 = @floatFromInt(std.math.minInt(i64));
    if (b >= max_i) return .lt;
    if (b < min_i) return .gt;
    if (b == std.math.trunc(b)) {
        const bi: i64 = @intFromFloat(b);
        return std.math.order(a, bi);
    }
    const floor: i64 = @intFromFloat(@floor(b));
    return switch (std.math.order(a, floor)) {
        .eq => .lt, // a == floor(b) < b
        else => |o| o,
    };
}

pub fn cmpTotal(a: ir.Value, b: ir.Value) std.math.Order {
    const ra = valueRank(a);
    const rb = valueRank(b);
    if (ra != rb) return std.math.order(ra, rb);
    switch (a) {
        .null => return .eq,
        .bool => |x| {
            const y = b.bool;
            return if (x == y) .eq else if (!x and y) .lt else .gt;
        },
        .int => |x| switch (b) {
            .int => |y| return std.math.order(x, y),
            .float => |y| return cmpIntFloat(x, y),
            else => unreachable,
        },
        .float => |x| switch (b) {
            .int => |y| return reverseOrder(cmpIntFloat(y, x)),
            .float => |y| return totalOrdF64(x, y),
            else => unreachable,
        },
        .str => |x| {
            const y = b.str;
            return std.mem.order(u8, x, y);
        },
        .arr => |xs| {
            const ys = b.arr;
            var i: usize = 0;
            while (i < xs.len and i < ys.len) : (i += 1) {
                const c = cmpTotal(xs[i], ys[i]);
                if (c != .eq) return c;
            }
            return std.math.order(xs.len, ys.len);
        },
        .doc => |xs| {
            const ys = b.doc;
            var i: usize = 0;
            while (i < xs.len and i < ys.len) : (i += 1) {
                const kc = std.mem.order(u8, xs[i].key, ys[i].key);
                if (kc != .eq) return kc;
                const c = cmpTotal(xs[i].value, ys[i].value);
                if (c != .eq) return c;
            }
            return std.math.order(xs.len, ys.len);
        },
        .vector => |xs| {
            const ys = b.vector;
            var i: usize = 0;
            while (i < xs.len and i < ys.len) : (i += 1) {
                const c = totalOrdF32(xs[i], ys[i]);
                if (c != .eq) return c;
            }
            return std.math.order(xs.len, ys.len);
        },
        .ref => |x| return cmpRecordId(x, b.ref),
    }
}

/// Exact value equality (`Value`'s derived PartialEq — used by `=`, `IN`).
/// Same variant required (Int(1) != Float(1.0)); strings compare by bytes;
/// NaN != NaN (IEEE), -0.0 == 0.0.
pub fn valueEql(a: ir.Value, b: ir.Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    switch (a) {
        .null => return true,
        .bool => |x| return x == b.bool,
        .int => |x| return x == b.int,
        .float => |x| return x == b.float,
        .str => |x| return std.mem.eql(u8, x, b.str),
        .doc => |xs| {
            const ys = b.doc;
            if (xs.len != ys.len) return false;
            for (xs, ys) |x, y| {
                if (!std.mem.eql(u8, x.key, y.key)) return false;
                if (!valueEql(x.value, y.value)) return false;
            }
            return true;
        },
        .arr => |xs| {
            const ys = b.arr;
            if (xs.len != ys.len) return false;
            for (xs, ys) |x, y| {
                if (!valueEql(x, y)) return false;
            }
            return true;
        },
        .vector => |xs| {
            const ys = b.vector;
            if (xs.len != ys.len) return false;
            for (xs, ys) |x, y| {
                if (x != y) return false; // NaN != NaN, -0.0 == 0.0
            }
            return true;
        },
        .ref => |x| return ir.recordIdEql(x, b.ref),
    }
}

// ---------------------------------------------------------------------------
// Deterministic cosine (issue #134 — the shared reference algorithm)
// ---------------------------------------------------------------------------

pub fn cosineSimilarity(a: []const f32, b: []const f32) f32 {
    const n = @min(a.len, b.len);
    var dot: f32 = 0.0;
    var na: f32 = 0.0;
    var nb: f32 = 0.0;
    for (0..n) |i| {
        dot += a[i] * b[i];
        na += a[i] * a[i];
        nb += b[i] * b[i];
    }
    if (na == 0.0 or nb == 0.0) return 0.0;
    return dot / (@sqrt(na) * @sqrt(nb));
}

// ---------------------------------------------------------------------------
// Execution
// ---------------------------------------------------------------------------

/// Execute a whole plan; one result per read statement.
pub fn executePlan(store: *EngineStore, plan: []const ir.Statement) EngineError![]QueryResult {
    var results: std.ArrayList(QueryResult) = .empty;
    var current_memory: ?[]const u8 = null;
    for (plan) |stmt| {
        if (try executeInContext(store, stmt, &current_memory)) |res| {
            try results.append(store.gpa, res);
        }
    }
    return results.items;
}

/// Execute a single `Statement` within a plan's memory context.
/// (Public for WAL replay — spec §2 / issue #109.)
pub fn executeInContext(
    store: *EngineStore,
    stmt: ir.Statement,
    current_memory: *?[]const u8,
) EngineError!?QueryResult {
    switch (stmt) {
        .memory => |m| {
            _ = try store.memorySlot(m.name);
            current_memory.* = m.name;
            return null;
        },
        .context_reset => {
            current_memory.* = null;
            return null;
        },
        else => {},
    }
    if (current_memory.*) |name| {
        const mem = try store.memoryMut(name);
        mem.err = null;
        return executeStatement(mem, stmt) catch |e| {
            // Surface the block's rich failure on the store the server
            // reads (`self.store.err`) — parity with the reference, whose
            // Result-based errors carry the message regardless of scope.
            if (store.err == null) store.err = mem.err;
            return e;
        };
    }
    return executeStatement(store, stmt);
}

fn executeStatement(store: *EngineStore, stmt: ir.Statement) EngineError!?QueryResult {
    switch (stmt) {
        .memory => |m| {
            const msg = std.fmt.allocPrint(
                store.gpa,
                "`MEMORY {s}` must run inside a plan to switch context",
                .{m.name},
            ) catch "MEMORY without context";
            store.err = .{ .variant = "MemoryWithoutContext", .message = msg };
            return EngineError.MemoryWithoutContext;
        },
        .context_reset => return null,
        .create_table => |c| {
            try store.upsertTable(c.table, c.vector_dim);
            try store.logMutation(stmt);
            return null;
        },
        .insert => |rec| {
            try validateEmbedding(store, rec);
            var stamped = rec;
            if (stamped.created_at == 0) stamped.created_at = store.clock + 1;
            try store.insert(stamped);
            try store.logMutation(stmt);
            return null;
        },
        .relate => |e| {
            var stamped = e;
            if (stamped.created_at == 0) stamped.created_at = store.clock + 1;
            try store.edges.append(store.gpa, stamped);
            try store.logMutation(stmt);
            return null;
        },
        .forget => |f| {
            store.remove(f.id);
            var i: usize = 0;
            while (i < store.edges.items.len) {
                const e = store.edges.items[i];
                if (ir.recordIdEql(e.from, f.id) or ir.recordIdEql(e.to, f.id)) {
                    _ = store.edges.orderedRemove(i);
                } else i += 1;
            }
            try store.logMutation(stmt);
            return null;
        },
        .select => |sel| {
            const rows = try runSelect(store, sel);
            return .{ .kind = .{ .select = sel.table }, .rows = rows };
        },
        .match_path => |path| {
            var view: ?EngineStore = null;
            const target = try temporalView(store.gpa, store, path.as_of, &view);
            const rows = try runMatch(target, store.gpa, path);
            return .{ .kind = .{ .match_ = path }, .rows = rows };
        },
        .match_count => |path| {
            var view: ?EngineStore = null;
            const target = try temporalView(store.gpa, store, path.as_of, &view);
            const n = runMatchCount(target, path);
            const row = try store.gpa.alloc(Row, 1);
            row[0] = try countRow(store.gpa, path.start.table, n);
            return .{ .kind = .{ .match_ = path }, .rows = row };
        },
        .closure => |path| {
            var view: ?EngineStore = null;
            const target = try temporalView(store.gpa, store, path.as_of, &view);
            const rows = try runClosure(target, store.gpa, path);
            return .{ .kind = .{ .closure = path }, .rows = rows };
        },
        // History compaction base: install the captured state (replay-only).
        .snapshot => |st| {
            store.records = .empty;
            store.mut_version +%= 1; // even a snapshot with no records
            for (st.records) |r| try store.insert(r);
            store.edges = .empty;
            for (st.edges) |e| try store.edges.append(store.gpa, e);
            store.tables = .empty;
            for (st.tables) |t| try store.tables.append(store.gpa, t);
            store.clock = st.clock;
            store.history = .empty;
            store.memories = .empty;
            for (st.memories) |m| {
                try store.memories.append(
                    store.gpa,
                    .{ .name = m.name, .store = try engineStoreFromSnap(store.gpa, m.store) },
                );
            }
            return null;
        },
        // History compaction (issue #95): snapshot the current state
        // (memories depth-first) and keep only declarations + the
        // snapshot. No clock bump — the snapshot is stamped at the
        // current clock, and PRUNE never logs itself.
        .prune_history => {
            try pruneHistory(store);
            return null;
        },
        // Exact delta read (issue #118): one row per mutation strictly
        // after the cutoff; snapshots are compaction bookkeeping and
        // are never reported as mutations.
        .history_since => |since| {
            const rows = try historySince(store, since);
            return .{ .kind = .{ .history = since }, .rows = rows };
        },
    }
}

/// Build a live store from a wire-form snapshot store (no `tables` field —
/// rebuilt from its own history, matching the reference's rebuild rule).
fn engineStoreFromSnap(gpa: std.mem.Allocator, s: ir.SnapStore) EngineError!EngineStore {
    var out = EngineStore.init(gpa);
    for (s.records) |r| try out.insert(r);
    for (s.edges) |e| try out.edges.append(gpa, e);
    out.clock = s.clock;
    for (s.history) |h| try out.history.append(gpa, h);
    for (s.memories) |m| {
        try out.memories.append(gpa, .{
            .name = m.name,
            .store = try engineStoreFromSnap(gpa, m.store),
        });
    }
    try rebuildTables(&out);
    return out;
}

/// Re-declare tables from a store's (and its memories') mutation histories —
/// the reference's `rebuild_tables` (issue #133) for snapshot installs.
fn rebuildTables(store: *EngineStore) EngineError!void {
    for (store.history.items) |h| {
        if (h.stmt == .create_table) {
            try store.upsertTable(h.stmt.create_table.table, h.stmt.create_table.vector_dim);
        }
    }
    for (store.memories.items) |*m| try rebuildTables(&m.store);
}

/// Build engine state from a decoded §5 store (file-load path).
pub fn fromIr(gpa: std.mem.Allocator, s: ir.Store) EngineError!EngineStore {
    var out = EngineStore.init(gpa);
    for (s.records) |r| try out.insert(r);
    for (s.edges) |e| try out.edges.append(gpa, e);
    for (s.tables) |t| try out.tables.append(gpa, t);
    out.clock = s.clock;
    for (s.history) |h| try out.history.append(gpa, h);
    for (s.memories) |m| {
        try out.memories.append(gpa, .{ .name = m.name, .store = try fromIr(gpa, m.store) });
    }
    return out;
}

/// Borrowed view of engine state as the §5 store (checkpoint encoding).
/// The slices borrow `self` — encode immediately; `memories` needs the
/// arena for the recursive struct array.
pub fn toIr(self: *EngineStore, gpa: std.mem.Allocator) EngineError!ir.Store {
    const mems = try gpa.alloc(ir.Memory, self.memories.items.len);
    for (mems, 0..) |*slot, i| {
        slot.* = .{
            .name = self.memories.items[i].name,
            .store = try toIr(&self.memories.items[i].store, gpa),
        };
    }
    return .{
        .tables = self.tables.items,
        .records = self.records.items,
        .edges = self.edges.items,
        .clock = self.clock,
        .history = self.history.items,
        .memories = mems,
    };
}

/// The reference's `is_mutating` (lib.rs): read-only statements are never
/// WAL-logged; `Memory` and `PruneHistory` are (they change replay state).
pub fn isMutating(stmt: ir.Statement) bool {
    return switch (stmt) {
        .select, .match_path, .match_count, .closure, .history_since, .snapshot, .context_reset => false,
        .create_table, .insert, .relate, .forget, .memory, .prune_history => true,
    };
}

fn validateEmbedding(store: *EngineStore, rec: ir.Record) EngineError!void {
    const dim = store.dimOf(rec.id.table) orelse return;
    if (rec.embedding) |emb| {
        if (emb.len != dim) {
            const m = std.fmt.allocPrint(
                store.gpa,
                "embedding dimension mismatch for table `{s}`: declared dim {d}, got {d}",
                .{ rec.id.table, dim, emb.len },
            ) catch "embedding dimension mismatch";
            store.err = .{ .variant = "EmbeddingDimMismatch", .message = m };
            return EngineError.EmbeddingDimMismatch;
        }
    }
}

// ---------------------------------------------------------------------------
// SELECT pipeline
// ---------------------------------------------------------------------------

fn bodyGet(body: []const ir.DocEntry, key: []const u8) ?ir.Value {
    for (body) |e| {
        if (std.mem.eql(u8, e.key, key)) return e.value;
    }
    return null;
}

fn bodyHas(body: []const ir.DocEntry, key: []const u8) bool {
    for (body) |e| {
        if (std.mem.eql(u8, e.key, key)) return true;
    }
    return false;
}

fn runSelect(root: *EngineStore, sel: ir.Select) EngineError![]Row {
    // Temporal read (`AS OF T`): query the replayed historical view.
    var as_view: ?EngineStore = null;
    const store: *EngineStore = try temporalView(root.gpa, root, sel.as_of, &as_view);

    // Candidates: canonical record order, table + filter.
    var candidates: std.ArrayList(ir.Record) = .empty;
    for (store.records.items) |rec| {
        if (!std.mem.eql(u8, rec.id.table, sel.table)) continue;
        if (!matchesFilter(rec, sel.filter)) continue;
        try candidates.append(store.gpa, rec);
    }

    // SELECT COUNT(*) — before scoring/ordering/paging/projection.
    if (sel.aggregate) |agg| {
        switch (agg) {
            .count_star => {
                const row = try store.gpa.alloc(Row, 1);
                row[0] = try countRow(store.gpa, sel.table, candidates.items.len);
                return row;
            },
        }
    }

    // kNN: exact cosine over embedded candidates (score desc, id asc, k=all).
    // `knn_dense` is the candidate-aligned lookup the row loop and the
    // vector half of RRF read — O(1) per row instead of an O(n) id scan.
    var knn_dense: []?f32 = &[_]?f32{};
    if (sel.knn) |knn| {
        const dense = try store.gpa.alloc(?f32, candidates.items.len);
        @memset(dense, null);
        var ci: usize = 0;
        for (candidates.items) |rec| {
            if (rec.embedding) |emb| dense[ci] = cosineSimilarity(emb, knn.query);
            ci += 1;
        }
        knn_dense = dense;
    }

    // BM25 over the filtered candidates.
    var bm25_index: ?bm25mod.Bm25Index = null;
    var bm25_tokens: []const []const u8 = &[_][]const u8{};
    if (sel.filter) |f| {
        switch (f) {
            .bm25 => |b| {
                bm25_index = try bm25IndexCached(store, sel.table, b.field, candidates.items);
                bm25_tokens = try bm25mod.tokenize(store.gpa, b.query);
            },
            else => {},
        }
    }

    // Hybrid RRF fusion (K=60, rank 1-based, tie-break id asc).
    // Fusion accumulates into a candidate-aligned dense array (binary-search
    // position by id) — same += sequence per id as the old list upsert, so
    // the f32 sums stay bit-identical; lookups become O(1) per row.
    var fused: []f32 = &[_]f32{};
    var fused_present = false;
    if (sel.knn != null and bm25_index != null) {
        const fdense = try store.gpa.alloc(f32, candidates.items.len);
        @memset(fdense, 0.0);
        fused = fdense;
        fused_present = true;
        const idx = &bm25_index.?;
        var lexical: std.ArrayList(Scored) = .empty;
        for (candidates.items) |rec| {
            try lexical.append(store.gpa, .{ .id = rec.id, .s = idx.score(rec.id, bm25_tokens) });
        }
        sortScoredDesc(lexical.items);
        for (lexical.items, 0..) |e, rank| {
            fdense[candPos(candidates.items, e.id)] += 1.0 / (60.0 + @as(f32, @floatFromInt(rank + 1)));
        }
        var vector_l: std.ArrayList(Scored) = .empty;
        for (candidates.items, 0..) |rec, i| {
            try vector_l.append(store.gpa, .{ .id = rec.id, .s = knn_dense[i] orelse 0.0 });
        }
        sortScoredDesc(vector_l.items);
        for (vector_l.items, 0..) |e, rank| {
            fdense[candPos(candidates.items, e.id)] += 1.0 / (60.0 + @as(f32, @floatFromInt(rank + 1)));
        }
    }

    // Score every candidate.
    var rows: std.ArrayList(Row) = .empty;
    for (candidates.items, 0..) |rec, i| {
        const kv: ?f32 = if (sel.knn != null) knn_dense[i] else null;
        const fv: ?f32 = if (fused_present) fused[i] else null;
        const score = computeScore(store, sel, rec, kv, fv, &bm25_index, bm25_tokens);
        try rows.append(store.gpa, .{ .record = rec, .score = score });
    }

    // ORDER BY <field> typo guard: rows nonempty + no record of the TABLE
    // carries the key → fail loudly (empty results skip the check).
    if (sel.order) |ord| {
        switch (ord) {
            .field => |f| {
                if (rows.items.len > 0) {
                    var any = false;
                    for (store.records.items) |r| {
                        if (std.mem.eql(u8, r.id.table, sel.table) and bodyHas(r.body, f.key)) {
                            any = true;
                            break;
                        }
                    }
                    if (!any) {
                        const m = std.fmt.allocPrint(
                            store.gpa,
                            "ORDER BY field `{s}` exists on no record of table `{s}` (typo? rows would sort as all-equal)",
                            .{ f.key, sel.table },
                        ) catch "unknown sort field";
                        store.err = .{ .variant = "UnknownSortField", .message = m };
                        return EngineError.UnknownSortField;
                    }
                }
            },
            else => {},
        }
    }

    rows.items = try orderRows(rows.items, sel);

    if (sel.offset) |off| {
        const skip = @min(off, rows.items.len);
        var i: usize = 0;
        while (i < skip) : (i += 1) _ = rows.orderedRemove(0);
    }
    if (effectiveLimit(sel)) |cap| {
        if (rows.items.len > cap) rows.items.len = cap;
    }

    // Field projection (presentation only, after ordering/paging).
    // Zero-alloc fast paths: fully-kept bodies keep the SAME slice, empty
    // results share one static empty slice — only a partial match copies
    // (one alloc, was an ArrayList growth per row: +26ms @100k projected).
    // Order and values are unchanged either way (bench-query + suite pin it).
    if (sel.fields) |fields| {
        for (rows.items) |*row| {
            const body = row.record.body;
            var keep_n: usize = 0;
            for (body) |e| {
                for (fields) |f| {
                    if (std.mem.eql(u8, f, e.key)) {
                        keep_n += 1;
                        break;
                    }
                }
            }
            if (keep_n == body.len) continue; // everything kept → same slice
            if (keep_n == 0) {
                row.record.body = &[_]ir.DocEntry{};
                continue;
            }
            const kept = try store.gpa.alloc(ir.DocEntry, keep_n);
            var k: usize = 0;
            for (body) |e| {
                for (fields) |f| {
                    if (std.mem.eql(u8, f, e.key)) {
                        kept[k] = e;
                        k += 1;
                        break;
                    }
                }
            }
            row.record.body = kept;
        }
    }
    return rows.items;
}

/// Cached BM25 index build — sound only where `candidates` is the whole
/// table, which holds exactly at the top-level `.bm25` call site (that
/// filter never prunes). Keyed on (mutation version, table, field); a
/// hit skips the O(n) tokenize/build entirely.
fn bm25IndexCached(
    store: *EngineStore,
    table: []const u8,
    field: []const u8,
    candidates: []const ir.Record,
) EngineError!bm25mod.Bm25Index {
    if (store.bm25_cache) |c| {
        if (c.version == store.mut_version and
            std.mem.eql(u8, c.table, table) and
            std.mem.eql(u8, c.field, field)) return c.index;
    }
    const idx = try bm25mod.Bm25Index.new(store.gpa, field, candidates);
    store.bm25_cache = .{
        .table = table,
        .field = field,
        .version = store.mut_version,
        .index = idx,
    };
    return idx;
}

/// Canonical position of `id` in a candidates slice (binary search;
/// candidates are unique and in RecordId order). Falls back to `len`
/// for an absent id — fusion entries always come from candidates.
fn candPos(candidates: []const ir.Record, id: ir.RecordId) usize {
    var lo: usize = 0;
    var hi: usize = candidates.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (ir.RecordId.less(candidates[mid].id, id)) lo = mid + 1 else hi = mid;
    }
    return lo;
}

fn sortScoredDesc(items: []Scored) void {
    // Total order (score desc, id asc — ids unique): any correct sort
    // algorithm yields the identical permutation; PDQ makes it O(n log n).
    std.mem.sortUnstable(Scored, items, {}, struct {
        fn less(_: void, a: Scored, b: Scored) bool {
            return scoredBefore(a, b);
        }
    }.less);
}

fn scoredBefore(a: Scored, b: Scored) bool {
    // score descending; equal (or NaN) → id ascending (partial_cmp
    // unwrap_or(Equal) semantics of the reference).
    if (a.s > b.s) return true;
    if (a.s < b.s) return false;
    return ir.RecordId.less(a.id, b.id);
}

fn countRow(gpa: std.mem.Allocator, table: []const u8, n: usize) EngineError!Row {
    const body = try gpa.alloc(ir.DocEntry, 1);
    body[0] = .{ .key = "count", .value = .{ .int = @intCast(n) } };
    return .{
        .record = .{
            .id = .{ .table = table, .id = .{ .str = "count" } },
            .body = body,
            .embedding = null,
            .created_at = 0,
        },
        .score = 0.0,
    };
}

fn effectiveLimit(sel: ir.Select) ?usize {
    var caps: [3]?usize = .{ null, null, null };
    if (sel.knn) |k| caps[0] = k.k;
    if (sel.filter) |f| {
        switch (f) {
            .bm25 => |b| caps[1] = b.k,
            else => {},
        }
    }
    caps[2] = sel.limit;
    var best: ?usize = null;
    for (caps) |c| {
        if (c) |v| best = if (best) |b| @min(b, v) else v;
    }
    return best;
}

// ---------------------------------------------------------------------------
// Graph traversal + temporal views (MATCH/CLOSURE/AS OF — the E01–E05 surface)
// ---------------------------------------------------------------------------

const Walk = struct { id: ir.RecordId, walks: u64 };

fn containsRid(list: []const ir.RecordId, id: ir.RecordId) bool {
    for (list) |x| {
        if (ir.recordIdEql(x, id)) return true;
    }
    return false;
}

fn scoredGet(list: []const Scored, id: ir.RecordId) f32 {
    for (list) |x| {
        if (ir.recordIdEql(x.id, id)) return x.s;
    }
    return 0.0;
}

fn walkGet(list: []const Walk, id: ir.RecordId) ?u64 {
    for (list) |x| {
        if (ir.recordIdEql(x.id, id)) return x.walks;
    }
    return null;
}

fn saturatingAdd(a: u64, b: u64) u64 {
    const r = a +% b;
    return if (r < a) std.math.maxInt(u64) else r;
}

/// The snapshot timestamp of a pruned history (issue #95), if any.
fn compactionHorizon(store: *const EngineStore) ?i64 {
    for (store.history.items) |h| {
        if (h.stmt == .snapshot) return h.ts;
    }
    return null;
}

/// The store a temporal read runs against: the current store, or a replayed
/// view when `as_of` is present (loud `HistoryPruned` below the horizon).
fn temporalView(
    gpa: std.mem.Allocator,
    root: *EngineStore,
    as_of: ?i64,
    out: *?EngineStore,
) EngineError!*EngineStore {
    const cutoff = as_of orelse return root;
    if (compactionHorizon(root)) |snap_ts| {
        if (cutoff < snap_ts) return failPruned(gpa, root, snap_ts);
    }
    out.* = try replayAsOf(gpa, root, cutoff);
    return &out.*.?;
}

/// Replay the mutation history up to `cutoff` into a fresh store (pure
/// function of `(history, cutoff)`; replay is total on valid stores).
fn replayAsOf(gpa: std.mem.Allocator, src: *const EngineStore, cutoff: i64) EngineError!EngineStore {
    var view = EngineStore.init(gpa);
    for (src.history.items) |h| {
        if (h.ts > cutoff) break;
        _ = try executeStatement(&view, h.stmt);
    }
    return view;
}

/// The loud retention contract (issues #95/#118), shared by `AS OF` and
/// `HISTORY SINCE`: a cutoff below the compaction horizon cannot be
/// answered — fail loudly rather than return a partial view/delta.
fn failPruned(gpa: std.mem.Allocator, store: *EngineStore, snap_ts: i64) EngineError {
    const m = std.fmt.allocPrint(
        gpa,
        "history before ts {d} was compacted (PRUNE HISTORY); AS OF / HISTORY SINCE timestamps earlier than the snapshot are no longer available",
        .{snap_ts},
    ) catch "history pruned";
    store.err = .{ .variant = "HistoryPruned", .message = m };
    return EngineError.HistoryPruned;
}

/// `PRUNE HISTORY` (issue #95): replace the history with the CreateTable
/// declarations it contained (original timestamps — the only record of
/// decl-only/dim-less tables) plus one Snapshot at the current clock.
/// Memories are pruned depth-first first, so embedded stores arrive
/// already compact. Deterministic and bounded: re-prune rebuilds the
/// snapshot in place instead of stacking them. Does NOT bump the clock.
fn pruneHistory(store: *EngineStore) EngineError!void {
    for (store.memories.items) |*m| try pruneHistory(&m.store);
    const gpa = store.gpa;
    var decls: std.ArrayList(ir.HistoryEntry) = .empty;
    for (store.history.items) |h| {
        if (h.stmt == .create_table) try decls.append(gpa, h);
    }
    const st = ir.SnapshotState{
        .records = store.records.items,
        .edges = store.edges.items,
        .vector_dims = try dimEntriesOf(store),
        .clock = store.clock,
        .memories = try snapMemoriesOf(store),
        .tables = try sortedTablesOf(store),
    };
    store.history = decls;
    try store.history.append(gpa, .{ .ts = store.clock, .stmt = .{ .snapshot = st } });
}

/// Table declarations in BTree (name-ascending) order — the reference
/// stores them in a BTreeMap, so snapshot bytes must sort the same way.
fn sortedTablesOf(store: *const EngineStore) EngineError![]const ir.TableEntry {
    const out = try store.gpa.alloc(ir.TableEntry, store.tables.items.len);
    @memcpy(out, store.tables.items);
    insertionSort(ir.TableEntry, out, {}, struct {
        fn less(_: void, a: ir.TableEntry, b: ir.TableEntry) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.less);
    return out;
}

/// `Store.vector_dims` — only tables with a declared dim, name-ascending.
fn dimEntriesOf(store: *const EngineStore) EngineError![]const ir.DimEntry {
    var n: usize = 0;
    for (store.tables.items) |t| {
        if (t.vector_dim != null) n += 1;
    }
    const out = try store.gpa.alloc(ir.DimEntry, n);
    var i: usize = 0;
    for (store.tables.items) |t| {
        if (t.vector_dim) |d| {
            out[i] = .{ .name = t.name, .dim = d };
            i += 1;
        }
    }
    insertionSort(ir.DimEntry, out, {}, struct {
        fn less(_: void, a: ir.DimEntry, b: ir.DimEntry) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.less);
    return out;
}

/// Memory blocks as embedded in a snapshot — each with its own already-
/// pruned history riding along (`SnapStore` has no `tables`; the install
/// path rebuilds declarations from the retained CREATE statements).
fn snapMemoriesOf(store: *const EngineStore) EngineError![]const ir.SnapMemory {
    const out = try store.gpa.alloc(ir.SnapMemory, store.memories.items.len);
    for (out, 0..) |*slot, i| {
        const m = &store.memories.items[i];
        slot.* = .{
            .name = m.name,
            .store = .{
                .records = m.store.records.items,
                .edges = m.store.edges.items,
                .vector_dims = try dimEntriesOf(&m.store),
                .clock = m.store.clock,
                .history = m.store.history.items,
                .memories = try snapMemoriesOf(&m.store),
            },
        };
    }
    return out;
}

/// `HISTORY SINCE <ts>` (issue #118): every mutation strictly after the
/// cutoff, in append (ts-ascending) order — one row per entry carrying
/// the mutation kind and its subject ids, so a sync consumer sees
/// changed rows AND changed edges (plus tombstones) in one read. The
/// PRUNE retention horizon applies (same `HistoryPruned` contract as
/// `AS OF`); snapshot entries are compaction bookkeeping, never reported.
fn historySince(store: *EngineStore, since: i64) EngineError![]Row {
    if (compactionHorizon(store)) |snap_ts| {
        if (since < snap_ts) return failPruned(store.gpa, store, snap_ts);
    }
    var rows: std.ArrayList(Row) = .empty;
    for (store.history.items) |h| {
        if (h.ts <= since) continue; // exclusive cutoff
        if (h.stmt == .snapshot) continue;
        try rows.append(store.gpa, try historyRow(store, h));
    }
    return rows.items;
}

/// One delta row: `history:<ts>` id, score = ts, body = {subject fields…,
/// kind, ts} in BTree (byte-ascending key) order — exactly the reference's
/// BTreeMap<String, Value> rendering.
fn historyRow(store: *EngineStore, h: ir.HistoryEntry) EngineError!Row {
    const gpa = store.gpa;
    var tmp: [6]ir.DocEntry = undefined;
    var n: usize = 0;
    const kind: []const u8 = switch (h.stmt) {
        .create_table => |c| blk: {
            tmp[n] = .{ .key = "table", .value = .{ .str = c.table } };
            n += 1;
            if (c.vector_dim) |d| {
                tmp[n] = .{ .key = "dim", .value = .{ .int = @intCast(d) } };
                n += 1;
            }
            break :blk "CREATE";
        },
        .insert => |rec| blk: {
            tmp[n] = .{ .key = "id", .value = .{ .str = try ir.recordIdDisplay(gpa, rec.id) } };
            n += 1;
            break :blk "INSERT";
        },
        .relate => |e| blk: {
            tmp[n] = .{ .key = "from", .value = .{ .str = try ir.recordIdDisplay(gpa, e.from) } };
            n += 1;
            tmp[n] = .{ .key = "to", .value = .{ .str = try ir.recordIdDisplay(gpa, e.to) } };
            n += 1;
            tmp[n] = .{ .key = "name", .value = .{ .str = e.name } };
            n += 1;
            break :blk "RELATE";
        },
        .forget => |f| blk: {
            tmp[n] = .{ .key = "id", .value = .{ .str = try ir.recordIdDisplay(gpa, f.id) } };
            n += 1;
            break :blk "FORGET";
        },
        .memory => |m| blk: {
            tmp[n] = .{ .key = "name", .value = .{ .str = m.name } };
            n += 1;
            break :blk "MEMORY";
        },
        .prune_history => "PRUNE",
        .history_since => |s| blk: {
            tmp[n] = .{ .key = "since", .value = .{ .int = s } };
            n += 1;
            break :blk "HISTORY_SINCE";
        },
        .context_reset => "CONTEXT_RESET",
        .select => "SELECT",
        .match_path, .match_count => "MATCH",
        .closure => "CLOSURE",
        .snapshot => unreachable, // skipped by the caller
    };
    tmp[n] = .{ .key = "ts", .value = .{ .int = h.ts } };
    n += 1;
    tmp[n] = .{ .key = "kind", .value = .{ .str = kind } };
    n += 1;
    // Heap-dupe: the returned row's body must outlive this frame (the
    // server arena owns it — a stack slice here rots across rows).
    const body = try gpa.alloc(ir.DocEntry, n);
    @memcpy(body, tmp[0..n]);
    insertionSort(ir.DocEntry, body, {}, struct {
        fn less(_: void, a: ir.DocEntry, b: ir.DocEntry) bool {
            return std.mem.lessThan(u8, a.key, b.key);
        }
    }.less);
    const id = ir.RecordId{
        .table = "history",
        .id = .{ .str = try std.fmt.allocPrint(gpa, "{d}", .{h.ts}) },
    };
    return .{
        .record = .{ .id = id, .body = body, .embedding = null, .created_at = h.ts },
        .score = @floatFromInt(h.ts),
    };
}

/// A step's edge-property filter against edge props (spec §2.5): field
/// predicates only — embedding/BM25 are never edge predicates.
fn matchesEdgeProps(edge: ir.RelationEdge, filter: ?ir.Filter) bool {
    const f = filter orelse return true;
    switch (f) {
        .has_embedding, .bm25 => return false,
        .and_filter => |terms| {
            for (terms) |t| {
                if (!matchesEdgeProps(edge, t)) return false;
            }
            return true;
        },
        else => return matchesFieldPred(edge.props, f),
    }
}

/// `MATCH` — one hop per step over the append-ordered edge list; endpoints
/// deduped keeping first appearance; score = weight of the first edge that
/// reached the endpoint (start = 0.0). Rows = the FINAL frontier.
fn runMatch(store: *EngineStore, gpa: std.mem.Allocator, path: ir.MatchPath) EngineError![]Row {
    if (store.findIndex(path.start) == null) return try gpa.alloc(Row, 0);
    var frontier: std.ArrayList(ir.RecordId) = .empty;
    try frontier.append(gpa, path.start);
    var scores: std.ArrayList(Scored) = .empty;
    try scores.append(gpa, .{ .id = path.start, .s = 0.0 });

    for (path.steps) |step| {
        var next: std.ArrayList(ir.RecordId) = .empty;
        for (store.edges.items) |edge| {
            const from_side: ir.RecordId = switch (step.direction) {
                .out => edge.from,
                .in => edge.to,
            };
            const to_side: ir.RecordId = switch (step.direction) {
                .out => edge.to,
                .in => edge.from,
            };
            if (!edgeNameMatches(edge.name, step.name)) continue;
            if (!containsRid(frontier.items, from_side)) continue;
            if (!matchesEdgeProps(edge, step.edge_props)) continue;
            if (store.findIndex(to_side) == null) continue; // dangling edge
            if (!containsRid(next.items, to_side)) try next.append(gpa, to_side);
            // First edge to reach this endpoint wins its score.
            var seen = false;
            for (scores.items) |sc| {
                if (ir.recordIdEql(sc.id, to_side)) {
                    seen = true;
                    break;
                }
            }
            if (!seen) try scores.append(gpa, .{ .id = to_side, .s = edge.weight orelse 0.0 });
        }
        frontier = next;
        if (frontier.items.len == 0) break;
    }

    var rows: std.ArrayList(Row) = .empty;
    for (frontier.items) |id| {
        if (store.findIndex(id)) |i| {
            try rows.append(gpa, .{ .record = store.records.items[i], .score = scoredGet(scores.items, id) });
        }
    }
    return rows.items;
}

/// `MATCH ... COUNT` — walk instances (parallel edges each count);
/// saturating u64 accumulation, missing start = 0, dangling skipped.
fn runMatchCount(store: *EngineStore, path: ir.MatchPath) u64 {
    if (store.findIndex(path.start) == null) return 0;
    var frontier_list: std.ArrayList(Walk) = .empty;
    frontier_list.append(store.gpa, .{ .id = path.start, .walks = 1 }) catch return 0;
    for (path.steps) |step| {
        var next: std.ArrayList(Walk) = .empty;
        for (store.edges.items) |edge| {
            const from_side: ir.RecordId = switch (step.direction) {
                .out => edge.from,
                .in => edge.to,
            };
            const to_side: ir.RecordId = switch (step.direction) {
                .out => edge.to,
                .in => edge.from,
            };
            if (!edgeNameMatches(edge.name, step.name)) continue;
            const walks = walkGet(frontier_list.items, from_side) orelse continue;
            if (!matchesEdgeProps(edge, step.edge_props)) continue;
            if (store.findIndex(to_side) == null) continue;
            // Accumulate walks(to) += walks(from), linear (BTree in Rust).
            var acc: ?usize = null;
            for (next.items, 0..) |w, idx| {
                if (ir.recordIdEql(w.id, to_side)) {
                    acc = idx;
                    break;
                }
            }
            if (acc) |idx| {
                next.items[idx].walks = saturatingAdd(next.items[idx].walks, walks);
            } else {
                next.append(store.gpa, .{ .id = to_side, .walks = walks }) catch return 0;
            }
        }
        if (next.items.len == 0) return 0;
        frontier_list = next;
    }
    var total: u64 = 0;
    for (frontier_list.items) |w| total = saturatingAdd(total, w.walks);
    return total;
}

/// `CLOSURE` — BFS to fixpoint per step; every reached record once, in
/// first-visit order, scored by BFS depth (start = 0.0).
fn runClosure(store: *EngineStore, gpa: std.mem.Allocator, path: ir.MatchPath) EngineError![]Row {
    if (store.findIndex(path.start) == null) return try gpa.alloc(Row, 0);
    var visited: std.ArrayList(ir.RecordId) = .empty;
    try visited.append(gpa, path.start);
    var depths: std.ArrayList(Scored) = .empty;
    try depths.append(gpa, .{ .id = path.start, .s = 0.0 });
    var frontier: std.ArrayList(ir.RecordId) = .empty;
    try frontier.append(gpa, path.start);
    var next_depth: u32 = 1;

    for (path.steps) |step| {
        while (true) {
            var newly: std.ArrayList(ir.RecordId) = .empty;
            for (frontier.items) |from| {
                for (store.edges.items) |edge| {
                    const from_side: ir.RecordId = switch (step.direction) {
                        .out => edge.from,
                        .in => edge.to,
                    };
                    const to_side: ir.RecordId = switch (step.direction) {
                        .out => edge.to,
                        .in => edge.from,
                    };
                    if (!ir.recordIdEql(from_side, from)) continue;
                    if (!edgeNameMatches(edge.name, step.name)) continue;
                    if (!matchesEdgeProps(edge, step.edge_props)) continue;
                    if (store.findIndex(to_side) == null) continue;
                    if (containsRid(visited.items, to_side)) continue;
                    try visited.append(gpa, to_side);
                    try newly.append(gpa, to_side);
                    try depths.append(gpa, .{ .id = to_side, .s = @floatFromInt(next_depth) });
                }
            }
            if (newly.items.len == 0) break; // fixpoint
            frontier = newly;
            next_depth += 1;
        }
        // Next step continues from everything visited so far (minus start).
        frontier = .empty;
        for (visited.items[1..]) |id| try frontier.append(gpa, id);
    }

    var rows: std.ArrayList(Row) = .empty;
    for (visited.items) |id| {
        if (store.findIndex(id)) |i| {
            try rows.append(gpa, .{ .record = store.records.items[i], .score = scoredGet(depths.items, id) });
        }
    }
    return rows.items;
}

// ---------------------------------------------------------------------------
// Filters
// ---------------------------------------------------------------------------

fn matchesFilter(rec: ir.Record, filter: ?ir.Filter) bool {
    const f = filter orelse return true;
    switch (f) {
        .has_embedding => return rec.embedding != null,
        .bm25 => return true, // scoring filter: never prunes
        .and_filter => |terms| {
            for (terms) |t| {
                if (!matchesFilter(rec, t)) return false;
            }
            return true;
        },
        .field_equals, .field_cmp, .field_in, .field_between => {
            // `id` pseudo-field binds to record identity, not a body key.
            if (predicateField(f)) |pf| {
                if (std.mem.eql(u8, pf, "id")) return recordIdMatches(rec, f);
            }
            return matchesFieldPred(rec.body, f);
        },
    }
}

fn predicateField(f: ir.Filter) ?[]const u8 {
    switch (f) {
        .field_equals => |x| return x.field,
        .field_cmp => |x| return x.field,
        .field_in => |x| return x.field,
        .field_between => |x| return x.field,
        else => return null,
    }
}

fn recordIdMatches(rec: ir.Record, f: ir.Filter) bool {
    const me = ir.recordIdDisplay(std.heap.page_allocator, rec.id) catch unreachable;
    defer std.heap.page_allocator.free(me);
    const isMe = struct {
        fn call(v: ir.Value, s: []const u8) bool {
            return switch (v) {
                .str => |x| std.mem.eql(u8, x, s),
                else => false,
            };
        }
    }.call;
    switch (f) {
        .field_equals => |x| return isMe(x.value, me),
        .field_cmp => |x| {
            if (x.op == .ne) return !isMe(x.value, me);
            return false; // ordered forms are parse-rejected for `id`
        },
        .field_in => |x| {
            for (x.values) |v| {
                if (isMe(v, me)) return true;
            }
            return false;
        },
        else => return false,
    }
}

fn matchesFieldPred(props: []const ir.DocEntry, f: ir.Filter) bool {
    switch (f) {
        .field_equals => |x| {
            const lhs = bodyGet(props, x.field) orelse return false;
            return valueEql(lhs, x.value);
        },
        .field_cmp => |x| {
            const lhs = bodyGet(props, x.field) orelse return false;
            const c = cmpTotal(lhs, x.value);
            return switch (x.op) {
                .ne => c != .eq,
                .lt => c == .lt,
                .le => c != .gt,
                .gt => c == .gt,
                .ge => c != .lt,
            };
        },
        .field_in => |x| {
            const lhs = bodyGet(props, x.field) orelse return false;
            for (x.values) |v| {
                if (valueEql(lhs, v)) return true;
            }
            return false;
        },
        .field_between => |x| {
            const lhs = bodyGet(props, x.field) orelse return false;
            return cmpTotal(lhs, x.lo) != .lt and cmpTotal(lhs, x.hi) != .gt;
        },
        .has_embedding, .bm25 => return true,
        .and_filter => |terms| {
            for (terms) |t| {
                if (!matchesFieldPred(props, t)) return false;
            }
            return true;
        },
    }
}

// ---------------------------------------------------------------------------
// Ordering + scoring
// ---------------------------------------------------------------------------

/// Order rows, keeping only the paging window when a bounded top-k
/// selection beats a full sort (window ≤ n/8). Returns the (possibly
/// shortened) slice — byte-identical: the window is the prefix of the
/// full sort under the same TOTAL-order comparator.
fn orderRows(rows: []Row, sel: ir.Select) EngineError![]Row {
    // Window = offset + limit (kNN/BM25 k / LIMIT); no cap → sort all.
    const window: ?usize = if (effectiveLimit(sel)) |c|
        (sel.offset orelse 0) + c
    else
        null;
    // ORDER BY <field> [DESC] — structural sort, id tie both ways.
    if (sel.order) |ord| {
        switch (ord) {
            .field => |f| {
                return orderWindowed(rows, window, f, struct {
                    fn less(c: @TypeOf(f), a: Row, b: Row) bool {
                        const ka = bodyGet(a.record.body, c.key) orelse .null;
                        const kb = bodyGet(b.record.body, c.key) orelse .null;
                        var o = cmpTotal(ka, kb);
                        if (c.desc) o = reverseOrder(o);
                        if (o != .eq) return o == .lt;
                        return ir.RecordId.less(a.record.id, b.record.id);
                    }
                }.less);
            },
            .recency => {
                return orderWindowed(rows, window, {}, struct {
                    fn less(_: void, a: Row, b: Row) bool {
                        const c = std.math.order(b.record.created_at, a.record.created_at);
                        if (c != .eq) return c == .lt;
                        return ir.RecordId.less(a.record.id, b.record.id);
                    }
                }.less);
            },
            else => {},
        }
    }
    // Score-based: explicit order, or implicit via kNN / BM25.
    var bm25_filter = false;
    if (sel.filter) |f| bm25_filter = f == .bm25;
    const score_based = sel.order != null or sel.knn != null or bm25_filter;
    if (score_based) {
        return orderWindowed(rows, window, {}, struct {
            fn less(_: void, a: Row, b: Row) bool {
                if (a.score > b.score) return true;
                if (a.score < b.score) return false;
                // Equal or NaN → id ascending (Rust partial_cmp semantics).
                return ir.RecordId.less(a.record.id, b.record.id);
            }
        }.less);
    }
    // else: BTree key order already (candidates came canonical).
    return rows;
}

/// Full sort, or bounded top-k selection when the window is small
/// relative to n (heap select O(n log w) + sort of w beats O(n log n)).
fn orderWindowed(
    rows: []Row,
    window: ?usize,
    ctx: anytype,
    lessFn: fn (@TypeOf(ctx), Row, Row) bool,
) []Row {
    if (window) |w| {
        if (w < rows.len and w > 0 and w * 8 <= rows.len) {
            topSelect(Row, rows, w, ctx, lessFn);
            return rows[0..w];
        }
    }
    std.mem.sortUnstable(Row, rows, ctx, lessFn);
    return rows;
}

/// Keep the `w` best elements under `lessFn` (a TOTAL order): bounded
/// max-heap (root = worst kept), scan, then sort just the window.
fn topSelect(comptime T: type, items: []T, w: usize, ctx: anytype, lessFn: fn (@TypeOf(ctx), T, T) bool) void {
    const heap = items[0..w];
    var i: usize = heap.len / 2;
    while (i > 0) {
        i -= 1;
        siftDown(T, heap, i, ctx, lessFn);
    }
    for (items[w..]) |x| {
        if (lessFn(ctx, x, heap[0])) {
            heap[0] = x;
            siftDown(T, heap, 0, ctx, lessFn);
        }
    }
    std.mem.sortUnstable(T, heap, ctx, lessFn);
}

fn siftDown(comptime T: type, heap: []T, start: usize, ctx: anytype, lessFn: fn (@TypeOf(ctx), T, T) bool) void {
    var i = start;
    while (true) {
        const l = 2 * i + 1;
        const r = l + 1;
        var worst = i;
        if (l < heap.len and lessFn(ctx, heap[worst], heap[l])) worst = l;
        if (r < heap.len and lessFn(ctx, heap[worst], heap[r])) worst = r;
        if (worst == i) return;
        const tmp = heap[i];
        heap[i] = heap[worst];
        heap[worst] = tmp;
        i = worst;
    }
}

fn reverseOrder(o: std.math.Order) std.math.Order {
    return switch (o) {
        .lt => .gt,
        .eq => .eq,
        .gt => .lt,
    };
}

fn insertionSort(comptime T: type, items: []T, ctx: anytype, lessFn: fn (@TypeOf(ctx), T, T) bool) void {
    // PDQ via std (O(n log n); the old insertion sort was O(n²) and
    // dominated large ORDER BY / kNN sorts). Every comparator here ends
    // in a unique-key tie-break (RecordId), i.e. a TOTAL order — so the
    // sorted result is byte-identical to insertion sort. ADR-001: the
    // comparator defines determinism, not the algorithm.
    std.mem.sortUnstable(T, items, ctx, lessFn);
}

fn clamp01(x: f32) f32 {
    if (x < 0.0) return 0.0;
    if (x > 1.0) return 1.0;
    return x;
}

fn computeScore(
    store: *EngineStore,
    sel: ir.Select,
    rec: ir.Record,
    knn_sim: ?f32, // candidate-aligned kNN cosine (null = no kNN / unembedded)
    fused: ?f32, // candidate-aligned RRF fusion (null = not hybrid)
    bm25_index: *const ?bm25mod.Bm25Index,
    bm25_tokens: []const []const u8,
) f32 {
    // Hybrid fusion dominates every score source.
    if (fused) |f| return f;
    // BM25 filter dominates ORDER BY / kNN.
    if (sel.filter) |f| {
        switch (f) {
            .bm25 => {
                if (bm25_index.*) |idx| return idx.score(rec.id, bm25_tokens);
            },
            else => {},
        }
    }
    const similarity: f32 = knn_sim orelse 0.0;
    const ord = sel.order orelse return similarity;
    switch (ord) {
        .score => return scoreOf(store, rec),
        .votes => return @floatFromInt(voteCounts(store, rec.id).net),
        .feedback => return feedbackScore(store, rec.id),
        .salience => {
            if (sel.knn != null) return 0.7 * similarity + 0.3 * clamp01(scoreOf(store, rec));
            return clamp01(scoreOf(store, rec));
        },
        .salience_weighted => |w| {
            const alpha = w[0];
            const beta = w[1];
            const gamma = w[2];
            const delta = w[3];
            return alpha * similarity +
                beta * strengthOf(store, rec) +
                gamma * importanceOf(rec) +
                delta * clamp01(scoreOf(store, rec));
        },
        else => return similarity,
    }
}

/// Tolerant edge-name match (leading `:` on either side, issue #98).
fn edgeNameMatches(stored: []const u8, want: []const u8) bool {
    const st = trimColons(stored);
    const w = trimColons(want);
    return std.mem.eql(u8, st, w);
}

fn trimColons(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and s[i] == ':') i += 1;
    return s[i..];
}

const VoteCounts = struct { up: u64, down: u64, net: i64 };

fn voteWeight(e: ir.RelationEdge) f32 {
    if (e.weight) |w| return w;
    const v = bodyGet(e.props, "value") orelse return 1.0;
    return switch (v) {
        .int => |n| @floatFromInt(n),
        .float => |f| @floatCast(f),
        else => 1.0,
    };
}

fn voteValue(props: []const ir.DocEntry) i8 {
    const v = bodyGet(props, "value") orelse return 0;
    return switch (v) {
        .int => |n| if (n == 1) 1 else if (n == -1) -1 else 0,
        .float => |f| if (f == 1.0) 1 else if (f == -1.0) -1 else 0,
        else => 0,
    };
}

fn voteCounts(store: *EngineStore, id: ir.RecordId) VoteCounts {
    var up: u64 = 0;
    var down: u64 = 0;
    for (store.edges.items) |e| {
        if (!edgeNameMatches(e.name, "voted")) continue;
        if (!ir.recordIdEql(e.to, id)) continue;
        switch (voteValue(e.props)) {
            1 => up += 1,
            -1 => down += 1,
            else => {},
        }
    }
    return .{ .up = up, .down = down, .net = @as(i64, @intCast(up)) - @as(i64, @intCast(down)) };
}

/// Laplace-smoothed mean of `:voted` weights: (sum + 1) / (n + 2).
fn scoreOf(store: *EngineStore, rec: ir.Record) f32 {
    var sum: f32 = 0.0;
    var n: f32 = 0.0;
    for (store.edges.items) |e| {
        if (edgeNameMatches(e.name, "voted") and ir.recordIdEql(e.to, rec.id)) {
            sum += voteWeight(e);
            n += 1.0;
        }
    }
    return (sum + 1.0) / (n + 2.0);
}

/// β term: strength(recency, freq) in [0, 1].
fn strengthOf(store: *EngineStore, rec: ir.Record) f32 {
    const age_raw = store.clock - rec.created_at;
    const age: f32 = @floatFromInt(if (age_raw > 0) age_raw else 0);
    const recency: f32 = 1.0 / (1.0 + age);
    var inc: f32 = 0.0;
    for (store.edges.items) |e| {
        if (ir.recordIdEql(e.from, rec.id) or ir.recordIdEql(e.to, rec.id)) inc += 1.0;
    }
    return 0.5 * recency + 0.5 * (inc / (inc + 1.0));
}

/// γ term: the agent-written `importance` field clamped to [0, 1].
fn importanceOf(rec: ir.Record) f32 {
    const v = bodyGet(rec.body, "importance") orelse return 0.0;
    const f: f32 = switch (v) {
        .float => |x| @floatCast(x),
        .int => |x| @floatFromInt(x),
        else => return 0.0,
    };
    return clamp01(f);
}

/// Time-decayed feedback over `:voted` edges; `now` = max voted created_at.
fn feedbackScore(store: *EngineStore, id: ir.RecordId) f32 {
    const lambda: f32 = 1.0;
    var now: ?i64 = null;
    for (store.edges.items) |e| {
        if (edgeNameMatches(e.name, "voted")) {
            now = if (now) |n| @max(n, e.created_at) else e.created_at;
        }
    }
    const now_v = now orelse return 0.0;
    var total: f32 = 0.0;
    for (store.edges.items) |e| {
        if (!edgeNameMatches(e.name, "voted")) continue;
        if (!ir.recordIdEql(e.to, id)) continue;
        const sign: f32 = @floatFromInt(voteValue(e.props));
        const age_raw = now_v - e.created_at;
        const age: f32 = @floatFromInt(if (age_raw > 0) age_raw else 0);
        total += sign * (1.0 / (1.0 + lambda * age));
    }
    return total;
}

test "cosine reference vectors" {
    try std.testing.expectEqual(@as(f32, 1.0), cosineSimilarity(&[_]f32{ 1.0, 0.0 }, &[_]f32{ 1.0, 0.0 }));
    try std.testing.expectEqual(@as(f32, 0.0), cosineSimilarity(&[_]f32{ 0.0, 0.0 }, &[_]f32{ 1.0, 0.0 }));
}

test "cmp_total ranks types" {
    const std2 = @import("std");
    _ = std2;
    try std.testing.expect(cmpTotal(.null, .{ .bool = false }) == .lt);
    try std.testing.expect(cmpTotal(.{ .int = 1 }, .{ .float = 1.0 }) == .eq);
    try std.testing.expect(cmpTotal(.{ .float = 2.5 }, .{ .int = 2 }) == .gt);
    try std.testing.expect(cmpTotal(.{ .str = "a" }, .{ .int = 999 }) == .gt);
}
