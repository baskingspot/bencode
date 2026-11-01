# Changelog

All notable changes to this project are documented here. The format is
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `Scanner`: the bencode grammar over buffers the caller feeds, with
  `error.BufferUnderrun` when a feed runs out and a cursor for slicing a
  container back out of the input.
- `Reader`: the scanner driven from any `std.Io.Reader`, with borrowed byte
  strings and `nextAlloc` when the caller needs to own one.
- `decode` and `decodeLeaky`: a whole value as a `Value` tree, with `Document`
  owning the arena.
- `Dict`: `stdx`'s byte-ordered map, so keys are always in the order bencode
  requires.
- `Writer` and `Value.format`: write a tree, or the pieces one at a time.
