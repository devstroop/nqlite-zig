//! IR types mirroring `nql_ir` (the Rust contract, spec/file-format.md §5.7).
//!
//! Two store flavours, because serde's context differs (this is the wire
//! truth, not an accident):
//! - [`Store`] — a §5 layout store (MEMORIES blobs): carries `tables`
//!   (written as its own TABLES section).
//! - [`SnapStore`] — a store embedded in `Statement::Snapshot` history
//!   entries: `Store.tables` is `#[serde(skip)]` in Rust, so postcard drops
//!   it — statements carry records/edges/vector_dims/clock/history/memories
//!   only, and replay rebuilds `tables` from the inner history (#133).
//!
//! All byte slices borrow the input buffer (zero-copy decode); allocations
//! come from the caller's arena. No ordered maps: canonical order is file
//! order, validated on decode (ADR-001 determinism-by-hand).

pub const Id = union(enum) {
    num: u64,
    str: []const u8,

    pub fn less(a: Id, b: Id) bool {
        // Canonical rank: Num < Str (derived enum order), then value/bytes.
        const ra: u8 = if (a == .num) 0 else 1;
        const rb: u8 = if (b == .num) 0 else 1;
        if (ra != rb) return ra < rb;
        return switch (a) {
            .num => |x| switch (b) {
                .num => |y| x < y,
                .str => true,
            },
            .str => |x| switch (b) {
                .num => false,
                .str => |y| std.mem.lessThan(u8, x, y),
            },
        };
    }
};

/// `table:id` (SurrealDB-style). Canonical order: table bytes, then `Id`.
pub const RecordId = struct {
    table: []const u8,
    id: Id,

    pub fn less(a: RecordId, b: RecordId) bool {
        const ct = std.mem.order(u8, a.table, b.table);
        if (ct != .eq) return ct == .lt;
        return Id.less(a.id, b.id);
    }
};

pub const DocEntry = struct {
    key: []const u8,
    value: Value,
};

/// `nql_ir::Value` — tags 0..=8, declaration order (append-only).
pub const Value = union(enum) {
    null,
    bool: bool,
    int: i64,
    float: f64,
    str: []const u8,
    doc: []const DocEntry,
    arr: []const Value,
    vector: []const f32,
    ref: RecordId,
};

/// `nql_ir::Record` — field order = serde declaration order.
pub const Record = struct {
    id: RecordId,
    body: []const DocEntry,
    embedding: ?[]const f32,
    created_at: i64,
};

/// `nql_ir::RelationEdge`.
pub const RelationEdge = struct {
    from: RecordId,
    name: []const u8,
    to: RecordId,
    created_at: i64,
    weight: ?f32,
    props: []const DocEntry,
};

pub const CmpOp = enum(u8) { ne, lt, le, gt, ge }; // tags 0..=4

pub const Order = union(enum) {
    similarity, // 0
    salience, // 1
    score, // 2
    votes, // 3
    feedback, // 4
    recency, // 5
    salience_weighted: [4]f32, // 6
    field: struct { key: []const u8, desc: bool }, // 7
};

pub const Aggregate = enum(u8) { count_star }; // tag 0

pub const Filter = union(enum) {
    field_equals: struct { field: []const u8, value: Value }, // 0
    has_embedding, // 1
    bm25: struct { field: []const u8, query: []const u8, k: ?usize }, // 2
    field_cmp: struct { field: []const u8, op: CmpOp, value: Value }, // 3
    field_in: struct { field: []const u8, values: []const Value }, // 4
    field_between: struct { field: []const u8, lo: Value, hi: Value }, // 5
    and_filter: []const Filter, // 6 (wire tag 6 — `And`)
};

pub const Knn = struct {
    query: []const f32,
    k: usize,
};

pub const Select = struct {
    table: []const u8,
    knn: ?Knn,
    filter: ?Filter,
    order: ?Order,
    limit: ?usize,
    as_of: ?i64,
    fields: ?[]const []const u8,
    offset: ?usize,
    aggregate: ?Aggregate,
};

pub const MatchDirection = enum(u8) { out, in }; // tags 0, 1

pub const MatchStep = struct {
    direction: MatchDirection,
    name: []const u8,
    edge_props: ?Filter,
};

pub const MatchPath = struct {
    start: RecordId,
    steps: []const MatchStep,
    as_of: ?i64,
};

/// `nql_ir::SnapshotState` (field order = declaration order).
pub const SnapshotState = struct {
    records: []const Record, // encoded as a map: RecordId key + Record value
    edges: []const RelationEdge,
    vector_dims: []const DimEntry,
    clock: i64,
    memories: []const SnapMemory,
    tables: []const TableEntry,
};

/// `BTreeMap<String, Option<usize>>` entry (`Store.tables` in snapshots).
pub const TableEntry = struct {
    name: []const u8,
    vector_dim: ?usize,
};

/// `BTreeMap<String, usize>` entry (`Store.vector_dims`).
pub const DimEntry = struct {
    name: []const u8,
    dim: usize,
};

/// Statement-embedded store (`Store.tables` is serde(skip)'ed there).
pub const SnapStore = struct {
    records: []const Record,
    edges: []const RelationEdge,
    vector_dims: []const DimEntry,
    clock: i64,
    history: []const HistoryEntry,
    memories: []const SnapMemory,
};

pub const SnapMemory = struct {
    name: []const u8,
    store: SnapStore,
};

/// A history entry: `(i64, Statement)` (§5.6).
pub const HistoryEntry = struct {
    ts: i64,
    stmt: Statement,
};

/// `nql_ir::Statement` — tags 0..=12, declaration order (append-only;
/// unknown tags must fail decode loudly, exactly as postcard does today).
pub const Statement = union(enum) {
    create_table: struct { table: []const u8, vector_dim: ?usize }, // 0
    insert: Record, // 1
    relate: RelationEdge, // 2
    select: Select, // 3
    match_path: MatchPath, // 4
    closure: MatchPath, // 5
    forget: struct { id: RecordId }, // 6
    memory: struct { name: []const u8 }, // 7
    context_reset, // 8
    match_count: MatchPath, // 9
    prune_history, // 10
    snapshot: SnapshotState, // 11
    history_since: i64, // 12
};

/// A §5 layout store (MEMORIES blobs): `tables` written as TABLES.
pub const Store = struct {
    tables: []const TableEntry,
    records: []const Record,
    edges: []const RelationEdge,
    clock: i64,
    history: []const HistoryEntry,
    memories: []const Memory,
};

pub const Memory = struct {
    name: []const u8,
    store: Store,
};

const std = @import("std");

/// Structural RecordId equality (table bytes + Id variant/value).
pub fn recordIdEql(a: RecordId, b: RecordId) bool {
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

/// Display form `table:id` (the `id` pseudo-field binds to this).
pub fn recordIdDisplay(gpa: std.mem.Allocator, rid: RecordId) ![]const u8 {
    return switch (rid.id) {
        .num => |n| std.fmt.allocPrint(gpa, "{s}:{d}", .{ rid.table, n }),
        .str => |s| std.fmt.allocPrint(gpa, "{s}:{s}", .{ rid.table, s }),
    };
}

test "canonical RecordId order" {
    const a = RecordId{ .table = "a", .id = .{ .num = 5 } };
    const b = RecordId{ .table = "a", .id = .{ .str = "007" } };
    const c = RecordId{ .table = "a", .id = .{ .str = "10" } };
    const d = RecordId{ .table = "a", .id = .{ .str = "2" } };
    const e = RecordId{ .table = "a", .id = .{ .num = 1 } };
    // Num < Str regardless of value; string ids compare as BYTES
    // (`007` < `10` < `2` — never numeric).
    try std.testing.expect(RecordId.less(e, a));
    try std.testing.expect(RecordId.less(a, b));
    try std.testing.expect(RecordId.less(b, c));
    try std.testing.expect(RecordId.less(c, d));
    // table bytes first
    const z = RecordId{ .table = "b", .id = .{ .num = 0 } };
    try std.testing.expect(RecordId.less(d, z));
}
