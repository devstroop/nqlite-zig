//! Line-protocol server — port of `nql-server/src/lib.rs`.
//!
//! One nql program per line (`;`-separated); one response: one line per read
//! result followed by `OK`, or a single `ERR <message>` line. The server
//! holds one shared engine store across lines and prepends synthetic
//! `CREATE TABLE`s for previously declared tables before per-line analysis
//! (the analyzer's context is per-plan), executing only the original
//! statements. All `ERR` texts mirror the Rust `Display` impls byte-exact.

const std = @import("std");
const ir = @import("ir.zig");
const parser = @import("parser.zig");
const analyzer = @import("analyzer.zig");
const engine = @import("engine.zig");
const storage = @import("storage.zig");
const v4 = @import("v4.zig");

pub const Server = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    store: engine.EngineStore,
    /// Tables declared so far — byte-sorted (the reference's BTree map).
    declared: std.ArrayList(ir.TableEntry) = .empty,
    /// Present in `--db` mode: WAL + checkpoints + the single-writer lock.
    file: ?storage.StoreFile = null,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Server {
        return .{ .gpa = gpa, .io = io, .store = engine.EngineStore.init(gpa) };
    }

    /// Open a persistent session (`--db <path>`): lock, load the v4 main
    /// file (if any), replay the WAL, and re-seed the analyzer's cross-line
    /// table context from the store's catalogs (root + memories — the
    /// reference's `seed_declared`, issue #89).
    pub fn open(gpa: std.mem.Allocator, io: std.Io, path: []const u8) storage.Error!Server {
        const sf = try storage.StoreFile.open(path, gpa, io);
        var self = Server.init(gpa, io);
        self.file = sf;
        if (try self.file.?.loadMain()) |ir_store| {
            self.store = engine.fromIr(gpa, ir_store) catch return error.OutOfMemory;
        }
        try self.file.?.replayWal(&self.store);
        seedDeclared(&self);
        return self;
    }

    /// Handle one protocol line; never panics on bad input.
    pub fn handleLine(self: *Server, line: []const u8) []const u8 {
        self.store.err = null;
        const gpa = self.gpa;
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) return "OK";

        // Arena-dupe the line: parser tokens borrow the source, and the
        // caller's read buffer is REUSED for the next line — without this,
        // stored names (records, `declared`) silently rot on every refill
        // (caught by the harness: cross-line CREATE/INSERT broke).
        const src = gpa.dupe(u8, trimmed) catch return "ERR out of memory";

        const outcome = parser.parse(gpa, src) catch return "ERR out of memory";
        if (outcome == .err) {
            const f = outcome.err;
            const prefix: []const u8 = switch (f.kind) {
                .lex => "lex",
                .parse => "parse",
            };
            return std.fmt.allocPrint(
                gpa,
                "ERR {s} error at {d}:{d}: {s}",
                .{ prefix, f.line, f.col, f.message },
            ) catch "ERR out of memory";
        }
        const plan = outcome.ok;

        // Cross-line table context (analyzer is per-plan): prepend synthetic
        // CREATE TABLEs for tables this line does not re-declare.
        var augmented: std.ArrayList(ir.Statement) = .empty;
        for (self.declared.items) |t| {
            if (!planHasCreate(plan, t.name)) {
                augmented.append(gpa, .{ .create_table = .{ .table = t.name, .vector_dim = t.vector_dim } }) catch
                    return "ERR out of memory";
            }
        }
        augmented.appendSlice(gpa, plan) catch return "ERR out of memory";
        const prefix_len = augmented.items.len - plan.len;

        const analyzed = analyzer.analyze(gpa, augmented.items) catch return "ERR out of memory";
        if (analyzed == .err) {
            return std.fmt.allocPrint(gpa, "ERR {s}", .{analyzed.err.message}) catch "ERR out of memory";
        }

        // Execute only the original statements (skip the synthetic prefix).
        const results = engine.executePlan(&self.store, analyzed.ok[prefix_len..]) catch |e| {
            if (self.store.err) |d| {
                return std.fmt.allocPrint(gpa, "ERR {s}", .{d.message}) catch "ERR out of memory";
            }
            return std.fmt.allocPrint(gpa, "ERR {s}", .{engine.errorVariant(e)}) catch "ERR out of memory";
        };

        // Record declarations only after success (a failed line never poisons
        // cross-line analysis) — and, in `--db` mode, log the plan to the WAL
        // first (the reference's order: WAL frames, then #109's ContextReset
        // marker, then a threshold checkpoint).
        if (self.file) |*sf| {
            var logged = false;
            for (plan) |stmt| {
                if (engine.isMutating(stmt)) {
                    sf.append(stmt) catch return "ERR wal append failed";
                    logged = true;
                }
            }
            if (logged) {
                sf.append(.{ .context_reset = {} }) catch return "ERR wal append failed";
                if (sf.needsCheckpoint()) {
                    const ir_store = engine.toIr(&self.store, gpa) catch return "ERR checkpoint failed";
                    const bytes = v4.encode(ir_store, gpa) catch return "ERR checkpoint encode failed";
                    sf.checkpoint(bytes) catch return "ERR checkpoint failed";
                }
            }
        }
        for (plan) |stmt| {
            switch (stmt) {
                .create_table => |c| self.upsertDeclared(c.table, c.vector_dim),
                else => {},
            }
        }

        var out: std.ArrayList(u8) = .empty;
        for (results) |res| {
            const l = formatResult(gpa, res) catch return "ERR out of memory";
            out.appendSlice(gpa, l) catch return "ERR out of memory";
            out.append(gpa, '\n') catch return "ERR out of memory";
        }
        out.appendSlice(gpa, "OK") catch return "ERR out of memory";
        return out.toOwnedSlice(gpa) catch return "ERR out of memory";
    }

    fn upsertDeclared(self: *Server, name: []const u8, dim: ?usize) void {
        for (self.declared.items, 0..) |t, i| {
            const c = std.mem.order(u8, name, t.name);
            if (c == .eq) {
                self.declared.items[i].vector_dim = dim;
                return;
            }
            if (c == .lt) {
                self.declared.insert(self.gpa, i, .{ .name = name, .vector_dim = dim }) catch {};
                return;
            }
        }
        self.declared.append(self.gpa, .{ .name = name, .vector_dim = dim }) catch {};
    }
};

fn planHasCreate(plan: []const ir.Statement, table: []const u8) bool {
    for (plan) |s| {
        switch (s) {
            .create_table => |c| {
                if (std.mem.eql(u8, c.table, table)) return true;
            },
            else => {},
        }
    }
    return false;
}

/// Re-seed the analyzer's cross-line context from a loaded store (root
/// catalogs plus every memory block's — issue #89). Names borrow the load
/// arena, which lives as long as the server.
fn seedDeclared(self: *Server) void {
    seedFrom(self, &self.store);
}

fn seedFrom(self: *Server, store: *const engine.EngineStore) void {
    for (store.tables.items) |t| self.upsertDeclared(t.name, t.vector_dim);
    for (store.memories.items) |m| seedFrom(self, &m.store);
}

// ---------------------------------------------------------------------------
// Response formatting (byte-exact with the reference server)
// ---------------------------------------------------------------------------

fn formatResult(gpa: std.mem.Allocator, res: engine.QueryResult) ![]const u8 {
    const label: []const u8 = switch (res.kind) {
        .select => |table| try std.fmt.allocPrint(gpa, "SELECT {s}", .{table}),
        .match_ => |path| try fmtPathLabel(gpa, "MATCH", path),
        .closure => |path| try fmtPathLabel(gpa, "CLOSURE", path),
    };
    if (res.rows.len == 0) {
        return std.fmt.allocPrint(gpa, "{s} (0 rows)", .{label});
    }
    var joined: std.ArrayList(u8) = .empty;
    for (res.rows, 0..) |row, i| {
        if (i > 0) try joined.appendSlice(gpa, "; ");
        try joined.appendSlice(gpa, try formatRow(gpa, row));
    }
    return std.fmt.allocPrint(gpa, "{s} ({d} rows): {s}", .{ label, res.rows.len, joined.items });
}

/// `MATCH <start> ->:name <-:other` — arrows as the reference prints them.
fn fmtPathLabel(gpa: std.mem.Allocator, kw: []const u8, path: ir.MatchPath) ![]const u8 {
    const start = try ir.recordIdDisplay(gpa, path.start);
    var hops: std.ArrayList(u8) = .empty;
    for (path.steps, 0..) |step, i| {
        if (i > 0) try hops.appendSlice(gpa, " ");
        const arrow: []const u8 = switch (step.direction) {
            .out => "->",
            .in => "<-",
        };
        try hops.appendSlice(gpa, try std.fmt.allocPrint(gpa, "{s}:{s}", .{ arrow, step.name }));
    }
    return std.fmt.allocPrint(gpa, "{s} {s} {s}", .{ kw, start, hops.items });
}

/// `<id> score=<f:.4> {fields}` —4dp scores, EXACTLY like Rust's
/// `{:.4}`: round-to-nearest with **half-to-EVEN on exact ties** (0.03125
/// → `0.0312`, while zig's default `{d:.4}` rounds half-away → `0.0313`).
/// The multiplication by 10^4 is exact for f32-sourced values (≤24-bit
/// mantissa × 10^4 fits in 53 bits), so the tie test is sound.
fn formatRow(gpa: std.mem.Allocator, row: engine.Row) ![]const u8 {
    const id = try ir.recordIdDisplay(gpa, row.record.id);
    const fields = try formatFields(gpa, row.record.body);
    const score = try rustFormat4(gpa, row.score);
    return std.fmt.allocPrint(gpa, "{s} score={s} {s}", .{ id, score, fields });
}

/// Rust `{:.4}` for an f32 (widened exactly to f64).
fn rustFormat4(gpa: std.mem.Allocator, x: f32) std.mem.Allocator.Error![]const u8 {
    const xf: f64 = x;
    const bits: u64 = @bitCast(xf);
    const negative = (bits >> 63) != 0; // includes −0.0 → "-0.0000"
    const a = @abs(xf);
    const scaled = a * 10000.0; // exact for f32-sourced values
    const fl = @floor(scaled);
    const frac = scaled - fl;
    var n: u64 = undefined;
    if (frac == 0.5) {
        // Exact tie → half-to-EVEN (Rust's float formatting).
        const base: u64 = @intFromFloat(fl);
        n = if (@mod(fl, 2.0) == 0) base else base + 1;
    } else {
        n = @intFromFloat(@round(scaled));
    }
    const int_part = n / 10000;
    const frac_part = n % 10000;
    const sign: []const u8 = if (negative) "-" else "";
    return std.fmt.allocPrint(gpa, "{s}{d}.{d:0>4}", .{ sign, int_part, frac_part });
}

/// BTree-order field rendering: `{k=v, k=v}` (or `{}` when empty).
/// (Explicit error set: `formatFields` ⇄ `shortValue` recurse.)
fn formatFields(gpa: std.mem.Allocator, body: []const ir.DocEntry) std.mem.Allocator.Error![]const u8 {
    if (body.len == 0) return "{}";
    var inner: std.ArrayList(u8) = .empty;
    for (body, 0..) |e, i| {
        if (i > 0) try inner.appendSlice(gpa, ", ");
        try inner.appendSlice(gpa, e.key);
        try inner.append(gpa, '=');
        try inner.appendSlice(gpa, try shortValue(gpa, e.value));
    }
    return std.fmt.allocPrint(gpa, "{{{s}}}", .{inner.items});
}

/// Values shortened exactly like the nql CLI: vectors/arrays truncated,
/// strings Rust-debug-quoted, floats via Rust's `{}` Display.
/// (Explicit error set: `formatFields` ⇄ `shortValue` recurse.)
fn shortValue(gpa: std.mem.Allocator, v: ir.Value) std.mem.Allocator.Error![]const u8 {
    switch (v) {
        .null => return "null",
        .bool => |b| return if (b) "true" else "false",
        .int => |n| return std.fmt.allocPrint(gpa, "{d}", .{n}),
        // Rust `{}` for f64 = shortest round-trip, NEVER exponential; zig's
        // `{d}` may emit `e` notation for extreme values (not present in the
        // E01–E05 corpora — tracked as a known gap).
        .float => |f| return std.fmt.allocPrint(gpa, "{d}", .{f}),
        .str => |s| return rustDebugString(gpa, s),
        .doc => |entries| return formatFields(gpa, entries),
        .arr => |items| {
            var shown: std.ArrayList(u8) = .empty;
            var n: usize = 0;
            for (items) |it| {
                if (n == 3) break;
                if (n > 0) try shown.appendSlice(gpa, ", ");
                try shown.appendSlice(gpa, try shortValue(gpa, it));
                n += 1;
            }
            return std.fmt.allocPrint(gpa, "[{s}]", .{shown.items});
        },
        .vector => |dims| {
            var shown: std.ArrayList(u8) = .empty;
            var n: usize = 0;
            for (dims) |x| {
                if (n == 4) break;
                if (n > 0) try shown.appendSlice(gpa, ", ");
                try shown.appendSlice(gpa, try std.fmt.allocPrint(gpa, "{d}", .{x}));
                n += 1;
            }
            const more: []const u8 = if (dims.len > 4) ", ..." else "";
            return std.fmt.allocPrint(gpa, "[{s}{s}]", .{ shown.items, more });
        },
        .ref => |rid| return ir.recordIdDisplay(gpa, rid),
    }
}

/// Rust `{:?}` for strings: quotes + the standard escapes (printable
/// non-ASCII passes through raw, as `escape_debug` does).
fn rustDebugString(gpa: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(gpa, '"');
    for (s) |c| {
        switch (c) {
            '\\' => try out.appendSlice(gpa, "\\\\"),
            '"' => try out.appendSlice(gpa, "\\\""),
            '\n' => try out.appendSlice(gpa, "\\n"),
            '\r' => try out.appendSlice(gpa, "\\r"),
            '\t' => try out.appendSlice(gpa, "\\t"),
            0 => try out.appendSlice(gpa, "\\0"),
            else => {
                if (c < 0x20 or c == 0x7f) {
                    try out.appendSlice(gpa, try std.fmt.allocPrint(gpa, "\\u{{{x:0>2}}}", .{c}));
                } else {
                    try out.append(gpa, c);
                }
            },
        }
    }
    try out.append(gpa, '"');
    return out.items;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "server session across lines" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var s = Server.init(gpa, std.testing.io);
    try std.testing.expectEqualStrings("OK", s.handleLine("CREATE TABLE t VECTOR<f32, 2>"));
    try std.testing.expectEqualStrings(
        "OK",
        s.handleLine("INSERT INTO t:1 { name: \"a\" } EMBED [1.0, 0.0]"),
    );
    try std.testing.expectEqualStrings(
        "OK",
        s.handleLine("INSERT INTO t:2 { name: \"b\" } EMBED [0.9, 0.1]"),
    );
    const out = s.handleLine("SELECT * FROM t WHERE vector::similarity(embedding, [1.0, 0.0]) AND k = 2");
    // kNN enrichment orders by similarity; 4dp scores; OK terminator.
    try std.testing.expect(std.mem.startsWith(u8, out, "SELECT t (2 rows): t:1 score=1.0000"));
    try std.testing.expect(std.mem.indexOf(u8, out, "t:2 score=0.99") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "\nOK"));
}

test "server error responses are single-line and exact" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var s = Server.init(gpa, std.testing.io);
    // Parse error: Rust Display `parse error at L:C: msg`.
    const err = s.handleLine("THIS IS NOT NQL");
    try std.testing.expect(std.mem.startsWith(u8, err, "ERR parse error at "));
    try std.testing.expect(std.mem.indexOf(u8, err, "\n") == null);
    // Session survives.
    try std.testing.expectEqualStrings("OK", s.handleLine("CREATE TABLE t"));
    try std.testing.expectEqualStrings("OK", s.handleLine("INSERT INTO t:1 {}"));
    // Cross-line analysis: declared context carried (no re-declare needed).
    const out = s.handleLine("SELECT * FROM t");
    try std.testing.expect(std.mem.indexOf(u8, out, "t:1") != null);
    // Engine-flow error with the reference's exact text: the ANALYZER
    // rejects first (server analyzes before executing), so the Display is
    // the AnalysisError's — same as nql-server.
    try std.testing.expectEqualStrings("OK", s.handleLine("CREATE TABLE v VECTOR<f32, 2>"));
    const dim_err = s.handleLine("INSERT INTO v:1 {} EMBED [1.0, 0.0, 0.0]");
    try std.testing.expectEqualStrings(
        "ERR INSERT into `v` has embedding of dimension 3, but the table declares VECTOR<f32, 2>",
        dim_err,
    );
}

test "rustFormat4 matches Rust {:.4} (half-to-even ties)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    // Verified against rustc: 0.03125 → 0.0312 (tie, even), −0.0 → −0.0000,
    // 0.15625 → 0.1562, 1.0 → 1.0000, 0.12345(f32) → 0.1235 (not a tie).
    try std.testing.expectEqualStrings("0.0312", try rustFormat4(gpa, 0.03125));
    try std.testing.expectEqualStrings("-0.0312", try rustFormat4(gpa, -0.03125));
    try std.testing.expectEqualStrings("0.0625", try rustFormat4(gpa, 0.0625));
    try std.testing.expectEqualStrings("0.1562", try rustFormat4(gpa, 0.15625));
    try std.testing.expectEqualStrings("1.0000", try rustFormat4(gpa, 1.0));
    try std.testing.expectEqualStrings("-0.0000", try rustFormat4(gpa, -0.0));
    try std.testing.expectEqualStrings("0.1235", try rustFormat4(gpa, 0.12345));
    try std.testing.expectEqualStrings("0.3333", try rustFormat4(gpa, 1.0 / 3.0));
}

test "match label formatting" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var s = Server.init(gpa, std.testing.io);
    try std.testing.expectEqualStrings("OK", s.handleLine("CREATE TABLE a"));
    try std.testing.expectEqualStrings("OK", s.handleLine("CREATE TABLE b"));
    try std.testing.expectEqualStrings("OK", s.handleLine("INSERT INTO a:1 {}"));
    try std.testing.expectEqualStrings("OK", s.handleLine("INSERT INTO b:2 {}"));
    try std.testing.expectEqualStrings("OK", s.handleLine("RELATE (a:1) -> :goes -> (b:2)"));
    const out = s.handleLine("MATCH (a:1) -> :goes");
    // Reference label: `MATCH <start> <hops>` (not the SELECT-style table),
    // rows with 4dp scores, then the OK terminator.
    try std.testing.expectEqualStrings(
        "MATCH a:1 ->:goes (1 rows): b:2 score=0.0000 {}\nOK",
        out,
    );
}

test "--db persists and reseeds declared tables" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(
        gpa,
        "{s}/{s}/store.nql",
        .{ std.testing.TmpDir.parent_dir_path, &tmp.sub_path },
    );

    {
        var s = try Server.open(gpa, io, path);
        try std.testing.expectEqualStrings("OK", s.handleLine("CREATE TABLE t VECTOR<f32, 2>"));
        try std.testing.expectEqualStrings(
            "OK",
            s.handleLine("INSERT INTO t:1 { \"text\": \"x\" } EMBED [0.5, 0.5];"),
        );
        // Declaration-only table (exists only in history — the #89 trap).
        try std.testing.expectEqualStrings("OK", s.handleLine("CREATE TABLE scratch;"));
        // Memory-scoped table.
        try std.testing.expectEqualStrings("OK", s.handleLine("MEMORY m; CREATE TABLE mt;"));
        try std.testing.expectEqualStrings(
            "OK",
            s.handleLine("MEMORY m; INSERT INTO mt:1 { \"v\": 1 };"),
        );
        s.file.?.close();
    } // drop: WAL persisted, lock released

    {
        var s = try Server.open(gpa, io, path);
        // Data survived (WAL replay on open).
        const out = s.handleLine("SELECT * FROM t;");
        try std.testing.expect(std.mem.indexOf(u8, out, "t:1") != null);
        // Pre-restart tables are analyzable again…
        try std.testing.expectEqualStrings(
            "OK",
            s.handleLine("INSERT INTO t:2 { \"text\": \"y\" } EMBED [0.5, 0.5];"),
        );
        // …including the empty, dimension-less one…
        try std.testing.expectEqualStrings(
            "OK",
            s.handleLine("INSERT INTO scratch:1 { \"n\": 1 };"),
        );
        // …and the memory-scoped one.
        try std.testing.expectEqualStrings(
            "OK",
            s.handleLine("MEMORY m; INSERT INTO mt:2 { \"v\": 2 };"),
        );
        const mout = s.handleLine("MEMORY m; SELECT * FROM mt;");
        try std.testing.expect(std.mem.indexOf(u8, mout, "mt:1") != null);
        try std.testing.expect(std.mem.indexOf(u8, mout, "mt:2") != null);
        // Row-shaped leak check: root t:2 must not appear in the memory.
        try std.testing.expect(std.mem.indexOf(u8, mout, ": t:2 score=") == null);
        const sout = s.handleLine("SELECT * FROM scratch;");
        try std.testing.expect(std.mem.indexOf(u8, sout, "scratch:1") != null);
        s.file.?.close();
    }
}
