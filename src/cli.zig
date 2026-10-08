//! nql CLI: `--script` runner + interactive REPL — port of `nql-cli`.
//!
//! Byte-contract with the reference (`nql-cli`): parse → execute with **no
//! analyzer pass and no cross-line `declared` context** (Session::run in the
//! reference parses and executes directly — engine state carries the tables);
//! CLI result format is `label (N rows)` + two-space-indented rows; parse
//! failures print `error: …` on stdout; the REPL banner/HELP/meta strings are
//! copied verbatim (byte parity for `run_cli_repl` transcripts).
//!
//! `--db` mirrors `Database`: mutating plans append WAL frames (+ #109
//! ContextReset) through the shared `server.walAfterPlan`, and `:flush`
//! checkpoints (claiming the lazy history tail first — issue #133).

const std = @import("std");
const Io = std.Io;
const parser = @import("parser.zig");
const engine = @import("engine.zig");
const ir = @import("ir.zig");
const storage = @import("storage.zig");
const server = @import("server.zig");
const v4 = @import("v4.zig");

/// `CARGO_PKG_VERSION` of the reference CLI — the workspace (0.1.0) and this
/// repo's `build.zig.zon` (0.1.0) agree, so the banners are identical bytes.
pub const BANNER = "nql 0.1.0 — type :help for help, :quit to exit";

const HELP_BODY =
    \\nql — deterministic neural query REPL (zero-LLM)
    \\
    \\Commands:
    \\  :help          this help
    \\  :quit | :exit  leave the REPL
    \\  :clear         start a fresh empty database (in-memory sessions only)
    \\  :flush         checkpoint the WAL into the main file (--db sessions)
    \\  :store         dump current records, edges, and vector dims
    \\
    \\Anything else is parsed as nql (multi-statement with ';' separators).
;

/// The reference's HELP raw string ends with `\n` (zig multiline literals
/// do not include one).
pub const HELP = HELP_BODY ++ "\n";

pub const USAGE = "usage: nql [--db FILE] [--script FILE]";

/// One CLI session: engine state (+ optional `--db` file) and a byte buffer
/// the driver flushes to stdout (mirrors the reference's buffered writer).
pub const Session = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    store: engine.EngineStore,
    file: ?storage.StoreFile = null,
    out: *std.ArrayList(u8),

    pub fn new(gpa: std.mem.Allocator, io: std.Io, out: *std.ArrayList(u8)) Session {
        return .{ .gpa = gpa, .io = io, .store = engine.EngineStore.init(gpa), .out = out };
    }

    /// Reference `Session::open`: lock + v4 load + WAL replay. No analyzer
    /// seeding — the CLI never analyzes, so declared tables are irrelevant.
    pub fn open(
        gpa: std.mem.Allocator,
        io: std.Io,
        out: *std.ArrayList(u8),
        path: []const u8,
    ) !Session {
        var sf = try storage.StoreFile.open(path, gpa, io);
        errdefer sf.close();
        var store = engine.EngineStore.init(gpa);
        if (try sf.loadMain()) |ir_store| {
            store = engine.fromIr(gpa, ir_store) catch return error.OutOfMemory;
        }
        try sf.replayWal(&store);
        return .{ .gpa = gpa, .io = io, .store = store, .file = sf, .out = out };
    }

    fn writeLine(self: *Session, s: []const u8) !void {
        try self.out.appendSlice(self.gpa, s);
        try self.out.append(self.gpa, '\n');
    }

    /// Run one input (multi-statement, `;`-separated). Parse failures print
    /// `error: …` and return 0; execute failures abort the session (stderr +
    /// nonzero exit — the reference propagates an io error the same way).
    pub fn run(self: *Session, input: []const u8) !usize {
        const trimmed = std.mem.trim(u8, input, " \t\r\n");
        if (trimmed.len == 0) return 0;
        const outcome = parser.parse(self.gpa, trimmed) catch return error.OutOfMemory;
        if (outcome == .err) {
            const f = outcome.err;
            const prefix: []const u8 = switch (f.kind) {
                .lex => "lex",
                .parse => "parse",
            };
            const msg = std.fmt.allocPrint(
                self.gpa,
                "error: {s} error at {d}:{d}: {s}",
                .{ prefix, f.line, f.col, f.message },
            ) catch return error.OutOfMemory;
            try self.writeLine(msg);
            return 0;
        }
        const plan = outcome.ok;
        // Lazy history (issue #133): temporal reads + PRUNE need the file log.
        if (self.file) |*sf| {
            if (server.Server.planNeedsHistory(plan)) {
                sf.ensureHistory(&self.store) catch return error.HistoryLoadFailed;
            }
        }
        const results = engine.executePlan(&self.store, plan) catch |e| {
            // Mirrors the reference's `execute error: {e}` abort (stderr).
            const msg = if (self.store.err) |d| d.message else engine.errorVariant(e);
            std.debug.print("execute error: {s}\n", .{msg});
            return error.ExecuteFailed;
        };
        if (self.file) |*sf| {
            const wal_err = server.walAfterPlan(sf, &self.store, plan, self.gpa);
            if (wal_err.len != 0) {
                std.debug.print("{s}\n", .{wal_err});
                return error.WalFailed;
            }
        }
        for (results) |res| try self.printResult(res);
        return plan.len;
    }

    /// CLI result format (differs from the line protocol): label line, then
    /// two-space-indented rows — byte-exact with `nql_cli::print_result`.
    fn printResult(self: *Session, res: engine.QueryResult) !void {
        const label: []const u8 = switch (res.kind) {
            .select => |table| try std.fmt.allocPrint(self.gpa, "SELECT {s}", .{table}),
            .match_ => |path| try server.fmtPathLabel(self.gpa, "MATCH", path),
            .closure => |path| try server.fmtPathLabel(self.gpa, "CLOSURE", path),
            .history => |since| try std.fmt.allocPrint(self.gpa, "HISTORY SINCE {d}", .{since}),
        };
        const head = try std.fmt.allocPrint(
            self.gpa,
            "{s} ({d} rows)\n",
            .{ label, res.rows.len },
        );
        try self.out.appendSlice(self.gpa, head);
        for (res.rows) |row| {
            const id = try ir.recordIdDisplay(self.gpa, row.record.id);
            const fields = try server.formatFields(self.gpa, row.record.body);
            const score = try server.rustFormat4(self.gpa, row.score);
            const line = try std.fmt.allocPrint(
                self.gpa,
                "  {s}  score={s}  {s}\n",
                .{ id, score, fields },
            );
            try self.out.appendSlice(self.gpa, line);
        }
    }

    /// `:flush` — checkpoint the WAL into the main file (no-op in-memory).
    pub fn checkpoint(self: *Session) !void {
        if (self.file == null) return; // in-memory session: no-op (reference)
        const sf = &self.file.?; // mutable: ensure/checkpoint take &mut state
        sf.ensureHistory(&self.store) catch return error.CheckpointFailed;
        const ir_store = engine.toIr(&self.store, self.gpa) catch return error.CheckpointFailed;
        const bytes = v4.encode(ir_store, self.gpa) catch return error.CheckpointFailed;
        sf.checkpoint(bytes) catch return error.CheckpointFailed;
    }

    /// `:store` — dump tables/records/edges (deterministic orders:
    /// dim'd tables name-sorted like the reference's vector_dims BTreeMap,
    /// records canonical, edges append order).
    pub fn dumpStore(self: *Session) !void {
        const st = &self.store;
        try self.writeLine("tables:");
        var dimmed: std.ArrayList(ir.TableEntry) = .empty;
        for (st.tables.items) |t| {
            if (t.vector_dim != null) try dimmed.append(self.gpa, t);
        }
        std.mem.sortUnstable(ir.TableEntry, dimmed.items, {}, struct {
            fn less(_: void, a: ir.TableEntry, b: ir.TableEntry) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.less);
        for (dimmed.items) |t| {
            const line = try std.fmt.allocPrint(
                self.gpa,
                "  {s}  VECTOR<f32,{d}>",
                .{ t.name, t.vector_dim.? },
            );
            try self.writeLine(line);
        }
        try self.writeLine("records:");
        for (st.records.items) |rec| {
            const id = try ir.recordIdDisplay(self.gpa, rec.id);
            const fields = try server.formatFields(self.gpa, rec.body);
            var emb: []const u8 = "";
            if (rec.embedding) |e| {
                var shown: std.ArrayList(u8) = .empty;
                var n: usize = 0;
                for (e) |x| {
                    if (n == 4) break;
                    if (n > 0) try shown.appendSlice(self.gpa, ", ");
                    try shown.appendSlice(self.gpa, try std.fmt.allocPrint(self.gpa, "{d}", .{x}));
                    n += 1;
                }
                if (e.len > 4) try shown.appendSlice(self.gpa, ", ...");
                emb = try std.fmt.allocPrint(self.gpa, " emb=[{s}]", .{shown.items});
            }
            const line = try std.fmt.allocPrint(self.gpa, "  {s}  {s}{s}", .{ id, fields, emb });
            try self.writeLine(line);
        }
        try self.writeLine("edges:");
        for (st.edges.items) |e| {
            const from = try ir.recordIdDisplay(self.gpa, e.from);
            const to = try ir.recordIdDisplay(self.gpa, e.to);
            const w: []const u8 = if (e.weight) |wv|
                try std.fmt.allocPrint(self.gpa, "Some({d})", .{wv})
            else
                "None";
            const line = try std.fmt.allocPrint(
                self.gpa,
                "  {s} -[:{s}]-> {s}  w={s}",
                .{ from, e.name, to, w },
            );
            try self.writeLine(line);
        }
    }

    /// `:clear` — fresh in-memory session (drops the file, like the
    /// reference's `Database::new` swap).
    pub fn clear(self: *Session) void {
        if (self.file) |*sf| {
            sf.close();
            self.file = null;
        }
        self.store = engine.EngineStore.init(self.gpa);
    }
};

pub const Meta = enum { ok, quit };

/// One REPL line: meta commands handled here (byte-identical outputs),
/// anything else runs as NQL. Caller owns line lifetime (REPL lines are
/// arena-duped before this — parser tokens borrow the source).
pub fn replLine(sess: *Session, line: []const u8) !Meta {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return .ok;
    if (std.mem.eql(u8, trimmed, ":help")) {
        try sess.out.appendSlice(sess.gpa, HELP);
        return .ok;
    }
    if (std.mem.eql(u8, trimmed, ":quit") or std.mem.eql(u8, trimmed, ":exit")) return .quit;
    if (std.mem.eql(u8, trimmed, ":clear")) {
        sess.clear();
        try sess.writeLine("cleared");
        return .ok;
    }
    if (std.mem.eql(u8, trimmed, ":flush")) {
        try sess.checkpoint();
        try sess.writeLine("flushed");
        return .ok;
    }
    if (std.mem.eql(u8, trimmed, ":store")) {
        try sess.dumpStore();
        return .ok;
    }
    _ = try sess.run(trimmed);
    return .ok;
}

pub const RunOpts = struct {
    db_path: ?[]const u8 = null,
    script_path: ?[]const u8 = null,
};

/// Driver: `--script FILE` runs the whole file; otherwise the REPL. Output
/// lands in `buf` per unit and is flushed to `out` (reference: per line /
/// end of script). REPL ends with a blank line; script mode does not.
pub fn run(
    arena: std.mem.Allocator,
    io: std.Io,
    out: *Io.Writer,
    opts: RunOpts,
) !void {
    var buf: std.ArrayList(u8) = .empty;
    var sess = if (opts.db_path) |p|
        try Session.open(arena, io, &buf, p)
    else
        Session.new(arena, io, &buf);

    if (opts.script_path) |sp| {
        const f = std.Io.Dir.cwd().openFile(io, sp, .{}) catch {
            std.debug.print("error: cannot open script {s}\n", .{sp});
            std.process.exit(1);
        };
        defer f.close(io);
        const st = try f.stat(io);
        const src = try arena.alloc(u8, st.size);
        _ = try f.readPositionalAll(io, src, 0);
        _ = sess.run(src) catch std.process.exit(1);
        try out.writeAll(buf.items);
        try out.flush();
        return;
    }

    // Interactive REPL.
    try out.writeAll(BANNER);
    try out.writeAll("\n");
    try out.flush();
    var in_buf: [1 << 20]u8 = undefined;
    var stdin_file_reader = Io.File.stdin().reader(io, &in_buf);
    const stdin_reader = &stdin_file_reader.interface;
    while (true) {
        const raw = stdin_reader.takeDelimiterInclusive('\n') catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
        // Arena-dupe: stored bodies borrow the line (the reference's
        // String-owned IR doesn't have this hazard — we do).
        const line = try arena.dupe(u8, std.mem.trim(u8, raw, " \t\r\n"));
        if (line.len == 0) continue;
        const meta = replLine(&sess, line) catch |e| {
            out.writeAll(buf.items) catch {};
            out.flush() catch {};
            std.debug.print("error: {s}\n", .{@errorName(e)});
            std.process.exit(1);
        };
        try out.writeAll(buf.items);
        buf.clearRetainingCapacity();
        try out.flush();
        if (meta == .quit) break;
    }
    // Reference behavior: trailing blank line at REPL exit.
    try out.writeAll("\n");
    try out.flush();
}

// ---------------------------------------------------------------------------
// Tests (goldens ported from nql-cli's own tests + contract pins)
// ---------------------------------------------------------------------------

fn runText(arena: std.mem.Allocator, input: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    var sess = Session.new(arena, std.testing.io, &buf);
    _ = try sess.run(input);
    return buf.toOwnedSlice(arena);
}

test "cli insert then kNN select (reference session_insert_then_select)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const out = try runText(gpa,
        \\CREATE TABLE t VECTOR<f32, 2>;
        \\INSERT INTO t:1 { "name": "a" } EMBED [1.0, 0.0];
        \\INSERT INTO t:2 { "name": "b" } EMBED [0.9, 0.1];
        \\SELECT * FROM t WHERE vector::similarity(embedding, [1.0, 0.0]) AND k = 1 ORDER BY ::similarity;
    );
    try std.testing.expect(std.mem.indexOf(u8, out, "t:1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "name=\"a\"") != null);
    // CLI row shape: label line + two-space-indented rows.
    try std.testing.expect(std.mem.indexOf(u8, out, "SELECT t (1 rows)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\n  t:1  score=") != null);
}

test "cli parse error is reported, not a panic (reference)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const out = try runText(arena.allocator(), "THIS IS NOT NQL");
    try std.testing.expect(std.mem.indexOf(u8, out, "error:") != null);
}

test "cli script with forget and relate (reference)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const out = try runText(arena.allocator(),
        \\CREATE TABLE n;
        \\INSERT INTO n:1 { "a": 1 };
        \\INSERT INTO n:2 { "a": 2 };
        \\RELATE (n:1) -> :refs -> (n:2) SET weight = 0.7;
        \\FORGET n:2;
        \\SELECT * FROM n;
    );
    try std.testing.expect(std.mem.indexOf(u8, out, "SELECT n (1") != null);
}

test "cli banner/help/meta strings are byte-exact (run_cli_repl pins)" {
    try std.testing.expectEqualStrings(
        "nql 0.1.0 — type :help for help, :quit to exit",
        BANNER,
    );
    try std.testing.expect(std.mem.indexOf(u8, HELP, ":flush         checkpoint the WAL into the main file (--db sessions)") != null);
    try std.testing.expect(std.mem.endsWith(u8, HELP, "(multi-statement with ';' separators).\n"));
    try std.testing.expectEqualStrings("usage: nql [--db FILE] [--script FILE]", USAGE);
}

test "cli repl meta: flush prints flushed, store dumps, clear resets" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var buf: std.ArrayList(u8) = .empty;
    var sess = Session.new(gpa, std.testing.io, &buf);
    _ = try replLine(&sess, "CREATE TABLE t;");
    _ = try replLine(&sess, "INSERT INTO t:1 { \"w\": 1 };");
    buf.clearRetainingCapacity();
    _ = try replLine(&sess, ":flush"); // in-memory: no-op checkpoint
    try std.testing.expectEqualStrings("flushed\n", buf.items);
    buf.clearRetainingCapacity();
    _ = try replLine(&sess, ":store");
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "tables:") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\n  t:1  {w=1}") != null);
    buf.clearRetainingCapacity();
    _ = try replLine(&sess, ":clear");
    try std.testing.expectEqualStrings("cleared\n", buf.items);
    try std.testing.expectEqual(@as(usize, 0), sess.store.records.items.len);
    try std.testing.expect((try replLine(&sess, ":quit")) == .quit);
}

test "cli --db: WAL append + reopen replays (server-free path)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(
        gpa,
        "{s}/{s}/cli.nql",
        .{ std.testing.TmpDir.parent_dir_path, &tmp.sub_path },
    );
    {
        var buf: std.ArrayList(u8) = .empty;
        var sess = try Session.open(gpa, io, &buf, path);
        _ = try sess.run("CREATE TABLE t; INSERT INTO t:1 { \"a\": 1 };");
        sess.file.?.close();
    }
    {
        var buf: std.ArrayList(u8) = .empty;
        var sess = try Session.open(gpa, io, &buf, path);
        const out = try sess.run("SELECT * FROM t;");
        try std.testing.expect(std.mem.indexOf(u8, buf.items, "SELECT t (1 rows)") != null);
        try std.testing.expect(out == 1);
    }
}
