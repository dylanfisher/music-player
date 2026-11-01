# 0027. Adversarial testing: a coverage-guided fuzzer, sanitizers, properties and mutation

- **Date:** 2026-11-01
- **Status:** accepted

## Context

Phase 14d asks for coverage-guided fuzzing of every parser and the tag writer, the whole suite
under ASan, TSan and UBSan, property tests for the queue, rescans and writer round trips, and
mutation testing of the core state machines. Everything has to ship with Xcode or macOS. Xcode's
toolchain has no libFuzzer (`libclang_rt.fuzzer_osx.a` isn't in it), so `-sanitize=fuzzer` is out.

## Decision

### Fuzzer

**Coverage hooks, built by SwiftPM without `unsafeFlags`.** A spike showed that
`swift build --sanitize=address -Xswiftc -sanitize-coverage=edge,trace-pc-guard` builds and
links: every Swift module gets `trace_pc_guard` calls and ASan, and C targets get neither, so the
callbacks themselves aren't instrumented. `scripts/fuzz` builds with those flags into
`.build/fuzz-build`, so the normal build, the tests and the app are untouched, and nothing in
`Package.swift` needs `unsafeFlags`. SwiftPM targets are one language each, so the C callbacks
are their own target, `Sources/Tools/FuzzCoverage`, beside the Swift driver `Sources/Tools/Fuzz`.

**Features.** Each guard has an 8-bit hit count. After each input the driver counts the
(edge, bucket) pairs no earlier input hit, with libFuzzer's buckets (1, 2, 3, 4-7, 8-15, 16-31,
32-127, 128+). An input with a new pair joins the corpus and is saved. In a build without the
flag nothing calls the hooks; a worker that sees no edges refuses to start.

**Targets.** One per parser, through the same `ByteReader` the scanner uses: `flac`, `mp4`,
`mp3` (ID3v1, ID3v2 and MPEG frames), `wav`, `aiff`, and `vorbis` (a comment block on its own).
Then the files the app reads at launch, each through its public API on a file in the target's
work folder: `config-file` (read, change a setting, read again; a good file must read back),
`state-file` (the same with a save), `undo-journal` (a record and a bytes file, read by
`TagUndoJournal.latest`, never undone, since a record names a path) and `smart-rules` (decode,
re-encode, store in a library and list; valid rules must list). `tag-writer` writes each input
to a file, applies an edit and undoes it, and the bytes must match. A broken invariant is a
`preconditionFailure`, which the fuzzer catches like any crash.

**Seeds.** The parsers' seeds are a generated library of `coveringLibraryFileCount` files
(`~/Library/Caches/MusicPlayer/fuzz/fixture-library`) and the tag corpus's APFS clones, picked
by content, not extension, and cut to 256 KB. `scripts/fuzz` makes the clones again from the
reference with `cp -c` into the tag corpus's clone folder; the tool only ever reads the clones.
The file targets make their own seeds: the config file the app writes, a saved state file,
journal records from real edits of generated files, and rules covering every field and
comparison. Over 300 seeds, every nth is kept. The mutator's dictionary is the target's few
fixed tokens plus what recurs in the seeds: runs of four ID characters (atom, chunk and frame
IDs) and quoted JSON strings. Harvesting keeps the format IDs defined once, in Metadata.

**Mutations,** after libFuzzer's: bit flips, random and edge-case bytes, 1, 2 and 4-byte edge
values in either byte order (sizes and counts), a 32-bit word nudged by up to 16, ranges
deleted, repeated or spliced in from another input, crossover, tokens, truncation. One to five
are stacked per input. A worker's mutations repeat with its seed.

**Supervisor.** `Fuzz run` starts workers (`Fuzz worker`) as child processes until the deadline.
A crash handler, installed for SIGABRT, SIGTRAP, SIGILL, SIGFPE, SIGALRM and, without ASan,
SIGSEGV and SIGBUS, and as ASan's death callback, writes the input that was running to
`crash-pending` with async-signal-safe calls only. An input running past 10 s is a hang
(SIGALRM). The supervisor minimises the input by removing ever smaller ranges and replaying each
candidate in a child (`Fuzz replay`), keeping a removal when the replay ends the same way, up to
400 replays. It saves the result and the replay's report under `.build/fuzz/<target>/crashes`,
and starts a new worker. Children run with `abort_on_error=1`, `max_allocation_size_mb=2048`, so
a size field that drives a huge allocation is a finding, and `SWIFT_DETERMINISTIC_HASHING=1`, so
a replay takes the same dictionary orders. A run keeps at most 10 crashes.

Each crash found becomes a minimised file under `Tests/<Module>Tests/Crashes/` with a test, and
a fix, in its own commit.

## Alternatives considered

- **A seeded mutation fuzzer without coverage**, the plan's fallback — not needed: the hooks
  build. Without coverage a fuzzer rarely gets past a parser's first size check.
- **`unsafeFlags` on a fuzz-only copy of each parser target** — rejected: two targets per
  module, and `-Xswiftc` already scopes the flag to one build.
- **One process, catching crashes in-process** — rejected: a Swift trap and an ASan report end
  the process; a child per worker is what libFuzzer's fork mode does.
- **Format IDs written out as the dictionary** — rejected: a second copy of every ID the
  readers define; harvesting from the seeds finds the same ones.
- **Fuzzing `undoLast` on hostile records** — rejected: a record names the file to restore, and
  the fuzzer must never write outside its work folder. The undo itself is fuzzed by `tag-writer`
  on records the journal wrote.

## Consequences

`scripts/fuzz <target> <seconds>` and `scripts/fuzz all <seconds>` (every target at once, a log
each in `.build/fuzz/<target>/log`) stay out of `./scripts/check`. The corpus in `.build/fuzz`
carries over between runs. Coverage of Foundation, SQLite and the standard library isn't seen,
only the package's own code. A new parser needs a target here.
