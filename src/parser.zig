//! Recursive-descent NQL parser (spec/nql.md §1) — port of
//! `nql/src/parser.rs`: nql text → `[]ir.Statement` (a Plan).
//!
//! Deterministic: documents use canonical sorted keys (the Rust side's
//! `BTreeMap`), `created_at` is always 0 (the engine clocks it), and error
//! positions are the offending token's 1-based line/column — the corpus
//! gate pins kind/line/col exactly (message wording mirrors Rust).

const std = @import("std");
const ir = @import("ir.zig");
const lexer = @import("lexer.zig");

pub const FailKind = enum { lex, parse };

pub const Fail = struct {
    kind: FailKind,
    line: usize,
    col: usize,
    message: []const u8,
};

pub const Outcome = union(enum) {
    ok: []const ir.Statement,
    err: Fail,
};

fn eqlKw(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// Canonicalize an object body: byte-wise key order + last-write-wins on
/// duplicate keys — exactly what `BTreeMap::insert` yields in Rust.
fn canonicalizeDoc(gpa: std.mem.Allocator, entries: []const ir.DocEntry) ![]ir.DocEntry {
    var kept = std.ArrayList(ir.DocEntry).initCapacity(gpa, entries.len) catch return error.OutOfMemory;
    // Keep the LAST entry per key: walk backwards, skip seen keys.
    var i = entries.len;
    while (i > 0) {
        i -= 1;
        const e = entries[i];
        var dup = false;
        for (kept.items) |k| {
            if (std.mem.eql(u8, k.key, e.key)) {
                dup = true;
                break;
            }
        }
        if (!dup) kept.append(gpa, e) catch return error.OutOfMemory;
    }
    // Keys are now unique — any stable order after sorting is canonical.
    std.mem.sort(ir.DocEntry, kept.items, {}, struct {
        fn lt(_: void, a: ir.DocEntry, b: ir.DocEntry) bool {
            return std.mem.lessThan(u8, a.key, b.key);
        }
    }.lt);
    return kept.toOwnedSlice(gpa) catch error.OutOfMemory;
}

const Parser = struct {
    toks: []const lexer.Spanned,
    idx: usize = 0,
    gpa: std.mem.Allocator,
    fail: ?Fail = null,

    fn peek(self: *const Parser) lexer.Spanned {
        if (self.idx < self.toks.len) return self.toks[self.idx];
        return self.toks[self.toks.len - 1]; // the eof terminator
    }

    fn peekTok(self: *const Parser) lexer.Token {
        return self.peek().tok;
    }

    /// Look ahead `n` tokens without consuming (0 = next); clamps to eof.
    fn peekN(self: *const Parser, n: usize) lexer.Token {
        const i = self.idx + n;
        if (i < self.toks.len) return self.toks[i].tok;
        return self.toks[self.toks.len - 1].tok;
    }

    fn atEof(self: *const Parser) bool {
        return self.peekTok() == .eof;
    }

    fn skipSemis(self: *Parser) void {
        while (self.peekTok() == .semi) self.idx += 1;
    }

    fn bump(self: *Parser) lexer.Spanned {
        const s = self.peek();
        if (s.tok != .eof) self.idx += 1;
        return s;
    }

    fn failHere(self: *Parser, comptime fmt: []const u8, args: anytype) error{Parse} {
        const s = self.peek();
        return self.failAtSpan(s, fmt, args);
    }

    fn failAtSpan(self: *Parser, s: lexer.Spanned, comptime fmt: []const u8, args: anytype) error{Parse} {
        self.fail = .{
            .kind = .parse,
            .line = s.line,
            .col = s.col,
            .message = std.fmt.allocPrint(self.gpa, fmt, args) catch "out of memory",
        };
        return error.Parse;
    }

    /// Consume and return an identifier (any bare word).
    fn expectIdent(self: *Parser, what: []const u8) error{Parse}![]const u8 {
        const s = self.bump();
        if (s.tok == .ident) return s.tok.ident;
        return self.failAtSpan(s, "expected {s}, found {s}", .{ what, describe(s.tok) });
    }

    /// Consume a specific keyword, matching case-insensitively.
    fn expectKeyword(self: *Parser, kw: []const u8, what: []const u8) error{Parse}!void {
        const s = self.bump();
        if (s.tok == .ident and eqlKw(s.tok.ident, kw)) return;
        return self.failAtSpan(s, "expected {s} (`{s}`), found {s}", .{ what, kw, describe(s.tok) });
    }

    fn expectToken(self: *Parser, tok: lexer.Token, what: []const u8) error{Parse}!void {
        const s = self.bump();
        if (std.meta.activeTag(s.tok) == std.meta.activeTag(tok)) return;
        return self.failAtSpan(s, "expected {s}, found {s}", .{ what, describe(s.tok) });
    }

    /// Consume an optional comma separator; true if present.
    fn eatComma(self: *Parser) bool {
        if (self.peekTok() == .comma) {
            self.idx += 1;
            return true;
        }
        return false;
    }

    /// If the next token is the given keyword (case-insensitive), consume it.
    fn eatKeyword(self: *Parser, kw: []const u8) bool {
        const t = self.peekTok();
        if (t == .ident and eqlKw(t.ident, kw)) {
            self.idx += 1;
            return true;
        }
        return false;
    }

    fn peekKw(self: *const Parser, kw: []const u8) bool {
        const t = self.peekTok();
        return t == .ident and eqlKw(t.ident, kw);
    }

    // -- statements --------------------------------------------------------

    fn statement(self: *Parser) error{Parse}!ir.Statement {
        const t = self.peekTok();
        if (t == .ident) {
            const kw = t.ident;
            if (eqlKw(kw, "create")) return self.parseCreate();
            if (eqlKw(kw, "insert")) return self.parseInsert();
            if (eqlKw(kw, "relate")) return self.parseRelate();
            if (eqlKw(kw, "match")) return self.parseMatch();
            if (eqlKw(kw, "closure")) return self.parseClosure();
            if (eqlKw(kw, "memory")) return self.parseMemory();
            if (eqlKw(kw, "select")) return self.parseSelect();
            if (eqlKw(kw, "forget")) return self.parseForget();
            if (eqlKw(kw, "prune")) return self.parsePrune();
            if (eqlKw(kw, "history")) return self.parseHistory();
        }
        return self.failHere(
            "expected a statement keyword (CREATE, INSERT, RELATE, MATCH, CLOSURE, MEMORY, SELECT, FORGET, PRUNE, HISTORY), found {s}",
            .{describe(t)},
        );
    }

    /// `HISTORY SINCE <ts>` (issue #118).
    fn parseHistory(self: *Parser) error{Parse}!ir.Statement {
        try self.expectKeyword("history", "HISTORY");
        try self.expectKeyword("since", "SINCE after HISTORY");
        return .{ .history_since = try self.expectInt("SINCE timestamp") };
    }

    /// `PRUNE HISTORY` (issue #95).
    fn parsePrune(self: *Parser) error{Parse}!ir.Statement {
        try self.expectKeyword("prune", "PRUNE");
        try self.expectKeyword("history", "HISTORY after PRUNE");
        return .prune_history;
    }

    fn parseCreate(self: *Parser) error{Parse}!ir.Statement {
        try self.expectKeyword("create", "CREATE");
        try self.expectKeyword("table", "TABLE");
        const table = try self.expectIdent("table name");
        var vector_dim: ?usize = null;
        if (self.eatKeyword("vector")) {
            try self.expectToken(.lt, "`<` after VECTOR");
            // `f32` (or any type placeholder) — accept the word.
            _ = try self.expectIdent("vector element type (e.g. `f32`)");
            try self.expectToken(.comma, "`,` in VECTOR declaration");
            const dim = try self.expectUsize("vector dimension");
            if (dim == 0) return self.failHere("vector dimension must be positive", .{});
            try self.expectToken(.gt, "`>` closing VECTOR declaration");
            vector_dim = dim;
        }
        return .{ .create_table = .{ .table = table, .vector_dim = vector_dim } };
    }

    fn parseInsert(self: *Parser) error{Parse}!ir.Statement {
        try self.expectKeyword("insert", "INSERT");
        try self.expectKeyword("into", "INTO");
        const id = try self.parseRecordId();
        const body = try self.parseObject();
        var embedding: ?[]const f32 = null;
        if (self.eatKeyword("embed")) {
            embedding = try self.parseFloatVector();
        }
        return .{ .insert = .{
            .id = id,
            .body = body,
            .embedding = embedding,
            .created_at = 0,
        } };
    }

    fn parseRelate(self: *Parser) error{Parse}!ir.Statement {
        try self.expectKeyword("relate", "RELATE");
        try self.expectToken(.l_paren, "`(` before FROM record");
        const from = try self.parseRecordId();
        try self.expectToken(.r_paren, "`)` after FROM record");
        try self.expectToken(.arrow, "`->` after FROM record");
        // Edge name: `:<edgename>` (colon optional for lenience).
        if (self.peekTok() == .colon) self.idx += 1;
        const name = try self.expectIdent("edge name");
        try self.expectToken(.arrow, "`->` before TO record");
        try self.expectToken(.l_paren, "`(` before TO record");
        const to = try self.parseRecordId();
        try self.expectToken(.r_paren, "`)` after TO record");

        var weight: ?f32 = null;
        var props: std.ArrayList(ir.DocEntry) = .empty;
        if (self.eatKeyword("set")) {
            while (true) {
                const field = try self.expectIdent("SET field name");
                try self.expectToken(.eq, "`=` in SET clause");
                const value = try self.parseValue();
                if (eqlKw(field, "weight")) {
                    weight = switch (value) {
                        .int => |n| @floatFromInt(n),
                        .float => |f| @floatCast(f),
                        else => return self.failHere("SET weight expects a number, found {s}", .{valueName(value)}),
                    };
                } else {
                    props.append(self.gpa, .{ .key = field, .value = value }) catch
                        return self.failHere("out of memory", .{});
                }
                if (!self.eatComma()) break;
            }
        }
        const props_slice = canonicalizeDoc(self.gpa, props.items) catch
            return self.failHere("out of memory", .{});
        return .{ .relate = .{
            .from = from,
            .name = name,
            .to = to,
            .created_at = 0,
            .weight = weight,
            .props = props_slice,
        } };
    }

    fn parseMatch(self: *Parser) error{Parse}!ir.Statement {
        try self.expectKeyword("match", "MATCH");
        const path = try self.parsePath("MATCH");
        // `MATCH ... COUNT` — walk-count mode (issue #94).
        if (self.peekKw("count")) {
            self.idx += 1;
            return .{ .match_count = path };
        }
        return .{ .match_path = path };
    }

    fn parseClosure(self: *Parser) error{Parse}!ir.Statement {
        try self.expectKeyword("closure", "CLOSURE");
        return .{ .closure = try self.parsePath("CLOSURE") };
    }

    /// `( recordid ) ( ('->' | '<-') ':' ident [WHERE conjunction] )+ [AS OF int]`
    fn parsePath(self: *Parser, kw: []const u8) error{Parse}!ir.MatchPath {
        try self.expectToken(.l_paren, "`(` before start record");
        const start = try self.parseRecordId();
        try self.expectToken(.r_paren, "`)` after start record");

        var steps: std.ArrayList(ir.MatchStep) = .empty;
        while (true) {
            const direction: ir.MatchDirection = if (self.peekTok() == .arrow) blk: {
                self.idx += 1;
                break :blk .out;
            } else if (self.peekTok() == .left_arrow) blk: {
                self.idx += 1;
                break :blk .in;
            } else break;
            if (self.peekTok() == .colon) self.idx += 1;
            const name = try self.expectIdent("edge name after `->`/`<-`");
            var edge_props: ?ir.Filter = null;
            if (self.peekKw("where")) {
                self.idx += 1;
                edge_props = try self.parseWhereConjunction();
            }
            steps.append(self.gpa, .{ .direction = direction, .name = name, .edge_props = edge_props }) catch
                return self.failHere("out of memory", .{});
        }
        if (steps.items.len == 0)
            return self.failHere("{s} requires at least one edge step (`-> :name`)", .{kw});
        // `[ 'AS OF' int ]` (issue #92) — precedes a trailing MATCH `COUNT`.
        var as_of: ?i64 = null;
        if (self.peekKw("as")) {
            self.idx += 1;
            try self.expectKeyword("of", "OF after AS");
            as_of = try self.expectInt("AS OF timestamp");
        }
        return .{ .start = start, .steps = steps.items, .as_of = as_of };
    }

    fn parseSelect(self: *Parser) error{Parse}!ir.Statement {
        try self.expectKeyword("select", "SELECT");
        const proj = try self.parseFieldList();
        try self.expectKeyword("from", "FROM");
        const table = try self.expectIdent("table name after FROM");

        var knn: ?ir.Knn = null;
        var filter: ?ir.Filter = null;
        var order: ?ir.Order = null;
        var limit: ?usize = null;
        var offset: ?usize = null;
        var as_of: ?i64 = null;

        while (true) {
            if (self.peekKw("where")) {
                self.idx += 1;
                const wf = try self.parseWhere();
                knn = wf.@"0";
                filter = wf.@"1";
            } else if (self.peekKw("order")) {
                self.idx += 1;
                try self.expectKeyword("by", "BY after ORDER");
                const colon_prefixed = self.peekTok() == .double_colon or self.peekTok() == .colon;
                if (colon_prefixed) self.idx += 1;
                const o = try self.expectIdent("order key after ORDER BY");
                order = if (eqlKw(o, "similarity"))
                    ir.Order.similarity
                else if (eqlKw(o, "salience"))
                    try self.parseSalienceOrder()
                else if (eqlKw(o, "score"))
                    ir.Order.score
                else if (eqlKw(o, "recency"))
                    ir.Order.recency
                else if (eqlKw(o, "votes"))
                    ir.Order.votes
                else if (eqlKw(o, "feedback"))
                    ir.Order.feedback
                else if (colon_prefixed)
                    return self.failHere(
                        "unknown ORDER BY operator `{s}` (expected similarity, salience, score, recency, votes, or feedback — or a bare field name without `::`)",
                        .{o},
                    )
                else
                    ir.Order{ .field = .{ .key = o, .desc = false } };
                // `<field> [DESC]` (issue #117): operators have fixed
                // directions, so DESC after one is a positioned error.
                if (self.peekKw("desc")) {
                    self.idx += 1;
                    if (order) |*ord| {
                        switch (ord.*) {
                            .field => |*f| f.desc = true,
                            else => return self.failHere(
                                "`DESC` applies to field sorts only (`ORDER BY <field> DESC`); `::` operators have fixed directions",
                                .{},
                            ),
                        }
                    } else {
                        return self.failHere(
                            "`DESC` applies to field sorts only (`ORDER BY <field> DESC`); `::` operators have fixed directions",
                            .{},
                        );
                    }
                }
            } else if (self.peekKw("as")) {
                self.idx += 1;
                try self.expectKeyword("of", "OF after AS");
                as_of = try self.expectInt("AS OF timestamp");
            } else if (self.peekKw("limit")) {
                self.idx += 1;
                limit = try self.expectUsize("LIMIT count");
                if (self.peekKw("offset")) {
                    self.idx += 1;
                    offset = try self.expectUsize("OFFSET count");
                }
            } else if (self.peekKw("offset")) {
                self.idx += 1;
                offset = try self.expectUsize("OFFSET count");
            } else break;
        }

        return .{ .select = .{
            .table = table,
            .knn = knn,
            .filter = filter,
            .order = order,
            .limit = limit,
            .as_of = as_of,
            .fields = proj.fields,
            .offset = offset,
            .aggregate = proj.aggregate,
        } };
    }

    fn parseForget(self: *Parser) error{Parse}!ir.Statement {
        try self.expectKeyword("forget", "FORGET");
        return .{ .forget = .{ .id = try self.parseRecordId() } };
    }

    fn parseMemory(self: *Parser) error{Parse}!ir.Statement {
        try self.expectKeyword("memory", "MEMORY");
        return .{ .memory = .{ .name = try self.expectIdent("memory name after MEMORY") } };
    }

    // -- shared pieces ------------------------------------------------------

    const Projection = struct {
        fields: ?[]const []const u8,
        aggregate: ?ir.Aggregate,
    };

    /// `SELECT <field>, ... | * | COUNT(*)`.
    fn parseFieldList(self: *Parser) error{Parse}!Projection {
        if (self.peekKw("count") and self.peekN(1) == .l_paren) {
            self.idx += 1; // `count`
            try self.expectToken(.l_paren, "`(` after COUNT");
            try self.expectToken(.star, "`*` inside COUNT(");
            try self.expectToken(.r_paren, "`)` after COUNT(");
            return .{ .fields = null, .aggregate = .count_star };
        }
        var fields: std.ArrayList([]const u8) = .empty;
        var star = false;
        while (true) {
            const t = self.peekTok();
            if (t == .star) {
                self.idx += 1;
                star = true;
            } else if (t == .ident) {
                const name = t.ident;
                self.idx += 1;
                fields.append(self.gpa, name) catch return self.failHere("out of memory", .{});
            } else {
                return self.failHere("expected a field name, `*`, or `COUNT(*)` in SELECT", .{});
            }
            if (!self.eatComma()) break;
        }
        return .{ .fields = if (star) null else fields.items, .aggregate = null };
    }

    /// `<ident>:<id>` — id is a number or a bare word.
    fn parseRecordId(self: *Parser) error{Parse}!ir.RecordId {
        const table = try self.expectIdent("table name");
        try self.expectToken(.colon, "`:` between table and id");
        const s = self.bump();
        const id: ir.Id = switch (s.tok) {
            .int => |n| if (n >= 0)
                .{ .num = @intCast(n) }
            else
                // Rust: negative Int tokens become the decimal STRING id.
                .{ .str = std.fmt.allocPrint(self.gpa, "{d}", .{n}) catch return self.failHere("out of memory", .{}) },
            .ident => |word| .{ .str = word },
            else => return self.failAtSpan(s, "expected record id (number or name), found {s}", .{describe(s.tok)}),
        };
        return .{ .table = table, .id = id };
    }

    /// The filter/knn portion after `WHERE` has been consumed.
    fn parseWhere(self: *Parser) error{Parse}!struct { ?ir.Knn, ?ir.Filter } {
        // `::bm25(...) [AND vector::similarity(...)]` — hybrid form.
        if (self.peekTok() == .double_colon) {
            const f = try self.parseBm25Filter();
            var knn: ?ir.Knn = null;
            if (self.eatKeyword("and")) {
                if (!self.peekKw("vector")) {
                    return self.failHere(
                        "`::bm25(...)` may only be ANDed with `vector::similarity(...)` (the hybrid form); field predicates belong to a plain WHERE conjunction (issue #125)",
                        .{},
                    );
                }
                knn = try self.parseKnn();
            }
            return .{ knn, f };
        }
        // `vector::similarity(...) AND k = N [AND ::bm25(...)]`.
        if (self.peekKw("vector")) {
            const knn = try self.parseKnn();
            var f: ?ir.Filter = null;
            if (self.eatKeyword("and")) {
                if (self.peekTok() != .double_colon) {
                    return self.failHere(
                        "after a kNN clause, `AND` may only introduce `::bm25(...)` (hybrid form) — field predicates belong to a plain WHERE conjunction (issue #125)",
                        .{},
                    );
                }
                f = try self.parseBm25Filter();
            }
            return .{ knn, f };
        }
        const f = try self.parseWhereConjunction();
        return .{ null, f };
    }

    /// `term (AND term)*` — n-ary all-of (issue #125); single term unwrapped.
    fn parseWhereConjunction(self: *Parser) error{Parse}!ir.Filter {
        var terms: std.ArrayList(ir.Filter) = .empty;
        terms.append(self.gpa, try self.parseWhereTerm()) catch return self.failHere("out of memory", .{});
        while (self.eatKeyword("and")) {
            if (self.peekTok() == .double_colon) {
                return self.failHere(
                    "`::bm25` does not take part in `AND` conjunctions — the hybrid form is `::bm25(...) AND vector::similarity(...)` (issue #125)",
                    .{},
                );
            }
            if (self.peekKw("vector")) {
                return self.failHere(
                    "`vector::similarity` does not take part in field-predicate `AND` conjunctions — put the kNN clause first: `WHERE vector::similarity(...) AND k = N [AND ::bm25(...)]` (issue #125)",
                    .{},
                );
            }
            terms.append(self.gpa, try self.parseWhereTerm()) catch return self.failHere("out of memory", .{});
        }
        if (terms.items.len == 1) return terms.items[0];
        return .{ .and_filter = terms.items };
    }

    /// One combinable WHERE term: a field predicate or `IS NOT NULL`.
    fn parseWhereTerm(self: *Parser) error{Parse}!ir.Filter {
        const field = try self.expectIdent("WHERE field name");
        if (self.peekKw("is")) {
            self.idx += 1;
            try self.expectKeyword("not", "NOT in `IS NOT NULL`");
            try self.expectKeyword("null", "NULL in `IS NOT NULL`");
            return .has_embedding;
        }
        return self.parseFieldPredicate(field);
    }

    /// A field predicate once its name is consumed (issues #93/#94/#125).
    fn parseFieldPredicate(self: *Parser, field: []const u8) error{Parse}!ir.Filter {
        // `id` pseudo-field (issue #128): `=`, `!=`, `IN [...]` only.
        const is_id = std.mem.eql(u8, field, "id");
        const t0 = self.peekTok();
        if (is_id and (t0 == .lt or t0 == .le or t0 == .gt or t0 == .ge)) {
            return self.failHere(
                "`id` supports only `=`, `!=`, and `IN [...]` — ids are not an ordered value (issue #128)",
                .{},
            );
        }
        if (t0 == .eq) {
            self.idx += 1;
            const value = try self.parseValue();
            if (is_id) try self.requireIdString(value);
            return .{ .field_equals = .{ .field = field, .value = value } };
        }
        if (self.peekKw("in")) {
            self.idx += 1;
            try self.expectToken(.l_bracket, "`[` after IN (e.g. `IN [1, 2, 3]`)");
            var values: std.ArrayList(ir.Value) = .empty;
            while (true) {
                if (self.peekTok() == .r_bracket) {
                    self.idx += 1;
                    break;
                }
                values.append(self.gpa, try self.parseValue()) catch return self.failHere("out of memory", .{});
                if (!self.eatComma()) {
                    try self.expectToken(.r_bracket, "`]` closing the IN list");
                    break;
                }
            }
            if (is_id) {
                for (values.items) |v| try self.requireIdString(v);
            }
            return .{ .field_in = .{ .field = field, .values = values.items } };
        }
        if (self.peekKw("between")) {
            if (is_id) {
                return self.failHere(
                    "`id` supports only `=`, `!=`, and `IN [...]` — ids are not an ordered value (issue #128)",
                    .{},
                );
            }
            self.idx += 1;
            const lo = try self.parseValue();
            try self.expectKeyword("and", "AND between BETWEEN bounds");
            const hi = try self.parseValue();
            return .{ .field_between = .{ .field = field, .lo = lo, .hi = hi } };
        }
        const op: ir.CmpOp = switch (self.peekTok()) {
            .ne => .ne,
            .lt => .lt,
            .le => .le,
            .gt => .gt,
            .ge => .ge,
            else => return self.failHere(
                "expected an operator after `{s}` (`=`, `!=`, `<`, `<=`, `>`, `>=`, `IN [...]`, or `BETWEEN ... AND ...`)",
                .{field},
            ),
        };
        self.idx += 1; // the comparison token
        const value = try self.parseValue();
        if (is_id) try self.requireIdString(value);
        return .{ .field_cmp = .{ .field = field, .op = op, .value = value } };
    }

    /// `WHERE id <op> …` compares against the `table:id` display string.
    fn requireIdString(self: *Parser, value: ir.Value) error{Parse}!void {
        if (value == .str) return;
        return self.failHere(
            "`id` predicates compare against the `table:id` string, e.g. `id = \"doc:7\"` (issue #128)",
            .{},
        );
    }

    /// `::bm25(<field>, "<query>") [AND k = <N>]`.
    fn parseBm25Filter(self: *Parser) error{Parse}!ir.Filter {
        if (self.peekTok() != .double_colon)
            return self.failHere("expected `::bm25` after `AND`", .{});
        self.idx += 1;
        const op = try self.expectIdent("operator after `::`");
        if (!eqlKw(op, "bm25"))
            return self.failHere("unknown WHERE operator `::{s}` (expected ::bm25)", .{op});
        try self.expectToken(.l_paren, "`(` after ::bm25");
        const field = try self.expectIdent("::bm25 field name");
        try self.expectToken(.comma, "`,` between field and query");
        const q = try self.parseValue();
        const query: []const u8 = switch (q) {
            .str => |s| s,
            else => return self.failHere("::bm25 query must be a string, found {s}", .{valueName(q)}),
        };
        try self.expectToken(.r_paren, "`)` closing ::bm25");
        var k: ?usize = null;
        // Only consume `AND k = <N>` when `k` actually follows — an
        // `AND vector::similarity(...)` here is the hybrid fusion bridge.
        const t1 = self.peekN(1);
        if (self.peekKw("and") and t1 == .ident and eqlKw(t1.ident, "k")) {
            self.idx += 1; // AND
            self.idx += 1; // k
            try self.expectToken(.eq, "`=` before k");
            k = try self.expectUsize("k");
        }
        return .{ .bm25 = .{ .field = field, .query = query, .k = k } };
    }

    /// `vector::similarity(embedding, [<f32>, ...]) AND k = <N>`.
    fn parseKnn(self: *Parser) error{Parse}!ir.Knn {
        _ = try self.expectIdent("`vector`");
        try self.expectToken(.double_colon, "`::` after `vector`");
        _ = try self.expectIdent("`similarity`");
        try self.expectToken(.l_paren, "`(` after vector::similarity");
        _ = try self.expectIdent("`embedding`");
        try self.expectToken(.comma, "`,` between embedding and query vector");
        const query = try self.parseFloatVector();
        try self.expectToken(.r_paren, "`)` closing vector::similarity");
        try self.expectKeyword("and", "AND in kNN WHERE clause");
        _ = try self.expectIdent("`k`");
        try self.expectToken(.eq, "`=` before k");
        const k = try self.expectUsize("k");
        if (k == 0) return self.failHere("k must be positive", .{});
        return .{ .query = query, .k = k };
    }

    /// `[<f32>, ...]` — numeric literal list (ints allowed, cast to f32).
    fn parseFloatVector(self: *Parser) error{Parse}![]const f32 {
        try self.expectToken(.l_bracket, "`[` starting vector literal");
        var out: std.ArrayList(f32) = .empty;
        while (true) {
            switch (self.peekTok()) {
                .r_bracket => {
                    self.idx += 1;
                    break;
                },
                .int => |n| {
                    self.idx += 1;
                    out.append(self.gpa, @floatFromInt(n)) catch return self.failHere("out of memory", .{});
                },
                .float => |f| {
                    self.idx += 1;
                    out.append(self.gpa, @floatCast(f)) catch return self.failHere("out of memory", .{});
                },
                else => return self.failHere("expected a number in vector literal, found {s}", .{describe(self.peekTok())}),
            }
            if (!self.eatComma()) {
                try self.expectToken(.r_bracket, "`]` closing vector literal");
                break;
            }
        }
        return out.items;
    }

    // -- JSON-ish values -----------------------------------------------------

    /// `{ ... }` object body → canonical `Value.doc`.
    fn parseObject(self: *Parser) error{Parse}![]const ir.DocEntry {
        try self.expectToken(.l_brace, "`{` starting record body");
        return self.parseObjectBody();
    }

    /// Assumes the opening `{` was already consumed.
    fn parseObjectBody(self: *Parser) error{Parse}![]const ir.DocEntry {
        var entries: std.ArrayList(ir.DocEntry) = .empty;
        while (true) {
            switch (self.peekTok()) {
                .r_brace => {
                    self.idx += 1;
                    break;
                },
                .str, .ident => {
                    const key = tokStrIdent(self.bump().tok);
                    try self.expectToken(.colon, "`:` after object key");
                    const value = try self.parseValue();
                    entries.append(self.gpa, .{ .key = key, .value = value }) catch
                        return self.failHere("out of memory", .{});
                },
                else => return self.failHere("expected object key or `}}`, found {s}", .{describe(self.peekTok())}),
            }
            if (!self.eatComma()) {
                try self.expectToken(.r_brace, "`}` closing record body");
                break;
            }
        }
        return canonicalizeDoc(self.gpa, entries.items) catch
            return self.failHere("out of memory", .{});
    }

    fn parseValue(self: *Parser) error{Parse}!ir.Value {
        const s = self.bump();
        switch (s.tok) {
            .str => |t| return .{ .str = t },
            .int => |n| return .{ .int = n },
            .float => |f| return .{ .float = f },
            .ident => |w| {
                if (eqlKw(w, "true")) return .{ .bool = true };
                if (eqlKw(w, "false")) return .{ .bool = false };
                if (eqlKw(w, "null")) return .null;
                return .{ .str = w };
            },
            .l_brace => return .{ .doc = try self.parseObjectBody() },
            .l_bracket => return self.parseArrayBody(),
            else => return self.failAtSpan(s, "expected a value, found {s}", .{describe(s.tok)}),
        }
    }

    /// The rest of an array whose opening `[` was consumed.
    /// All-numeric arrays collapse to `Value.vector` (M0 contract).
    fn parseArrayBody(self: *Parser) error{Parse}!ir.Value {
        var elems: std.ArrayList(ir.Value) = .empty;
        while (true) {
            if (self.peekTok() == .r_bracket) {
                self.idx += 1;
                break;
            }
            const v = try self.parseValue();
            elems.append(self.gpa, v) catch return self.failHere("out of memory", .{});
            if (!self.eatComma()) {
                try self.expectToken(.r_bracket, "`]` closing array");
                break;
            }
        }
        const slice = elems.items;
        if (slice.len > 0) {
            var all_numeric = true;
            for (slice) |v| {
                if (v != .int and v != .float) {
                    all_numeric = false;
                    break;
                }
            }
            if (all_numeric) {
                const floats = self.gpa.alloc(f32, slice.len) catch return self.failHere("out of memory", .{});
                for (slice, 0..) |v, i| {
                    floats[i] = switch (v) {
                        .int => |n| @floatFromInt(n),
                        .float => |f| @floatCast(f),
                        else => unreachable,
                    };
                }
                return .{ .vector = floats };
            }
        }
        return .{ .arr = slice };
    }

    fn expectUsize(self: *Parser, what: []const u8) error{Parse}!usize {
        const s = self.bump();
        switch (s.tok) {
            .int => |n| {
                if (n >= 0) return @intCast(n);
                return self.failAtSpan(s, "{s} must be non-negative, found {d}", .{ what, n });
            },
            else => return self.failAtSpan(s, "expected a non-negative integer for {s}, found {s}", .{ what, describe(s.tok) }),
        }
    }

    fn expectInt(self: *Parser, what: []const u8) error{Parse}!i64 {
        const s = self.bump();
        switch (s.tok) {
            .int => |n| return n,
            else => return self.failAtSpan(s, "expected an integer for {s}, found {s}", .{ what, describe(s.tok) }),
        }
    }

    /// `::salience` order key: bare or `::salience(α, β, γ, δ)` (issue #88).
    fn parseSalienceOrder(self: *Parser) error{Parse}!ir.Order {
        if (self.peekTok() != .l_paren) return .salience;
        self.idx += 1;
        var w: [4]f32 = .{ 0, 0, 0, 0 };
        for (&w, 0..) |*slot, i| {
            if (i > 0) try self.expectToken(.comma, "`,` between salience weights");
            const s = self.bump();
            const raw: f64 = switch (s.tok) {
                .int => |n| @floatFromInt(n),
                .float => |f| f,
                else => return self.failAtSpan(s, "expected a number for salience weight {d} of 4 (α, β, γ, δ), found {s}", .{ i + 1, describe(s.tok) }),
            };
            const v: f32 = @floatCast(raw);
            if (!std.math.isFinite(v))
                return self.failAtSpan(s, "salience weights must be finite", .{});
            slot.* = v;
        }
        try self.expectToken(.r_paren, "`)` after salience weights");
        return .{ .salience_weighted = w };
    }
};

/// Helper on the token union: payload of `.str` or `.ident` (object keys).
fn tokStrIdent(t: lexer.Token) []const u8 {
    return switch (t) {
        .str => |s| s,
        .ident => |s| s,
        else => unreachable,
    };
}

fn describe(t: lexer.Token) []const u8 {
    return switch (t) {
        .ident => "identifier",
        .int => "integer",
        .float => "float",
        .str => "string",
        .l_paren => "`(`",
        .r_paren => "`)`",
        .l_brace => "`{`",
        .r_brace => "`}`",
        .l_bracket => "`[`",
        .r_bracket => "`]`",
        .semi => "`;`",
        .comma => "`,`",
        .arrow => "`->`",
        .left_arrow => "`<-`",
        .plus => "`+`",
        .colon => "`:`",
        .double_colon => "`::`",
        .eq => "`=`",
        .ne => "`!=`",
        .lt => "`<`",
        .le => "`<=`",
        .gt => "`>`",
        .ge => "`>=`",
        .star => "`*`",
        .eof => "end of input",
    };
}

fn valueName(v: ir.Value) []const u8 {
    return switch (v) {
        .null => "null",
        .bool => "boolean",
        .int => "integer",
        .float => "float",
        .str => "string",
        .doc => "object",
        .arr => "array",
        .vector => "vector",
        .ref => "reference",
    };
}

/// Parse a full nql program (zero or more statements) into a plan.
pub fn parse(gpa: std.mem.Allocator, input: []const u8) error{OutOfMemory}!Outcome {
    const lex = lexer.tokenize(gpa, input);
    if (lex == .err) {
        return .{ .err = .{ .kind = .lex, .line = lex.err.line, .col = lex.err.col, .message = lex.err.message } };
    }
    var p = Parser{ .toks = lex.ok, .gpa = gpa };
    var plan: std.ArrayList(ir.Statement) = .empty;
    while (true) {
        if (p.atEof()) break;
        p.skipSemis();
        if (p.atEof()) break;
        const s = p.statement() catch {
            return .{ .err = p.fail orelse Fail{ .kind = .parse, .line = 0, .col = 0, .message = "parse error" } };
        };
        plan.append(gpa, s) catch return error.OutOfMemory;
    }
    const out = plan.toOwnedSlice(gpa) catch return error.OutOfMemory;
    return .{ .ok = out };
}

/// Parse exactly one statement; trailing input (beyond whitespace/semis)
/// is an error — the `mode: statement` corpus contract.
pub fn parseStatement(gpa: std.mem.Allocator, input: []const u8) error{OutOfMemory}!Outcome {
    const lex = lexer.tokenize(gpa, input);
    if (lex == .err) {
        return .{ .err = .{ .kind = .lex, .line = lex.err.line, .col = lex.err.col, .message = lex.err.message } };
    }
    var p = Parser{ .toks = lex.ok, .gpa = gpa };
    const s = p.statement() catch {
        return .{ .err = p.fail orelse Fail{ .kind = .parse, .line = 0, .col = 0, .message = "parse error" } };
    };
    if (!p.atEof()) {
        return .{ .err = .{
            .kind = .parse,
            .line = p.peek().line,
            .col = p.peek().col,
            .message = try std.fmt.allocPrint(gpa, "unexpected trailing input after statement", .{}),
        } };
    }
    const out = gpa.alloc(ir.Statement, 1) catch return error.OutOfMemory;
    out[0] = s;
    return .{ .ok = out };
}

test "parse simple plan" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const res = try parse(gpa, "CREATE TABLE t\nINSERT INTO t:1 { a: 1 }\nSELECT * FROM t");
    try std.testing.expect(res == .ok);
    try std.testing.expectEqual(@as(usize, 3), res.ok.len);
    try std.testing.expect(res.ok[0] == .create_table);
    try std.testing.expect(res.ok[1] == .insert);
    try std.testing.expect(res.ok[2] == .select);
}
