//! The guide's examples, compiled and run with the module's own test suite.
//! A guide page cannot show code that does not build.

const std = @import("std");
const testing = std.testing;

const bencode = @import("bencode");

const torrent = "d4:infod4:name7:bencode6:pieces0:e5:valuei42ee";

test "read a torrent one value at a time" {
    var reader: bencode.Reader = .init(torrent);
    var top = (try reader.next()).?.dict;

    var info: ?[]const u8 = null;
    while (try top.next()) |entry| {
        if (!std.mem.eql(u8, entry.key, "info")) continue;

        // Finish the inner dict before the outer one moves again.
        var dict = entry.value.dict;
        while (try dict.next()) |_| {}
        info = dict.raw().?;
    }

    try testing.expectEqualStrings("d4:name7:bencode6:pieces0:e", info.?);
    try testing.expectEqual(@as(?bencode.Token, null), try reader.next());
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
    var reader: bencode.Reader = .init("d1:bi1e1:ai2ee");
    var dict = (try reader.next()).?.dict;
    _ = (try dict.next()).?;
    try testing.expectError(error.UnsortedKey, dict.next());

    try testing.expectError(error.InvalidInteger, bencode.decode(testing.allocator, "i-0e"));
    try testing.expectError(error.TrailingData, bencode.decode(testing.allocator, "i1ei2e"));
}
