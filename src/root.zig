//! Bencode in Zig: an incremental reader, a value tree, and a writer.
//!
//! `Reader` yields one value at a time and hands back a nested reader for
//! each container, so a caller can walk a torrent without building the tree.
//! `decode` reads one value into a tree of `Value`s. Byte strings are slices
//! into the input; nothing is copied, and the input must outlive the tree.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const btree = @import("stdx").btree;

/// The incremental reader: one value at a time.
pub const Reader = @import("Reader.zig");
/// One value as the reader yields it.
pub const Token = Reader.Token;
/// The inside of a list.
pub const ListReader = Reader.ListReader;
/// The inside of a dict.
pub const DictReader = Reader.DictReader;
/// One dict pair.
pub const Entry = Reader.Entry;
pub const Writer = @import("Writer.zig");

/// How many containers deep a decode goes before it gives up.
pub const max_depth = 128;

/// A dict: `[]const u8` keys in byte order, which is the order bencode
/// requires, so iteration is already the order the writer emits.
pub const Dict = btree.String(Value);

pub const Value = union(enum) {
    bytes: []const u8,
    int: i64,
    list: []const Value,
    dict: *Dict,

    /// Free every container this value owns. Byte strings that point into
    /// the input are not freed; the input is the caller's.
    pub fn deinit(self: *Value, allocator: Allocator) void {
        switch (self.*) {
            .int, .bytes => {},
            .list => |list| {
                for (@constCast(list)) |*item| item.deinit(allocator);
                allocator.free(list);
            },
            .dict => |dict| {
                var it = dict.iterator();
                while (it.next()) |entry| entry.value_ptr.deinit(allocator);
                dict.clearAndFree(allocator);
                allocator.destroy(dict);
            },
        }
        self.* = undefined;
    }

    pub fn format(v: Value, writer: *Io.Writer) Io.Writer.Error!void {
        var w: Writer = .init(writer);
        try w.write(v);
    }
};

/// What a decode can return: the reader's errors, the allocator's, a second
/// value after the first, or a tree past `max_depth`.
pub const DecodeError = Reader.Error || Allocator.Error || error{ TrailingData, TooDeep };

/// A decoded value and the memory that holds it.
pub const Document = struct {
    /// Owns every list and dict in `value`, not the byte strings.
    arena: ArenaAllocator,
    value: Value,

    /// Free the containers. The input the value borrows is untouched.
    pub fn deinit(self: *Document) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Decode one bencoded value.
///
/// The tree borrows every byte string from `input`, so keep `input` alive as
/// long as the document. `Document.deinit` frees the containers; it does not
/// free or copy the input.
pub fn decode(allocator: Allocator, input: []const u8) DecodeError!Document {
    var arena: ArenaAllocator = .init(allocator);
    errdefer arena.deinit();
    const value = try decodeLeaky(arena.allocator(), input);
    return .{ .arena = arena, .value = value };
}

/// Decode one bencoded value into memory the caller owns.
///
/// `Value.deinit` frees the containers, so a caller with no arena can hand
/// the allocator back. The byte strings still borrow `input`.
pub fn decodeLeaky(allocator: Allocator, input: []const u8) DecodeError!Value {
    var reader: Reader = .init(input);
    const token = try reader.next() orelse return error.UnexpectedEof;

    var value = try decodeToken(allocator, token, max_depth);
    errdefer value.deinit(allocator);
    if (reader.pos != reader.input.len) return error.TrailingData;
    return value;
}

fn decodeToken(allocator: Allocator, token: Token, remaining: u32) DecodeError!Value {
    return switch (token) {
        .int => |int| .{ .int = int },
        .bytes => |bytes| .{ .bytes = bytes },
        .list => |list| blk: {
            if (remaining == 0) return error.TooDeep;

            var items: std.ArrayList(Value) = .empty;
            errdefer {
                for (items.items) |*item| item.deinit(allocator);
                items.deinit(allocator);
            }

            var list_reader = list;
            while (try list_reader.next()) |item| {
                var value = try decodeToken(allocator, item, remaining - 1);
                errdefer value.deinit(allocator);
                try items.append(allocator, value);
            }
            break :blk .{ .list = try items.toOwnedSlice(allocator) };
        },
        .dict => |dict| blk: {
            if (remaining == 0) return error.TooDeep;

            const map = try allocator.create(Dict);
            map.* = .empty;
            errdefer {
                var it = map.iterator();
                while (it.next()) |entry| entry.value_ptr.deinit(allocator);
                map.clearAndFree(allocator);
                allocator.destroy(map);
            }

            var dict_reader = dict;
            while (try dict_reader.next()) |entry| {
                var value = try decodeToken(allocator, entry.value, remaining - 1);
                errdefer value.deinit(allocator);
                try map.put(allocator, entry.key, value);
            }
            break :blk .{ .dict = map };
        },
    };
}

test Value {
    const Case = struct {
        v: Value,
        s: []const u8,
    };

    var empty: Dict = .empty;
    defer empty.clearAndFree(testing.allocator);

    // Inserted out of order on purpose: the map owns the order.
    var dict: Dict = .empty;
    defer dict.clearAndFree(testing.allocator);
    try dict.put(testing.allocator, "wiki", .{ .bytes = "bencode" });
    try dict.put(testing.allocator, "meaning", .{ .int = 42 });

    const cases = [_]Case{
        .{ .v = .{ .int = 0 }, .s = "i0e" },
        .{ .v = .{ .int = 42 }, .s = "i42e" },
        .{ .v = .{ .int = -42 }, .s = "i-42e" },
        .{ .v = .{ .bytes = "" }, .s = "0:" },
        .{ .v = .{ .bytes = "bencode" }, .s = "7:bencode" },
        .{ .v = .{ .list = &[_]Value{} }, .s = "le" },
        .{ .v = .{ .list = &[_]Value{
            .{ .bytes = "bencode" },
            .{ .int = -20 },
        } }, .s = "l7:bencodei-20ee" },
        .{ .v = .{ .dict = &empty }, .s = "de" },
        .{ .v = .{ .dict = &dict }, .s = "d7:meaningi42e4:wiki7:bencodee" },
    };

    var buf: [128]u8 = undefined;
    var w: Io.Writer = undefined;
    for (cases) |case| {
        w = .fixed(&buf);
        try w.print("{f}", .{case.v});
        try testing.expectEqualStrings(case.s, w.buffered());
    }
}

test "Dict orders by bytes, not length, and answers lookups" {
    var dict: Dict = .empty;
    defer dict.clearAndFree(testing.allocator);

    try dict.put(testing.allocator, "b", .{ .int = 2 });
    try dict.put(testing.allocator, "aa", .{ .int = 1 });
    try dict.put(testing.allocator, "a", .{ .int = 0 });

    // "a" is a prefix of "aa": byte order puts it first.
    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try w.print("{f}", .{Value{ .dict = &dict }});
    try testing.expectEqualStrings("d1:ai0e2:aai1e1:bi2ee", w.buffered());

    try testing.expect(dict.get("nope") == null);
    try testing.expectEqual(@as(i64, 1), dict.get("aa").?.int);
}

test "decode builds the tree" {
    var doc = try decode(testing.allocator, "d4:listli1ei2ee4:name7:bencodee");
    defer doc.deinit();

    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try w.print("{f}", .{doc.value});
    try testing.expectEqualStrings("d4:listli1ei2ee4:name7:bencodee", w.buffered());
}

test "decode borrows the input's bytes" {
    const input = "3:abc";
    var doc = try decode(testing.allocator, input);
    defer doc.deinit();

    try testing.expectEqualStrings("abc", doc.value.bytes);
    try testing.expect(doc.value.bytes.ptr == input.ptr + 2);
}

test "byte strings are cut by length, whatever bytes they hold" {
    var doc = try decode(testing.allocator, "d1:x3:a:ee");
    defer doc.deinit();

    try testing.expectEqualStrings("a:e", doc.value.dict.get("x").?.bytes);
}

test "decode rejects trailing data" {
    try testing.expectError(error.TrailingData, decode(testing.allocator, "i1ei2e"));
    try testing.expectError(error.UnexpectedEof, decode(testing.allocator, ""));
}

test "decode rejects an unsorted dict" {
    try testing.expectError(error.UnsortedKey, decode(testing.allocator, "d1:bi1e1:ai2ee"));
    try testing.expectError(error.UnsortedKey, decode(testing.allocator, "d1:ai1e1:ai2ee"));
}

test "decode stops at max_depth" {
    var ok: [2 * max_depth + 1]u8 = undefined;
    var i: usize = 0;
    while (i < max_depth) : (i += 1) ok[i] = 'l';
    const open = i;
    while (i < 2 * open) : (i += 1) ok[i] = 'e';
    var doc = try decode(testing.allocator, ok[0..i]);
    doc.deinit();

    var deep: [2 * (max_depth + 1) + 1]u8 = undefined;
    i = 0;
    while (i <= max_depth) : (i += 1) deep[i] = 'l';
    const deep_open = i;
    while (i < 2 * deep_open) : (i += 1) deep[i] = 'e';
    try testing.expectError(error.TooDeep, decode(testing.allocator, deep[0..i]));
}

test "decodeLeaky leaves the tree to the caller" {
    var value = try decodeLeaky(testing.allocator, "d1:ad1:bl1:cdeeee");
    defer value.deinit(testing.allocator);

    const a = value.dict.get("a").?;
    const b = a.dict.get("b").?;
    try testing.expectEqualStrings("c", b.list[0].bytes);
}
