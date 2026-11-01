const std = @import("std");
const Io = std.Io;
pub const Error = Io.Writer.Error;
const root = @import("root.zig");
const Value = root.Value;
const Dict = root.Dict;

const Writer = @This();

writer: *Io.Writer,

pub fn init(writer: *Io.Writer) Writer {
    return .{ .writer = writer };
}

pub fn beginList(self: *Writer) Error!void {
    try self.writer.writeByte('l');
}

pub fn endList(self: *Writer) Error!void {
    try self.writer.writeByte('e');
}

pub fn beginDict(self: *Writer) Error!void {
    try self.writer.writeByte('d');
}

pub fn endDict(self: *Writer) Error!void {
    try self.writer.writeByte('e');
}

pub fn writeInt(self: *Writer, value: i64) Error!void {
    try self.writer.print("i{d}e", .{value});
}

pub fn writeBytes(self: *Writer, value: []const u8) Error!void {
    try self.writer.print("{d}:{s}", .{ value.len, value });
}

pub fn writeList(self: *Writer, values: []const Value) Error!void {
    try self.beginList();
    for (values) |value| try self.write(value);
    try self.endList();
}

pub fn writeDict(self: *Writer, dict: *const Dict) Error!void {
    try self.beginDict();
    var it = dict.iterator();
    while (it.next()) |entry| {
        try self.writeBytes(entry.key_ptr.*);
        try self.write(entry.value_ptr.*);
    }
    try self.endDict();
}

pub fn write(self: *Writer, value: Value) Error!void {
    try switch (value) {
        .int => |i| self.writeInt(i),
        .bytes => |b| self.writeBytes(b),
        .list => |list| self.writeList(list),
        .dict => |dict| self.writeDict(dict),
    };
}
