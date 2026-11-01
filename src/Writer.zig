//! Bencode output: a whole `Value` tree, or the pieces one at a time.

const std = @import("std");
const Io = std.Io;
/// What a write can fail with: the sink's error, and nothing else.
pub const Error = Io.Writer.Error;
const root = @import("root.zig");
const Value = root.Value;
const Dict = root.Dict;

const Writer = @This();

/// The sink. Borrowed, and it must outlive the writer.
writer: *Io.Writer,

/// A writer over `writer`. Nothing is buffered here; each call reaches the
/// sink.
pub fn init(writer: *Io.Writer) Writer {
    return .{ .writer = writer };
}

/// Write the `l` that opens a list. `endList` closes it, and `writeList` does
/// both for a slice.
pub fn beginList(self: *Writer) Error!void {
    try self.writer.writeByte('l');
}

/// Write the `e` that closes a list. It is the same byte `endDict` writes.
pub fn endList(self: *Writer) Error!void {
    try self.writer.writeByte('e');
}

/// Write the `d` that opens a dict. `endDict` closes it, and `writeDict` does
/// both for a map.
pub fn beginDict(self: *Writer) Error!void {
    try self.writer.writeByte('d');
}

/// Write the `e` that closes a dict. It is the same byte `endList` writes.
pub fn endDict(self: *Writer) Error!void {
    try self.writer.writeByte('e');
}

/// Write `value` as `i{d}e`. Every `i64` has exactly one spelling, so the
/// output is canonical.
pub fn writeInt(self: *Writer, value: i64) Error!void {
    try self.writer.print("i{d}e", .{value});
}

/// Write `value` as `{d}:{s}`: the length in decimal, a colon, then the bytes
/// unchanged. Nothing is escaped.
pub fn writeBytes(self: *Writer, value: []const u8) Error!void {
    try self.writer.print("{d}:{s}", .{ value.len, value });
}

/// Write `values` as a list: `l`, each element through `write`, then `e`.
pub fn writeList(self: *Writer, values: []const Value) Error!void {
    try self.beginList();
    for (values) |value| try self.write(value);
    try self.endList();
}

/// Write `dict` as a dict: `d`, each pair, then `e`. Pairs come out in the
/// map's order, which is byte order, which is what bencode requires. This
/// does not sort.
pub fn writeDict(self: *Writer, dict: *const Dict) Error!void {
    try self.beginDict();
    var it = dict.iterator();
    while (it.next()) |entry| {
        try self.writeBytes(entry.key_ptr.*);
        try self.write(entry.value_ptr.*);
    }
    try self.endDict();
}

/// Write one value, dispatching on its arm.
pub fn write(self: *Writer, value: Value) Error!void {
    try switch (value) {
        .int => |i| self.writeInt(i),
        .bytes => |b| self.writeBytes(b),
        .list => |list| self.writeList(list),
        .dict => |dict| self.writeDict(dict),
    };
}
