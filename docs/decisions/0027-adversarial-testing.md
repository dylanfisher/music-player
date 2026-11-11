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
`mp3` (ID3v1, ID3v2 and MPEG frames), `wav`, `aiff`, `dsf` and `dff` (each file the parser reads then goes through the DoP reader, which must read
exactly the frames it promises; [0064](0064-dsd-over-dop.md)), and
`vorbis` (a comment block on its own).
Then the files the app reads at launch, each through its public API on a file in the target's
work folder: `config-file` (read, change a setting, read again; a good file must read back),
`state-file` (the same with a save), `undo-journal` (a record and a bytes file, read by
`TagUndoJournal.latest`, never undone, since a record names a path), `smart-rules` (decode,
re-encode, store in a library and list; valid rules must list) and `playlist-file` (M3U, M3U8
or PLS by the first byte; entries must be folded absolute paths, and written as M3U8,
absolute and relative, they must read back the same), `sync-log` (another machine's sync
log, line by line: each event must read back as written, and Foundation must read its paths
as relative, folded and in NFC; then the whole input is merged into a library, which must
not throw and must keep its problems under the cap), `swinsian` (a database through
`PlayerLibrary.read`, copied aside first) and `itunes-xml` (a `Library.xml`); for both, tracks
must have absolute NUL-free paths, one per path in NFC, with ratings in stars, and playlists
must name only tracks read. `swinsian-predicate` reads a smart playlist's archived rules
on their own; rules that map must be valid, and ones that don't must say why, 11 reasons at
most. `swinsian-columns` reads Swinsian's preferences for its column layout, which must make
a valid table layout ([0061](0061-swinsian-column-layout.md)). `tag-writer` writes each input
to a file, applies an edit and undoes it, and the bytes must match. Phase 9a's network
input: `receiver-line` (a receiver's status lines, split at each CR; volumes must be in range
and sound mode names printable and at most 25 characters), `device-description` (names,
manufacturers and models must hold no control character) and `soap-reply` (a
`GetProtocolInfo` sink list, at most 1,024 entries of four parts) and `chunked-body` (a
chunked HTTP body, never past its cap) ([0039](0039-network-control.md)). Phase 9b's:
`avtransport-reply` (`GetTransportInfo` and `GetPositionInfo` replies; states hold no control
character and times are finite and in range) and `service-description` (an action list, at
most 256 names), `http-request` (a request head and its `Range`; a served range stays in the file) and `didl-lite` (a track's tags in DIDL-Lite in a SetAVTransportURI request must read back as written) ([0041](0041-upnp-output.md)). Phase 51e's: `discogs-dump` (a batch of a Discogs dump's records, no more records than start tags) ([0134](0134-resuming-a-discogs-import.md)). A broken invariant is a
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

### Sanitizers

`scripts/sanitize` runs `swift test --sanitize=address`, `thread` and `undefined`, each in its
own scratch path (`.build/<sanitizer>`) so the three builds and the normal one don't evict each
other. Swift has no UBSan of its own (its integer and bounds checks trap in every build), so
`undefined` checks the C targets; swiftc doesn't link the UBSan runtime they then call, and the
script links `libclang_rt.ubsan_osx_dynamic.dylib` by hand. `--thread-runs <n>` repeats the TSan
run to find tests that depend on start order; the first run of each sanitizer has 1,000
property cases, the repeats the default 50, so 20 TSan runs take about an hour, not a day.

### Properties

`Fixtures.forEachPropertyCase` runs `PROPERTY_CASES` cases (50 in `./scripts/check`), each with
a `SplitMix64` seeded from `PROPERTY_SEED` (default 0x14D) plus the case number, and wraps the
first failure in an error naming the seed that repeats it. No property library: the generator
is a few lines the fixtures already had. The properties:

- **Queue:** random replaces, shuffles, inserts, moves and removes, against a model of the
  listed and play orders by URL: what plays at each position, where each old position went,
  and the next and previous positions under each repeat mode.
- **Rescans:** a random tree of generated files, changed at random (files added, deleted,
  moved, rewritten or touched; folders added, deleted or renamed), rescanned whole or by the
  changed folders as the watcher reports them, must index what a full scan into a new index
  does. A root left empty removes nothing, by ADR 0009's rule, and is checked for that instead.
- **Writer round trips:** random edits to a random generated file, each read back, then undone
  one at a time, each undo giving back the bytes from before its edit.

### Mutation

`scripts/mutate.swift` makes mutants only in code, not comments or strings: a comparison moved
across its boundary (`<` and `<=`, `>` and `>=`) or negated (`==` and `!=`), `&&` and `||`
swapped, a statement alone on its line dropped, and an integer literal plus or minus one. It
finds binary operators by the spaces the formatter puts around them, which generics, ranges and
shifts don't have. `scripts/mutate` runs them in 3 git worktrees of HEAD under `.build/mutate`
(`--jobs`, never more than there are mutants), each with its own scratch path, applying one
mutant, building only its entry's test targets and running their bundles as `scripts/test`
does, then checking the file out again; the main checkout isn't written. A mutant that doesn't
compile isn't counted. The files and line ranges are in `scripts/mutate-files.txt`.

Each job first runs the entries' tests unmutated, and the run refuses to score when they fail,
or when a mutant's tests never start: until phase 84 the script called `/usr/bin/timeout`,
which macOS doesn't have, so no test ran and every mutant that built counted as killed. A
mutant's run has three times its targets' unmutated time, 4 minutes at least, before a perl
parent kills it, polling, since an alarm reached neither the test helper nor a perl waiting
on it. A bundle that fails runs once more and counts only when it fails again: on a loaded
machine the watcher and search timing tests fail now and then. `LibraryBrowserTests` is run
with `--jobs 1`, since three of its window tests at once time out.

### What the runs found, and the mutants that survive

The fuzzer found two config file bugs: a doubled comma that crashed the scan (Foundation now
takes a trailing comma itself, so the blanker's half-blanked pair parsed), and problem
reporting that was quadratic in the file's size. The tag edit property found that a file's
second edit could never be undone after its first undo. The first mutation run scored 50% to
72% on most files; the tests added since bring it to 353 killed of 385 (91.7%): PlayQueue and
the tag writer's checks 100%, PlayCounter 93.8%, the engine 91.8%, the scanner 89.2%,
ConfigStore 86.8%, and PlayTracker 85.7% (6 of 7). Logging lines aren't mutated: no test reads
the log. Each of the 32 survivors is one no test can tell from the original:

- **Tuning constants:** the scanner's default 500-file batch (tests store in batches of 3
  through the scanner's test initializer, so the batching itself is covered) and the engine's
  256-update buffer.
- **Values every path sets before reading:** the engine's initial `failuresInARow` and
  `cursor`, `failuresInARow` reset in `setQueue` (every way to play resets it again),
  `cursor` on an empty `setQueue`, in `load`, after an edit and on a lost device (`cursor` is
  read only while nothing is loaded, and each way to unload sets it), the removed next item's
  `-1` placeholders (any value that isn't an entry), the `+ 1` after a removed current track
  (that position is nil), and `nextItem = nil` in two `finished` branches that already leave
  it nil.
- **Clean-up nothing can observe:** dropping finished subscribers, `wake = nil` after
  `cancel()`, and FSEvents' context `version`, which it ignores. The FSEvents stop, invalidate
  and release calls: the stream's context holds the watch's box unretained, so a stream left
  running past the watch's `deinit` would call into freed memory. That was checked: with the
  stop or the invalidate dropped, `aWatchThatsGoneCallsNothing` (a watch freed, then a write in
  its folder, then a second of run loop) passes under ASan, since either call alone takes the
  stream off its queue; a dropped release only leaks. The two calls after a failed start can't
  be reached without FSEvents refusing a start.
- **Equal results by another way:** a store not recording the bytes of its own write reads
  that write back on its next change and parses the same values, so no value, `changed` call
  or problem differs, only the work; `||` to `&&` on the same-bytes shortcut, which parses to
  the same values too; the shortcut sort with `<=` on unique keys; the scanner's subtree
  coalescing with `==`, which only scans a nested folder twice; an exact path match among
  protected paths, which are folders the walk couldn't list and never a file's path; the root
  check with `&&`, which differs only if a lost root comes back on the same device before the
  scan ends; and the play count's `>= needed - 0.001` as `>`, where no `Date` lands on the
  boundary.

ConfigStore's backoff is `nextRetry(after:)`, so the longest wait is tested directly, and its
retry timer is injectable, so the retry tests don't wait on real time.

### Scores measured again in phase 84

The scores and survivors above can't be repeated: from 1b6c9057 to phase 84 the script called
`/usr/bin/timeout`, which macOS doesn't have, so a run's scores said nothing. Measured on
2026-11-11 with the tests running, the seven entries score 450 killed of 528 (85.2%): PlayQueue
100% (40 of 40), PlayCounter 93.8% (15 of 16), PlayTracker 85.7% (6 of 7), the tag writer's
checks 85.7% (18 of 21), ConfigStore 84.7% (72 of 85), the engine 83.6% (249 of 298) and the
scanner 82.0% (50 of 61). Their survivors aren't sorted into the groups above yet; the engine's
are mostly the initial values and resets listed there.

Phase 84 added entries for the logic agents change most, and tests for each survivor that
matters. Before and after, at the phase's commits:

| File | Before | After |
|---|---|---|
| `Discogs/TieBreak.swift` | 57.6% (68 of 118) | 78.0% (92 of 118) |
| `Discogs/AlbumMatcher.swift` | 63.5% (61 of 96) | 88.5% (85 of 96) |
| `Library/LibrarySyncMerge.swift` | 56.1% (60 of 107) | 70.1% (75 of 107) |
| `Recommender/DownloadJob.swift` | 60.0% (12 of 20) | 100% (20 of 20) |
| `Downloads/DownloadsModel.swift` | 82.5% (47 of 57) | 94.7% (54 of 57) |
| `Downloads/Downloads+AutoUpgrade.swift` | 58.6% (17 of 29) | 82.8% (24 of 29) |
| `LibraryBrowser/BrowserModel.swift`, sort and steps | 62.9% (22 of 35) | 85.7% (30 of 35) |

The sync merge's After was measured before the test of a cleared rating, which kills one
more. The survivors left, none of which a test can tell from the original:

- **Weights and edges no input reaches:** tie-break step weights raised from 1 to 2, a step's
  `?? 0` for a tag the album lacks, which every release gets alike, the tie's `1e-9` margin and
  the matcher's caches and caps by one.
- **Clean-up of a row about to go:** a merged move's ratings, opinions, imported counts and
  clocks on the path it empties, and the merge's path cache. The move's case with no clock on
  either path holds only stats from before the clocks.
- **What nothing reads:** a run's progress before its first report, the reporter's stride,
  `reserveCapacity`, the default sleep's floor, a run's first cancel check, which the one per
  album repeats, and a move outside this Mac's folders, counted toward a problem line.
- **Equal results by another way:** the browser's selection timer cancelled, where a second
  timer settles the same pending place again, a step shown reloading its panes from the second
  column, and the sort from before a deleted playlist left set; a requeue giving up this Mac's
  review claim first, which the stand-in service doesn't hold it to.

Two survive tests written to kill them, for reasons not found: a stop leaving the downloads
model's polling task set, and forgetting the jobs left for review without rebuilding the rows.

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

`scripts/sanitize` and `scripts/mutate` stay out of `./scripts/check` too.

`scripts/fuzz <target> <seconds>` and `scripts/fuzz all <seconds>` (every target at once, a log
each in `.build/fuzz/<target>/log`) stay out of `./scripts/check`. The corpus in `.build/fuzz`
carries over between runs. Coverage of Foundation, SQLite and the standard library isn't seen,
only the package's own code. A new parser needs a target here.
