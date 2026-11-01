//! Drives a `Scanner` from an `std.Io.Reader`.
//!
//! `next` handles `error.BufferUnderrun` by reading more and returns one
//! token at a time. A byte string is a slice into the reader's buffer, valid
//! until the next call, or a copy the reader keeps for that same window. A
//! payload that does not fit the buffer is gathered in one allocation and
//! freed at the next call. `nextAlloc` copies instead, when the caller needs
//! the bytes to outlive the call.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Scanner = @import("Scanner.zig");
const testing = std.testing;
const Token = Scanner.Token;

const Reader = @This();

scanner: Scanner,
io: *Io.Reader,
/// The gathered payload for the token just returned, when one did not fit the
/// source's buffer. Freed at the next call.
scratch: ?[]u8,
allocator: Allocator,

/// What a read can fail with. `error.BufferUnderrun` is handled here.
pub const Error = Allocator.Error || error{
    ReadFailed,
    UnexpectedEof,
    UnexpectedByte,
    InvalidInteger,
    InvalidLength,
    Overflow,
    UnsortedKey,
};

/// Whether `nextAlloc` copies a byte string that is already in one piece.
pub const AllocWhen = enum {
    /// Borrow it when the source has it in one buffer, copy only when it does
    /// not.
    alloc_if_needed,
    /// Always copy, so the caller owns the bytes.
    alloc_always,
};

pub fn init(allocator: Allocator, io: *Io.Reader) Reader {
    return .{
        .scanner = .init(allocator),
        .io = io,
        .scratch = null,
        .allocator = allocator,
    };
}

pub fn deinit(self: *Reader) void {
    self.releaseScratch();
    self.scanner.deinit();
    self.* = undefined;
}

/// The next token, or null at the end of the stream.
pub fn next(self: *Reader) Error!?Token {
    self.releaseScratch();
    while (true) {
        const token = self.scanner.next() catch |err| switch (err) {
            error.BufferUnderrun => {
                try self.feed();
                continue;
            },
            else => |e| return e,
        };
        return token;
    }
}

/// The next token, with a byte string copied when `when` asks for it. A
/// `Token.allocated_bytes` belongs to `allocator`; free it there.
pub fn nextAlloc(self: *Reader, allocator: Allocator, when: AllocWhen) Error!?Token {
    const token = try self.next() orelse return null;
    if (when == .alloc_always and token == .bytes) {
        const copy = try allocator.dupe(u8, token.bytes);
        return .{ .allocated_bytes = copy };
    }
    return token;
}

fn feed(self: *Reader) Error!void {
    if (self.scanner.wantsPayload()) return self.gatherPayload();

    const buffered = self.io.buffered();
    if (buffered.len > 0) {
        self.scanner.feedInput(buffered);
        self.io.tossBuffered();
        return;
    }

    self.io.fillMore() catch |err| switch (err) {
        error.EndOfStream => {
            self.scanner.endInput();
            return;
        },
        error.ReadFailed => return error.ReadFailed,
    };
}

/// A byte string is longer than the source's buffer. Take what is buffered,
/// read the rest, and hand the scanner the whole payload as one buffer.
fn gatherPayload(self: *Reader) Error!void {
    const have = self.scanner.buffered();
    const total = self.scanner.payloadLen();
    assert(have.len < total);

    const buffer = try self.allocator.alloc(u8, total);
    errdefer self.allocator.free(buffer);
    @memcpy(buffer[0..have.len], have);
    self.io.readSliceAll(buffer[have.len..]) catch |err| switch (err) {
        error.EndOfStream => return error.UnexpectedEof,
        error.ReadFailed => return error.ReadFailed,
    };

    self.scratch = buffer;
    self.scanner.feedInput(buffer);
}

fn releaseScratch(self: *Reader) void {
    const buffer = self.scratch orelse return;
    self.scanner.feedInput(&.{});
    self.allocator.free(buffer);
    self.scratch = null;
}

test "a fixed reader yields the token stream" {
    var io: Io.Reader = .fixed("i1ed1:ai2ee");
    var reader: Reader = .init(testing.allocator, &io);
    defer reader.deinit();

    try testing.expectEqual(@as(i64, 1), (try reader.next()).?.int);
    try testing.expect((try reader.next()).? == .dict_begin);
    try testing.expectEqualStrings("a", (try reader.next()).?.bytes);
    try testing.expectEqual(@as(i64, 2), (try reader.next()).?.int);
    try testing.expect((try reader.next()).? == .dict_end);
    try testing.expectEqual(@as(?Token, null), try reader.next());
}

test "a payload larger than the source buffer is gathered" {
    var io: Io.Reader = .fixed("8:abcd:efg");
    var buffer: [4]u8 = undefined;
    var limited = io.limited(.unlimited, &buffer);
    var reader: Reader = .init(testing.allocator, &limited.interface);
    defer reader.deinit();

    try testing.expectEqualStrings("abcd:efg", (try reader.next()).?.bytes);
    try testing.expectEqual(@as(?Token, null), try reader.next());
}

test "nextAlloc copies when asked" {
    var io: Io.Reader = .fixed("3:abc3:def");
    var reader: Reader = .init(testing.allocator, &io);
    defer reader.deinit();

    const borrowed = (try reader.nextAlloc(testing.allocator, .alloc_if_needed)).?;
    try testing.expect(borrowed == .bytes);
    try testing.expectEqualStrings("abc", borrowed.bytes);

    const owned = (try reader.nextAlloc(testing.allocator, .alloc_always)).?;
    defer testing.allocator.free(owned.allocated_bytes);
    try testing.expect(owned == .allocated_bytes);
    try testing.expectEqualStrings("def", owned.allocated_bytes);
}
