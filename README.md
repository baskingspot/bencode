<h1>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/static/logo-dark.svg">
    <img src="docs/static/logo.svg" alt="bencode" height="48">
  </picture>
</h1>

Bencode in Zig: an incremental reader, a value tree, and a writer.

Bencode is the format a torrent's metadata is written in: byte strings,
integers, lists, and dicts. This reads a stream one value at a time, decodes
one value into a tree you can walk, and writes it back.

The reader wraps any `std.Io.Reader`; `Io.Reader.fixed(input)` is the slice
case. A scanner does the grammar over whatever buffer the source hands over,
and a byte string is a slice into it, copied only when the whole string does
not fit. Keys come out in byte order because the dict is a sorted map, not an
array that has to be sorted before writing. With the file in one buffer,
`Scanner.cursor` gives the exact span a torrent's `info` hash covers.

```zig
var document = try bencode.decode(gpa, input);
defer document.deinit();
```

## What is in it

- [Reading a stream](https://baskingspot.dev/bencode/#reading-a-stream): `Reader` drives a `Scanner` from any `std.Io.Reader`; each `next` is one `Token`, and `nextAlloc` copies a byte string when it has to outlive the call.
- [The value tree](https://baskingspot.dev/bencode/#the-value-tree): `decode` returns a `Document` over an arena; `Value` is `bytes`, `int`, `list`, or `dict`, and `Dict` is `stdx`'s ordered map.
- [Writing](https://baskingspot.dev/bencode/#writing): `Value.format` writes a tree through `{f}`, and `Writer` takes the pieces when a tree is not what you have.
- [Limits](https://baskingspot.dev/bencode/#limits): byte strings that borrow their input, and a fixed depth cap.

Not implemented:

- Owned byte strings in `decode`: the tree borrows the input, and there is no mode that copies the strings into the arena. `Reader.nextAlloc` is the owning path.
- A configurable depth cap: `max_depth` is 128, and `decode` takes no options.
- A rewindable scanner: input moves forward only, so a token cannot be unread.

## Install

```sh
zig fetch --save https://baskingspot.dev/bencode/v0.1.1.tar.gz
```

Add the module in `build.zig`:

```zig
const bencode = b.dependency("bencode", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("bencode", bencode.module("bencode"));
```

`bencode` builds with Zig 0.16 and 0.17.

## Documentation

- The [guide](https://baskingspot.dev/bencode/) covers the scanner, the reader, the tree, and writing, with examples that compile.
- The [API reference](https://baskingspot.dev/bencode/api/) documents every public symbol.
- [`docs/examples/`](docs/examples/) is the code the guide shows, compiled by `just test`.
- [`AGENTS.md`](AGENTS.md) has the working notes for the repository.

## Work on it

```sh
just ci
```

`nix develop` provides the toolchain and the site tools. `just` lists the
recipes, and `just ci` runs what CI runs: the tests, lint, and the site build.
`just guide` serves the guide with live reload, and `just doc` builds the
whole site into `zig-out/site/bencode/`.

## License

MIT. See [`LICENSE`](LICENSE). The logo files in `docs/static/` are
baskingspot marks and are not covered by it. See
[`docs/static/LICENSE`](docs/static/LICENSE).

## How it's made

Built with LLM assistance. [How, in detail](https://github.com/baskingspot/.github/blob/main/docs/AI.md).

<a href="https://github.com/baskingspot"><img src="https://raw.githubusercontent.com/baskingspot/.github/main/brand/assets/badge.svg" alt="baskingspot" height="24"></a>
