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
        // Lazy history (issue #133 seam): temporal reads and PRUNE need the
        // full log — decode the file's HISTORY section on first use.
        if (self.file) |*sf| {
            if (planNeedsHistory(plan))
                sf.ensureHistory(&self.store) catch return "ERR failed to load history";
        }
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
            const wal_err = walAfterPlan(sf, &self.store, plan, gpa);
            if (wal_err.len != 0) return wal_err;
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

    /// The reference's `needs_history` (lib.rs): statements that read the
    /// mutation history — temporal reads (`AS OF`), `HISTORY SINCE`, and
    /// `PRUNE HISTORY` (compaction retains declarations from the full log).
    pub fn planNeedsHistory(plan: []const ir.Statement) bool {
        for (plan) |s| {
            switch (s) {
                .select => |sel| if (sel.as_of != null) return true,
                .match_path => |p| if (p.as_of != null) return true,
                .match_count => |p| if (p.as_of != null) return true,
                .closure => |p| if (p.as_of != null) return true,
                .history_since, .prune_history => return true,
                else => {},
            }
        }
        return false;
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
// Post-plan WAL duties (shared by the line server and the CLI --db path)
// ---------------------------------------------------------------------------

/// Append the plan's mutating frames + #109 ContextReset, then a threshold
/// checkpoint that claims the lazy history tail first (issue #133 — an
/// encode without it would write history without the file era). Returns ""
/// or a response-style error string (identical behavior for every `--db`
/// frontend: the reference's Database::execute does the same inside).
pub fn walAfterPlan(
    sf: *storage.StoreFile,
    store: *engine.EngineStore,
    plan: []const ir.Statement,
    gpa: std.mem.Allocator,
) []const u8 {
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
            sf.ensureHistory(store) catch return "ERR checkpoint failed";
            const ir_store = engine.toIr(store, gpa) catch return "ERR checkpoint failed";
            const bytes = v4.encode(ir_store, gpa) catch return "ERR checkpoint encode failed";
            sf.checkpoint(bytes) catch return "ERR checkpoint failed";
        }
    }
    return "";
}

// ---------------------------------------------------------------------------
// Response formatting (byte-exact with the reference server)
// ---------------------------------------------------------------------------

/// One response line: `<label> (<n> rows): <row>; <row>; …` — byte-exact
/// with the reference (golden/transcript tests pin it). Also the
/// `bench-format` entry point (pub for the bench, callers = this file).
pub fn formatResult(gpa: std.mem.Allocator, res: engine.QueryResult) ![]const u8 {
    const label: []const u8 = switch (res.kind) {
        .select => |table| try std.fmt.allocPrint(gpa, "SELECT {s}", .{table}),
        .match_ => |path| try fmtPathLabel(gpa, "MATCH", path),
        .closure => |path| try fmtPathLabel(gpa, "CLOSURE", path),
        .history => |since| try std.fmt.allocPrint(gpa, "HISTORY SINCE {d}", .{since}),
    };
    if (res.rows.len == 0) {
        return std.fmt.allocPrint(gpa, "{s} (0 rows)", .{label});
    }
    // One buffer for the whole response (was: ~6 heap allocations per row —
    // id/score/fields/row-template — ≈550ms @100k; now one reserve + stack
    // scratch only). Byte-identical: golden + transcript tests pin it.
    var out: std.ArrayList(u8) = .empty;
    out.ensureTotalCapacity(gpa, label.len + res.rows.len * 80 + 32) catch {};
    try out.appendSlice(gpa, label);
    try out.append(gpa, ' ');
    var num_buf: [24]u8 = undefined;
    const suffix = std.fmt.bufPrint(&num_buf, "({d} rows): ", .{res.rows.len}) catch unreachable;
    try out.appendSlice(gpa, suffix);
    try appendRowsInto(&out, gpa, res.rows);
    return out.toOwnedSlice(gpa);
}

/// The hot row loop as a standalone fn with primitive args — no `self`,
/// no method context (TIGER_STYLE §Performance, issue #27): the compiler
/// caches `out`/`gpa`/`rows` in registers without proving aliasing, and
/// the separator rule reads on its own. Byte-identical output (the
/// golden/transcript tests pin it).
fn appendRowsInto(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    rows: []const engine.Row,
) !void {
    for (rows, 0..) |row, i| {
        if (i > 0) try out.appendSlice(gpa, "; ");
        try formatRowInto(out, gpa, row);
    }
}

/// `MATCH <start> ->:name <-:other` — arrows as the reference prints them.
pub fn fmtPathLabel(gpa: std.mem.Allocator, kw: []const u8, path: ir.MatchPath) ![]const u8 {
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

/// Hot row path: appends `<id> score=<:.4> {fields}` into `out` with ZERO
/// per-row heap allocations (stack scratch only) — byte-identical to the
/// old allocating `formatRow` (pinned by the golden/transcript tests).
fn formatRowInto(out: *std.ArrayList(u8), gpa: std.mem.Allocator, row: engine.Row) !void {
    var id_buf: [512]u8 = undefined;
    const id: []const u8 = idInto(&id_buf, row.record.id) orelse
        try ir.recordIdDisplay(gpa, row.record.id); // rare: overlong ids
    try out.appendSlice(gpa, id);
    try out.appendSlice(gpa, " score=");
    var score_buf: [64]u8 = undefined;
    try out.appendSlice(gpa, score4Into(&score_buf, row.score));
    try out.append(gpa, ' ');
    try fieldsInto(out, gpa, row.record.body);
}

/// `table:id` into `buf` — null when the buffer is too small.
fn idInto(buf: []u8, rid: ir.RecordId) ?[]const u8 {
    return switch (rid.id) {
        .num => |n| std.fmt.bufPrint(buf, "{s}:{d}", .{ rid.table, n }) catch null,
        .str => |s| std.fmt.bufPrint(buf, "{s}:{s}", .{ rid.table, s }) catch null,
    };
}

/// Rust `{:.4}` for an f32 (widened exactly to f64) — into `buf`; the math
/// is identical to the original `rustFormat4`: round-to-nearest with
/// half-to-EVEN on exact ties (0.03125 → `0.0312`), exact multiplication
/// for f32-sourced values.
fn score4Into(buf: []u8, x: f32) []const u8 {
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
    return std.fmt.bufPrint(buf, "{s}{d}.{d:0>4}", .{ sign, int_part, frac_part }) catch unreachable;
}

/// Allocating wrapper over `score4Into` (kept for the CLI/MCP callers;
/// the response hot path uses the Into form directly).
pub fn rustFormat4(gpa: std.mem.Allocator, x: f32) std.mem.Allocator.Error![]const u8 {
    var buf: [64]u8 = undefined;
    return gpa.dupe(u8, score4Into(&buf, x));
}

/// BTree-order field rendering: `{k=v, k=v}` (or `{}` when empty) —
/// appends into `out` (no per-entry allocations on the hot path).
fn fieldsInto(out: *std.ArrayList(u8), gpa: std.mem.Allocator, body: []const ir.DocEntry) std.mem.Allocator.Error!void {
    if (body.len == 0) {
        try out.appendSlice(gpa, "{}");
        return;
    }
    try out.append(gpa, '{');
    for (body, 0..) |e, i| {
        if (i > 0) try out.appendSlice(gpa, ", ");
        try out.appendSlice(gpa, e.key);
        try out.append(gpa, '=');
        try shortValueInto(out, gpa, e.value);
    }
    try out.append(gpa, '}');
}

/// Allocating wrapper over `fieldsInto` (CLI callers; the server response
/// path uses the Into form directly).
pub fn formatFields(gpa: std.mem.Allocator, body: []const ir.DocEntry) std.mem.Allocator.Error![]const u8 {
    if (body.len == 0) return "{}";
    var out: std.ArrayList(u8) = .empty;
    try fieldsInto(&out, gpa, body);
    return out.toOwnedSlice(gpa);
}

/// Values shortened exactly like the nql CLI: vectors/arrays truncated,
/// strings Rust-debug-quoted, floats via Rust's `{}` Display — appended
/// into `out` (recursion shares one buffer).
fn shortValueInto(out: *std.ArrayList(u8), gpa: std.mem.Allocator, v: ir.Value) std.mem.Allocator.Error!void {
    switch (v) {
        .null => try out.appendSlice(gpa, "null"),
        .bool => |b| try out.appendSlice(gpa, if (b) "true" else "false"),
        .int => |n| {
            var b: [24]u8 = undefined;
            try out.appendSlice(gpa, std.fmt.bufPrint(&b, "{d}", .{n}) catch unreachable);
        },
        // Rust `{}` for f64 = shortest round-trip, NEVER exponential; zig's
        // `{d}` may emit `e` notation for extreme values (not present in the
        // E01–E05 corpora — tracked as a known gap).
        .float => |f| {
            var b: [48]u8 = undefined;
            try out.appendSlice(gpa, std.fmt.bufPrint(&b, "{d}", .{f}) catch unreachable);
        },
        .str => |s| try debugStrInto(out, gpa, s),
        .doc => |entries| try fieldsInto(out, gpa, entries),
        .arr => |items| {
            try out.append(gpa, '[');
            var n: usize = 0;
            for (items) |it| {
                if (n == 3) break;
                if (n > 0) try out.appendSlice(gpa, ", ");
                try shortValueInto(out, gpa, it);
                n += 1;
            }
            try out.append(gpa, ']');
        },
        .vector => |dims| {
            try out.append(gpa, '[');
            var n: usize = 0;
            for (dims) |x| {
                if (n == 4) break;
                if (n > 0) try out.appendSlice(gpa, ", ");
                var b: [48]u8 = undefined;
                try out.appendSlice(gpa, std.fmt.bufPrint(&b, "{d}", .{x}) catch unreachable);
                n += 1;
            }
            if (dims.len > 4) try out.appendSlice(gpa, ", ...");
            try out.append(gpa, ']');
        },
        .ref => |rid| try out.appendSlice(gpa, try ir.recordIdDisplay(gpa, rid)),
    }
}

/// Rust `{:?}` for strings: quotes + the standard escapes (printable
/// non-ASCII passes through raw, as `escape_debug` does) — appended into
/// `out`.
fn debugStrInto(out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error!void {
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
                    var b: [8]u8 = undefined;
                    try out.appendSlice(gpa, std.fmt.bufPrint(&b, "\\u{{{x:0>2}}}", .{c}) catch unreachable);
                } else {
                    try out.append(gpa, c);
                }
            },
        }
    }
    try out.append(gpa, '"');
}

// ---------------------------------------------------------------------------
// TCP mode (nql-server's default transport — main.zig `--tcp`)
// ---------------------------------------------------------------------------

/// `PORT` env semantics of nql-server: absent → 7878; present-but-invalid →
/// null (the reference fails at bind time; we fail loudly before it).
pub fn parsePort(env: ?[]const u8) ?u16 {
    const s = env orelse return 7878;
    return std.fmt.parseInt(u16, s, 10) catch null;
}

/// Mode A of nql-server (its default): listen on `127.0.0.1:PORT`, one
/// shared server (database) across every connection, accept served
/// SEQUENTIALLY — the reference's "deterministic for sequential/single
/// clients" design. One nql program per line in; one response (result
/// lines + terminator) flushed per line out; a disconnect just ends that
/// connection while the listener and store keep going.
pub fn runTcp(io: std.Io, server: *Server, port: u16) !void {
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    std.debug.print("nqlite_zig listening on 127.0.0.1:{d}\n", .{port});
    while (true) {
        const stream = listener.accept(io) catch |e| {
            // Transient accept failure — the listener is still open.
            std.debug.print("accept error: {s}\n", .{@errorName(e)});
            continue;
        };
        defer stream.close(io);
        serveTcpConn(io, server, stream) catch {}; // disconnect ends this conn
    }
}

/// Serve one connection: same line loop as stdio mode, over the socket.
fn serveTcpConn(io: std.Io, server: *Server, stream: std.Io.net.Stream) !void {
    var in_buf: [1 << 20]u8 = undefined;
    var reader = stream.reader(io, &in_buf);
    const in = &reader.interface;
    var out_buf: [1 << 16]u8 = undefined;
    var writer = stream.writer(io, &out_buf);
    const w = &writer.interface;
    while (true) {
        // EOF or any read error just ends this connection (reference:
        // "A client disconnect … just ends this connection").
        const raw = in.takeDelimiterInclusive('\n') catch break;
        const resp = server.handleLine(raw);
        w.writeAll(resp) catch break;
        w.writeAll("\n") catch break;
        w.flush() catch break;
    }
    w.flush() catch {}; // best-effort drain on disconnect
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parsePort: default7878, strict u16" {
    try std.testing.expectEqual(@as(?u16, 7878), parsePort(null));
    try std.testing.expectEqual(@as(?u16, 7878), parsePort("7878"));
    try std.testing.expectEqual(@as(?u16, 1), parsePort("1"));
    try std.testing.expect(parsePort("abc") == null);
    try std.testing.expect(parsePort("70000") == null); // > u16
    try std.testing.expect(parsePort("-1") == null);
}

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
        "{s}/{s}/store.ndb",
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

test "history surface transcript (M7 golden, byte-exact with the Rust oracle)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const io = std.testing.io;
    var s = Server.init(gpa, io);

    const pruned6 = "history before ts 6 was compacted (PRUNE HISTORY); AS OF / HISTORY SINCE timestamps earlier than the snapshot are no longer available";
    const pruned7 = "history before ts 7 was compacted (PRUNE HISTORY); AS OF / HISTORY SINCE timestamps earlier than the snapshot are no longer available";
    const pruned2 = "history before ts 2 was compacted (PRUNE HISTORY); AS OF / HISTORY SINCE timestamps earlier than the snapshot are no longer available";

    try std.testing.expectEqualStrings("OK", s.handleLine("CREATE TABLE t VECTOR<f32, 2>"));
    try std.testing.expectEqualStrings("OK", s.handleLine("CREATE TABLE scratch")); // decl-only
    try std.testing.expectEqualStrings("OK", s.handleLine("INSERT INTO t:1 { \"a\": 1 }"));
    try std.testing.expectEqualStrings("OK", s.handleLine("INSERT INTO t:2 { \"a\": 2 }"));
    try std.testing.expectEqualStrings("OK", s.handleLine("RELATE (t:1) -> :knows -> (t:2)"));
    try std.testing.expectEqualStrings("OK", s.handleLine("FORGET t:2")); // clock 6

    // Rotation-equivalence anchor: the unpruned window must answer this
    // byte-identically after compaction (t >= horizon).
    const asof6 = "SELECT t (1 rows): t:1 score=0.0000 {a=1}\nOK";
    try std.testing.expectEqualStrings(asof6, s.handleLine("SELECT * FROM t AS OF 6"));

    // Full delta before pruning: every mutation in append order with its
    // subject ids — edge-only RELATE included (#118).
    try std.testing.expectEqualStrings(
        "HISTORY SINCE 0 (6 rows): history:1 score=1.0000 {dim=2, kind=\"CREATE\", table=\"t\", ts=1}; history:2 score=2.0000 {kind=\"CREATE\", table=\"scratch\", ts=2}; history:3 score=3.0000 {id=\"t:1\", kind=\"INSERT\", ts=3}; history:4 score=4.0000 {id=\"t:2\", kind=\"INSERT\", ts=4}; history:5 score=5.0000 {from=\"t:1\", kind=\"RELATE\", name=\"knows\", to=\"t:2\", ts=5}; history:6 score=6.0000 {id=\"t:2\", kind=\"FORGET\", ts=6}\nOK",
        s.handleLine("HISTORY SINCE 0"),
    );
    // Exclusive cutoff: strictly-after semantics.
    try std.testing.expectEqualStrings(
        "HISTORY SINCE 5 (1 rows): history:6 score=6.0000 {id=\"t:2\", kind=\"FORGET\", ts=6}\nOK",
        s.handleLine("HISTORY SINCE 5"),
    );
    // At the last mutation: empty delta, not an error.
    try std.testing.expectEqualStrings("HISTORY SINCE 6 (0 rows)\nOK", s.handleLine("HISTORY SINCE 6"));

    // ---- Compaction (#95): snapshot at the current clock (6) ----
    try std.testing.expectEqualStrings("OK", s.handleLine("PRUNE HISTORY"));
    const err6 = "ERR ";
    var out = s.handleLine("HISTORY SINCE 0");
    try std.testing.expectEqualStrings(err6 ++ pruned6, out);
    out = s.handleLine("SELECT * FROM t AS OF 2");
    try std.testing.expectEqualStrings(err6 ++ pruned6, out);
    // From the horizon on: the snapshot is bookkeeping (never a mutation),
    // and rotation-equivalence holds byte-for-byte.
    try std.testing.expectEqualStrings("HISTORY SINCE 6 (0 rows)\nOK", s.handleLine("HISTORY SINCE 6"));
    try std.testing.expectEqualStrings(asof6, s.handleLine("SELECT * FROM t AS OF 6"));

    // Post-prune mutations stream on from the horizon.
    try std.testing.expectEqualStrings("OK", s.handleLine("INSERT INTO t:3 { \"a\": 3 }")); // clock 7
    try std.testing.expectEqualStrings(
        "HISTORY SINCE 6 (1 rows): history:7 score=7.0000 {id=\"t:3\", kind=\"INSERT\", ts=7}\nOK",
        s.handleLine("HISTORY SINCE 6"),
    );

    // Re-prune rebuilds the snapshot in place (no stacking): horizon = 7.
    try std.testing.expectEqualStrings("OK", s.handleLine("PRUNE HISTORY"));
    out = s.handleLine("HISTORY SINCE 6");
    try std.testing.expectEqualStrings(err6 ++ pruned7, out);
    try std.testing.expectEqualStrings("HISTORY SINCE 7 (0 rows)\nOK", s.handleLine("HISTORY SINCE 7"));
    try std.testing.expectEqualStrings(
        "SELECT t (2 rows): t:1 score=0.0000 {a=1}; t:3 score=0.0000 {a=3}\nOK",
        s.handleLine("SELECT * FROM t;"),
    );

    // ---- Memory blocks: own clock, own deltas, own horizon (#95) ----
    try std.testing.expectEqualStrings(
        "OK",
        s.handleLine("MEMORY m; CREATE TABLE mt; INSERT INTO mt:1 { \"v\": 1 }"),
    );
    try std.testing.expectEqualStrings(
        "HISTORY SINCE 0 (2 rows): history:1 score=1.0000 {kind=\"CREATE\", table=\"mt\", ts=1}; history:2 score=2.0000 {id=\"mt:1\", kind=\"INSERT\", ts=2}\nOK",
        s.handleLine("MEMORY m; HISTORY SINCE 0"),
    );
    // PRUNE inside the block compacts the block (root untouched).
    try std.testing.expectEqualStrings("OK", s.handleLine("MEMORY m; PRUNE HISTORY"));
    out = s.handleLine("MEMORY m; HISTORY SINCE 0");
    try std.testing.expectEqualStrings(err6 ++ pruned2, out);
    out = s.handleLine("HISTORY SINCE 0");
    try std.testing.expectEqualStrings(err6 ++ pruned7, out);
    // Current reads in the block survive its own compaction.
    try std.testing.expectEqualStrings(
        "SELECT mt (1 rows): mt:1 score=0.0000 {v=1}\nOK",
        s.handleLine("MEMORY m; SELECT * FROM mt;"),
    );
}

test "prune history preserves reseed across reopen" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(
        gpa,
        "{s}/{s}/store.ndb",
        .{ std.testing.TmpDir.parent_dir_path, &tmp.sub_path },
    );

    {
        var s = try Server.open(gpa, io, path);
        try std.testing.expectEqualStrings("OK", s.handleLine("CREATE TABLE scratch")); // decl-only
        try std.testing.expectEqualStrings("OK", s.handleLine("CREATE TABLE t"));
        try std.testing.expectEqualStrings("OK", s.handleLine("INSERT INTO t:1 { \"n\": 1 }"));
        try std.testing.expectEqualStrings("OK", s.handleLine("PRUNE HISTORY"));
        // Live insert into the declaration-only table still works.
        try std.testing.expectEqualStrings("OK", s.handleLine("INSERT INTO scratch:1 { \"n\": 2 }"));
        s.file.?.close();
    }

    {
        var s = try Server.open(gpa, io, path);
        // Re-seeded from the retained declarations in the pruned history.
        try std.testing.expectEqualStrings("OK", s.handleLine("INSERT INTO scratch:2 { \"n\": 3 }"));
        const out = s.handleLine("SELECT * FROM scratch;");
        try std.testing.expect(std.mem.indexOf(u8, out, "scratch:1") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "scratch:2") != null);
        // Pre-snapshot AS OF errors loudly …
        const err = s.handleLine("SELECT * FROM t AS OF 1;");
        try std.testing.expect(std.mem.startsWith(u8, err, "ERR"));
        try std.testing.expect(std.mem.indexOf(u8, err, "compacted") != null);
        // … while current reads are unaffected.
        const now = s.handleLine("SELECT * FROM t;");
        try std.testing.expect(std.mem.indexOf(u8, now, "t:1") != null);
        s.file.?.close();
    }
}

test "lazy history seam: file history decodes on first temporal read" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(
        gpa,
        "{s}/{s}/store.ndb",
        .{ std.testing.TmpDir.parent_dir_path, &tmp.sub_path },
    );

    // Session 1: real history, checkpointed (main file carries it).
    {
        var s = try Server.open(gpa, io, path);
        try std.testing.expectEqualStrings("OK", s.handleLine("CREATE TABLE t;"));
        try std.testing.expectEqualStrings("OK", s.handleLine("INSERT INTO t:1 { \"a\": 1 };"));
        try std.testing.expectEqualStrings("OK", s.handleLine("INSERT INTO t:2 { \"a\": 2 };"));
        const ir_store = try engine.toIr(&s.store, gpa);
        const bytes = try v4.encode(ir_store, gpa);
        try s.file.?.checkpoint(bytes);
        s.file.?.close();
    }

    // Session 2: lazy load — history stays encoded until a temporal read.
    {
        var s = try Server.open(gpa, io, path);
        try std.testing.expect(s.file.?.hist != null); // remembered, not decoded
        // A non-temporal mutating line must NOT consume the seam.
        try std.testing.expectEqualStrings("OK", s.handleLine("INSERT INTO t:3 { \"a\": 3 };"));
        try std.testing.expect(s.file.?.hist != null);
        // First temporal read: ensure (one-shot) + correct view of the file era.
        const asof = s.handleLine("SELECT * FROM t AS OF 2;");
        try std.testing.expect(std.mem.indexOf(u8, asof, "t:1") != null);
        try std.testing.expect(std.mem.indexOf(u8, asof, "t:2") == null);
        try std.testing.expect(std.mem.indexOf(u8, asof, "t:3") == null);
        try std.testing.expect(s.file.?.hist == null); // taken exactly once
        // WAL-era insert merges onto the file era: full log = create+3 inserts.
        const h = s.handleLine("HISTORY SINCE 0;");
        try std.testing.expect(std.mem.startsWith(u8, h, "HISTORY SINCE 0 (4 rows)"));
        // A later temporal read reuses the already-loaded history (no double prepend).
        const asof3 = s.handleLine("SELECT * FROM t AS OF 3;");
        try std.testing.expect(std.mem.indexOf(u8, asof3, "t:2") != null);
        try std.testing.expect(std.mem.indexOf(u8, asof3, "t:3") == null);
        s.file.?.close();
    }
}
