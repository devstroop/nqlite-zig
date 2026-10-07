//! Format-v4 container — spec/file-format.md §5.1–§5.6 (adopted target).
//!
//! Encoder mirrors the Rust fixture-gen oracle exactly (byte-deterministic:
//! zero padding, ascending tags, per-tag alignment, iff-non-empty presence);
//! decoder is loud on every §5.1 rule — bad magic/version/flags, bounds,
//! ordering, alignment, CRC32, required sections — never a partial load.
//!
//! Container structure (counts, offsets, entry fields, CLOCK) is fixed-width
//! little-endian (§5.1 "Fixed vs varint"); only payload bytes (bodies, edge
//! payloads, HISTORY verbatim) use §5.7 varints.

const std = @import("std");
const ir = @import("ir.zig");
const payload = @import("payload.zig");
const crc32mod = @import("crc32.zig");

pub const MAGIC = "NQLITE01";
pub const HEADER_LEN: u64 = 24;
pub const DIR_ENTRY_LEN: u64 = 32;
const V4: u32 = 4;

pub const Tag = enum(u32) {
    tables = 1,
    records = 2,
    strings = 3,
    embeds = 4,
    edges = 5,
    memories = 6,
    clock = 7,
    history = 8,
};

pub fn alignment(tag: u32) u64 {
    return switch (tag) {
        @backingInt(Tag.strings), @backingInt(Tag.embeds), @backingInt(Tag.history) => 4096,
        else => 8,
    };
}

fn alignUp(x: u64, a: u64) u64 {
    const rem = x % a;
    return if (rem == 0) x else x + (a - rem);
}

pub const Error = error{
    // §5.1 container rules
    Truncated,
    BadMagic,
    BadVersion,
    BadFlags,
    NonZeroReserved,
    ZeroLengthSection,
    Misaligned,
    Overlap,
    OutOfBounds,
    CrcMismatch,
    TrailingBytes,
    RequiredMissing,
    UnknownTag,
    NotAscending,
    ClockSize,
    // §5.3–§5.5 cross-references
    UndeclaredTable,
    TableIdxRange,
    EmbedWithoutDim,
    EmbedBeforeHeap,
    StringIdBeforeHeap,
    IdLenBad,
    BodyOutside,
    EdgeOutside,
    NonCanonical,
    BadIdKind,
    // writer-side (encoder inputs)
    DimMismatch,
    OutOfMemory,
} || payload.ReadError || payload.WriteError;

pub const DirEnt = struct {
    tag: u32,
    off: u64,
    len: u64,
    crc: u32,
};

// ---------------------------------------------------------------------------
// Encoder
// ---------------------------------------------------------------------------

const RecBuilt = struct {
    table_idx: u32,
    kind: u8,
    /// Numeric id (kind 0) or heap-relative STRINGS offset (kind 1).
    id_val: u64,
    id_len: u32,
    /// Section-relative body offset: 8 + 48·count + bytes of prior bodies.
    body_rel: u64,
    body: []const u8,
    embed_rel: ?u64,
    created_at: i64,
};

const SectionMeta = struct {
    tag: u32,
    len: usize,
    off: u64,
};

fn indexOfTable(tables: []const ir.TableEntry, name: []const u8) ?u32 {
    for (tables, 0..) |t, i| {
        if (std.mem.eql(u8, t.name, name)) return @intCast(i);
    }
    return null;
}

fn stagingOffset(secs: []const SectionMeta, tag: u32) ?usize {
    var acc: usize = 0;
    for (secs) |s| {
        if (s.tag == tag) return acc;
        acc += s.len;
    }
    return null;
}

pub fn encode(store: ir.Store, gpa: std.mem.Allocator) Error![]u8 {
    // ---- TABLES (always): names byte-wise sorted (validated) ----
    var tables_p = payload.Writer.init(gpa);
    defer tables_p.deinit();
    try tables_p.u64le(store.tables.len);
    {
        var prev: ?[]const u8 = null;
        for (store.tables) |t| {
            if (prev) |p| {
                if (std.mem.order(u8, p, t.name) != .lt) return error.NotAscending;
            }
            prev = t.name;
            try tables_p.str(t.name);
            const dim: u64 = if (t.vector_dim) |d| d else std.math.maxInt(u64);
            try tables_p.u64le(dim);
        }
    }

    // ---- RECORDS input: heaps packed in entry order ----
    var strings = payload.Writer.init(gpa);
    defer strings.deinit();
    var embeds = payload.Writer.init(gpa);
    defer embeds.deinit();

    const n_rec = store.records.len;
    var recs: std.ArrayList(RecBuilt) = .empty;
    defer recs.deinit(gpa);
    var bodies_len: u64 = 0;
    var prev_id: ?ir.RecordId = null;
    for (store.records) |rec| {
        if (prev_id) |p| {
            if (!ir.RecordId.less(p, rec.id)) return error.NonCanonical;
        }
        prev_id = rec.id;
        const ti = indexOfTable(store.tables, rec.id.table) orelse return error.UndeclaredTable;
        const dim = store.tables[ti].vector_dim;
        var kind: u8 = 0;
        var id_val: u64 = 0;
        var id_len: u32 = 0;
        switch (rec.id.id) {
            .num => |n| id_val = n,
            .str => |s| {
                kind = 1;
                id_val = strings.bytes().len;
                id_len = @intCast(s.len);
                try strings.raw(s);
            },
        }
        const embed_rel: ?u64 = if (rec.embedding) |emb| blk: {
            const d = dim orelse return error.EmbedWithoutDim;
            if (emb.len != d) return error.DimMismatch;
            const rel = embeds.bytes().len;
            for (emb) |f| try embeds.f32le(f);
            break :blk rel;
        } else null;
        var tmp = payload.Writer.init(gpa);
        defer tmp.deinit();
        try tmp.doc(rec.body);
        const body = try gpa.alloc(u8, tmp.bytes().len);
        @memcpy(body, tmp.bytes());
        const body_rel = 8 + 48 * n_rec + bodies_len;
        bodies_len += body.len;
        try recs.append(gpa, .{
            .table_idx = ti,
            .kind = kind,
            .id_val = id_val,
            .id_len = id_len,
            .body_rel = body_rel,
            .body = body,
            .embed_rel = embed_rel,
            .created_at = rec.created_at,
        });
    }
    // Bodies are gpa-allocated slices (stable across further growth).
    defer for (recs.items) |r| gpa.free(r.body);

    // ---- EDGES: payloads in APPEND order (§5.5) ----
    var edge_payloads: std.ArrayList(payload.Writer) = .empty;
    defer {
        for (edge_payloads.items) |*p| p.deinit();
        edge_payloads.deinit(gpa);
    }
    for (store.edges) |e| {
        var p = payload.Writer.init(gpa);
        try p.relationEdge(e);
        try edge_payloads.append(gpa, p);
    }
    const edge_dir_len: usize = 8 + 16 * edge_payloads.items.len;
    var edge_bytes: usize = 0;
    for (edge_payloads.items) |p| edge_bytes += p.bytes().len;

    // ---- MEMORIES: recursive blobs (names byte-wise sorted) ----
    var memories_p: ?payload.Writer = null;
    errdefer if (memories_p) |*mp| mp.deinit();
    if (store.memories.len > 0) {
        var m = payload.Writer.init(gpa);
        try m.u64le(store.memories.len);
        var prev: ?[]const u8 = null;
        for (store.memories) |mem| {
            if (prev) |p| {
                if (std.mem.order(u8, p, mem.name) != .lt) return error.NotAscending;
            }
            prev = mem.name;
            try m.str(mem.name);
            const blob = try encode(mem.store, gpa);
            defer gpa.free(blob);
            try m.u64le(blob.len);
            try m.raw(blob);
        }
        memories_p = m;
    }

    // ---- CLOCK (fixed i64 LE), HISTORY (§5.6 verbatim postcard vec) ----
    var clock_p = payload.Writer.init(gpa);
    defer clock_p.deinit();
    try clock_p.i64le(store.clock);
    var history_p: ?payload.Writer = null;
    errdefer if (history_p) |*hp| hp.deinit();
    if (store.history.len > 0) {
        var h = payload.Writer.init(gpa);
        try h.historyVec(store.history);
        history_p = h;
    }

    // ---- Presence (§5.1 errata) ----
    var sections: std.ArrayList(SectionMeta) = .empty;
    defer sections.deinit(gpa);
    try sections.append(gpa, .{ .tag = @backingInt(Tag.tables), .len = tables_p.bytes().len, .off = 0 });
    try sections.append(gpa, .{ .tag = @backingInt(Tag.records), .len = 8 + 48 * n_rec + bodies_len, .off = 0 });
    if (strings.bytes().len > 0)
        try sections.append(gpa, .{ .tag = @backingInt(Tag.strings), .len = strings.bytes().len, .off = 0 });
    if (embeds.bytes().len > 0)
        try sections.append(gpa, .{ .tag = @backingInt(Tag.embeds), .len = embeds.bytes().len, .off = 0 });
    if (edge_payloads.items.len > 0)
        try sections.append(gpa, .{ .tag = @backingInt(Tag.edges), .len = edge_dir_len + edge_bytes, .off = 0 });
    if (memories_p) |*mp|
        try sections.append(gpa, .{ .tag = @backingInt(Tag.memories), .len = mp.bytes().len, .off = 0 });
    try sections.append(gpa, .{ .tag = @backingInt(Tag.clock), .len = clock_p.bytes().len, .off = 0 });
    if (history_p) |*hp|
        try sections.append(gpa, .{ .tag = @backingInt(Tag.history), .len = hp.bytes().len, .off = 0 });

    // ---- Layout: ascending tags, per-tag alignment, zero gaps ----
    const table_end = HEADER_LEN + DIR_ENTRY_LEN * sections.items.len;
    var cursor: u64 = table_end;
    for (sections.items) |*s| {
        const off = alignUp(cursor, alignment(s.tag));
        s.off = off;
        cursor = off + s.len;
    }
    const baseOf = struct {
        fn call(secs: []const SectionMeta, tag: u32) ?u64 {
            for (secs) |s| if (s.tag == tag) return s.off;
            return null;
        }
    }.call;
    const recs_base = baseOf(sections.items, @backingInt(Tag.records)).?;
    const str_base = baseOf(sections.items, @backingInt(Tag.strings));
    const emb_base = baseOf(sections.items, @backingInt(Tag.embeds));
    const edges_base = baseOf(sections.items, @backingInt(Tag.edges));

    // ---- Header + zeroed section table, then staged payloads ----
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.appendSlice(gpa, MAGIC);
    try appendU32le(&out, gpa, V4);
    try appendU32le(&out, gpa, 0); // flags = 0
    try appendU32le(&out, gpa, @intCast(sections.items.len));
    try appendU32le(&out, gpa, 0); // reserved = 0
    const dir_start = out.items.len;
    try out.appendNTimes(gpa, 0, DIR_ENTRY_LEN * sections.items.len);

    var staged: std.ArrayList(u8) = .empty;
    defer staged.deinit(gpa);

    try staged.appendSlice(gpa, tables_p.bytes());
    {
        var rp = payload.Writer.init(gpa);
        defer rp.deinit();
        try rp.u64le(n_rec);
        for (recs.items) |r| {
            try rp.u32le(r.table_idx);
            try rp.byte(r.kind);
            try rp.byte(0); // reserved
            try rp.raw(&[_]u8{ 0, 0 }); // u16 pad
            const id_val: u64 = switch (r.kind) {
                0 => r.id_val,
                else => (str_base orelse return error.StringIdBeforeHeap) + r.id_val,
            };
            try rp.u64le(id_val);
            try rp.u32le(r.id_len);
            try rp.u32le(@intCast(r.body.len));
            try rp.u64le(recs_base + r.body_rel);
            const embed_off: u64 = if (r.embed_rel) |rel|
                (emb_base orelse return error.EmbedBeforeHeap) + rel
            else
                std.math.maxInt(u64);
            try rp.u64le(embed_off);
            try rp.i64le(r.created_at);
        }
        for (recs.items) |r| try rp.raw(r.body);
        try staged.appendSlice(gpa, rp.bytes());
    }
    if (strings.bytes().len > 0) try staged.appendSlice(gpa, strings.bytes());
    if (embeds.bytes().len > 0) try staged.appendSlice(gpa, embeds.bytes());
    if (edge_payloads.items.len > 0) {
        var ep = payload.Writer.init(gpa);
        defer ep.deinit();
        try ep.u64le(edge_payloads.items.len);
        const eb = edges_base.?;
        var rel: u64 = edge_dir_len;
        for (edge_payloads.items) |p| {
            try ep.u64le(eb + rel);
            try ep.u32le(@intCast(p.bytes().len));
            try ep.u32le(0);
            rel += p.bytes().len;
        }
        for (edge_payloads.items) |p| try ep.raw(p.bytes());
        try staged.appendSlice(gpa, ep.bytes());
    }
    if (memories_p) |*mp| try staged.appendSlice(gpa, mp.bytes());
    try staged.appendSlice(gpa, clock_p.bytes());
    if (history_p) |*hp| try staged.appendSlice(gpa, hp.bytes());
    {
        var total: usize = 0;
        for (sections.items) |s| total += s.len;
        if (staged.items.len != total) return error.Overlap;
    }

    // ---- Section table entries (tag, reserved, off, len, crc32, pad) ----
    var i: usize = 0;
    while (i < sections.items.len) : (i += 1) {
        const s = sections.items[i];
        const pstart = stagingOffset(sections.items, s.tag).?;
        const entry = dir_start + DIR_ENTRY_LEN * i;
        var e = payload.Writer.init(gpa);
        defer e.deinit();
        try e.u32le(s.tag);
        try e.u32le(0);
        try e.u64le(s.off);
        try e.u64le(s.len);
        try e.u32le(crc32mod.crc32(staged.items[pstart .. pstart + s.len]));
        try e.u32le(0);
        @memcpy(out.items[entry .. entry + DIR_ENTRY_LEN], e.bytes());
    }

    // ---- Zero-gapped payload placement (file ends at last section) ----
    for (sections.items) |s| {
        if (out.items.len > s.off) return error.Overlap;
        try out.appendNTimes(gpa, 0, s.off - out.items.len);
        const pstart = stagingOffset(sections.items, s.tag).?;
        try out.appendSlice(gpa, staged.items[pstart .. pstart + s.len]);
    }
    if (out.items.len != cursor) return error.Overlap;
    return out.toOwnedSlice(gpa);
}

fn appendU32le(list: *std.ArrayList(u8), gpa: std.mem.Allocator, v: u32) payload.WriteError!void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, v, .little);
    try list.appendSlice(gpa, &buf);
}

// ---------------------------------------------------------------------------
// Decoder
// ---------------------------------------------------------------------------

pub fn parseDir(bytes: []const u8) Error![]DirEnt {
    const gpa = std.heap.page_allocator;
    if (bytes.len < HEADER_LEN) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..8], MAGIC)) return error.BadMagic;
    const version = std.mem.readInt(u32, bytes[8..12], .little);
    if (version != V4) return error.BadVersion;
    if (std.mem.readInt(u32, bytes[12..16], .little) != 0) return error.BadFlags;
    const n: usize = std.mem.readInt(u32, bytes[16..20], .little);
    if (std.mem.readInt(u32, bytes[20..24], .little) != 0) return error.NonZeroReserved;
    const table_end = HEADER_LEN + DIR_ENTRY_LEN * n;
    if (table_end > bytes.len) return error.Truncated;

    var out: std.ArrayList(DirEnt) = .empty;
    errdefer out.deinit(gpa);
    var prev_tag: u32 = 0;
    var prev_end: u64 = table_end;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const e0: usize = @intCast(HEADER_LEN + DIR_ENTRY_LEN * i);
        const e = bytes[e0 .. e0 + DIR_ENTRY_LEN];
        const tag = std.mem.readInt(u32, e[0..4], .little);
        if (tag < 1 or tag > 8) return error.UnknownTag;
        if (tag <= prev_tag) return error.NotAscending;
        prev_tag = tag;
        if (std.mem.readInt(u32, e[4..8], .little) != 0 or std.mem.readInt(u32, e[28..32], .little) != 0)
            return error.NonZeroReserved;
        const off = std.mem.readInt(u64, e[8..16], .little);
        const len = std.mem.readInt(u64, e[16..24], .little);
        const c = std.mem.readInt(u32, e[24..28], .little);
        if (len == 0) return error.ZeroLengthSection;
        if (off % alignment(tag) != 0) return error.Misaligned;
        if (off < prev_end) return error.Overlap;
        const end = off +| len;
        if (end > bytes.len) return error.OutOfBounds;
        if (crc32mod.crc32(bytes[off..end]) != c) return error.CrcMismatch;
        try out.append(gpa, .{ .tag = tag, .off = off, .len = len, .crc = c });
        prev_end = end;
    }
    if (prev_end != bytes.len) return error.TrailingBytes;
    for ([_]u32{ 1, 2, 7 }) |req| {
        var found = false;
        for (out.items) |e| {
            if (e.tag == req) found = true;
        }
        if (!found) return error.RequiredMissing;
    }
    return out.toOwnedSlice(gpa);
}

fn findSection(dir: []const DirEnt, tag: u32) ?DirEnt {
    for (dir) |e| if (e.tag == tag) return e;
    return null;
}

pub fn decode(bytes: []const u8, gpa: std.mem.Allocator) Error!ir.Store {
    const dir = try parseDir(bytes);
    defer std.heap.page_allocator.free(dir);

    const clock_e = findSection(dir, @backingInt(Tag.clock)).?;
    if (clock_e.len != 8) return error.ClockSize;
    const clock = std.mem.readInt(i64, bytes[clock_e.off .. clock_e.off + 8][0..8], .little);

    // TABLES (§5.3): fixed u64 LE count, names strictly ascending.
    const tables_e = findSection(dir, @backingInt(Tag.tables)).?;
    var tp = payload.Reader.init(bytes[tables_e.off .. tables_e.off + tables_e.len]);
    const tcount = std.math.cast(usize, try tp.u64le()) orelse return error.UlebOverflow;
    const tables = try gpa.alloc(ir.TableEntry, tcount);
    errdefer gpa.free(tables);
    var prev_name: ?[]const u8 = null;
    for (tables) |*t| {
        const name = try tp.str();
        if (prev_name) |p| {
            if (std.mem.order(u8, p, name) != .lt) return error.NotAscending;
        }
        prev_name = name;
        const dim = try tp.u64le();
        t.* = .{ .name = name, .vector_dim = if (dim == std.math.maxInt(u64)) null else @intCast(dim) };
    }
    if (tp.pos != tp.bytes.len) return error.Trailing;

    const strings_e = findSection(dir, @backingInt(Tag.strings));
    const embeds_e = findSection(dir, @backingInt(Tag.embeds));

    // RECORDS (§5.4): [u64 count][n × 48B][bodies].
    const recs_e = findSection(dir, @backingInt(Tag.records)).?;
    const rec_bytes = bytes[recs_e.off .. recs_e.off + recs_e.len];
    var rp = payload.Reader.init(rec_bytes);
    const n_rec = std.math.cast(usize, try rp.u64le()) orelse return error.UlebOverflow;
    const dir_end: usize = 8 + 48 * n_rec;
    if (rec_bytes.len < dir_end) return error.Truncated;

    var records: std.ArrayList(ir.Record) = .empty;
    errdefer records.deinit(gpa);
    var prev_id: ?ir.RecordId = null;
    var ri: usize = 0;
    while (ri < n_rec) : (ri += 1) {
        const e = try rp.take(48);
        const table_idx: usize = std.mem.readInt(u32, e[0..4], .little);
        const kind = e[4];
        if (e[5] != 0 or std.mem.readInt(u16, e[6..8], .little) != 0) return error.NonZeroReserved;
        if (kind > 1) return error.BadIdKind;
        const id_val = std.mem.readInt(u64, e[8..16], .little);
        const id_len = std.mem.readInt(u32, e[16..20], .little);
        const body_len: u64 = std.mem.readInt(u32, e[20..24], .little);
        const body_off = std.mem.readInt(u64, e[24..32], .little);
        const embed_off = std.mem.readInt(u64, e[32..40], .little);
        const created_at = std.mem.readInt(i64, e[40..48], .little);

        if (table_idx >= tables.len) return error.TableIdxRange;
        const table = tables[table_idx];
        const id: ir.Id = switch (kind) {
            0 => blk: {
                if (id_len != 0) return error.IdLenBad;
                break :blk .{ .num = id_val };
            },
            else => blk: {
                const se = strings_e orelse return error.StringIdBeforeHeap;
                if (id_val < se.off) return error.StringIdBeforeHeap;
                const rel = id_val - se.off;
                if (rel + id_len > se.len) return error.StringIdBeforeHeap;
                const s = bytes[se.off + rel .. se.off + rel + id_len];
                if (!std.unicode.utf8ValidateSlice(s)) return error.Utf8Invalid;
                break :blk .{ .str = s };
            },
        };

        if (body_off < recs_e.off + dir_end or body_off + body_len > recs_e.off + recs_e.len)
            return error.BodyOutside;
        const body_slice = bytes[body_off .. body_off + body_len];
        var br = payload.Reader.init(body_slice);
        const body = try br.docInto(gpa);
        if (br.pos != body_slice.len) return error.Trailing;

        const embedding: ?[]const f32 = if (embed_off == std.math.maxInt(u64))
            null
        else blk: {
            const d = table.vector_dim orelse return error.EmbedWithoutDim;
            const se = embeds_e orelse return error.EmbedBeforeHeap;
            if (embed_off < se.off) return error.EmbedBeforeHeap;
            const rel = embed_off - se.off;
            const bytes_len: u64 = @as(u64, @intCast(d)) * 4;
            if (rel + bytes_len > se.len) return error.EmbedBeforeHeap;
            const heap = bytes[se.off + rel .. se.off + rel + bytes_len];
            const vec = try gpa.alloc(f32, d);
            var k: usize = 0;
            while (k < d) : (k += 1) {
                vec[k] = @bitCast(std.mem.readInt(u32, heap[k * 4 ..][0..4], .little));
            }
            break :blk vec;
        };

        const rid = ir.RecordId{ .table = table.name, .id = id };
        if (prev_id) |p| {
            if (!ir.RecordId.less(p, rid)) return error.NonCanonical;
        }
        prev_id = rid;
        try records.append(gpa, .{
            .id = rid,
            .body = body,
            .embedding = embedding,
            .created_at = created_at,
        });
    }
    const records_out = try records.toOwnedSlice(gpa);
    errdefer gpa.free(records_out);

    // EDGES (§5.5): append order, payloads after the index.
    var edges: std.ArrayList(ir.RelationEdge) = .empty;
    errdefer edges.deinit(gpa);
    if (findSection(dir, @backingInt(Tag.edges))) |ed_e| {
        const ed_bytes = bytes[ed_e.off .. ed_e.off + ed_e.len];
        var er = payload.Reader.init(ed_bytes);
        const n_e = std.math.cast(usize, try er.u64le()) orelse return error.UlebOverflow;
        const idx_end: usize = 8 + 16 * n_e;
        if (ed_bytes.len < idx_end) return error.Truncated;
        var offs = try gpa.alloc(u64, n_e);
        defer gpa.free(offs);
        var lens = try gpa.alloc(u64, n_e);
        defer gpa.free(lens);
        var ei: usize = 0;
        while (ei < n_e) : (ei += 1) {
            offs[ei] = try er.u64le();
            lens[ei] = try er.u32le();
            const pad = try er.u32le();
            if (pad != 0) return error.NonZeroReserved;
        }
        for (offs, lens) |off, len| {
            if (off < ed_e.off + idx_end or off + len > ed_e.off + ed_e.len)
                return error.EdgeOutside;
            const s = bytes[off .. off + len];
            var pr = payload.Reader.init(s);
            const e = try pr.relationEdge(gpa);
            if (pr.pos != s.len) return error.Trailing;
            try edges.append(gpa, e);
        }
    }
    const edges_out = try edges.toOwnedSlice(gpa);
    errdefer gpa.free(edges_out);

    // MEMORIES (§5.2): recursive complete §5 layouts, names sorted.
    var memories: std.ArrayList(ir.Memory) = .empty;
    errdefer memories.deinit(gpa);
    if (findSection(dir, @backingInt(Tag.memories))) |me| {
        var mr = payload.Reader.init(bytes[me.off .. me.off + me.len]);
        const n_m = std.math.cast(usize, try mr.u64le()) orelse return error.UlebOverflow;
        var prev: ?[]const u8 = null;
        var mi: usize = 0;
        while (mi < n_m) : (mi += 1) {
            const name = try mr.str();
            if (prev) |p| {
                if (std.mem.order(u8, p, name) != .lt) return error.NotAscending;
            }
            prev = name;
            const len = std.math.cast(usize, try mr.u64le()) orelse return error.UlebOverflow;
            const blob = try mr.take(len);
            const sub = try decode(blob, gpa);
            try memories.append(gpa, .{ .name = name, .store = sub });
        }
        if (mr.pos != mr.bytes.len) return error.Trailing;
    }
    const memories_out = try memories.toOwnedSlice(gpa);
    errdefer gpa.free(memories_out);

    // HISTORY (§5.6): absent = empty (§5.1 errata).
    var history: []const ir.HistoryEntry = &[_]ir.HistoryEntry{};
    if (findSection(dir, @backingInt(Tag.history))) |he| {
        const h_bytes = bytes[he.off .. he.off + he.len];
        var hr = payload.Reader.init(h_bytes);
        history = try hr.historyVecInto(gpa);
        if (hr.pos != h_bytes.len) return error.Trailing;
    }

    return .{
        .tables = tables,
        .records = records_out,
        .edges = edges_out,
        .clock = clock,
        .history = history,
        .memories = memories_out,
    };
}
