//! NQL tokenizer (spec/nql.md §1) — port of `nql/src/lexer.rs`.
//!
//! Keywords are NOT distinguished: they arrive as `ident` and the parser
//! matches case-insensitively. Positions are 1-based, counted in BYTES
//! (matching the Rust reference, including inside UTF-8 text). Line
//! comments are only recognized in skip position, so `-1` and `->` lex as
//! tokens while a surviving bare `-` is a positioned lex error.

const std = @import("std");

pub const Token = union(enum) {
    ident: []const u8, // keyword, table/field name, `f32`, ...
    int: i64,
    float: f64,
    str: []const u8, // decoded (escapes applied)
    l_paren,
    r_paren,
    l_brace,
    r_brace,
    l_bracket,
    r_bracket,
    semi, // `;`
    comma,
    arrow, // `->`
    left_arrow, // `<-`
    plus,
    colon, // `:`
    double_colon, // `::`
    eq,
    ne, // `!=`
    lt,
    le,
    gt,
    ge,
    star,
    eof,
};

pub const Spanned = struct {
    tok: Token,
    line: usize,
    col: usize,
};

/// Lex failure with 1-based position (message mirrors the Rust wording;
/// only kind/line/col are corpus-gated).
pub const LexFail = struct {
    line: usize,
    col: usize,
    message: []const u8,
};

pub const LexResult = union(enum) {
    ok: []Spanned,
    err: LexFail,
};

fn isIdentStart(b: u8) bool {
    return std.ascii.isAlphabetic(b) or b == '_';
}

fn isIdentContinue(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_';
}

/// Number of bytes in a UTF-8 leading byte (Rust `utf8_len`).
fn utf8Len(b: u8) usize {
    if (b >= 0xF0) return 4;
    if (b >= 0xE0) return 3;
    if (b >= 0xC0) return 2;
    return 1;
}

const Lexer = struct {
    src: []const u8,
    gpa: std.mem.Allocator,
    pos: usize = 0,
    line: usize = 1,
    col: usize = 1,
    fail: ?LexFail = null,

    fn peek(self: *const Lexer) ?u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else null;
    }

    fn peek2(self: *const Lexer) ?u8 {
        return if (self.pos + 1 < self.src.len) self.src[self.pos + 1] else null;
    }

    fn bump(self: *Lexer) ?u8 {
        const b = self.peek() orelse return null;
        self.pos += 1;
        if (b == '\n') {
            self.line += 1;
            self.col = 1;
        } else {
            self.col += 1;
        }
        return b;
    }

    fn failAt(self: *Lexer, line: usize, col: usize, comptime fmt: []const u8, args: anytype) error{Lex} {
        self.fail = .{
            .line = line,
            .col = col,
            .message = std.fmt.allocPrint(self.gpa, fmt, args) catch "out of memory",
        };
        return error.Lex;
    }

    /// Display a byte the way Rust's `escape_default` does for messages.
    fn disp(gpa: std.mem.Allocator, b: u8) []const u8 {
        if (b == '\n') return "\\n";
        if (b == '\r') return "\\r";
        if (b == '\t') return "\\t";
        if (b >= 0x20 and b < 0x7F) {
            return std.fmt.allocPrint(gpa, "{c}", .{b}) catch "?";
        }
        return std.fmt.allocPrint(gpa, "\\x{x:0>2}", .{b}) catch "?";
    }

    /// Skip whitespace and comments (spec §1: `--` to end of line, `/* */`).
    fn skipWs(self: *Lexer) error{Lex}!void {
        while (true) {
            const b = self.peek() orelse return;
            if (b == ' ' or b == '\t' or b == '\n' or b == '\r') {
                _ = self.bump();
            } else if (b == '-' and self.peek2() == '-') {
                // `--` line comment: to end of line (or EOF).
                while (self.peek()) |c| {
                    if (c == '\n') break;
                    _ = self.bump();
                }
            } else if (b == '/' and self.peek2() == '*') {
                // `/* ... */` block comment: non-nested, error when unterminated.
                _ = self.bump(); // '/'
                _ = self.bump(); // '*'
                while (true) {
                    const inner = self.peek() orelse
                        return self.failAt(self.line, self.col, "unterminated block comment (expected `*/`)", .{});
                    if (inner == '*' and self.peek2() == '/') {
                        _ = self.bump(); // '*'
                        _ = self.bump(); // '/'
                        break;
                    }
                    _ = self.bump();
                }
            } else return;
        }
    }

    fn nextToken(self: *Lexer) error{Lex}!Spanned {
        try self.skipWs();
        const line = self.line;
        const col = self.col;
        const first = self.peek() orelse return Spanned{ .tok = .eof, .line = line, .col = col };
        const tok: Token = switch (first) {
            '(' => blk: {
                _ = self.bump();
                break :blk .l_paren;
            },
            ')' => blk: {
                _ = self.bump();
                break :blk .r_paren;
            },
            '{' => blk: {
                _ = self.bump();
                break :blk .l_brace;
            },
            '}' => blk: {
                _ = self.bump();
                break :blk .r_brace;
            },
            '[' => blk: {
                _ = self.bump();
                break :blk .l_bracket;
            },
            ']' => blk: {
                _ = self.bump();
                break :blk .r_bracket;
            },
            ';' => blk: {
                _ = self.bump();
                break :blk .semi;
            },
            ',' => blk: {
                _ = self.bump();
                break :blk .comma;
            },
            '+' => blk: {
                _ = self.bump();
                break :blk .plus;
            },
            '*' => blk: {
                _ = self.bump();
                break :blk .star;
            },
            '=' => blk: {
                _ = self.bump();
                break :blk .eq;
            },
            '!' => {
                _ = self.bump();
                if (self.peek() == '=') {
                    _ = self.bump();
                    return Spanned{ .tok = .ne, .line = line, .col = col };
                }
                // Rust: `self.err(...)` — CURRENT position (after the bump).
                return self.failAt(self.line, self.col, "unexpected `!` (did you mean `!=`?)", .{});
            },
            '<' => blk: {
                _ = self.bump();
                if (self.peek() == '=') {
                    _ = self.bump();
                    break :blk .le;
                } else if (self.peek() == '-') {
                    _ = self.bump();
                    break :blk .left_arrow;
                } else {
                    break :blk .lt;
                }
            },
            '>' => blk: {
                _ = self.bump();
                if (self.peek() == '=') {
                    _ = self.bump();
                    break :blk .ge;
                } else {
                    break :blk .gt;
                }
            },
            ':' => {
                _ = self.bump();
                if (self.peek() == ':') {
                    _ = self.bump();
                    return Spanned{ .tok = .double_colon, .line = line, .col = col };
                }
                return Spanned{ .tok = .colon, .line = line, .col = col };
            },
            '-' => {
                _ = self.bump();
                if (self.peek() == '>') {
                    _ = self.bump();
                    return Spanned{ .tok = .arrow, .line = line, .col = col };
                } else if (self.peek()) |c| {
                    if (std.ascii.isDigit(c)) {
                        const t = try self.readNumber(true);
                        return Spanned{ .tok = t, .line = line, .col = col };
                    }
                }
                // Rust: `self.err(...)` — CURRENT position (after the bump):
                // this is the corpus-visible dash-trap column.
                return self.failAt(self.line, self.col, "unexpected character '-' (expected `->` or a number)", .{});
            },
            '\'' => {
                const s = try self.readString('\'', line, col);
                return Spanned{ .tok = .{ .str = s }, .line = line, .col = col };
            },
            '"' => {
                const s = try self.readString('"', line, col);
                return Spanned{ .tok = .{ .str = s }, .line = line, .col = col };
            },
            else => {
                if (std.ascii.isDigit(first)) {
                    const t = try self.readNumber(false);
                    return Spanned{ .tok = t, .line = line, .col = col };
                }
                if (isIdentStart(first) or first >= 0x80) {
                    const word = self.readIdent();
                    return Spanned{ .tok = .{ .ident = word }, .line = line, .col = col };
                }
                return self.failAt(self.line, self.col, "unexpected character `{s}`", .{disp(self.gpa, first)});
            },
        };
        return Spanned{ .tok = tok, .line = line, .col = col };
    }

    fn readIdent(self: *Lexer) []const u8 {
        const start = self.pos;
        while (self.peek()) |b| {
            if (isIdentContinue(b) or b >= 0x80) {
                _ = self.bump();
            } else break;
        }
        const slice = self.src[start..self.pos];
        // Rust: String::from_utf8_lossy — invalid sequences become U+FFFD.
        if (std.unicode.utf8ValidateSlice(slice)) return slice;
        return "\u{FFFD}";
    }

    /// Numeric literal (positioned at entry: first digit / after sign, as in
    /// the Rust reference). Overflowing integers fall back to float — the
    /// id-overflow trap: a huge `table:id` becomes a Float token.
    fn readNumber(self: *Lexer, neg: bool) error{Lex}!Token {
        const line = self.line;
        const col = self.col;
        var buf: [512]u8 = undefined;
        var len: usize = 0;
        if (neg) {
            buf[len] = '-';
            len += 1;
        }
        var is_float = false;

        const tooLong = struct {
            fn call(lx: *Lexer, l: usize, c: usize) error{Lex} {
                return lx.failAt(l, c, "numeric literal too long", .{});
            }
        }.call;

        while (self.peek()) |b| {
            if (std.ascii.isDigit(b)) {
                if (len >= buf.len) return tooLong(self, line, col);
                buf[len] = b;
                len += 1;
                _ = self.bump();
            } else break;
        }
        // Fractional part: `.` only when a digit follows.
        if (self.peek() == '.') {
            if (self.peek2()) |c2| {
                if (std.ascii.isDigit(c2)) {
                    is_float = true;
                    if (len >= buf.len) return tooLong(self, line, col);
                    buf[len] = '.';
                    len += 1;
                    _ = self.bump();
                    while (self.peek()) |b| {
                        if (std.ascii.isDigit(b)) {
                            if (len >= buf.len) return tooLong(self, line, col);
                            buf[len] = b;
                            len += 1;
                            _ = self.bump();
                        } else break;
                    }
                }
            }
        }
        // Exponent.
        if (self.peek()) |b| {
            if (b == 'e' or b == 'E') {
                is_float = true;
                if (len >= buf.len) return tooLong(self, line, col);
                buf[len] = 'e';
                len += 1;
                _ = self.bump();
                if (self.peek()) |s| {
                    if (s == '+' or s == '-') {
                        if (len >= buf.len) return tooLong(self, line, col);
                        buf[len] = s;
                        len += 1;
                        _ = self.bump();
                    }
                }
                const need_digit = if (self.peek()) |d| std.ascii.isDigit(d) else false;
                if (!need_digit) return self.failAt(line, col, "malformed numeric exponent", .{});
                while (self.peek()) |d| {
                    if (std.ascii.isDigit(d)) {
                        if (len >= buf.len) return tooLong(self, line, col);
                        buf[len] = d;
                        len += 1;
                        _ = self.bump();
                    } else break;
                }
            }
        }

        const s = buf[0..len];
        if (is_float) {
            const f = std.fmt.parseFloat(f64, s) catch
                return self.failAt(line, col, "invalid float literal `{s}`", .{s});
            return .{ .float = f };
        }
        if (std.fmt.parseInt(i64, s, 10)) |n| {
            return .{ .int = n };
        } else |_| {
            const f = std.fmt.parseFloat(f64, s) catch
                return self.failAt(line, col, "invalid integer literal `{s}`", .{s});
            return .{ .float = f };
        }
    }

    /// Quoted string with escapes; arena-allocated (escapes rewrite bytes).
    fn readString(self: *Lexer, quote: u8, line: usize, col: usize) error{Lex}![]const u8 {
        _ = self.bump(); // opening quote
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            const b = self.peek() orelse
                return self.failAt(line, col, "unterminated string literal", .{});
            if (b == quote) {
                _ = self.bump();
                break;
            }
            if (b == '\\') {
                _ = self.bump();
                const esc = self.peek() orelse
                    return self.failAt(line, col, "unterminated string literal", .{});
                _ = self.bump();
                const decoded: u8 = switch (esc) {
                    '"' => '"',
                    '\'' => '\'',
                    '\\' => '\\',
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    else => return self.failAt(line, col, "invalid escape sequence `\\{s}`", .{disp(self.gpa, esc)}),
                };
                out.append(self.gpa, decoded) catch return self.failAt(line, col, "out of memory", .{});
            } else if (b == '\n') {
                return self.failAt(line, col, "unterminated string literal (newline before closing quote)", .{});
            } else if (b < 0x80) {
                out.append(self.gpa, b) catch return self.failAt(line, col, "out of memory", .{});
                _ = self.bump();
            } else {
                const start = self.pos;
                const n = utf8Len(b);
                var k: usize = 0;
                while (k < n) : (k += 1) _ = self.bump();
                const slice = self.src[start..self.pos];
                if (!std.unicode.utf8ValidateSlice(slice))
                    return self.failAt(line, col, "invalid UTF-8 in string literal", .{});
                out.appendSlice(self.gpa, slice) catch return self.failAt(line, col, "out of memory", .{});
            }
        }
        return out.toOwnedSlice(self.gpa) catch return self.failAt(line, col, "out of memory", .{});
    }
};

/// Tokenize `input`; the stream ends with exactly one `.eof`.
pub fn tokenize(gpa: std.mem.Allocator, input: []const u8) LexResult {
    var lx = Lexer{ .src = input, .gpa = gpa };
    var out: std.ArrayList(Spanned) = .empty;
    while (true) {
        const t = lx.nextToken() catch {
            return .{ .err = lx.fail orelse LexFail{ .line = 0, .col = 0, .message = "lex error" } };
        };
        out.append(gpa, t) catch
            return .{ .err = LexFail{ .line = t.line, .col = t.col, .message = "out of memory" } };
        if (t.tok == .eof) break;
    }
    const slice = out.toOwnedSlice(gpa) catch
        return .{ .err = LexFail{ .line = 0, .col = 0, .message = "out of memory" } };
    return .{ .ok = slice };
}

test "lexer basic tokens" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const res = tokenize(gpa, "SELECT * FROM t WHERE x >= 1.5 -- c\n");
    try std.testing.expect(res == .ok);
    const tags = [_]std.meta.Tag(Token){ .ident, .star, .ident, .ident, .ident, .ident, .ge, .float, .eof };
    try std.testing.expectEqual(tags.len, res.ok.len);
    for (tags, res.ok) |want, got| try std.testing.expectEqual(want, std.meta.activeTag(got.tok));
}

test "lexer traps: dash and positions" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    // Bare `-` after an ident is a lex error at the `-` (1-based col 19).
    const res = tokenize(gpa, "INSERT INTO t:abc-def { k: 1 }");
    try std.testing.expect(res == .err);
    try std.testing.expectEqual(@as(usize, 1), res.err.line);
    try std.testing.expectEqual(@as(usize, 19), res.err.col);
    // `-1` lexes as a number, not a comment or error.
    const ok = tokenize(gpa, "x = -1");
    try std.testing.expect(ok == .ok);
    try std.testing.expectEqual(std.meta.Tag(Token).int, std.meta.activeTag(ok.ok[2].tok));
}
