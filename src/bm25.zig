//! Deterministic BM25 lexical retrieval (spec/nql.md §2) — port of
//! `nql/src/bm25.rs`'s sibling `nqlite/src/bm25.rs`.
//!
//! Okapi BM25 with Robertson–Sparck Jones +1-smoothed idf (Lucene-style),
//! K1=1.2, B=0.75, over one text field. All arithmetic is **f32** — byte-
//! exact score parity with the Rust oracle demands it. Tokenization is the
//! reference's naive split-on-non-alphanumeric + lowercase (ASCII case; the
//! golden fixtures are ASCII — non-ASCII case folding is deferred).

const std = @import("std");
const ir = @import("ir.zig");

pub const K1: f32 = 1.2;
pub const B: f32 = 0.75;

/// Split `text` into deterministic lowercase tokens: every run of
/// alphanumeric bytes is one token (≥0x80 bytes ride alphanumeric runs —
/// matches the reference for Latin-1 letters; ASCII is corpus-exact).
pub fn tokenize(gpa: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var start: ?usize = null;
    for (text, 0..) |c, i| {
        const alnum = std.ascii.isAlphanumeric(c) or c >= 0x80;
        if (alnum) {
            if (start == null) start = i;
        } else if (start) |s| {
            try out.append(gpa, try lowerDup(gpa, text[s..i]));
            start = null;
        }
    }
    if (start) |s| try out.append(gpa, try lowerDup(gpa, text[s..]));
    return out.items;
}

fn lowerDup(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try gpa.alloc(u8, s.len);
    for (s, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

const TokenCount = struct { tok: []const u8, count: u32 };

const DocEntry = struct {
    id: ir.RecordId,
    /// Distinct tokens, byte-sorted (the BTreeMap order of the reference).
    counts: []const TokenCount,
};

pub const Bm25Index = struct {
    field: []const u8,
    docs: []const DocEntry,
    n_docs: u32,
    total_tokens: u64,
    /// Document frequency per distinct token, byte-sorted.
    df: []const TokenCount,
    gpa: std.mem.Allocator,

    /// Build the index over `field` for the given records (canonical order).
    pub fn new(gpa: std.mem.Allocator, field: []const u8, records: []const ir.Record) !Bm25Index {
        var docs: std.ArrayList(DocEntry) = .empty;
        var df: std.ArrayList(TokenCount) = .empty;
        var n_docs: u32 = 0;
        var total_tokens: u64 = 0;

        for (records) |rec| {
            const text = bodyStr(rec.body, field) orelse continue;
            const toks = try tokenize(gpa, text);
            // Distinct counts, byte-sorted (BTreeMap<String, u32>).
            var counts: std.ArrayList(TokenCount) = .empty;
            for (toks) |t| {
                var found = false;
                for (counts.items) |*tc| {
                    if (std.mem.eql(u8, tc.tok, t)) {
                        tc.count += 1;
                        found = true;
                        break;
                    }
                }
                if (!found) try counts.append(gpa, .{ .tok = t, .count = 1 });
            }
            std.mem.sort(TokenCount, counts.items, {}, struct {
                fn lt(_: void, a: TokenCount, b: TokenCount) bool {
                    return std.mem.lessThan(u8, a.tok, b.tok);
                }
            }.lt);
            n_docs += 1;
            if (counts.items.len == 0) {
                // Empty string: length-0 document — in n_docs/avgdl, matches nothing.
                try docs.append(gpa, .{ .id = rec.id, .counts = counts.items });
                continue;
            }
            for (counts.items) |tc| {
                total_tokens += tc.count;
                // df: bump (or create) the token's document frequency.
                var found = false;
                for (df.items) |*d| {
                    if (std.mem.eql(u8, d.tok, tc.tok)) {
                        d.count += 1;
                        found = true;
                        break;
                    }
                }
                if (!found) try df.append(gpa, .{ .tok = tc.tok, .count = 1 });
            }
            try docs.append(gpa, .{ .id = rec.id, .counts = counts.items });
        }
        // Sort the document frequencies ONCE after the merge (df is read by
        // token equality — order never affects scores; the per-doc sort
        // cost O(n_docs · |df| log |df|) and dominated index builds).
        std.mem.sort(TokenCount, df.items, {}, struct {
            fn lt(_: void, a: TokenCount, b: TokenCount) bool {
                return std.mem.lessThan(u8, a.tok, b.tok);
            }
        }.lt);
        return .{
            .field = field,
            .docs = docs.items,
            .n_docs = n_docs,
            .total_tokens = total_tokens,
            .df = df.items,
            .gpa = gpa,
        };
    }

    fn bodyStr(body: []const ir.DocEntry, field: []const u8) ?[]const u8 {
        for (body) |e| {
            if (std.mem.eql(u8, e.key, field)) {
                return switch (e.value) {
                    .str => |s| s,
                    else => null,
                };
            }
        }
        return null;
    }

    fn tf(counts: []const TokenCount, tok: []const u8) f32 {
        for (counts) |tc| {
            if (std.mem.eql(u8, tc.tok, tok)) return @floatFromInt(tc.count);
        }
        return 0;
    }

    /// BM25 score of `id` against `query_tokens` (0.0 when unindexed).
    pub fn score(self: *const Bm25Index, id: ir.RecordId, query_tokens: []const []const u8) f32 {
        var counts: []const TokenCount = &[_]TokenCount{};
        // `docs` follows canonical record order (unique keys) → binary
        // search; a linear id scan here was O(n²) per query at scale.
        var lo: usize = 0;
        var hi: usize = self.docs.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (ir.RecordId.less(self.docs[mid].id, id)) lo = mid + 1 else hi = mid;
        }
        if (lo < self.docs.len and ir.recordIdEql(self.docs[lo].id, id)) {
            counts = self.docs[lo].counts;
        }
        var doc_len_f: f32 = 0;
        for (counts) |tc| doc_len_f += @floatFromInt(tc.count);
        if (counts.len == 0 or query_tokens.len == 0) return 0.0;
        if (doc_len_f == 0.0) return 0.0;
        if (self.n_docs == 0) return 0.0;

        const n: f32 = @floatFromInt(self.n_docs);
        const avgdl: f32 = @as(f32, @floatFromInt(self.total_tokens)) / @as(f32, @floatFromInt(@max(self.n_docs, 1)));
        var total: f32 = 0.0;
        // Sum each distinct query term once, in query order.
        var i: usize = 0;
        while (i < query_tokens.len) : (i += 1) {
            const tok = query_tokens[i];
            var seen = false;
            var j: usize = 0;
            while (j < i) : (j += 1) {
                if (std.mem.eql(u8, query_tokens[j], tok)) {
                    seen = true;
                    break;
                }
            }
            if (seen) continue;
            const f = tf(counts, tok);
            if (f == 0.0) continue;
            var df_tok: f32 = 0;
            for (self.df) |d| {
                if (std.mem.eql(u8, d.tok, tok)) {
                    df_tok = @floatFromInt(d.count);
                    break;
                }
            }
            if (df_tok < 1.0) df_tok = 1.0;
            // Natural log in f32 — bit-identical to Rust's `f32::ln` for the
            // corpus arguments (verified: musl-derived @log == glibc logf).
            const idf = @log(1.0 + (n - df_tok + 0.5) / (df_tok + 0.5));
            const len_norm = 1.0 - B + B * (doc_len_f / @max(avgdl, 1.0));
            total += idf * (f * (K1 + 1.0)) / (f + K1 * len_norm);
        }
        return total;
    }
};

test "tokenize matches the reference" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const toks = try tokenize(gpa, "Hello, WORLD!  123  hello-world #tag");
    const want = [_][]const u8{ "hello", "world", "123", "hello", "world", "tag" };
    try std.testing.expectEqual(want.len, toks.len);
    for (want, toks) |w, t| try std.testing.expectEqualStrings(w, t);
    try std.testing.expect((try tokenize(gpa, "  !!!  ,,, ")).len == 0);
}
