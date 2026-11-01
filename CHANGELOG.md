# Changelog

All notable changes to this project are documented here. The format is
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `Reader`: one value at a time from a slice, with `ListReader` and
  `DictReader` nested over the same cursor, zero-copy byte strings, and `raw`
  for a container's exact bytes.
- `decode` and `decodeLeaky`: a whole value as a `Value` tree, with `Document`
  owning the arena.
- `Dict`: `stdx`'s byte-ordered map, so keys are always in the order bencode
  requires.
- `Writer` and `Value.format`: write a tree, or the pieces one at a time.
