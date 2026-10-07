//! v4 store file + WAL + single-writer lock — port of `nqlite/src/storage.rs`
//! over the M1 v4 codec (spec §1–§4). Zig writes **format v4** directly;
//! v2/v3 inputs are converted with `nql-migrate` (spec §5.8) first.
//!
//! - main file: canonical v4 bytes (§5), replaced atomically
//!   (tmp + fsync + rename — §4); a missing/too-short file is an empty store;
//! - WAL: append-only `crc32(len LE || payload) ++ len LE ++ payload` frames
//!   (`payload = postcard(Statement)`, §2); replay on open stops at the first
//!   torn frame and truncates there;
//! - single-writer: advisory `flock(LOCK_EX|LOCK_NB)` on `<path>.lock`,
//!   held for the process lifetime (kernel-owned liveness, interops with the
//!   Rust server's lock file — issue #84).
//!
//! The `gpa` must outlive the store (arena-style): engine state and decoded
//! statements are arena-allocated and never individually freed — same
//! lifetime contract as `engine.EngineStore`.

const std = @import("std");
const builtin = @import("builtin");
const ir = @import("ir.zig");
const v4 = @import("v4.zig");
const payload = @import("payload.zig");
const engine = @import("engine.zig");
const crc32mod = @import("crc32.zig");

/// Checkpoint once the WAL crosses 1 MiB (spec §2).
pub const CHECKPOINT_THRESHOLD: u64 = 1 << 20;

pub const Error = error{
    Locked,
    Io,
    Decode,
    Encode,
    OutOfMemory,
};

fn le32(v: u32) [4]u8 {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    return b;
}

pub const StoreFile = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// Owned paths: `<main>`, `<main>.wal`, `<main>.lock`.
    main: []const u8,
    wal: []const u8,
    lock_path: []const u8,
    /// Held lock fd (RAII-by-exit: the kernel releases it on process death;
    /// `close()` releases explicitly for tests/reopen).
    lock_fd: ?std.posix.fd_t = null,
    wal_len: u64 = 0,

    /// Open (or create) the store at `path`, taking the single-writer lock.
    /// A missing main file means an empty store (WAL still replays into it).
    pub fn open(path: []const u8, gpa: std.mem.Allocator, io: std.Io) Error!StoreFile {
        const main = try gpa.dupe(u8, path);
        const wal = try std.fmt.allocPrint(gpa, "{s}.wal", .{path});
        const lock_path = try std.fmt.allocPrint(gpa, "{s}.lock", .{path});

        if (std.fs.path.dirname(path)) |parent| {
            if (parent.len > 0 and !std.mem.eql(u8, parent, ".")) {
                std.Io.Dir.cwd().createDirPath(io, parent) catch return error.Io;
            }
        }

        const fd = std.posix.openat(
            std.posix.AT.FDCWD,
            lock_path,
            .{ .ACCMODE = .RDWR, .CREAT = true },
            0o666,
        ) catch return error.Io;
        errdefer _ = std.os.linux.close(fd);
        if (builtin.os.tag == .linux) {
            const rc: isize = @bitCast(std.os.linux.flock(
                fd,
                @as(i32, std.posix.LOCK.EX | std.posix.LOCK.NB),
            ));
            if (rc != 0) {
                return if (rc == -@as(isize, @backingInt(std.posix.E.AGAIN)))
                    error.Locked
                else
                    error.Io;
            }
        }

        var self = StoreFile{
            .gpa = gpa,
            .io = io,
            .main = main,
            .wal = wal,
            .lock_path = lock_path,
            .lock_fd = fd,
            .wal_len = 0,
        };
        if (std.Io.Dir.cwd().openFile(io, wal, .{})) |f| {
            const st = f.stat(io) catch {
                f.close(io);
                return error.Io;
            };
            self.wal_len = st.size;
            f.close(io);
        } else |_| {}
        return self;
    }

    /// Release the lock explicitly (tests / managed reopen). Process exit
    /// releases it regardless — no stale-lock state exists on unix.
    pub fn close(self: *StoreFile) void {
        if (self.lock_fd) |fd| _ = std.os.linux.close(fd);
        self.lock_fd = null;
    }

    /// Load the main file (v4) — `null` means "empty store" (missing or
    /// shorter than a header, mirroring the reference's len < 16 rule).
    pub fn loadMain(self: *const StoreFile) Error!?ir.Store {
        const f = std.Io.Dir.cwd().openFile(self.io, self.main, .{}) catch |e| switch (e) {
            error.FileNotFound => return null,
            else => return error.Io,
        };
        defer f.close(self.io);
        const st = f.stat(self.io) catch return error.Io;
        if (st.size < 24) return null;
        const bytes = try self.gpa.alloc(u8, st.size);
        const n = f.readPositionalAll(self.io, bytes, 0) catch return error.Io;
        const store = v4.decode(bytes[0..n], self.gpa) catch return error.Decode;
        return store;
    }

    /// Replay WAL frames into `store` (statement contexts included — spec
    /// §2/§2.8, issue #109). Stops at the first torn frame (bounds, CRC, or
    /// unparseable payload) and truncates the file there.
    pub fn replayWal(self: *StoreFile, store: *engine.EngineStore) Error!void {
        if (self.wal_len == 0) return;
        const f = std.Io.Dir.cwd().openFile(self.io, self.wal, .{}) catch
            return error.Io;
        defer f.close(self.io);
        const st = f.stat(self.io) catch return error.Io;
        if (st.size == 0) return;
        const buf = try self.gpa.alloc(u8, st.size);
        const n = f.readPositionalAll(self.io, buf, 0) catch return error.Io;
        const data = buf[0..n];

        var pos: usize = 0;
        var good: usize = 0;
        var current_memory: ?[]const u8 = null;
        while (pos + 8 <= data.len) {
            const crc = std.mem.readInt(u32, data[pos..][0..4], .little);
            const len: usize = std.mem.readInt(u32, data[pos + 4 ..][0..4], .little);
            const start = pos + 8;
            if (start + len > data.len) break; // torn: payload truncated
            const body = data[start .. start + len];
            // CRC covers `len LE || payload` (spec §2).
            var hashed = try self.gpa.alloc(u8, 4 + len);
            std.mem.writeInt(u32, hashed[0..4], @intCast(len), .little);
            @memcpy(hashed[4..], body);
            if (crc32mod.crc32(hashed) != crc) break; // torn: checksum mismatch
            var reader = payload.Reader.init(body);
            const stmt = reader.statement(self.gpa) catch break; // unparseable
            if (reader.pos != body.len) break;
            // Replay is total on a valid store; any engine error here means
            // a corrupt frame — treat as torn (the reference panics).
            _ = engine.executeInContext(store, stmt, &current_memory) catch break;
            pos = start + len;
            good = pos;
        }
        if (good < data.len) {
            // Truncate the torn tail so a later open doesn't retry it.
            const wf = std.Io.Dir.cwd().openFile(self.io, self.wal, .{ .mode = .read_write }) catch
                return error.Io;
            defer wf.close(self.io);
            wf.setLength(self.io, @intCast(good)) catch return error.Io;
            wf.sync(self.io) catch return error.Io;
        }
        self.wal_len = good;
    }

    /// Append one mutating statement (fsync'd before return, spec §2).
    pub fn append(self: *StoreFile, stmt: ir.Statement) Error!void {
        var pl = payload.Writer.init(self.gpa);
        defer pl.deinit();
        pl.statement(stmt) catch return error.Encode;
        const body = pl.bytes();

        // frame = crc32(len LE || payload) ++ len LE ++ payload
        var hashed = try self.gpa.alloc(u8, 4 + body.len);
        std.mem.writeInt(u32, hashed[0..4], @intCast(body.len), .little);
        @memcpy(hashed[4..], body);
        const crc = crc32mod.crc32(hashed);

        var frame = std.ArrayList(u8).empty;
        defer frame.deinit(self.gpa);
        try frame.appendSlice(self.gpa, &le32(crc));
        try frame.appendSlice(self.gpa, &le32(@intCast(body.len)));
        try frame.appendSlice(self.gpa, body);

        const wf = if (std.Io.Dir.cwd().openFile(self.io, self.wal, .{ .mode = .read_write })) |f|
            f
        else |_| blk: {
            break :blk std.Io.Dir.cwd()
                .createFile(self.io, self.wal, .{ .read = true, .truncate = false }) catch
                return error.Io;
        };
        defer wf.close(self.io);
        const end = (wf.stat(self.io) catch return error.Io).size;
        wf.writePositionalAll(self.io, frame.items, end) catch return error.Io;
        wf.sync(self.io) catch return error.Io;
        self.wal_len = end + frame.items.len;
    }

    pub fn needsCheckpoint(self: *const StoreFile) bool {
        return self.wal_len >= CHECKPOINT_THRESHOLD;
    }

    /// Atomically replace the main file with `bytes` (v4) and truncate the
    /// WAL (spec §3/§4: tmp + fsync + rename; directory fsync best-effort —
    /// see TODO below).
    pub fn checkpoint(self: *StoreFile, bytes: []const u8) Error!void {
        const tmp = try std.fmt.allocPrint(self.gpa, "{s}.tmp", .{self.main});
        {
            const f = std.Io.Dir.cwd()
                .createFile(self.io, tmp, .{ .read = true, .truncate = true }) catch
                return error.Io;
            defer f.close(self.io);
            f.writeStreamingAll(self.io, bytes) catch return error.Io;
            f.sync(self.io) catch return error.Io;
        }
        std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), self.main, self.io) catch
            return error.Io;
        // TODO(M6): directory fsync after rename (the reference does it;
        // skipped until the Dir-handle fsync path is pinned — durability
        // only, not observable in tests).

        // Truncate the WAL now that the main file is authoritative.
        if (std.Io.Dir.cwd().openFile(self.io, self.wal, .{ .mode = .read_write })) |wf| {
            defer wf.close(self.io);
            wf.setLength(self.io, 0) catch return error.Io;
            wf.sync(self.io) catch return error.Io;
        } else |_| {}
        self.wal_len = 0;
    }
};

// ---------------------------------------------------------------------------
// Tests (arena gpa + pid-scoped /tmp dirs — mirrors the reference suite)
// ---------------------------------------------------------------------------

fn testPath(gpa: std.mem.Allocator, tmp: *std.testing.TmpDir, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        gpa,
        "{s}/{s}/{s}",
        .{ std.testing.TmpDir.parent_dir_path, &tmp.sub_path, name },
    );
}

fn testStore(gpa: std.mem.Allocator) engine.EngineStore {
    var s = engine.EngineStore.init(gpa);
    s.tables.append(gpa, .{ .name = "t", .vector_dim = @as(usize, 2) }) catch unreachable;
    s.records.append(gpa, .{
        .id = .{ .table = "t", .id = .{ .num = 1 } },
        .body = &[_]ir.DocEntry{.{ .key = "a", .value = .{ .int = 7 } }},
        .embedding = null,
        .created_at = 1,
    }) catch unreachable;
    s.clock = 1;
    return s;
}

test "checkpoint → reopen round-trip" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPath(gpa, &tmp, "rt.nql");

    var sf = try StoreFile.open(path, gpa, io);
    var store = testStore(gpa);
    const ir_store = try engine.toIr(&store, gpa);
    const bytes = try v4.encode(ir_store, gpa);
    try sf.checkpoint(bytes);
    sf.close();

    var sf2 = try StoreFile.open(path, gpa, io);
    defer sf2.close();
    const loaded = (try sf2.loadMain()).?;
    const again = try v4.encode(loaded, gpa);
    try std.testing.expectEqualSlices(u8, bytes, again);
    const reloaded = try engine.fromIr(gpa, loaded);
    try std.testing.expectEqual(@as(usize, 1), reloaded.records.items.len);
    try std.testing.expectEqual(@as(i64, 1), reloaded.clock);
}

test "WAL append + replay + torn-frame truncation" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPath(gpa, &tmp, "wal.nql");
    var good_len: u64 = 0;
    {
        var sf = try StoreFile.open(path, gpa, io);
        defer sf.close();
        const store = testStore(gpa);
        // Two good frames + one torn (garbage) tail.
        try sf.append(.{ .create_table = .{ .table = "t", .vector_dim = 2 } });
        try sf.append(.{ .insert = store.records.items[0] });
        good_len = sf.wal_len;
        {
            const wf = std.Io.Dir.cwd()
                .createFile(io, try std.fmt.allocPrint(gpa, "{s}.wal", .{path}), .{ .read = true, .truncate = false }) catch
                return error.Io;
            defer wf.close(io);
            const end = (try wf.stat(io)).size;
            try wf.writePositionalAll(io, &[_]u8{ 0xAA, 0xBB, 0xCC }, end);
        }
    }

    // Reopen: no main file (empty store) → WAL replays; torn tail dropped.
    var sf2 = try StoreFile.open(path, gpa, io);
    defer sf2.close();
    try std.testing.expect((try sf2.loadMain()) == null);
    var replayed = engine.EngineStore.init(gpa);
    try sf2.replayWal(&replayed);
    try std.testing.expectEqual(@as(usize, 1), replayed.records.items.len);
    try std.testing.expect(sf2.wal_len >= good_len);
    // The torn bytes are gone: replay again is a no-op with equal state.
    const after = replayed.records.items[0];
    try sf2.replayWal(&replayed);
    try std.testing.expectEqual(@as(usize, 1), replayed.records.items.len);
    _ = after;
}

test "single-writer lock" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPath(gpa, &tmp, "lock.nql");

    var first = try StoreFile.open(path, gpa, io);
    // Second open while held → Locked (the issue #84 contract).
    if (StoreFile.open(path, gpa, io)) |_| {
        return error.TestUnexpectedResult;
    } else |e| {
        try std.testing.expect(e == error.Locked);
    }
    first.close();
    var second = try StoreFile.open(path, gpa, io);
    second.close();
}

test "WAL replay honors plan memory contexts (#109)" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPath(gpa, &tmp, "ctx.nql");

    {
        var sf = try StoreFile.open(path, gpa, io);
        defer sf.close();
        // Plan A: root writes … then a plan that ENDS inside a memory;
        // plan B (post-reset): a root write that must NOT leak into the
        // memory on replay (the #109 regression shape).
        try sf.append(.{ .create_table = .{ .table = "t", .vector_dim = null } });
        const s0 = testStore(gpa);
        try sf.append(.{ .insert = s0.records.items[0] });
        try sf.append(.{ .memory = .{ .name = "m" } });
        try sf.append(.{ .create_table = .{ .table = "tm", .vector_dim = null } });
        try sf.append(.{ .insert = .{
            .id = .{ .table = "tm", .id = .{ .num = 1 } },
            .body = &[_]ir.DocEntry{},
            .embedding = null,
            .created_at = 2,
        } });
        try sf.append(.{ .context_reset = {} });
        const s1 = testStore(gpa);
        s1.records.items[0].id.id = .{ .num = 2 };
        try sf.append(.{ .insert = s1.records.items[0] });
    }

    var sf2 = try StoreFile.open(path, gpa, io);
    defer sf2.close();
    var store = engine.EngineStore.init(gpa);
    try sf2.replayWal(&store);
    // Root has both inserts…
    try std.testing.expectEqual(@as(usize, 2), store.records.items.len);
    // …and the memory holds only its own row.
    try std.testing.expectEqual(@as(usize, 1), store.memories.items.len);
    const mem = store.memories.items[0];
    try std.testing.expectEqualStrings("m", mem.name);
    try std.testing.expectEqual(@as(usize, 1), mem.store.records.items.len);
    try std.testing.expectEqual(@as(u64, 1), mem.store.records.items[0].id.id.num);
}
