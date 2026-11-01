//! The incremental reader: one value at a time, containers as nested readers.
//!
//! `Reader.next` hands back a `Token`. A scalar is the value itself; a list
//! or a dict is a `ListReader` or a `DictReader` that borrows the same
//! cursor, so the elements come out in order until the container's `next`
//! returns null. Hold one reader per open container and finish the inner one
//! before asking the outer one for anything else.
//!
//! Nothing is copied: a byte string is a slice into the input, and a
//! container's exact bytes are available through `raw` once it has ended.

const std = @import("std");
const assert = std.debug.assert;
const ascii = std.ascii;
const mem = std.mem;
const math = std.math;
const testing = std.testing;

const stdx = @import("stdx");

const Reader = @This();

/// The whole input. Byte strings are slices into it.
input: []const u8,
/// Offset of the next unread byte.
pos: usize,

/// What a read can fail with.
pub const Error = error{
    /// The input ended in the middle of a value.
    UnexpectedEof,
    /// A byte where no value can start.
    UnexpectedByte,
    /// An integer with a sign, a leading zero, or no digits.
    InvalidInteger,
    /// A byte-string length with a leading zero or a non-digit.
    InvalidLength,
    /// A number or length past what the type holds.
    Overflow,
    /// A dict key that does not sort after the key before it.
    UnsortedKey,
};

pub fn init(input: []const u8) Reader {
    return .{ .input = input, .pos = 0 };
}

/// The bytes not read yet.
pub fn rest(self: Reader) []const u8 {
    return self.input[self.pos..];
}

/// The next value in the stream, or null when the input is exhausted.
pub fn next(self: *Reader) Error!?Token {
    if (self.pos == self.input.len) return null;
    const token = try self.value();
    return token;
}

/// One value, which must be present.
fn value(self: *Reader) Error!Token {
    const byte = self.peek() orelse return error.UnexpectedEof;
    return switch (byte) {
        'i' => .{ .int = try self.integer() },
        '0'...'9' => .{ .bytes = try self.bytes() },
        'l' => blk: {
            const start = self.pos;
            self.pos += 1;
            break :blk .{ .list = .{ .reader = self, .start = start, .end = null } };
        },
        'd' => blk: {
            const start = self.pos;
            self.pos += 1;
            break :blk .{ .dict = .{ .reader = self, .start = start, .end = null, .previous = null } };
        },
        else => error.UnexpectedByte,
    };
}

fn peek(self: Reader) ?u8 {
    if (self.pos == self.input.len) return null;
    return self.input[self.pos];
}

/// `i`, an optional `-`, digits, `e`. No `+`, no leading zero, no `-0`.
fn integer(self: *Reader) Error!i64 {
    assert(self.input[self.pos] == 'i');
    self.pos += 1;

    const begin = self.pos;
    while (true) {
        const byte = self.peek() orelse return error.UnexpectedEof;
        if (byte == 'e') break;
        self.pos += 1;
    }
    const text = self.input[begin..self.pos];
    self.pos += 1; // 'e'

    // stdx enforces no leading zero and at least one digit after a sign.
    // Bencode also forbids `+` and `-0`, which stdx accepts.
    if (text.len > 0 and text[0] == '+') return error.InvalidInteger;
    if (mem.eql(u8, text, "-0")) return error.InvalidInteger;

    return stdx.fmt.atoiWith(i64, text, .{ .leading_zeros = .reject }) catch |err| switch (err) {
        error.Overflow => error.Overflow,
        error.InvalidCharacter => error.InvalidInteger,
    };
}

/// Digit length, `:`, then exactly that many bytes.
fn bytes(self: *Reader) Error![]const u8 {
    const begin = self.pos;
    var length: usize = 0;
    while (true) {
        const byte = self.peek() orelse return error.UnexpectedEof;
        if (byte == ':') break;
        if (!ascii.isDigit(byte)) return error.InvalidLength;
        length = math.mul(usize, length, 10) catch return error.Overflow;
        length = math.add(usize, length, byte - '0') catch return error.Overflow;
        self.pos += 1;
    }

    const digits = self.input[begin..self.pos];
    if (digits.len == 0) return error.InvalidLength;
    if (digits.len > 1 and digits[0] == '0') return error.InvalidLength;
    self.pos += 1; // ':'

    const tail = self.input[self.pos..];
    if (tail.len < length) return error.UnexpectedEof;
    const slice = tail[0..length];
    self.pos += length;
    return slice;
}

/// One value, as the reader yields it.
pub const Token = union(enum) {
    int: i64,
    bytes: []const u8,
    list: ListReader,
    dict: DictReader,
};

/// The inside of a list, borrowed from its `Reader`.
pub const ListReader = struct {
    reader: *Reader,
    /// Offset of the opening `l`.
    start: usize,
    /// Offset one past the closing `e`, once the list has ended.
    end: ?usize,

    /// The next element, or null at the closing `e`.
    pub fn next(self: *ListReader) Reader.Error!?Token {
        const byte = self.reader.peek() orelse return error.UnexpectedEof;
        if (byte == 'e') {
            self.reader.pos += 1;
            self.end = self.reader.pos;
            return null;
        }
        const token = try self.reader.value();
        return token;
    }

    /// The list's exact bytes, once it has ended; null while it is open.
    pub fn raw(self: ListReader) ?[]const u8 {
        const end = self.end orelse return null;
        return self.reader.input[self.start..end];
    }
};

/// One dict pair: the key, and the value that follows it.
pub const Entry = struct {
    key: []const u8,
    value: Token,
};

/// The inside of a dict, borrowed from its `Reader`. Keys must arrive in
/// strictly ascending byte order, which is what bencode requires.
pub const DictReader = struct {
    reader: *Reader,
    /// Offset of the opening `d`.
    start: usize,
    /// Offset one past the closing `e`, once the dict has ended.
    end: ?usize,
    /// The key before the one `next` is about to read.
    previous: ?[]const u8,

    /// The next pair, or null at the closing `e`.
    pub fn next(self: *DictReader) Reader.Error!?Entry {
        const byte = self.reader.peek() orelse return error.UnexpectedEof;
        if (byte == 'e') {
            self.reader.pos += 1;
            self.end = self.reader.pos;
            return null;
        }

        const key = try self.reader.bytes();
        if (self.previous) |previous| {
            if (mem.order(u8, previous, key) != .lt) return error.UnsortedKey;
        }
        self.previous = key;

        const token = try self.reader.value();
        return .{ .key = key, .value = token };
    }

    /// The dict's exact bytes, once it has ended; null while it is open.
    pub fn raw(self: DictReader) ?[]const u8 {
        const end = self.end orelse return null;
        return self.reader.input[self.start..end];
    }
};

test "scalars" {
    var reader: Reader = .init("i0ei42ei-42e0:7:bencode");
    try testing.expectEqual(@as(i64, 0), (try reader.next()).?.int);
    try testing.expectEqual(@as(i64, 42), (try reader.next()).?.int);
    try testing.expectEqual(@as(i64, -42), (try reader.next()).?.int);
    try testing.expectEqualStrings("", (try reader.next()).?.bytes);
    try testing.expectEqualStrings("bencode", (try reader.next()).?.bytes);
    try testing.expectEqual(@as(?Token, null), try reader.next());
}

test "integer limits" {
    var reader: Reader = .init("i9223372036854775807ei-9223372036854775808e");
    try testing.expectEqual(math.maxInt(i64), (try reader.next()).?.int);
    try testing.expectEqual(math.minInt(i64), (try reader.next()).?.int);

    var over: Reader = .init("i9223372036854775808e");
    try testing.expectError(error.Overflow, over.next());
    var under: Reader = .init("i-9223372036854775809e");
    try testing.expectError(error.Overflow, under.next());
}

test "rejects malformed integers" {
    const invalid = [_][]const u8{ "ie", "i-e", "i+1e", "i03e", "i-0e", "i-01e", "i0x1e", "i1 2e" };
    for (invalid) |input| {
        var reader: Reader = .init(input);
        try testing.expectError(error.InvalidInteger, reader.next());
    }

    var truncated: Reader = .init("i1");
    try testing.expectError(error.UnexpectedEof, truncated.next());
}

test "rejects malformed byte strings" {
    var leading: Reader = .init("03:abc");
    try testing.expectError(error.InvalidLength, leading.next());
    var no_digits: Reader = .init("d:i1ee");
    var dict = (try no_digits.next()).?.dict;
    try testing.expectError(error.InvalidLength, dict.next());

    // A byte string has to start with a digit at the top level.
    var colon: Reader = .init(":abc");
    try testing.expectError(error.UnexpectedByte, colon.next());
    var short: Reader = .init("5:abc");
    try testing.expectError(error.UnexpectedEof, short.next());
    var huge: Reader = .init("99999999999999999999999999:x");
    try testing.expectError(error.Overflow, huge.next());
}

test "a list yields its elements" {
    var reader: Reader = .init("li1ei2ee");
    var list = (try reader.next()).?.list;
    try testing.expectEqual(@as(i64, 1), (try list.next()).?.int);
    try testing.expectEqual(@as(i64, 2), (try list.next()).?.int);
    try testing.expectEqual(@as(?Token, null), try list.next());
    try testing.expectEqual(@as(?Token, null), try reader.next());
}

test "a dict yields key and value, and enforces key order" {
    var reader: Reader = .init("d1:ai1e1:bi2ee");
    var dict = (try reader.next()).?.dict;

    const first = (try dict.next()).?;
    try testing.expectEqualStrings("a", first.key);
    try testing.expectEqual(@as(i64, 1), first.value.int);

    const second = (try dict.next()).?;
    try testing.expectEqualStrings("b", second.key);
    try testing.expectEqual(@as(i64, 2), second.value.int);

    try testing.expectEqual(@as(?Entry, null), try dict.next());

    var unsorted: Reader = .init("d1:bi1e1:ai2ee");
    var bad = (try unsorted.next()).?.dict;
    _ = (try bad.next()).?;
    try testing.expectError(error.UnsortedKey, bad.next());

    var duplicate: Reader = .init("d1:ai1e1:ai2ee");
    var twice = (try duplicate.next()).?.dict;
    _ = (try twice.next()).?;
    try testing.expectError(error.UnsortedKey, twice.next());
}

test "containers nest, and raw is the exact bytes" {
    var reader: Reader = .init("d1:ali1eee");
    var dict = (try reader.next()).?.dict;

    const entry = (try dict.next()).?;
    try testing.expectEqualStrings("a", entry.key);

    var list = entry.value.list;
    try testing.expectEqualStrings("", list.raw() orelse "");
    try testing.expectEqual(@as(i64, 1), (try list.next()).?.int);
    try testing.expectEqual(@as(?Token, null), try list.next());
    try testing.expectEqualStrings("li1ee", list.raw().?);

    try testing.expectEqual(@as(?Entry, null), try dict.next());
    try testing.expectEqualStrings("d1:ali1eee", dict.raw().?);
    try testing.expectEqual(@as(?Token, null), try reader.next());
}

test "rejects a bare continuation byte and truncation" {
    var close: Reader = .init("e");
    try testing.expectError(error.UnexpectedByte, close.next());

    var open: Reader = .init("li1e");
    var list = (try open.next()).?.list;
    try testing.expectEqual(@as(i64, 1), (try list.next()).?.int);
    try testing.expectError(error.UnexpectedEof, list.next());

    var open_dict: Reader = .init("d1:a");
    var dict = (try open_dict.next()).?.dict;
    try testing.expectError(error.UnexpectedEof, dict.next());
}
