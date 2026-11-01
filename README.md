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

Byte strings are slices into the input, and `raw` on a finished container is
the exact bytes it occupied, so a torrent's `info` hash is a hash of the
bytes you already have. Keys come out in byte order because the dict is a
sorted map, not an array that has to be sorted before writing.

```zig
var document = try bencode.decode(gpa, input);
defer document.deinit();
```

The library is incubating: pin a commit, and expect the API to move.

## What is in it

- [Reading one value at a time](https://baskingspot.dev/bencode/#reading-one-value-at-a-time): `Reader.next` returns a `Token`; a list or a dict is a nested reader over the same cursor, and `raw` gives back a container's exact bytes.
- [The value tree](https://baskingspot.dev/bencode/#the-value-tree): `decode` returns a `Document` over an arena; `Value` is `bytes`, `int`, `list`, or `dict`, and `Dict` is `stdx`'s ordered map.
- [Writing](https://baskingspot.dev/bencode/#writing): `Value.format` writes a tree through `{f}`, and `Writer` takes the pieces when a tree is not what you have.
- [Limits](https://baskingspot.dev/bencode/#limits): a slice in, byte strings that borrow it, and a fixed depth cap.

Not implemented:

- Streaming from an `std.Io.Reader`: `Reader.init` takes `[]const u8`, so a whole value is in memory before it is read.
- Owned byte strings: `decode` borrows the input, and there is no mode that copies them into the arena.
- A configurable depth cap: `max_depth` is 128, and `decode` takes no options.

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

## Documentation

- The [guide](https://baskingspot.dev/bencode/) covers reading, the tree, and writing, with examples that compile.
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
