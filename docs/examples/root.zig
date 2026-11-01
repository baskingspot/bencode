//! The guide's examples, compiled and run with the module's own test suite.
//! A guide page cannot show code that does not build.

const std = @import("std");
const testing = std.testing;

const bencode = @import("bencode");

const torrent = "d4:infod4:name7:bencode6:pieces0:e5:valuei42ee";

test "read a stream one token at a time" {
    var io: std.Io.Reader = .fixed("d1:ai1ee");
    var reader: bencode.Reader = .init(testing.allocator, &io);
    defer reader.deinit();

    try testing.expectEqual(@as(?bencode.Token, .dict_begin), try reader.next());
    try testing.expectEqualStrings("a", (try reader.next()).?.bytes);
    try testing.expectEqual(@as(i64, 1), (try reader.next()).?.int);
    try testing.expectEqual(@as(?bencode.Token, .dict_end), try reader.next());
    try testing.expectEqual(@as(?bencode.Token, null), try reader.next());
}

test "copy a byte string out of the stream" {
    var io: std.Io.Reader = .fixed("3:abc");
    var reader: bencode.Reader = .init(testing.allocator, &io);
    defer reader.deinit();

    const token = (try reader.nextAlloc(testing.allocator, .alloc_always)).?;
    defer testing.allocator.free(token.allocated_bytes);
    try testing.expectEqualStrings("abc", token.allocated_bytes);
}

test "decode a tree and read a field" {
    var document = try bencode.decode(testing.allocator, torrent);
    defer document.deinit();

    const info = document.value.dict.get("info").?.dict;
    try testing.expectEqualStrings("bencode", info.get("name").?.bytes);
    try testing.expectEqual(@as(i64, 42), document.value.dict.get("value").?.int);
}

test "write a tree back out" {
    var document = try bencode.decode(testing.allocator, torrent);
    defer document.deinit();

    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try writer.print("{f}", .{document.value});
    try testing.expectEqualStrings(torrent, writer.buffered());
}

test "write the pieces" {
    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    var w: bencode.Writer = .init(&writer);
    try w.beginDict();
    try w.writeBytes("a");
    try w.writeInt(1);
    try w.endDict();

    try testing.expectEqualStrings("d1:ai1ee", writer.buffered());
}

test "a broken value is rejected" {
    var scanner: bencode.Scanner = .init(testing.allocator);
    defer scanner.deinit();
    scanner.feedInput("d1:bi1e1:ai2ee");
    scanner.endInput();
    _ = try scanner.next();
    _ = try scanner.next();
    _ = try scanner.next();
    try testing.expectError(error.UnsortedKey, scanner.next());

    try testing.expectError(error.InvalidInteger, bencode.decode(testing.allocator, "i-0e"));
    try testing.expectError(error.TrailingData, bencode.decode(testing.allocator, "i1ei2e"));
}
