//! The bencode grammar over buffers the caller feeds.
//!
//! `Reader` drives a scanner from an `std.Io.Reader`. Use the scanner directly
//! when the bytes are already in hand: feed the input, call `endInput`, then
//! `next` until it returns null.
//!
//! The scanner never copies a byte string. When one does not fit the buffer,
//! `next` returns `error.BufferUnderrun`; `buffered` and `payloadLen` say what
//! is already here and how long the payload is. The next `feedInput` must hold
//! the rest of that payload, so the token can be one slice.
//!
//! Tokens are positional, like `std.json.Token`: a dict emits `dict_begin`, a
//! `bytes` key, the value, and so on, and the caller tracks which position it
//! is in. The scanner still rejects a dict key that does not sort after the
//! one before it.

const std = @import("std");
const stdx = @import("stdx");
const assert = std.debug.assert;
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;

const Scanner = @This();

/// The buffer being scanned.
input: []const u8,
/// Offset of the next unread byte in `input`.
cursor: usize,
/// The caller will feed no more input.
is_end_of_input: bool,
/// Open containers, innermost last.
stack: std.ArrayList(Container),
/// Where in a token the last feed ran out.
state: State,

/// The integer being read, as its own text. Twenty-one bytes hold every
/// `i64` and one digit past the longest.
integer_text: [21]u8,
integer_len: usize,
/// The byte string being read.
length: usize,
length_digits: usize,

allocator: Allocator,

const State = enum { value, integer, length, payload };

const Container = struct {
    kind: Kind,
    /// The previous key, copied because a feed invalidates the buffer it came
    /// from. Null until a key has been read.
    key: ?[]u8,
    /// The next token is a key, or the `e` that closes the dict.
    expect_key: bool,

    const Kind = enum { list, dict };
};

/// What a scan can fail with. `error.BufferUnderrun` is the one the caller
/// handles by feeding more.
pub const Error = Allocator.Error || error{
    /// The buffer ran out; feed more and call `next` again.
    BufferUnderrun,
    /// The input ended inside a token or a container.
    UnexpectedEof,
    /// A byte that starts no value, or a structural byte in the wrong place.
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

/// One token, as the scanner yields it.
pub const Token = union(enum) {
    int: i64,
    /// A slice into the fed buffer. It lives until the next `feedInput`.
    bytes: []const u8,
    /// A copy. Only `Reader.nextAlloc` produces this, and the caller frees it.
    allocated_bytes: []const u8,
    list_begin,
    list_end,
    dict_begin,
    dict_end,
};

pub fn init(allocator: Allocator) Scanner {
    return .{
        .input = &.{},
        .cursor = 0,
        .is_end_of_input = false,
        .stack = .empty,
        .state = .value,
        .integer_text = undefined,
        .integer_len = 0,
        .length = 0,
        .length_digits = 0,
        .allocator = allocator,
    };
}

pub fn deinit(self: *Scanner) void {
    for (self.stack.items) |container| {
        if (container.key) |key| self.allocator.free(key);
    }
    self.stack.deinit(self.allocator);
    self.* = undefined;
}

/// Replace the buffer and start reading it at offset zero. The previous buffer
/// must be drained: either `cursor` is at its end, or `state` is `.payload`
/// and the caller kept `buffered` for the next feed.
pub fn feedInput(self: *Scanner, input: []const u8) void {
    assert(self.cursor == self.input.len or self.state == .payload);
    self.input = input;
    self.cursor = 0;
}

/// The caller will feed no more input.
pub fn endInput(self: *Scanner) void {
    self.is_end_of_input = true;
}

/// The bytes of `input` not read yet. They are the first bytes of the payload
/// `next` is waiting for.
pub fn buffered(self: Scanner) []const u8 {
    return self.input[self.cursor..];
}

/// The length of the byte string `next` is waiting for. Meaningful only when
/// `wantsPayload` is true.
pub fn payloadLen(self: Scanner) usize {
    return self.length;
}

/// Whether `error.BufferUnderrun` came from a byte string that needs the rest
/// of its payload in one buffer.
pub fn wantsPayload(self: Scanner) bool {
    return self.state == .payload;
}

/// The next token, or null at the end of input.
pub fn next(self: *Scanner) Error!?Token {
    while (true) {
        if (self.atEnd()) return null;
        const token = switch (self.state) {
            .value => try self.value(),
            .integer => try self.integer(),
            .length => try self.byteLength(),
            .payload => try self.payload(),
        };
        if (token) |done| return done;
    }
}

fn atEnd(self: Scanner) bool {
    return self.stack.items.len == 0 and self.state == .value and
        self.cursor == self.input.len and self.is_end_of_input;
}

fn value(self: *Scanner) Error!?Token {
    const byte = (try self.takeByte()) orelse return error.UnexpectedEof;

    if (self.expectKey()) {
        // A dict key is a byte string or the `e` that closes the dict.
        switch (byte) {
            'e' => return try self.close(),
            '0'...'9' => {
                self.state = .length;
                self.length = byte - '0';
                self.length_digits = 1;
                return null;
            },
            else => return error.UnexpectedByte,
        }
    }

    switch (byte) {
        'i' => {
            self.state = .integer;
            self.integer_len = 0;
            return null;
        },
        '0'...'9' => {
            self.state = .length;
            self.length = byte - '0';
            self.length_digits = 1;
            return null;
        },
        'l' => {
            self.finishValue();
            const token = try self.open(.list, .list_begin);
            return token;
        },
        'd' => {
            self.finishValue();
            const token = try self.open(.dict, .dict_begin);
            return token;
        },
        'e' => {
            const token = try self.close();
            return token;
        },
        else => return error.UnexpectedByte,
    }
}

fn integer(self: *Scanner) Error!?Token {
    while (true) {
        const byte = (try self.takeByte()) orelse return error.UnexpectedEof;
        switch (byte) {
            '-' => {
                if (self.integer_len != 0) return error.InvalidInteger;
                self.integer_text[self.integer_len] = '-';
                self.integer_len += 1;
            },
            '0'...'9' => {
                if (self.integer_len == self.integer_text.len) return error.Overflow;
                self.integer_text[self.integer_len] = byte;
                self.integer_len += 1;
            },
            'e' => {
                const parsed = try self.finishInteger();
                self.state = .value;
                self.finishValue();
                return .{ .int = parsed };
            },
            else => return error.InvalidInteger,
        }
    }
}

fn finishInteger(self: Scanner) Error!i64 {
    const text = self.integer_text[0..self.integer_len];
    // stdx takes `-0`; bencode does not.
    if (mem.eql(u8, text, "-0")) return error.InvalidInteger;
    return stdx.fmt.atoiWith(i64, text, .{ .leading_zeros = .reject }) catch |err| switch (err) {
        error.Overflow => error.Overflow,
        error.InvalidCharacter => error.InvalidInteger,
    };
}

fn byteLength(self: *Scanner) Error!?Token {
    while (true) {
        const byte = (try self.takeByte()) orelse return error.UnexpectedEof;
        switch (byte) {
            ':' => {
                self.state = .payload;
                return null;
            },
            '0'...'9' => {
                // A length is zero or starts with a non-zero digit.
                if (self.length_digits == 1 and self.length == 0) return error.InvalidLength;
                self.length = std.math.mul(usize, self.length, 10) catch return error.Overflow;
                self.length = std.math.add(usize, self.length, byte - '0') catch return error.Overflow;
                self.length_digits += 1;
            },
            else => return error.InvalidLength,
        }
    }
}

fn payload(self: *Scanner) Error!?Token {
    if (self.input.len - self.cursor < self.length) {
        if (self.is_end_of_input) return error.UnexpectedEof;
        return error.BufferUnderrun;
    }

    const slice = self.input[self.cursor..][0..self.length];
    self.cursor += self.length;
    self.state = .value;

    if (self.stack.items.len > 0) {
        const top = &self.stack.items[self.stack.items.len - 1];
        if (top.kind == .dict and top.expect_key) {
            if (top.key) |previous| {
                if (mem.order(u8, previous, slice) != .lt) return error.UnsortedKey;
            }
            const copy = try self.allocator.dupe(u8, slice);
            if (top.key) |previous| self.allocator.free(previous);
            top.key = copy;
            top.expect_key = false;
            return .{ .bytes = slice };
        }
        if (top.kind == .dict) top.expect_key = true;
    }
    return .{ .bytes = slice };
}

fn open(self: *Scanner, kind: Container.Kind, token: Token) Error!?Token {
    try self.stack.append(self.allocator, .{
        .kind = kind,
        .key = null,
        .expect_key = kind == .dict,
    });
    return token;
}

fn close(self: *Scanner) Error!?Token {
    if (self.stack.items.len == 0) return error.UnexpectedByte;
    const container = self.stack.items[self.stack.items.len - 1];
    // `d1:ae` closes a dict after a key with no value.
    if (container.kind == .dict and !container.expect_key) return error.UnexpectedByte;

    self.stack.items.len -= 1;
    if (container.key) |key| self.allocator.free(key);
    return switch (container.kind) {
        .list => .list_end,
        .dict => .dict_end,
    };
}

/// Call after any token that fills a dict's value position.
fn finishValue(self: *Scanner) void {
    if (self.stack.items.len == 0) return;
    const top = &self.stack.items[self.stack.items.len - 1];
    if (top.kind == .dict and !top.expect_key) top.expect_key = true;
}

fn expectKey(self: Scanner) bool {
    if (self.stack.items.len == 0) return false;
    const top = self.stack.items[self.stack.items.len - 1];
    return top.kind == .dict and top.expect_key;
}

fn takeByte(self: *Scanner) Error!?u8 {
    if (self.cursor == self.input.len) {
        if (self.is_end_of_input) return null;
        return error.BufferUnderrun;
    }
    const byte = self.input[self.cursor];
    self.cursor += 1;
    return byte;
}

test "scalars and the end of input" {
    var scanner: Scanner = .init(testing.allocator);
    defer scanner.deinit();
    scanner.feedInput("i42e3:abc");
    scanner.endInput();

    try testing.expectEqual(@as(i64, 42), (try scanner.next()).?.int);
    try testing.expectEqualStrings("abc", (try scanner.next()).?.bytes);
    try testing.expectEqual(@as(?Token, null), try scanner.next());
}

test "containers" {
    var scanner: Scanner = .init(testing.allocator);
    defer scanner.deinit();
    scanner.feedInput("d1:ali1eee");
    scanner.endInput();

    try testing.expect((try scanner.next()).? == .dict_begin);
    try testing.expectEqualStrings("a", (try scanner.next()).?.bytes);
    try testing.expect((try scanner.next()).? == .list_begin);
    try testing.expectEqual(@as(i64, 1), (try scanner.next()).?.int);
    try testing.expect((try scanner.next()).? == .list_end);
    try testing.expect((try scanner.next()).? == .dict_end);
    try testing.expectEqual(@as(?Token, null), try scanner.next());
}

test "a feed that ends mid-token asks for more" {
    var scanner: Scanner = .init(testing.allocator);
    defer scanner.deinit();

    scanner.feedInput("i4");
    try testing.expectError(error.BufferUnderrun, scanner.next());

    scanner.feedInput("2e");
    try testing.expectEqual(@as(i64, 42), (try scanner.next()).?.int);
    scanner.endInput();
    try testing.expectEqual(@as(?Token, null), try scanner.next());
}

test "a payload that does not fit asks for the whole string" {
    var scanner: Scanner = .init(testing.allocator);
    defer scanner.deinit();

    scanner.feedInput("5:he");
    try testing.expectError(error.BufferUnderrun, scanner.next());
    try testing.expect(scanner.wantsPayload());
    try testing.expectEqual(@as(usize, 5), scanner.payloadLen());
    try testing.expectEqualStrings("he", scanner.buffered());

    // The caller hands the payload over as one buffer.
    scanner.feedInput("hello");
    try testing.expectEqualStrings("hello", (try scanner.next()).?.bytes);
}

test "keys must ascend, and a duplicate does not" {
    var scanner: Scanner = .init(testing.allocator);
    defer scanner.deinit();
    scanner.feedInput("d1:bi1e1:ai2ee");
    scanner.endInput();

    try testing.expect((try scanner.next()).? == .dict_begin);
    try testing.expectEqualStrings("b", (try scanner.next()).?.bytes);
    try testing.expectEqual(@as(i64, 1), (try scanner.next()).?.int);
    try testing.expectError(error.UnsortedKey, scanner.next());

    var twice: Scanner = .init(testing.allocator);
    defer twice.deinit();
    twice.feedInput("d1:ai1e1:ai2ee");
    twice.endInput();
    _ = try twice.next();
    _ = try twice.next();
    _ = try twice.next();
    try testing.expectError(error.UnsortedKey, twice.next());
}

test "malformed input" {
    const cases = [_]struct { input: []const u8, want: Error }{
        .{ .input = "e", .want = error.UnexpectedByte },
        .{ .input = "i-0e", .want = error.InvalidInteger },
        .{ .input = "i03e", .want = error.InvalidInteger },
        .{ .input = "i+1e", .want = error.InvalidInteger },
        .{ .input = "03:abc", .want = error.InvalidLength },
        .{ .input = "i9223372036854775808e", .want = error.Overflow },
        .{ .input = "3:ab", .want = error.UnexpectedEof },
    };
    for (cases) |case| {
        var scanner: Scanner = .init(testing.allocator);
        defer scanner.deinit();
        scanner.feedInput(case.input);
        scanner.endInput();
        try testing.expectError(case.want, scanner.next());
    }

    // A dict that closes after a key has no value.
    var closed: Scanner = .init(testing.allocator);
    defer closed.deinit();
    closed.feedInput("d1:ae");
    closed.endInput();
    _ = try closed.next();
    _ = try closed.next();
    try testing.expectError(error.UnexpectedByte, closed.next());
}
