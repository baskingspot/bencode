+++
title = "bencode"
+++

Bencode in Zig: an incremental reader, a value tree, and a writer.

Bencode is the format a torrent's metadata is written in: byte strings,
integers, lists, and dicts. This reads a stream one value at a time, decodes
one value into a tree you can walk, and writes it back. Keys come out in byte
order because the dict is a sorted map, not an array that has to be sorted
before it is written.

- [Reading a stream](#reading-a-stream): `Scanner` holds the grammar over buffers you feed, `Reader` drives one from any `std.Io.Reader`, and each `next` is one `Token`.
- [The value tree](#the-value-tree): `decode` returns a `Document` over an arena, with `Value` for the scalars and containers and `Dict` for the keys.
- [Writing](#writing): `Value.format` writes a tree, and `Writer` writes the pieces when a tree is not what you have.
- [Limits](#limits): byte strings that borrow their input, and a fixed depth cap.

The [API reference](api/) documents every public symbol.

# Getting started

## Install

```sh
zig fetch --save git+https://github.com/baskingspot/bencode
```

Add the module in `build.zig`:

```zig
const bencode = b.dependency("bencode", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("bencode", bencode.module("bencode"));
```

`bencode` builds with Zig 0.16 only.

## Import it

```zig
const bencode = @import("bencode");
```

The module imports `stdx` for its ordered map. `zig fetch` resolves that
dependency when it resolves this one, so an adopter does nothing extra.

## Read the examples

[`docs/examples/root.zig`](https://github.com/baskingspot/bencode/blob/main/docs/examples/root.zig)
is the code this guide shows, compiled against the public module and run by
`just test`.

# Reading a stream

Two layers, the same split `std.json.Scanner` and `std.json.Reader` make. The
scanner holds the grammar and does no I/O. The reader feeds it from an
`std.Io.Reader` and handles the refills.

## Scan a buffer

```zig
var scanner: bencode.Scanner = .init(gpa);
defer scanner.deinit();
scanner.feedInput(input);
scanner.endInput();

while (try scanner.next()) |token| {
    switch (token) {
        .bytes => |bytes| bytes,
        else => {},
    }
}
```

`next` returns null when the input ends at a value boundary. Tokens are
positional, like `std.json.Token`:

```zig
pub const Token = union(enum) {
    int: i64,
    bytes: []const u8,
    allocated_bytes: []const u8,
    list_begin,
    list_end,
    dict_begin,
    dict_end,
};
```

A dict emits `dict_begin`, then a `bytes` key and its value, repeating, then
`dict_end`. The caller tracks which position it is in. A `bytes` slice points
into the buffer just fed, and lives until the next `feedInput`.

If the buffer runs out mid-token, `next` returns `error.BufferUnderrun`. The
scanner keeps its place: feed the next buffer and call `next` again. A byte
string is the one case that cannot split. When `next` returns
`error.BufferUnderrun` with `wantsPayload` true, `payloadLen` is the string's
length and `buffered` is the part already here. The next `feedInput` must hold
the whole payload, so the token can be one slice.

## Read from an Io.Reader

```zig
var io: std.Io.Reader = .fixed(input);
var reader: bencode.Reader = .init(gpa, &io);
defer reader.deinit();

while (try reader.next()) |token| {
    switch (token) {
        .bytes => |bytes| bytes,
        else => {},
    }
}
```

`Reader` refills on `error.BufferUnderrun`, so `next` returns whole tokens
only. A byte string is a slice into the reader's buffer, valid until the next
call, or a copy the reader frees at the next call when the string had to be
gathered. With `Io.Reader.fixed` the buffer is the input, so the slice lives
as long as the input does.

`nextAlloc(allocator, .alloc_always)` copies a byte string into your allocator
and returns `Token.allocated_bytes`. Free it there. With `.alloc_if_needed`
the reader copies only when the source could not hand the string over in one
piece.

## Take a container's bytes

`scanner.cursor` is the offset just past the token it just returned, so a
caller holding the whole file can slice a value back out. Record the cursor on
a `dict_begin`, subtract one for the `d`, and record it again after the
matching `dict_end`. That slice is the bytes a torrent's `info` hash covers,
without rebuilding them.

## Reject what bencode rejects

`Scanner.Error` is the grammar:

- `error.InvalidInteger`: a `+`, a leading zero, a `-0`, or no digits.
- `error.InvalidLength`: a byte-string length with a leading zero or a non-digit.
- `error.Overflow`: an integer past `i64`, or a length past `usize`.
- `error.UnexpectedByte`: a byte that starts no value, or an `e` where a value was expected.
- `error.UnexpectedEof`: the input ended inside a token or a container.
- `error.UnsortedKey`: a dict key that does not sort after the one before it, which catches duplicates too.

# The value tree

## Decode into a document

```zig
var document = try bencode.decode(gpa, input);
defer document.deinit();
```

`decode` reads one value and fails on anything after it with
`error.TrailingData`. The tree borrows every byte string from `input`, so keep
the input alive as long as the document. `Document.deinit` frees the
containers, not the input.

## Read the tree

`Value` has four arms: `bytes`, `int`, `list`, and `dict`.

```zig
const root = document.value.dict;
const name = root.get("name").?.bytes;
```

`Dict` is `stdx.btree.String(Value)`, so it has `get`, `put`, `iterator`,
`count`, and `clearAndFree`. Iteration is in key order, so a decoded tree
writes back canonically.

## Own the memory yourself

```zig
var arena: std.heap.ArenaAllocator = .init(gpa);
defer arena.deinit();

const value = try bencode.decodeLeaky(arena.allocator(), input);
```

`decodeLeaky` returns the `Value` and leaves the memory to you. With a plain
allocator, free it with `value.deinit(gpa)`.

`decode` stops at `max_depth` containers, which is 128, with `error.TooDeep`.

# Writing

## Write a tree

`Value.format` writes to any `std.Io.Writer`:

```zig
var buf: [128]u8 = undefined;
var writer: std.Io.Writer = .fixed(&buf);
try writer.print("{f}", .{document.value});
```

Keys come out in byte order because the dict is sorted. The writer does not
sort.

## Write the pieces

For a value you assemble yourself, `Writer` takes each piece:

```zig
var w: bencode.Writer = .init(&writer);
try w.beginDict();
try w.writeBytes("a");
try w.writeInt(1);
try w.endDict();
```

`beginDict` and `endDict` bracket a dict; `beginList` and `endList` bracket a
list. `writeList` takes a `[]const Value` and `writeDict` a `*const Dict` when
the container already exists.

# Limits

- Byte strings borrow. `decode` has no mode that copies them into the arena,
  so the input must outlive the tree. `decodeLeaky` behaves the same way, and
  a slice from `Reader.next` lives until the next call unless you copy it with
  `nextAlloc`.
- A payload takes one buffer. `Scanner` needs a byte string's whole payload in
  one `feedInput`, so a caller feeding fixed chunks has to gather it. `Reader`
  does that with one allocation.
- The depth cap is fixed. `max_depth` is 128, and `decode` takes no options.
- One value at a time at the top. `decode` rejects trailing bytes; for a
  stream of values, drive `Reader.next` yourself.
