//! Analyzer — plan validation + SELECT enrichment (spec/nql.md, M2) —
//! port of `nql/src/analyzer.rs`.
//!
//! Takes the plan the parser produced and either rejects it (structured
//! variant names — the corpus pins them; the Rust analyzer carries no
//! positions) or returns an enriched copy: a kNN SELECT with no `ORDER BY`
//! gains `Order.similarity`. Deterministic and pure; the input plan is
//! never mutated.

const std = @import("std");
const ir = @import("ir.zig");

/// Built-in table names that exist without an explicit `CREATE TABLE`.
pub const BUILTIN_TABLES = [_][]const u8{ "global", "meta" };

/// Analysis failure — variant names mirror `nql_ir`'s `AnalysisError`
/// discriminants (gated by the M2 corpus) and `message` is the Rust
/// `Display` text, byte-exact for the server's `ERR` lines.
pub const AnalysisFail = struct {
    variant: []const u8,
    message: []const u8,
};

pub const Outcome = union(enum) {
    ok: []const ir.Statement,
    err: AnalysisFail,
};

const Step = union(enum) {
    stmt: ir.Statement,
    fail: AnalysisFail,
};

const Ctx = struct {
    gpa: std.mem.Allocator,
    declared: std.ArrayList([]const u8) = .empty,
    vector_dims: std.ArrayList(struct { name: []const u8, dim: usize }) = .empty,

    fn isDeclared(self: *const Ctx, table: []const u8) bool {
        for (self.declared.items) |d| {
            if (std.mem.eql(u8, d, table)) return true;
        }
        return false;
    }

    fn dimOf(self: *const Ctx, table: []const u8) ?usize {
        for (self.vector_dims.items) |d| {
            if (std.mem.eql(u8, d.name, table)) return d.dim;
        }
        return null;
    }

    /// Validate a `table:id` pair: non-empty table, non-empty string id.
    fn validateRecordId(gpa: std.mem.Allocator, rid: ir.RecordId) ?AnalysisFail {
        if (rid.table.len == 0)
            return .{ .variant = "EmptyTable", .message = "record id table must not be empty" };
        switch (rid.id) {
            .str => |s| {
                if (s.len == 0) {
                    const m = std.fmt.allocPrint(
                        gpa,
                        "record id in table `{s}` has an empty id string",
                        .{rid.table},
                    ) catch "record id has an empty id string";
                    return .{ .variant = "EmptyId", .message = m };
                }
            },
            else => {},
        }
        return null;
    }

    /// Analyze one statement (declaration context accumulates).
    fn analyzeStatement(self: *Ctx, stmt: ir.Statement) error{OutOfMemory}!Step {
        switch (stmt) {
            .create_table => |c| {
                var replaced = false;
                for (self.declared.items) |*d| {
                    if (std.mem.eql(u8, d.*, c.table)) {
                        d.* = c.table;
                        replaced = true;
                        break;
                    }
                }
                if (!replaced) try self.declared.append(self.gpa, c.table);
                if (c.vector_dim) |dim| {
                    var replaced_dim = false;
                    for (self.vector_dims.items) |*d| {
                        if (std.mem.eql(u8, d.name, c.table)) {
                            d.* = .{ .name = c.table, .dim = dim };
                            replaced_dim = true;
                            break;
                        }
                    }
                    if (!replaced_dim)
                        try self.vector_dims.append(self.gpa, .{ .name = c.table, .dim = dim });
                }
                return .{ .stmt = stmt };
            },
            .insert => |rec| {
                if (validateRecordId(self.gpa, rec.id)) |f| return .{ .fail = f };
                if (!self.isDeclared(rec.id.table)) {
                    const m = std.fmt.allocPrint(
                        self.gpa,
                        "INSERT into table `{s}` requires a prior CREATE TABLE statement or a built-in table",
                        .{rec.id.table},
                    ) catch "INSERT into undeclared table";
                    return .{ .fail = .{ .variant = "UnknownTableForInsert", .message = m } };
                }
                if (self.dimOf(rec.id.table)) |expected| {
                    if (rec.embedding) |emb| {
                        if (emb.len != expected) {
                            const m = std.fmt.allocPrint(
                                self.gpa,
                                "INSERT into `{s}` has embedding of dimension {d}, but the table declares VECTOR<f32, {d}>",
                                .{ rec.id.table, emb.len, expected },
                            ) catch "embedding dimension mismatch";
                            return .{ .fail = .{ .variant = "EmbeddingDimMismatch", .message = m } };
                        }
                    }
                }
                return .{ .stmt = stmt };
            },
            .relate => |e| {
                if (validateRecordId(self.gpa, e.from)) |f| return .{ .fail = f };
                if (validateRecordId(self.gpa, e.to)) |f| return .{ .fail = f };
                return .{ .stmt = stmt };
            },
            .match_path => |p| {
                if (validateRecordId(self.gpa, p.start)) |f| return .{ .fail = f };
                return .{ .stmt = stmt };
            },
            .match_count => |p| {
                if (validateRecordId(self.gpa, p.start)) |f| return .{ .fail = f };
                return .{ .stmt = stmt };
            },
            .closure => |p| {
                if (validateRecordId(self.gpa, p.start)) |f| return .{ .fail = f };
                return .{ .stmt = stmt };
            },
            .select => |sel| {
                if (!self.isDeclared(sel.table)) {
                    const m = std.fmt.allocPrint(
                        self.gpa,
                        "SELECT on table `{s}` requires a prior CREATE TABLE statement or a built-in table",
                        .{sel.table},
                    ) catch "SELECT on undeclared table";
                    return .{ .fail = .{ .variant = "UnknownTableForSelect", .message = m } };
                }
                // Enrich: kNN without ORDER BY gains similarity; explicit
                // similarity without a kNN vector is an error.
                var out = sel;
                const has_knn = sel.knn != null;
                const order_is_similarity = if (sel.order) |o| o == .similarity else false;
                if (has_knn and out.order == null) out.order = .similarity;
                if (order_is_similarity and !has_knn)
                    return .{ .fail = .{
                        .variant = "SimilarityWithoutKnn",
                        .message = "ORDER BY similarity requires a kNN query vector (WHERE vector::similarity(...))",
                    } };
                return .{ .stmt = .{ .select = out } };
            },
            .forget => |f| {
                if (validateRecordId(self.gpa, f.id)) |e| return .{ .fail = e };
                return .{ .stmt = stmt };
            },
            // Pass-throughs: MEMORY, ContextReset (parser can't produce it),
            // PRUNE, Snapshot (replay-only), HistorySince.
            .memory, .context_reset, .prune_history, .snapshot, .history_since => return .{ .stmt = stmt },
        }
    }
};

/// Analyze a whole plan, statement by statement (earlier statements
/// declare tables for later ones). `err` = analysis failure.
pub fn analyze(gpa: std.mem.Allocator, plan: []const ir.Statement) error{OutOfMemory}!Outcome {
    var ctx = Ctx{ .gpa = gpa };
    for (BUILTIN_TABLES) |b| try ctx.declared.append(gpa, b);
    const out = try gpa.alloc(ir.Statement, plan.len);
    for (plan, 0..) |stmt, i| {
        switch (try ctx.analyzeStatement(stmt)) {
            .stmt => |s| out[i] = s,
            .fail => |f| return .{ .err = f },
        }
    }
    return .{ .ok = out };
}

test "analyzer enriches kNN select" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const plan = [_]ir.Statement{
        .{ .create_table = .{ .table = "t", .vector_dim = null } },
        .{ .select = .{
            .table = "t",
            .knn = .{ .query = &[_]f32{ 0.1, 0.2 }, .k = 3 },
            .filter = null,
            .order = null,
            .limit = null,
            .as_of = null,
            .fields = null,
            .offset = null,
            .aggregate = null,
        } },
    };
    const res = try analyze(gpa, &plan);
    try std.testing.expect(res == .ok);
    const sel = res.ok[1].select;
    try std.testing.expect(sel.order != null);
    try std.testing.expect(sel.order.? == .similarity);
}

test "analyzer rejects undeclared insert" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const plan = [_]ir.Statement{
        .{ .insert = .{
            .id = .{ .table = "t", .id = .{ .num = 1 } },
            .body = &[_]ir.DocEntry{},
            .embedding = null,
            .created_at = 0,
        } },
    };
    const res = try analyze(gpa, &plan);
    try std.testing.expect(res == .err);
    try std.testing.expectEqualStrings("UnknownTableForInsert", res.err.variant);
}
