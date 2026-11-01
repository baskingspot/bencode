# AGENTS.md

Working notes for AI coding agents in baskingspot/bencode.

## What this is

Bencode in Zig: an incremental reader, a value tree, and a writer. v0.1.0 is
the first tag; the public API moves with semver.

`Scanner` holds the grammar over buffers the caller feeds; `Reader` drives one
from an `std.Io.Reader`, with the same split `std.json.Scanner` and
`std.json.Reader` use. `decode` builds the whole tree. Byte strings borrow the
buffer they arrived in. `Dict` is `stdx.btree.String(Value)`, which is what
makes key order canonical in both the tree and the output.

## Environment

Zig 0.16 only. The flake is the tool contract, from `baskingspot/nix`:
`nix develop` provides Zig, `ziglint`, `baskingspot-lint`, the docs tools, and
the base tools, and nothing comes from the system PATH. The justfile is the
command interface: `just test`, `just lint`, `just ci`. Run `just fmt` before
you commit.

Tests run under testingx, the org's test runner, a lazy dependency. Every
`addTest` carries `.test_runner = .{ .path = dep.path("src/runner.zig"), .mode = .simple }`
and a `--seed` argument.

`stdx` is a normal dependency, not lazy: `Dict` is part of the public API, and
a consumer resolves it through the module's own import.

The guide's examples in `docs/examples/` compile against the public module and
run with `just test`. A snippet in the guide that does not build is a bug.

## Rules

- Commit messages are one line, `area: summary`, and every commit is signed.
  Do not rewrite pushed history.
- Gate commands on their exit codes, and claim only what you ran.
- Format with `zig fmt`; lint with `ziglint` and `baskingspot-lint`, which runs
  the org's shared ast-grep rules. `just fmt` formats and `just lint` lints.
- Constructors are named, never a bare `.{}`: a type either carries a
  `pub const init`/`empty`/`zero` with the defaults spelled out, or a
  `pub fn init(...)` when there are variables to set. The fields stay
  required, so a bare `.{}` or a partial literal does not compile. An options
  bag is the one exception: a `Config`/`Options` struct a caller passes to a
  function or a type constructor keeps its field defaults, with
  `// ast-grep-ignore: public-struct-field-default -- options bag: call sites override one knob`
  between its doc comment and its declaration.
- This repo's GitHub settings come from `baskingspot/.github`, with
  `just settings`. Do not change them by hand.
- To graduate the project, follow the `baskingspot-new-repo` skill: logos, a
  real README, and the audit passing.

## Scanner and reader

- The scanner does no I/O. It returns `error.BufferUnderrun` when a feed runs
  out and keeps its place for the next one.
- A byte string token is one slice, so the scanner needs the whole payload in
  one `feedInput`. `Reader` gathers a payload that does not fit into a single
  allocation and frees it at the next call.
- Tokens are positional, like `std.json.Token`: a dict emits `dict_begin`, a
  `bytes` key, the value, then `dict_end`. The caller tracks position.
- The scanner copies each dict key into its allocator, because the next feed
  can invalidate the buffer the key came from and the order check needs it.
  That is why `Scanner.init` takes an allocator.
- Integers go through `stdx.fmt.atoiWith` with `.leading_zeros = .reject`, on
  a 21-byte copy of the digits so a feed can split them. Bencode's two extra
  rules (`+` and `-0`) live in `finishInteger`.
- `Reader.next` returns byte strings valid until the next call. `nextAlloc`
  copies into the caller's allocator and returns `allocated_bytes`.
- `decode` feeds the whole input to a scanner and builds the tree. It rejects
  anything after the first value (`error.TrailingData`) and stops at
  `max_depth` containers (`error.TooDeep`).

## Changelog

`CHANGELOG.md` is one file, Keep a Changelog format, newest first. Add a bullet
under `## [Unreleased]` in the same change that alters something a user can
notice: the public API, expected behavior, or the build requirements. Docs,
CI, and internal refactors do not need one unless they change how someone uses
the package.

Write from the user's side: what changed, and what they must do about it. Name
the symbol, flag, or error. One line, under Added, Changed, Fixed, or Removed.

To release, dispatch the repo's `release.yml` with the version. The workflow
moves the Unreleased section into a dated heading, sets `.version` in
`build.zig.zon`, commits, tags, and opens the GitHub release. Do not tag by hand.
