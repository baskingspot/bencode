+++
title = "bencode"
+++

Bencode in Zig: an incremental reader, a value tree, and a writer.

Bencode is the format a torrent's metadata is written in: byte strings,
integers, lists, and dicts. This reads a stream one value at a time, decodes
one value into a tree you can walk, and writes it back. Keys come out in byte
order because the dict is a sorted map, not an array that has to be sorted
before it is written.

- [Reading one value at a time](#reading-one-value-at-a-time): `Reader.next` returns a `Token`, a list or a dict arrives as a nested reader over the same cursor, and `raw` gives back a container's exact bytes.
- [The value tree](#the-value-tree): `decode` returns a `Document` over an arena, with `Value` for the scalars and containers and `Dict` for the keys.
- [Writing](#writing): `Value.format` writes a tree, and `Writer` writes the pieces when a tree is not what you have.
- [Limits](#limits): a slice in, byte strings that borrow it, and a fixed depth cap.

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

# Reading one value at a time

`Reader` is a cursor over `[]const u8`. It reads one value and returns a
`Token`:

```zig
pub const Token = union(enum) {
    int: i64,
    bytes: []const u8,
    list: ListReader,
    dict: DictReader,
};
```

```zig
var reader: bencode.Reader = .init(input);
const token = try reader.next() orelse return; // null at end of input
```

A scalar token is the value: the integer, or a slice into `input`. A container
token is a reader for that container. It borrows the same cursor, so the bytes
under it move forward as you read.

## Read a list

```zig
var sum: i64 = 0;
var list = token.list;
while (try list.next()) |item| {
    if (item == .int) sum += item.int;
}
```

`list.next` returns null after it consumes the closing `e`. The parent reader
is then pointing at whatever follows the list.

## Read a dict

A dict entry carries the key and the value:

```zig
var dict = token.dict;
while (try dict.next()) |entry| {
    const key = entry.key; // []const u8 into input
    if (std.mem.eql(u8, key, "name") and entry.value == .bytes) {
        const name = entry.value.bytes;
    }
}
```

Hold one reader per open container and finish the inner one before asking the
outer one for anything else. A copy of a reader is a second view of the same
cursor, with its own end marker, so do not copy one mid-read.

## Take the bytes back

`raw` returns the exact input slice a finished container occupied, including
its `l`/`d` and `e`:

```zig
var info = entry.value.dict;
while (try info.next()) |_| {}
const span = info.raw().?; // the bytes a torrent's info hash covers
```

`raw` returns null until the container has ended.

## Reject what bencode rejects

`Reader.Error` is the grammar:

- `error.InvalidInteger`: a `+`, a leading zero, a `-0`, or no digits.
- `error.InvalidLength`: a byte-string length with a leading zero or a non-digit.
- `error.Overflow`: an integer past `i64`, or a length past `usize`.
- `error.UnexpectedByte`: a byte that starts no value.
- `error.UnexpectedEof`: the input ended inside a value or a container.
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
`count`, and `clearAndFree`. Iteration is in key order, which is the order
bencode requires, so a decoded tree writes back canonically.

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

`Value` implements `format`, so a fixed buffer or a file takes it directly:

```zig
var buf: [128]u8 = undefined;
var writer: std.Io.Writer = .fixed(&buf);
try writer.print("{f}", .{document.value});
```

Dict keys come out in byte order because they went in that way. The writer
does not sort.

## Write the pieces

When the tree is not what you have, `Writer` takes the pieces:

```zig
var w: bencode.Writer = .init(&writer);
try w.beginDict();
try w.writeBytes("a");
try w.writeInt(1);
try w.endDict();
```

`writeList` and `writeDict` take a slice and a `*const Dict`. An int writes as
`i{d}e`, a byte string as `{d}:{s}`, so both use the same decimal formatting
bencode requires.

# Limits

- The input is a slice. `Reader.init` takes `[]const u8`, and there is no
  adapter for `std.Io.Reader`, so a whole value is in memory before it is read.
- Byte strings borrow. `decode` has no mode that copies them into the arena,
  so the input must outlive the tree. `decodeLeaky` behaves the same way.
- The depth cap is fixed. `max_depth` is 128, and `decode` takes no options.
- One value at a time at the top. `decode` rejects trailing bytes; for a
  stream of values, drive `Reader.next` yourself.
