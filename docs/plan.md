# Build plan

The roadmap from today's command-line player to the full app. Agents work through it phase by
phase, mostly unattended, and stop only at **hardware checkpoints**, where the owner has to try
something on the DAC Mac, the Denon, a phone, or the 2015 MacBook Pro.

Each phase ends with the [phase gate](#phase-gate): review, performance audit, and architecture
check. A phase isn't done until its gate passes.

## How to run it

Start a session with "run the next phase of docs/plan.md". For several phases unattended, say "use
a workflow to run phases N–M of docs/plan.md". For each phase, the orchestrating agent:

1. **Plans.** It reads the phase, the code it touches, and `docs/map.md`, then writes a short
   implementation plan under the phase heading: files, modules, tests, and order. It does a
   search first (map.md recipes), so it extends existing code instead of writing a second copy.
2. **Implements** on a branch `phase/<n>-<slug>` with an Opus subagent (per the owner's
   CLAUDE.md), in small commits that each pass `./scripts/check`.
3. **Runs the phase gate.** The reviewers and auditors are Sonnet subagents running in parallel.
   It fixes every confirmed finding, then reruns the gate.
4. **Records.** It ticks the phase's boxes, adds a "Result" line with measured numbers, commits,
   and fast-forwards `main` to the branch. It never pushes.
5. **Continues.** A hardware checkpoint doesn't stop the run. It's recorded as pending in the
   Result line, and the run moves on to the next phase that doesn't depend on its result. When
   the run ends, it lists every pending checkpoint at once: what to push, what to run on which
   machine, and what to paste back.

If something blocks a phase that only the owner can resolve (a product decision, missing
hardware, an Apple API that can't do what the phase assumes), stop and ask. Don't work around it.

### Current run order

Set by the owner on 2026-10-30, 2026-10-31 and 2026-11-02:

1. Finish phase 5. Its 2015 MacBook Pro checkpoint stays pending.
2. Phases 6, 7, 8, 11 and then 15, each through its gate.
3. Write the [hardening sub-plan](#14-hardening), committed as `docs: plan phase 14`, then run
   14a onward, each through its gate.
4. Phases 16 to 23 in order, each through its gate. Added by the owner on 2026-11-01.
5. Phase 9 last, if time is left, against a simulated renderer only. Nothing contacts the Denon
   or any real device: no SSDP on the LAN, no HTTP or receiver control to real addresses. Its Denon checkpoint stays
   pending.
6. Phases 24 to 28 in order, each through its gate, their rows in parallel. Added by the owner
   on 2026-11-02.
7. Phase 12 next, through its gate. Moved up by the owner on 2026-11-02. Its DSD to the Denon
   is built against the simulated renderer only, like phase 9, and its Denon and ADI-2
   checkpoints stay pending.
8. Phase 29 after phase 12, through its gate. Added by the owner on 2026-11-02.
9. Skip 10 and 13 for now. Phase 10 adds pairing tokens, a secret, so the owner decides how
   they're stored first (AGENTS.md).
10. Phase 34 first, alone, because it guards the library. Then 33, 35 and 36 in parallel, and
    37 after 36. Added by the owner on 2026-11-03.
11. Phase 39: 39a and 39c in parallel, then 39b. Added by the owner on 2026-11-03.

## Phase gate

Run after every phase, before ticking it off.

- [ ] **Gate:** `./scripts/check` passes.
- [ ] **Code review:** `/code-review high` on the phase branch. Fix confirmed findings in
      their own commits, then rerun the review until it finds nothing new above low severity.
- [ ] **Simplify:** `/simplify` on the same branch. Look especially for duplication across modules
      and for abstractions with one caller.
- [ ] **Performance audit:** `./scripts/bench` against the budgets in
      [Performance budgets](#performance-budgets). A budget miss blocks the phase. A regression
      over 10% against the last recorded result needs a fix or a written reason in the Result
      line.
- [ ] **Real-time audit**, if the phase touched playback: everything reachable from the IO proc
      is C in `HALRender` and uses no locks, no allocation, no logging and no ObjC. Ring buffer
      sizing is justified in a comment.
- [ ] **Architecture audit:** `docs/map.md` still describes the tree. No module reaches around
      another (the tier check only catches tier direction). Settings are read in one place. New
      user-facing strings and constants each have one definition.
- [ ] **Docs:** an ADR in `docs/decisions/` for every non-obvious choice. AGENTS.md boundaries
      updated if the phase created something that must not be edited directly, keeping AGENTS.md
      under ~50 lines.
- [ ] **Result line** written: what shipped, the benchmark numbers, and anything deferred.

## Performance budgets

These are targets for a 43k-track library, measured by `./scripts/bench` on the fixture library
(phase 1). "Old Mac" means the 2015 MacBook Pro on macOS 12, measured at hardware checkpoints.
Change a budget only with a reason in the Result line.

This table is the human copy. Each budget is defined in code next to its benchmark in
`Sources/Tools/Bench`, and the two change together.

| What | Apple Silicon | Old Mac |
|---|---|---|
| Cold launch to an interactive library window | < 1 s | < 2.5 s |
| Search-as-you-type, per keystroke (p95) | < 20 ms | < 80 ms |
| Re-sort the track table by any column | < 100 ms | < 250 ms |
| Full scan of the fixture library, local SSD | < 5 s | < 180 s |
| Rescan with no changes, on the NAS | < 30 s | < 60 s |
| Scan 3,000 fixture files on a simulated NAS (2 ms per operation, 16 at once), tuned readers | < 4 s | < 8 s |
| Scan 2,000 fixture files on a slow simulated NAS (about 60 ms per file with a long tail, 45 ms per listing, 24 at once), tuned readers, ending at 16 or more and within 80% of the best fixed level | < 10 s | < 20 s |
| Rescan with no changes, fixture library, local SSD | < 1.5 s | < 15 s |
| Rescan after renaming every fixture file, matching each move (phase 23); the old Mac figure is an estimate until its checkpoint | < 10 s | < 240 s |
| Merge 1M play events from another machine's sync log over 43k tracks (phase 23); the old Mac figure is an estimate until its checkpoint | < 20 s | < 120 s |
| Library database for the fixture library | < 60 MB | < 60 MB |
| Memory a scan of the fixture library adds, at its peak | < 50 MB | < 50 MB |
| Browser pane query: genres, artists, albums (p95) | < 2 ms | < 60 ms |
| Palette results per keystroke, Go to Item over every fixture track (p95) | < 15 ms | < 80 ms |
| Palette opening rows, Go to Item over every fixture track, ranked on the main actor before the panel shows (phase 24); the old Mac figure is an estimate until its checkpoint | < 4 ms | < 16 ms |
| List a smart playlist of six rules over every fixture track (p95); the old Mac figure is an estimate until its checkpoint | < 50 ms | < 150 ms |
| The list totals of every fixture track right after a play is recorded (p95; phase 32c); the old Mac figure is an estimate until its checkpoint | < 2 ms | < 12 ms |
| The second of two search keystrokes 50 ms apart, typed until its rows and totals are read, through the browser's reader (p95; phase 32c); the old Mac figure is an estimate until its checkpoint | < 20 ms | < 80 ms |
| The same while a scan rewrites every fixture file and the browser refreshes every 2 s (p95; phase 32c); the old Mac figure is an estimate until its checkpoint | < 50 ms | < 150 ms |
| Resident memory with the library loaded, after scrolling every row with art | < 120 MB | < 250 MB |
| Scroll every row by scroll-bar drag, a screenful a step with the Album Art column shown, time to scroll and draw a step (p95; phase 28); the old Mac figure is an estimate until its checkpoint | < 16 ms | < 33 ms |
| Trackpad scroll with the Album Art column, the main thread's busy time per frame (p95; phase 32b), each of: the default rows, compact rows under a 256 pt art column, and sorted by title with art on the slow simulated NAS; the old Mac figure is an estimate until its checkpoint | < 16 ms | < 33 ms |
| Trackpad scroll while a scan refreshes the list every 2 s, the busy time of a frame a refresh lands in (median; phase 32b); the old Mac figure is an estimate until its checkpoint | < 16 ms | < 33 ms |
| Page down sorted by title, art on the slow simulated NAS, to the last cover on screen (phase 32b); the old Mac figure is an estimate until its checkpoint | < 250 ms | < 500 ms |
| Page down 30 screens sorted by title, art on the slow simulated NAS, after a relaunch: the waits for each screen's covers added up (phase 32e); the old Mac figure is an estimate until its checkpoint | < 1 s | < 3 s |
| Live resize of the window and the Album Art column, a frame's main-thread time (p95; phase 32e, set from measurement in 32f: AppKit's relayout and redraw of the window); the old Mac figure is an estimate until its checkpoint | < 35 ms | < 70 ms |
| A row height change with the Album Art column, its frame (median; phase 32e); the old Mac figure is an estimate until its checkpoint | < 50 ms | < 150 ms |
| Every fixture track selected, Play Next to the files queued (median of 3; phase 32e); the old Mac figure is an estimate until its checkpoint | < 200 ms | < 600 ms |
| Every fixture track selected, Add to Playlist (median of 3; phase 32e); the old Mac figure is an estimate until its checkpoint | < 200 ms | < 1500 ms |
| Every fixture track selected, Get Info's read of a file (phase 32e); the old Mac figure is an estimate until its checkpoint | < 0.12 ms | < 4 ms |
| Decode a 3000 px JPEG cover to a 256 px column thumbnail (median; phase 32e); the old Mac figure is an estimate until its checkpoint | < 30 ms | < 120 ms |
| Decode a 3000 px PNG cover to a 256 px column thumbnail (median; phase 32e); the old Mac figure is an estimate until its checkpoint | < 150 ms | < 600 ms |
| Track change with the whole library queued and the queue panel open, to drawn (p95; phase 32b); the old Mac figure is an estimate until its checkpoint | < 8 ms | < 16 ms |
| CPU while playing 24/192 FLAC | < 3 percent of a core | < 5 percent of a core |
| CPU while playing 44.1 and 96 kHz FLAC converted for a device that takes only 48 kHz float (phase 31); the old Mac figure is an estimate until its checkpoint | < 3 percent of a core | < 6 percent of a core |
| Underruns in a 1-hour playback soak (`--soak 3600`; 20 s by default), with a full fixture scan every 5 minutes and a search every second | 0 frames | 0 frames |
| Memory growth in that soak, from the first scan trough after minute 5 to the last (30 s after each scan ends) | < 10 MB | < 10 MB |
| Gap between same-format tracks | 0 samples | 0 samples |
| Gap where tracks meet through conversion to 48 kHz float, 44.1 and 96 kHz albums, with the whole album within 1e-3 of full scale of the sine (phase 31) | 0 samples | 0 samples |
| Track change that switches sample rate | < 500 ms | < 500 ms |
| Double-click a row of the whole library (43k tracks) to the first frame in the output, null device; the old Mac figure is an estimate until its checkpoint | < 25 ms | < 100 ms |
| Main thread busy over that double-click; the old Mac figure is an estimate until its checkpoint | < 4 ms | < 10 ms |
| Double-click a track of the same rate while one plays, to the first IO cycle carrying it, null device with estimated HAL step times, slow simulated NAS (median of 5; phase 32a); the old Mac figure is an estimate until its checkpoint | < 100 ms | < 200 ms |
| The same, a track of another rate (phase 32a); the old Mac figure is an estimate until its checkpoint | < 250 ms | < 400 ms |
| The same, Next (phase 32a); the old Mac figure is an estimate until its checkpoint | < 25 ms | < 80 ms |
| The same, a seek while the track is decoded (phase 32a); the old Mac figure is an estimate until its checkpoint | < 25 ms | < 80 ms |
| The same, a seek in the last seconds after decoding moved on (phase 32a); the old Mac figure is an estimate until its checkpoint | < 25 ms | < 80 ms |
| A seek 20 ms after another, inside the refill that follows it, 24/192 FLAC on the slow simulated NAS, to playing from its target, null device (median of 5; phase 35); the old Mac figure is an estimate until its checkpoint | < 25 ms | < 80 ms |
| CPU when idle, the library window open and nothing playing, over a minute after the app reports its launch rescan done (`--report-launch`) and a 5 s settle; the old Mac figure set from the 32f checkpoint's 0.11% in phase 33 | < 0.1 percent of a core | < 0.15 percent of a core |
| Idle wakeups in the same minute, as `top` counts them | < 1 wakeups a second | < 1 wakeups a second |
| Load and validate settings, every key changed | < 2 ms | < 20 ms |
| Generate the fixture library | < 6 s | < 120 s |
| Rerun the fixture generator with nothing to do | < 3 s | < 30 s |
| Parse every fixture file's tags, first read in a fresh process | < 5 s | < 20 s |
| Tag journal: write a 1000-file batch with 1 MB art each, flushed per file | < 20 s | < 60 s |
| Play timeline: one page of 200 plays, 1M synthetic plays over the fixture library (p95) | < 5 ms | < 15 ms |
| History, one row per track played, 1M synthetic plays (p95) | < 30 ms | < 80 ms |
| Record a play, 1M synthetic plays (p95) | < 1 ms | < 6 ms |
| History table plus its index, 1M synthetic plays | < 40 MB | < 40 MB |
| Build the library health report over every fixture track (p95); the old Mac figure is an estimate until its checkpoint | < 1 s | < 3 s |
| Palette, Go to Item over every fixture track, the last of 8 keystrokes 50 ms apart to its results (median; phase 32d); the old Mac figure is an estimate until its checkpoint | < 15 ms | < 80 ms |
| Tag editor, read 200 fixture files with each file's opens on the slow simulated NAS (phase 32d); the old Mac figure is an estimate until its checkpoint | < 5 s | < 15 s |
| Launch to the first scan's start with a 1M-event sync merge pending (phase 32d); the old Mac figure is an estimate until its checkpoint | < 1 s | < 3 s |

## Phases

### 1. Foundations: settings, logging, benchmarks, fixtures

Everything later phases measure and configure against.

- [x] **Settings** module (Core): one typed schema holding every setting's key, type, default and
      description. Settings are stored as JSON, since phase 6 in the config file,
      `~/.config/music-player/config.json`, which lists every setting
      ([ADR 0015](decisions/0015-config-file.md)). The schema is the
      single source for defaults, the settings window (phase 6) and the command palette. A file
      that doesn't match the schema fails loudly, naming the bad key; it isn't silently replaced
      with defaults.
- [x] **Settings export and import:** export the full effective settings as JSON. Import a JSON
      file as overrides, validating it the same way.
- [x] **Logging** through `os.Logger`, with one subsystem and a category per module. Nothing logs
      from the real-time path.
- [x] **Fixture library generator** (`scripts/fixtures`): builds a 43k-file tree on local disk in
      the shape of a real library (artists, albums, mixed FLAC, ALAC, AAC, WAV, AIFF, MP3, varied
      tags, some with embedded art, a few malformed files). It takes a handful of real tiny
      encoded files (afconvert) and clones them with rewritten tag blocks. Fixture files go in
      `.build/` or `~/Library/Caches`, never in git.
- [x] **Benchmark harness:** a `Bench` executable target and `scripts/bench`. It runs named
      benchmarks, prints a table, and exits non-zero on a budget miss. Each later phase adds its
      own benchmarks. Bench stays out of `./scripts/check`, because it takes too long.

Implementation plan:

1. **Tools tier** (`Sources/Tools`, ADR 0004): tooling that must never link into the app. It may
   import every other tier and nothing imports it. `scripts/arch.swift` and `docs/map.md` learn it.
2. **Log** (Core): `bundleIdentifier` is declared once in Swift and is the log subsystem.
   `scripts/bundle` writes it into the `.app`'s Info.plist, the way it already writes the minimum
   macOS (ADR 0002). `moduleLogger()` takes its category from `#fileID`, so each module gets one.
   HALOutput, Playback and Settings log state changes; the IO proc and the CLI's stdout stay as
   they are.
3. **Settings** (Core): `Setting<Value>` declares key, default, summary and an optional range;
   `AppSettings` holds the declarations as stored properties, enumerated in order (ADR 0003).
   Values: Bool, Int, Double, String, string-backed enums, optionals, lists, and `WatchedFolder`.
   The store loads, validates (unknown key, wrong type, out of range, each naming the key),
   saves only changed values atomically, exports the effective settings and imports overrides.
   Phase 6 replaced it with `ConfigStore` and `StateStore`.
   The file URL is injected. Seeded with the output device UID, hog mode, watched folders and
   pausing polls during playback.
4. **CLI:** `--export-settings <path>` and `--import-settings <path>` next to `--play`.
5. **Fixtures** (Tools library) and **GenerateFixtures** (Tools executable, `scripts/fixtures`):
   seeds from afconvert (FLAC, ALAC, AAC, WAV, AIFF) plus hand-built silent MP3 frames, since
   macOS has no MP3 encoder. A deterministic plan of artists, albums and discs; per-file tag
   blocks (Vorbis comments + PICTURE, MP4 `ilst`, ID3v2.2/2.3/2.4, RIFF `LIST/INFO`); a set of
   malformed files; `manifest.json` with expected tags and audio properties. Written in parallel,
   skipped when the stored manifest already matches the plan (ADR 0005).
6. **Bench** (Tools executable, `scripts/bench`): `Benchmark` with a `Budget` per machine class,
   defined next to each benchmark. Phase 1 benchmarks: settings load and validate, fixture
   generation for 43k files, and the up-to-date rerun. Budgets join the table above.
7. Tests: LogTests, SettingsTests, FixturesTests (AudioToolbox decodes every valid fixture to the
   seed's samples and reads its tags back), BenchTests (budget selection and miss reporting).

Result: shipped as planned. Bench on Apple Silicon: settings load 0.18 ms (budget 5 ms), generating
43k fixture files 4.49 s (30 s), the up-to-date rerun 1.17 s (10 s). The fixture library is about
550 MB. The review added strict watched-folder keys, CLI errors for flags with no value, one
app-directory constant, and a test that keeps code budgets and this file's table in step. Deferred:
the CLI settings flags have no automated test, and `scripts/bench` builds only for the native arch,
so the phase 5 old-Mac run needs a prebuilt universal `Bench`.

### 2. Tag and format reading

- [x] Our own parsers (no dependencies) for FLAC/Vorbis comments, MP4 atoms (ALAC, AAC), ID3v2.2,
      2.3 and 2.4 (MP3, AIFF, WAV, and DSF later), and WAV `LIST/INFO`. They read the common
      fields, track and disc numbers, compilation and album-artist flags, and embedded art.
- [x] Audio properties from the container: codec, sample rate, bit depth, channels and duration,
      without decoding audio.
- [x] Malformed input never crashes or hangs: tests with truncated, oversized and garbage blocks,
      plus a fuzz test over the fixtures with random byte flips.
- [x] Benchmark: parse 43k fixture files cold.

Implementation plan:

1. **Metadata** (Core): `readMetadata(at:)` returns `TrackMetadata` (tags, audio properties, and
   embedded art as offset, length and MIME type) plus the bytes and reads it took. `readArt(_:at:)`
   reads one picture's bytes. Errors are a typed `MetadataError` with the path, the byte offset and
   what was wrong. One `ByteReader` per file reads through `pread` with a 16 KiB minimum, checks
   every length against the file size before reading, and skips art and audio by length.
2. Parsers, one file each: FLAC (STREAMINFO, Vorbis comment, PICTURE), MP4 (`moov` wherever it
   sits, `stsd` with the ALAC cookie or the AAC `esds`, `mdhd`, `iTunSMPB`, `ilst`), ID3v2.2–2.4
   over any byte range (unsynchronisation, extended header, v2.4 frame flags, footer), MPEG audio
   frames with Xing/Info and VBRI, WAV (`fmt `, `LIST/INFO`, `id3 `) and AIFF/AIFC (`COMM`,
   `ID3 `). The ID3v1 genre list lives here; Fixtures takes it from here instead of its own copy.
3. Tests (`MetadataTests`): every file of a 1000-file fixture library against its manifest entry,
   every malformed file failing with the expected kind, an AudioToolbox cross-check of rate,
   channels and length, hand-built truncated, oversized and garbage blocks per format, ID3
   unsynchronisation and art reads, bytes-read bounds for big art and a trailing `moov`, and a
   seeded byte-flip fuzz over a sample of fixtures.
4. **Bench:** "metadata: parse 43000 fixture files, first read in this process", reporting
   throughput, bytes read per file and the second pass. Benchmarks can attach notes to their row.
5. ADRs for the parser's strictness and I/O, and for what the cold benchmark measures.

Result: shipped as planned. Bench on Apple Silicon: 43k fixture files parsed in 2.29 s (budget 5 s),
about 19k files/s, 8.9 KB read per file in 1.11 reads on average. The second pass matches because
the page cache is warm; a truly cold read needs `sudo purge` (ADR 0007). After the first pass, a
bad field (such as track "A1", bad text encoding, or an iTunes non-syncsafe ID3v2.4 size) became a
per-file warning, not a failure, so messy real tags don't drop tracks. The review fixed truncated
WAV/AIFF bodies, QuickTime `udta` terminators, multi-reference TCON, Xing after a CRC, GIF and
untyped covers, and wide AAC layouts. Deferred: DSF to phase 12.

### 3. Library index and watched folders

- [x] **SQLite** primitive: a thin wrapper over system `libsqlite3` with prepared statements, a
      transaction helper, and errors that throw with the SQL and message.
- [x] **Schema:** tracks, albums, artists, and an FTS5 table for search. Plays, ratings and
      history go in their own tables, so a rescan never touches them. Because of the pre-release
      boundary there are no migrations: a schema mismatch means rebuilding the index, but keep the
      stats tables.
- [x] **Scanner:** a parallel file walk with incremental rescans keyed on path, size and mtime.
      It's NAS-friendly: one stat per file, bounded concurrency, and it can be paused and
      cancelled. Progress is reported, never blocking the UI.
- [x] **Watched folders,** configurable in settings: a list of roots, each with an include/exclude
      pattern list. FSEvents doesn't report changes on SMB volumes, so local roots use FSEvents and
      network roots use a polling rescan at a configurable interval (default 60 minutes, never
      while playback is starting). Optionally pause polling during playback.
- [x] Benchmarks: full scan, no-change rescan, and the query latencies the UI will need.
- [x] **Hardware checkpoint (owner):** scan the real NAS library on the DAC Mac. Report the time,
      the database size, and any files that failed to parse.
      Done 2026-10-30, Synology over wired Ethernet: 43,329 files, 0 failed, 0 warnings, 33.9 MB
      database. The cold first scan took 718.7 s at 60 files/s, and the controller held 3–8
      readers, which the stall fix after 3b addresses (ADR 0010). The no-change rescan took 25.4 s
      (budget 30 s). `xargs -P 16` showed the NAS scales about 17x with parallel reads.

Implementation plan:

1. **SQLite** (Primitives): `Database` and `Statement` over the SDK's `SQLite3` module, linked
   with `-lsqlite3`. Open flags, `execute`, prepare, bind, step and read columns, `transaction`,
   and `SQLiteError` carrying the result code, `sqlite3_errmsg` and the SQL. WAL, a busy timeout,
   foreign keys on. Neither type is `Sendable`: one connection per thread or actor.
2. **Metadata:** `MetadataWarning.Kind` and `MetadataError.Kind` get `String` raw values, so the
   index stores each kind by one name.
3. **Library** (Core), schema: `files` (path, size, mtime, failure), `tracks`, `artists`,
   `albums`, `genres`, `warnings`, and an FTS5 `track_search` with prefix indexes. Stats tables
   (`plays`, `ratings`, `history`) are keyed by path and created, not yet written. The SQL of each
   part is its identity, stored in the database: an index mismatch drops and recreates the index
   tables only. SQLite features stop at 3.36 (macOS 12). ADR for linking stats by path.
4. **Library** queries for phase 5: track IDs sorted by any column, FTS prefix search sorted the
   same way, the genre, artist and album panes, and the list of stored warnings and failures.
5. **Scanner:** walks each `WatchedFolder` with `contentsOfDirectory` and prefetched resource
   values (one stat per entry), applies include/exclude globs, compares (path, size, mtime) with
   the index, reads changed files in parallel (fewer workers on network volumes), and writes in
   batched transactions. `ScanControl` pauses and cancels; progress goes to an `AsyncStream`
   continuation buffering only the newest value. A missing, emptied or vanished root, or an
   unreadable directory, removes nothing under it. ADR for the scan's safety rules.
6. **Watcher:** `WatchState` decides what to scan and when (FSEvents subtrees, polls due, the
   playback hook), so tests drive it without timers. `LibraryWatcher` runs it with FSEvents for
   local roots, a one-shot timer for the next poll, and a serial scan queue. The app starts it
   with the folders from Settings.
7. **CLI:** `MusicPlayer --scan <folder> [--db <path>]`, with live progress, a summary, and a
   text file listing every warned or failed file.
8. **Bench:** full scan and no-change rescan of the fixture library, search keystroke p95, sort
   p95, browser pane p95, database size, and resident memory after a scan. Budgets join the table.
9. Tests: SQLiteTests, LibraryTests (schema rebuild keeps stats, queries, scanner incremental and
   removal rules, vanished roots, patterns, pause and cancel, watch state with a fake playback
   engine, one FSEvents round trip).

Result: shipped as planned, apart from the owner's checkpoint, which is pending. Bench on Apple Silicon: a full
scan of 43k fixture files takes 2.96 s (budget 60 s), a no-change rescan 0.90 s (5 s), search
keystroke p95 12.6 ms (30 ms), sort p95 43.7 ms (100 ms), pane query p95 0.56 ms (20 ms). The
database is 30 MB (60 MB) and a scan adds 17 MB at its peak (50 MB). The memory row now measures
what a scan adds; the whole-app budget is measured in phase 5. The review fixed an ejected root
emptying the index, a trailing "/" making duplicate tracks, case-only renames, excluded subtrees,
stale ID caches with two scanners, and roots spelled precomposed (ADR 0009). The App now hands
Library its watched folders. Known limit: one subfolder that lists as empty without an error has
its files dropped from the index until it lists again; stats survive.

Follow-up (3b), scan speed on network volumes:

1. **Controller** (Library): `ReadConcurrency`, a pure state machine fed one measured window at
   a time (files/s and seconds per file). Doubles from 4 while throughput rises clearly, then
   holds and probes ±25%, keeping the lowest level that matches the best, and halves when a held
   level's throughput collapses or its latency doubles. Clamped to 2…64 on network volumes;
   local volumes keep the core count. Tests drive it with simulated NAS curves.
2. **Pipeline** (Library): `ScanPipeline` replaces the walk-then-read sequence and
   `concurrentPerform`. Four lister threads walk directories depth-first and queue changed files
   in listing order; reader threads take them under a limit the controller changes mid-scan.
   The empty-root, vanished-root, unreadable-directory and filter rules stay, and removal still
   waits for a walk that finished.
3. **File access seam:** `ScanFileAccess` (list a directory, read tags, volume locality), so the
   bench and tests can scan through `SimulatedNAS` (Fixtures), which adds a fixed latency per
   operation and serves a bounded number at once.
4. **Fewer round trips:** measure Foundation's listing syscalls, `F_RDAHEAD`/`F_NOCACHE` on a
   disk image, and the reads-per-file distribution against the first read size; keep what helps.
5. **Settings and CLI:** `library.networkScanReaders` (null for automatic, or 1…64);
   `--scan … --readers <n>`; the summary prints the readers trace and files/s.
6. **Bench:** a fixture subset through `SimulatedNAS` at 2 ms per operation, adaptive against
   fixed 4, budgeted. ADR 0010 for the controller, the pipeline and the measured tricks.
7. `scripts/bundle release` refuses, with a clear message, a toolchain that can't link x86_64.

Result (3b): shipped as planned. Each full batch is stored outside the lock that readers share.
Bench on Apple Silicon: a full scan of 43k fixture files takes 1.26 s (was 2.96 s), a no-change
rescan 0.53 s (was 0.90 s), and a scan through a simulated NAS (2 ms per operation) runs 3.0x
faster tuned than with 4 fixed readers (2.46 s against 7.28 s, budget 4 s). The review fixed
pauses leaking into a measurement window, an unbounded `--readers`, and readers spawned at
scan end. Whether smbfs honours `F_RDAHEAD`/`F_NOCACHE` waits on the NAS checkpoint.

### 4. Playback engine

Turns the one-file command into the engine everything else drives.

- [x] An **output** protocol with two implementations: `HALOutput` now, UPnP in phase 9. The
      engine never knows which one it's driving.
- [x] **Queue** and a state machine: play, pause, stop, next, previous, seek, repeat and shuffle.
      State changes go out as one observable stream that the UI, media keys and the remote all
      read.
- [x] **Gapless:** the next track decodes ahead. Same format means no reconfigure and zero gap.
      A rate change reconfigures the device between tracks.
- [x] **Device handling:** pick the output device in settings, by UID so it survives renames. If
      the device is unplugged, pause and report it rather than switching to the speakers. When it
      reappears, offer to resume.
- [x] **Volume:** none in the bit-perfect path. An optional digital volume, off by default, says
      plainly that it stops the output being bit-perfect.
- [x] Restores the device and default outputs on every exit path, as `ExclusiveDevice.close()`
      does today.
- [x] Benchmarks: playback CPU, a 1-hour soak with underrun count, and gap measurement.
- [x] **Hardware checkpoint (owner):** on the ADI-2, play a gapless album, a playlist mixing
      44.1 and 96 kHz tracks, unplug the DAC during playback, and quit with Ctrl-C. Confirm the
      macOS default output is restored after each.
      Done 2026-10-30 on the ADI-2 and approved by the owner: the gapless album, Ctrl-C and restore
      all worked, and the DAC took each file's exact rate in 32-bit non-mixable hog mode. Rate
      changes measured 839–843 ms against the 500 ms budget, so the fix is on `fix/rate-switch-time`.

Implementation plan:

1. **RingBuffer:** `RingBufferSkip`, a consumer-side discard, so a seek never resets the buffer
   under the reader.
2. **HALRender** (C): atomics the IO proc shares with the decode thread. A consumed-bytes
   counter times track boundaries and position. `HALRenderDiscard` is the seek handshake: the
   producer names a byte range, and the IO proc skips it when it gets there (at once for a seek)
   while the producer keeps writing after it. A draining flag and the refill after a
   discard keep expected silence out of the underrun count. An atomic gain, ramped per buffer, for
   the optional digital volume; at unity the samples are copied untouched.
3. **Playback** (no CoreAudio): the `Output` protocol at the track level (load, set next, play,
   pause, stop, seek, position, volume, and an event stream naming each item), `PlayQueue`
   (order, shuffle, repeat off/one/all), and the `PlaybackEngine` actor, whose `updates()`
   streams every state change with the event that caused it. Tests drive it with a fake output.
   The single-file `playFile` and `FileDecoder` move to HALOutput first, so the dependency runs
   HALOutput → Playback.
4. **HALOutput:** `ExclusiveDevice` becomes `HALDevice`: hog mode follows the setting, and it
   restores a snapshot taken by UID at the session's first open. `PCMDevice` and
   `PCMDeviceProvider` are the seam between the output and a device. `HALDeviceProvider` finds
   the device by UID and listens to `kAudioHardwarePropertyDevices` and
   `kAudioDevicePropertyDeviceIsAlive`. A restore record in Application Support, deleted after a
   clean close, lets the next run put the device and default outputs back after a crash.
   `DeviceOutput` implements `Output` on one control thread: it decodes ahead into the ring
   buffer, records each track's start as a byte position, gaplessly appends a next track of the
   same rate and channels, and drains and reconfigures between tracks that differ.
5. **Settings:** `output.digitalVolume`, off by default, saying it stops output being
   bit-perfect.
6. **Fixtures:** `NullDevice`, a `PCMDeviceProvider` that pulls `HALRenderIOProc` on its own
   thread at real-time pace or as fast as it can, captures what it pulls, and can be unplugged.
   Playback fixtures generated with afconvert into the cache: a ramp split into a two-track album
   at 44.1/16 and at 96/24, and two minutes of 24/192 FLAC.
7. **CLI:** `--play` takes files and folders as a queue (a folder by disc and track from tags,
   then filename). Keys: space, n, p, ←/→, r (repeat), s (shuffle), -/+ (digital volume), q. It
   prints track changes with the device format, rate switches with their time, device lost and
   returned, and underruns. The terminal mode and the device are restored on q, Ctrl-C, SIGTERM
   and the end of the queue.
8. **Bench:** CPU playing 24/192 FLAC for 30 s through `NullDevice` at real-time pace, gap
   samples across a same-format boundary, a rate-switching track change, and a soak (20 s by
   default, `./scripts/bench --soak 3600` for the hour) counting underruns.
9. Tests: RingBufferTests, HALRenderTests (discard while reading, draining, gain kinds),
   PlaybackTests (queue rules, engine state machine), HALOutputTests (sample-exact gapless
   continuity, rate-change sequencing, seek, pause, device loss and return, restore record).
   ADR 0011 for the output protocol and the HAL output's design.

Result: shipped up to the owner's checkpoint, which is pending. Bench on Apple Silicon: same-format gap 0
samples, a rate-change track switch 29 ms on the output path (budget 500 ms), soak underruns 0, CPU
while playing 24/192 FLAC 2.78% of a core. That budget went from 2% to 3% by the owner's choice:
AudioToolbox's FLAC packet scan costs about a quarter of decode time. If the 2015 MacBook Pro misses
its 5% at phase 5, we write our own FLAC decoder (ADR 0011). The review fixed silence inserted
when a queued next track changed, stale or overwritten crash-restore records, a restore that
stopped at its first error, and engine subscriber leaks. Not wired yet: pausing library polls
during playback, which waits for the phase 5 window.

### 5. Main window

- [x] AppKit window: a sidebar (library, playlists, watched folders), Swinsian-style column
      browser panes (genre, artist, album), and an `NSTableView` of tracks with configurable,
      sortable and reorderable columns. A now-playing bar with art, seek and time.
- [x] Search field filtering through FTS5 as you type.
- [x] Queue view: reorder, remove, and "play next".
- [x] Album art loaded lazily and cached at display size. No full-size images held in memory.
- [x] Window layout and column state are saved through Settings.
- [x] Benchmarks: launch to interactive, search keystroke, re-sort, and memory.
- [ ] **Hardware checkpoint (owner):** run the release build on the 2015 MacBook Pro (macOS 12,
      Intel) with the real library. Report launch time and how scrolling and searching feel, and
      run `./scripts/bench` there.

**Look and controls** ([ADR 0012](decisions/0012-searcher-conventions.md)): the layout follows
Swinsian, not Music.app, and behaviour questions go Swinsian's way. Native AppKit controls,
system colours and materials, and hover, pressed, focused and disabled looks on every control.
The layout keys were saved with the settings; phase 6 moved them to the state file.

Implementation plan:

1. **SQLite:** bind a parameter list as well as variadic values, for queries whose filters vary.
2. **Settings:** `TrackColumn` (every column the table can show and sort by) moves here from
   Library's `TrackSortColumn`, since Settings stores the layout and Library can import Settings
   but not the reverse. New values `WindowFrame` and `TrackTableLayout`, strict about keys like
   `WatchedFolder` (the third such type, so the unknown-key check is shared). Keys for the window
   frame, split positions, queue panel, visible columns with order and widths, sort, the sidebar
   source and the pane selections (by name, since IDs change on a rebuild).
3. **Library:** `files.added_seconds` for "date added". `TrackFilter` (watched folder, genre,
   artist, album, search) narrows `trackIDs` and the panes, each pane by the panes to its left.
   `TrackRow` and `rows(ids:)` fetch a page of rows by ID in one statement; `track(path:)` for the
   queue and now playing. `LibraryReader`, an actor with its own connection, runs the ID, search
   and pane queries off the main thread. `LibraryWatcher` reports each scan's progress and summary
   through a callback, so the window refreshes and shows scan problems.
4. **Playback:** queue edits on the engine: play next, move and remove, in play order, keeping the
   current track playing (removing it moves on). `PlaybackState.order` exposes the play order.
   `clock` and `kilohertz` move to a `DisplayText` primitive, since three features show times and
   rates.
5. **Artwork** (Core): `ArtworkLoader` reads art with `readArt`, decodes it straight to a thumbnail
   at display size with ImageIO, and keeps a bounded cache. Never holds a full-size image.
6. **Features:** `LibraryBrowser` (sidebar, whose Playlists group stays empty until phase 7; Genre |
   Artist | Album panes, the track table with a paged row cache, search, the play-selection order),
   `NowPlaying` (the bar: art, title, artist, transport, seek, times, format line) and `QueueView`
   (the side panel). View models hold the logic and are tested; the AppKit views stay thin. Features
   never import each other.
7. **App:** the window composes the three, and wires `PlaybackEngine`, `DeviceOutput`
   (created after the first rows are drawn, never playing on its own) and `LibraryWatcher`,
   including its playback hook. Settings are read once at launch and passed in; layout changes are
   saved through Settings, coalesced. Watched folders are added and removed from the sidebar.
   `--settings <file>` points the app at another config file, and `--home <folder>` keeps every
   file in one folder.
   `--measure-window` prints launch-to-first-rows and memory, after scrolling the whole table and
   loading art, as JSON and quits, for Bench. `--snapshot <file>` draws the window into a PNG.
8. **Bench:** launch to interactive and resident memory (the app run as a subprocess against the
   fixture library), search keystroke p95 and re-sort through the view model. `scripts/bundle
   release` also writes a universal `Bench` beside the `.app`, which builds its own fixtures.
9. Tests: SQLiteTests (list binding), SettingsTests (new values and keys), LibraryTests (filters
   across panes, search with panes, every sort column, rows by ID, date added, watcher events),
   PlaybackTests (queue edits), ArtworkTests (thumbnail size, cache bound), LibraryBrowserTests
   (pane cascade, search plus panes, sort, row cache eviction, play-selection order, selection kept
   across a refresh), NowPlayingTests, QueueViewTests, MusicPlayerTests (the watcher hook).
   ADRs for the window's data flow and the launch measurement.

Result: shipped as planned; the 2015 MacBook Pro checkpoint is pending. Bench on Apple Silicon: launch
to the first rows drawn 0.60 s (budget 1 s), memory after scrolling all 43k rows with art 53 MB
(250 MB), search keystroke p95 12.7 ms (30 ms), re-sort p95 42.5 ms (100 ms). The review fixed the
selection and scroll anchor following row numbers instead of tracks, overlapping filter changes
dropping one another, sort state committed before its query, oversized column widths stopping
layout saves, watcher events applied out of order, and stale queue and now-playing rows. The default
layout now fits 1440x900 with the queue open. Known limit: the album pane lists one row per album,
so albums that share a title by different artists repeat by name.

### 6. Commands, shortcuts, command palette, settings window

Ported from Searcher's decisions, not its code ([ADR 0012](decisions/0012-searcher-conventions.md)).
Read 0012 and the Searcher records it lists before planning this phase.

- [x] A **command registry**: every user action is one command with an ID, a title, and up to
      two default chords, primary and alternate. A chord has one spelling (`cmd+shift+k`). Two
      defaults on one chord throw at registration. Menus, key handling, the palette, the
      Shortcuts pane, the config file and the remote API all read from it. No action exists
      outside it. Boolean and choice settings get generated commands.
- [x] **Menus from command IDs:** every command has a menu item, its primary as the key
      equivalent and a hidden item for the alternate. Reserved chords (Quit, Hide, Minimize,
      Settings…) can't be rebound; the Edit items' chords stay fixed. Unbound ⌘/⌃/⌥ chords beep.
      Row movement and type-to-select as Searcher's 0029 and 0034.
- [x] **Default chords** from 0012's tables: player conventions (Space, Return, ⌘←/⌘→ …), with
      Searcher's keys where the job is the same (⌘K, ⌘P, row movement, ⌘F …).
- [x] **Configurable shortcuts** for every command, with a recorder per slot in a Shortcuts
      pane. A clash names the other command, with Replace and Cancel; the user's chord beats a
      default, and the loss is logged and shown.
- [x] **Config file** at `~/.config/music-player/config.json`: JSON with comments, every
      preference listed with a comment when the file is created, patches that keep the user's
      text, live reload, and an error banner that applies nothing from a broken file. Open
      Config File and Copy Default Config commands. `--export-settings` and `--import-settings`
      go.
- [x] **App state** (window layout, sort, pane selections, the palette's place, frecency) moves
      from the settings to `state.json` in Application Support.
- [x] **⌘K palette** (commands, settings, artists, albums, genres, playlists) and **⌘P Go to
      Item** (rows of the current track list): one panel, Searcher's keys, fuzzy matching (0079)
      and ranking with frecency (0085), driven only by the keyboard. Results in < 30 ms per
      keystroke (< 80 ms on the old Mac) at 43k rows.
- [x] **Settings window** in AppKit: General generated from the settings schema, so a new
      setting appears there without any UI code, and a Shortcuts pane.
- [x] **Appearance** setting: auto, light or dark.

Implementation plan, in six slices, each its own commits:

1. **Registry.** `Primitives/KeyChord`: a key plus modifiers with one stored spelling
   (`cmd+shift+k`), the menu's symbols (⌃⌥⇧⌘), and the conversions to and from `NSEvent` and
   menu key equivalents. `Core/Commands`: `CommandID`, `Command` (ID, title, up to two default
   chords), `CommandRegistry` (a clash between defaults throws), `KeyBindings` (defaults, the
   user's overrides, reserved and fixed chords: the effective chords, what was dropped, and the
   rules for assigning a chord), `AppCommands` (every command, in menu sections), and the commands
   generated from the settings schema. Settings gains a title per setting, `Appearance` and
   `ShortcutOverride`.
2. **Menus and keys.** `App`: the main menu built from the sections, a hidden item per
   alternate, reserved and fixed chords, chords that change in place. `CommandDispatcher`
   (Commands): a handler and an enabled check per ID, and the key rule (bound runs, unbound
   ⌘/⌃/⌥ beeps). Row movement (`RowMove`, Commands) and type-to-select (`TypeSelect`,
   LibraryBrowser) in the track table and panes; Space, Return, the arrows and Tab through the
   focused list's `keyDown`. The search field takes Esc, ↑ and ↓ and keeps ⌘←/⌘→.
3. **Config file.** Settings: `ConfigText` (comments, trailing commas and a BOM blanked to
   spaces, a scan of key spans, patches that keep the text), `ConfigFile` (the file's settings
   and shortcuts, errors by line and key, the default text), `ConfigStore` (watched with
   FSEvents, reloads, a queue of patches that waits while the file is broken).
   `~/.config/music-player/config.json`; `--home <folder>` puts the config file, library, state
   file and device record in one folder for tests, Bench and runs on the build Mac. The error
   banner, Open Config File and Copy Default Config. `--export-settings` and `--import-settings`
   go.
4. **State file.** The layout keys move to `AppState`, a second schema saved by `StateStore`
   to `state.json` in Application Support, discarded whole when it
   doesn't decode.
5. **Palette.** `Primitives/FuzzyMatch` (0079's scores, top-k without a full sort).
   `Features/Palette`: the model (sources, ranking with kind and frecency bonuses off the main
   actor, latest query wins), the borderless panel and its rows. ⌘K lists commands, settings,
   genres, artists and albums; ⌘P the current track list, read by `LibraryReader` off the main
   actor. Frecency and the panel's place go to the state file. Bench: a keystroke over 43k rows.
6. **Settings window.** `Features/SettingsWindow`: a toolbar of panes. General is an
   `NSGridView` generated from the schema with Open Config File, Reveal in Finder and Copy
   Default Config; Shortcuts has a search field, sections as the menus, two recorders and Reset
   per row, Reset All. `--snapshot-of` takes `main`, `palette`, `settings` or `shortcuts` to draw that window.

Tests: KeyChordTests (spellings, text-editing chords), FuzzyMatchTests, CommandsTests (clashes, overrides, reserved and fixed,
assign, generated commands, row moves), SettingsTests (config text, patches, errors, store
reloads, state file), LibraryBrowserTests (type-to-select), PaletteTests (ranking, frecency,
latest query), SettingsWindowTests (General rows from the schema, the Shortcuts model),
MusicPlayerTests (every command has a menu item, key equivalents, the palette's library rows).
ADRs for the decisions 0012 leaves open.

Result: shipped as planned. Bench on Apple Silicon: Go to Item keystroke p95 6.75 ms over 43k rows
(budget 30 ms), launch 0.61 s, search p95 12.5 ms, re-sort p95 41.8 ms, playback CPU 2.81% (3%,
close to the limit). The review fixed the palette merging same-titled albums by different artists
(albums are now keyed by title and album artist), menu chords such as ⌘⌫ firing while a text field
was being edited (one key-down monitor now hands text-editing chords to the field editor first),
late palette items lost to a race and resetting the selection, config patches left waiting after a
confirmed re-read, a refused value staying in its General field, inserting a key into an object
whose `}` shares the last member's line, the palette edge ignoring live appearance changes, and
silent failures in config, layout and state writes. `--snapshot-of` without `--snapshot` now fails.
Known limit: ⌘↑ and ⌘↓ stay with the menu even in a text field.

### 7. Playlists, smart playlists, stats

- [x] Manual playlists: create, rename, reorder, and add with drag and drop or a command.
- [x] Smart playlists: a rule editor (field, operator, value; any or all; limit and sort) that
      compiles to SQL. They update live as the library changes.
- [x] Play counts, skip counts, last played, ratings and a history view, all in SQLite and never
      in files. A play counts after 50% or 4 minutes.
- [x] Benchmark: evaluating a complex smart playlist over 43k tracks.

Implementation plan:

1. **Library.** Playlists live beside the stats in the part an index rebuild keeps (ADR 0008):
   `playlists` (name, smart rules as JSON or null) and `playlist_entries` (playlist, position,
   path), each track at most once per playlist. `SmartRules` (Core/Library): rules of field,
   operator and value, all or any, an optional limit picked by an order; decoded strictly at
   every level and compiled to one SQL condition, with the stats joined by path. A
   `BrowserSource` (Settings, since the state file saves it) replaces the filter's folder: a
   watched folder, a playlist or History. New columns: plays, skips, last played, rating and
   playlist order. Writes for plays, skips, ratings and playlist edits go through
   `LibraryReader`, off the main thread.
2. **Playback.** `PlayCounter` turns the engine's updates into plays and skips: a play counts
   once the track has played (not paused) for half its length or 4 minutes, and a skip when
   another track starts before that. It gives the app the time the current track would count,
   so one timer per track does it, nothing polls.
3. **LibraryBrowser.** The sidebar lists History under Music and the playlists by name; a
   manual playlist opens sorted by playlist order, History by last played. Tracks dragged from
   the table onto a manual playlist are added; dragged within a playlist sorted by order, they
   move. The browser reloads the sidebar after edits, and refreshes after plays and ratings.
4. **PlaylistEditor** (new feature): the rule editor's model (rows of field, operator and
   value; all or any; limit and its order) and an AppKit sheet of pop-up buttons and fields.
5. **App.** Commands for New Playlist (⌘N), New Playlist from Selection (⇧⌘N), New Smart
   Playlist… (⌥⌘N), Edit Smart Playlist…, Rename Playlist…, Delete Playlist…, Add to
   Playlist…, ratings 0–5, and ⌘⌫ removing from a playlist as well as the queue. Playlists in
   ⌘K. Plays recorded from `PlayCounter`. `--snapshot-of playlist` opens the rule editor.
6. **Bench:** a smart playlist of six mixed rules (text, numbers, stats, dates) with a limit
   ordered by plays, over the fixture library, p95 < 50 ms on Apple Silicon.
7. Tests: LibraryTests (rules decode and compile, every field and operator, playlists and
   entries survive an index rebuild, stats by path, limits), SettingsTests (`BrowserSource`),
   PlaybackTests (`PlayCounter` thresholds, pauses, skips, repeats), LibraryBrowserTests
   (playlist sources, default sorts, reorder), PlaylistEditorTests, MusicPlayerTests (menu
   items, palette playlists). ADR for the playlist and stats choices.

Result: shipped as planned. Bench on Apple Silicon: a six-rule smart playlist over 43k tracks p95
37 ms (budget 50 ms; the old Mac's 150 ms is an estimate until its checkpoint), re-sort 42 ms,
launch 0.62 s. Stats and playlists are keyed by path, so they survive an index rebuild. The review
fixed rows dropped onto their own block jumping to the end, untagged tracks matching year rules as
year 0, the Order sort leaking out of manual playlists, ⌘⌫ removing playlist rows while another
list had focus, a play lost when its timer woke early, Stop counting as a skip, history recording a
playlist whose rules can't be read, and reused playlist IDs. The play timer moved to
`Core/Playback/PlayTracker`. Known limits: number rules compare whole numbers, so a 200.4 s track
is not "more than 200"; the dialogs and drag and drop are tested only through their models.

### 8. System integration

- [x] Media keys and headphone controls via `MPRemoteCommandCenter`.
- [x] Now Playing in Control Center via `MPNowPlayingInfoCenter`, with art.
- [x] Dock menu with the current track and transport controls.
- [ ] **Hardware checkpoint (owner):** on the DAC Mac, after pushing, run `./scripts/pull` and
      play an album with art to the ADI-2. Then check each of these and report which work:
      1. Press F8 (play/pause) twice, then F9 (next) and F7 (previous), with another app in
         front.
      2. With AirPods or wired headphones with a remote connected to that Mac, press the stem
         or button once (play/pause), twice (next) and three times (previous).
      3. Open Control Center and expand Now Playing: the title, artist, album and art show, the
         time moves while playing and stops when paused, dragging the scrubber seeks, and the
         buttons work.
      4. Right-click the Dock icon: the title and "artist — album" show above Play/Pause, Next
         Track and Previous Track, and each works.
      5. Choose Controls ▸ Stop: Now Playing in Control Center goes back to empty.

Implementation plan:

1. **Playback.** The engine publishes `.seeked(seconds:)` after a seek, so anything showing the
   time re-anchors it without polling.
2. **NowPlaying** (the feature that already has the bar's model) gains the system side, without
   AppKit or MediaPlayer except in `DockMenu.swift` (AppKit), `SystemRemoteCommands.swift`
   (MediaPlayer) and `SystemNowPlaying.swift` (AppKit and MediaPlayer): `RemoteCommand` (the
   remote commands and what each runs: Play/Pause, Play, Pause, Stop, Next Track, Previous Track
   from the registry; the scrubber's position seeks the engine as the bar's slider does), `RemoteCommandCenter` and
   `NowPlayingCenter` (protocols over `MPRemoteCommandCenter` and `MPNowPlayingInfoCenter`),
   `NowPlayingInfo` (title, artist, album, duration, elapsed at an anchor time, rate, art, and
   the art's size for a requested box), and `MediaControls` (applies updates: which commands are
   on, the info re-anchored only on track start, pause, resume, seek, device changes and
   metadata changes, cleared on stop; art read off the main thread through `ArtworkLoader`).
   `DockMenu` lists the current track and the transport commands, titles from the registry,
   enabled from the dispatcher. `SystemRemoteCommands` and `SystemNowPlaying` are the
   MediaPlayer adapters.
3. **App.** Builds `MediaControls` with the adapters, connects it to the engine, passes library
   refreshes on, and answers `applicationDockMenu`.
4. **Docs.** MediaPlayer on AGENTS.md's frameworks line; an ADR for the choices.
5. **Tests.** PlaybackTests (seek publishes), NowPlayingTests (commands enabled by state, each
   remote command runs its registry command, play and pause by state, seek clamped, info on
   start, pause, resume, seek and stop, no update for events that change nothing, elapsed
   extrapolated when art arrives, art sizes, the Dock menu's items).

Result: shipped up to the owner's checkpoint, which is pending. Bench on Apple Silicon: playback
CPU 2.77% (budget 3%; Now Playing adds no timer), launch 0.62 s. The review made remote Play and
Pause absolute (new Play and Pause commands) so a double press can't flip state through a lagging
model, ran off-main remote calls synchronously on main so they report their real status, checked
commands live, refused NaN seeks and clamped seeks inside the track, and carried the position in
each engine update so Control Center's time can't pair with a newer state. Untested until the
checkpoint: the MediaPlayer adapters' off-main path.

### 9. UPnP/DLNA output (Denon AVR-X1800H)

Split in two on 2026-11-01. 9a builds everything that can be checked against loopback stand-ins.
9b needs the owner at the receiver, and starts from captures of the real one: its device
description XML, its `GetProtocolInfo` reply, and the status lines it sends on port 23.

#### 9a. Network control

- [x] **HTTP server** primitive on Network.framework: serves files with `Range` support, bound to
      the LAN, and only to paths the library knows about. Nothing calls it until 9b.
- [x] **SSDP discovery** of MediaRenderers, and fetching each renderer's description and
      `GetProtocolInfo` to learn what formats it accepts.
- [x] Info.plist gets `NSLocalNetworkUsageDescription` (no Bonjour entries: SSDP isn't Bonjour).
- [x] **Receiver control** over Denon's AVR control protocol: plain-text commands ending in a
      carriage return, on TCP port 23. It works on any input, not only while the Denon plays the
      UPnP stream. The receiver's address comes from SSDP discovery.
      - Commands in the registry: receiver volume up, down and set (`MV`), mute (`MU`), sound mode
        with Pure Direct, Direct and Stereo (`MS`), input (`SI`), power (`PW`).
      - The receiver pushes a status line whenever its state changes, including from its own
        remote or front panel. The model follows those lines, not what the app last sent.
      - At least 50 ms between commands, as Denon's spec asks, so held volume keys are throttled.
      - Many Denon models accept one control client at a time. When the connection is refused or
        dropped, the UI says the receiver is unreachable; it doesn't retry silently.
      - Off by default: nothing on the network starts until the owner turns receiver control on.
      - Tests run against a simulated receiver on loopback.
- [x] **Security requirements** ([ADR 0025](decisions/0025-threat-model.md), rows 28–30), each
      with a test against a loopback stand-in:
      - "Local subnet" means, per interface that's up, its IPv4 address and netmask or its IPv6
        prefix; an IPv6 link-local address counts only with the zone it arrived on. On a Mac
        with several interfaces, an address is matched against the one interface whose subnet
        holds it. The interface list is injected, so tests can make up interfaces.
      - The HTTP server listens only on the interface address the renderer reached the Mac on,
        on a port the system picks, accepts connections only from that subnet, and stops when
        no renderer is in use.
      - It serves only tracks the index holds, by a token mapped to a track ID, never a path in
        the URL. Tokens are 128 random bits, per track per session, expiring with the session or
        after 24 hours. Anything else is 404 without touching the file system: no directory
        listings, no links followed, files opened read-only.
      - `GET` and `HEAD` only, and the `Host` header must be the bound address and port, against
        DNS rebinding. A request line and headers over 8 KiB, a body, more than one `Range`, or a
        range outside the file is refused; at most 8 connections, each closed after 30 s idle.
      - SSDP replies, device descriptions and SOAP replies are hostile: replies only from the
        local subnet, at most 64 KiB; a `LOCATION` followed only to `http` on the subnet the
        reply came from, with redirects refused; descriptions and replies capped at 1 MiB, parsed
        by `XMLParser` with external entities off, timed out after 5 s. A renderer's name is
        escaped like any other display text.
      - The receiver's address comes only from SSDP on the local subnet, or, when SSDP finds
        none, from `receiver.address`, a literal address on a local subnet. Its status lines are at
        most 135 bytes, the cap in Denon's protocol spec, and at most 135 bytes are buffered
        without a carriage return before the connection is dropped and reported; unknown lines
        are ignored and values range-checked before the model takes them; commands come from the
        registry, never from received text. The protocol has no authentication, so the app sends
        only what the owner asked for.
      - The Info.plist item above adds only the local network usage string and Bonjour types; no
        new entitlements unless `scripts/check-signature` lists them with a reason.
- [ ] **Hardware checkpoint (owner):** with the receiver's IP Control set to Always On, turn
      receiver control on, switch Pure Direct on and off, change volume and input from the app,
      then from the Denon's remote, and report whether the app follows. Paste back the captures
      9b starts from.

Implementation plan (ADR 0039):

1. **LocalNetwork** (new primitive): `IPAddress` and `NetworkInterface`, the live interface
   list from `getifaddrs` (up, not loopback or point-to-point), and `LocalSubnets`, which
   finds the one interface whose subnet holds an address. One HTTP head parser with a byte cap,
   shared by the three users below. `SSDPSearch`: the M-SEARCH, reply parsing and `LOCATION`
   checks, over an injected `SSDPTransport`; the real one is a UDP socket whose destination
   is passed in, so tests aim it at a loopback stand-in. `LocalHTTPClient`: GET and POST on
   `NWConnection` to a checked `LocalURL` only, no redirects, a byte cap and a deadline, chunked
   bodies decoded. `HTTPServer`: `NWListener` on one address, a token map, and the request
   rules. Network.framework instead of URLSession, so no proxy, cache, redirect or ATS rule
   sits between the app and the checks.
2. **UPnP** (new Core module): device description and SOAP parsing with `XMLParser` (external
   entities off, any DTD refused), `GetProtocolInfo`, and `RendererDiscovery`, which turns SSDP
   replies into `Renderer`s with names escaped as display text.
3. **Receiver** (new Core module): the line parser, the commands as typed values encoded to
   bytes, the state the pushed lines build, and `ReceiverConnection` on `NWConnection` (135-byte
   cap, 50 ms between commands and 1 s after power on, a refused or dropped connection reported
   and never retried on its own). `ReceiverControl` finds the one Denon among the discovered
   renderers and connects only to that address.
4. **Settings and Commands:** `receiver.enabled`, false by default, and `receiver.address`,
   a literal address used only when SSDP finds no receiver and only on a local subnet. Registry commands for volume
   up, down and set, mute, Pure Direct, Direct and Stereo, each input, power on and standby, in
   a Receiver submenu of Controls with the setting's toggle. Only Receiver Volume Down runs from
   links.
5. **App:** start receiver control when the setting is on, stop it when it's turned off; route
   the commands and the set-volume argument; report problems in the status bar.
6. **Info.plist:** `NSLocalNetworkUsageDescription`.
7. **Fuzz targets:** `receiver-line`, `device-description` and `soap-reply`.
8. **Tests:** LocalNetworkTests (subnets with made-up interfaces, SSDP replies hostile, oversize
   and off-subnet, `LOCATION` refusals, the client against loopback servers that redirect,
   send too much or stall, every server rule), UPnPTests (descriptions and SOAP, XXE and a DTD,
   oversize, discovery end to end on loopback), ReceiverTests (a simulated receiver on loopback:
   pushed lines, an oversize line, a line with no CR, refused and dropped connections,
   throttling), CommandsTests (the receiver commands and links). Network tests looped 20 times
   under a timeout.

Result: shipped up to the owner's checkpoint, checked only against loopback stand-ins; nothing
contacted the receiver. `receiver.enabled` is off by default. LocalNetwork holds the interface
list and subnet rules, SSDP over an injected transport (per interface, TTL 1, an interface that
fails is skipped), a capped HTTP client and the token file server 9b will use; UPnP reads
descriptions and SOAP replies as UTF-8 XML with no DOCTYPE. The receiver is found by SSDP (an
"AVR" model, a `LOCATION` only on the replying device), else at `receiver.address`, a literal IP
on a local subnet, and found again on the next command after it moves. Controls › Receiver has
power, volume, mute, Pure Direct, Direct and Stereo, and inputs; the menu follows the
receiver's pushed lines, cleared on a drop; a silent connection is unreachable after 1 s, with a
hint that another app may hold it. Lines are capped at 135 bytes (the X1000 spec), commands 50
ms apart. Inputs, power and `MV` levels are confirmed by the owner's scripts; the rest is † in
ADR 0039. Fuzz targets: receiver line, description, SOAP reply, chunked body.

#### 9b. UPnP output

- [ ] A **UPnP output** that implements the phase 4 output protocol, using AVTransport (set URI,
      play, pause, seek, `SetNextAVTransportURI` for gapless) and RenderingControl (volume). It
      sends original file bytes. Formats the renderer can't take are reported, not transcoded.
      It serves tracks through 9a's HTTP server.
- [ ] Renderers appear next to HAL devices in the output picker.
- [ ] Tests against a fake renderer on loopback, built from the owner's captures.
- [ ] **Hardware checkpoint (owner):** play 16/44.1, 24/96 and 24/192 FLAC to the Denon. Report
      what its display shows, gapless behavior, seek, and volume.

Implementation plan (ADR 0041), from the owner's captures of the Denon and two Sonos speakers:

1. **Fixtures.** Scrubbed copies of the captures in `Tests/UPnPOutputTests/Fixtures` and the
   status lines in `Tests/ReceiverTests/Fixtures`: addresses to 192.0.2.x, UUIDs, serials,
   MACs, household and network IDs to fake values, every other byte as captured.
2. **UPnP:** a `Renderer` keeps its AVTransport control and description URLs, checked like
   any other URL a description names. SOAP actions with escaped arguments; replies read
   through `XMLTree`, and a fault's UPnP error code and text kept from a status 500 reply.
   AVTransport's `GetTransportInfo` and `GetPositionInfo` replies, `H+:MM:SS` times range
   checked, a service description's action names (for `SetNextAVTransportURI`), DIDL-Lite
   for a track with every tag escaped and control characters dropped. Receiver control's
   "is it a Denon receiver" rule moves onto `Renderer`, where the output reads it too.
3. **Playback:** `PlaybackEngine.use(_:)` moves playback to another output mid-track, at the
   position it had, and ignores events from any output but the current one. `SignalSink`
   gets a renderer case and `SignalVerdict` an `unverifiable` one.
4. **UPnPOutput** (new Core module): `RendererOutput` implements `Output` for one renderer.
   One task runs commands and polls in order, so nothing overlaps and nothing runs on the
   main thread. A track is read by the Metadata parsers (no decoding), offered under the
   first MIME type of its container the renderer's sink lists, or reported; the HTTP server
   starts on the interface the renderer is on, serves only the current and next items by
   token, and stops when nothing is loaded. `SetNextAVTransportURI` when the renderer's
   AVTransport description lists it, otherwise set-URI on track end with the gap logged.
   Position and track end come from polling `GetTransportInfo` and `GetPositionInfo` once a
   second; three failed polls in a row or a failed command loses the renderer.
5. **Settings and App:** `output.renderer`, a renderer's UDN, null by default, sits beside
   `output.deviceUID`; set, the app finds it by SSDP and plays to it, null plays on the
   device. `--list-devices` lists renderers after the devices. The signal path panel follows
   whichever output is in use. The app's digital volume is off while a renderer plays; the
   Denon's volume is the receiver's (port 23).
6. **NowPlaying:** the signal path panel says the bytes go unchanged to the renderer, which
   decodes them, so bit-perfect can't be checked from the Mac, and whether it's gapless.
7. **Fuzz targets:** `avtransport-reply`, `service-description`.
8. **Tests:** UPnPTests (SOAP, faults, times, actions, DIDL escaping, the captured
   descriptions), PlaybackTests (switching outputs), UPnPOutputTests against a fake renderer
   on loopback built from the captures (play, pause, seek, next URI, set-URI fallback, track
   end, a renderer that vanishes, stalls or plays something else, unsupported formats, the
   renderer fetching the file with `Range`), ReceiverTests (the captured status lines),
   NowPlayingTests (the panel's renderer lines). Network tests looped 20 times.

Result: shipped up to the owner's checkpoint, checked only against a fake renderer on loopback
built from the captures; nothing contacted the receiver. `output.renderer` (a UDN, null by
default) plays to a renderer found by SSDP, and `--list-devices` lists renderers with their
UDNs. Files go as their own bytes: FLAC, WAV and MP3 to both renderers, MP4 (ALAC or AAC) as
the Denon's `audio/m4a` and the Sonos's `audio/mp4`, AIFF to the Sonos and reported on the
Denon, hi-res as it is; the library holds no DSD. Both captured AVTransports list
`SetNextAVTransportURI`, so the next track goes over while one plays; a renderer without it,
or one that refuses it or stops instead, gets each track after the last stops, the gap logged.
Polling once a second, not GENA. No volume is sent to a renderer: the Denon's is the
receiver's over port 23. The signal path panel says the renderer decodes the bytes and
bit-perfect can't be checked from the Mac. Fuzz targets: AVTransport replies, service
descriptions. Benches left for the merge.

### 10. Web remote

- [ ] **API:** HTTP plus WebSocket JSON on the phase 9 server. It exposes the command registry,
      playback state, queue, library browsing and search, and pushes state changes to every
      connected client.
- [ ] **Pairing:** a code shown in the app is exchanged for a token. Clients without a token get
      nothing. LAN only, configurable port, and the whole remote can be switched off.
- [ ] **Web app:** static HTML, CSS and JS in `Support/`, with no framework and no build step,
      sized for phones. Now playing, transport, queue, browse and search.
- [ ] Several clients stay in sync with each other and with the Mac UI.
- [ ] **Hardware checkpoint (owner):** control playback from a phone and a second computer at
      once, and pair a new device.

### 11. Tag editor

This replaces the read-only boundary in AGENTS.md. Do it first in the phase, with an ADR.

- [x] **New boundary:** music files are written only through the tag-writer module, only for a
      tag edit the user confirmed, and never by tests against real libraries.
- [x] **Writers** for FLAC/Vorbis, MP4, ID3v2.3/2.4 (MP3, and the AIFF and WAV `ID3 ` chunk),
      reusing the phase 2 parsers.
- [x] **Safety:** write to a temp file next to the original, then re-read it and check that the
      audio payload is byte-identical (hash before and after) and that the tags read back as
      written. Replace atomically. Keep an undo journal of the old tag blocks for the last N
      edits. Any check failing leaves the original untouched.
- [x] **UI:** an editor for one track or a batch, with mixed-value display for multiple
      selection, and art replace and remove.
- [x] **Corpus round trips:** every file in the test corpus below survives every edit and its undo.
- [ ] **Hardware checkpoint (owner):** open the edited corpus clones in Swinsian and Finder, then
      edit tags on copies of a few NAS files, then on real ones. Confirm both apps read the
      results. Do this once the owner has pushed the phase. Each snippet is for Terminal (zsh)
      and runs under bash.
      1. **Corpus clones, on the build Mac.** This makes fresh clones of the corpus (the
         reference is only read; the tool names both folders), makes a JPEG to use as art, and
         opens the app watching the clones:
         ```
         bash <<'EOF'
         set -euo pipefail
         cd ~/projects/music-player
         paths=$(./scripts/tag-corpus --paths)
         reference=$(printf '%s\n' "$paths" | sed -n 1p)
         clones=$(printf '%s\n' "$paths" | sed -n 2p)
         home=~/Library/Caches/MusicPlayer/tag-editor-check
         rm -rf "$clones" "$home"
         mkdir -p "$home"
         cp -c -Rp "$reference" "$clones"
         icons=/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources
         sips -s format jpeg -Z 600 --out "$home/cover.jpg" "$icons/GenericFolderIcon.icns" \
           > /dev/null
         printf '{"library.watchedFolders": [{"path": "%s", "kind": "local"}]}\n' "$clones" \
           > "$home/config.json"
         ./scripts/dev --home "$home"
         EOF
         ```
         In the app, with Swinsian quit: select the three tracks of Latoma EP, press ⌘I, set
         Album to "Latoma EP Perälä", Save, then Change Tags. Do the same for Compilation
         Tracks (AIFF), Alithia A' and Anima (both M4A). On one track of Anima also choose
         Replace Artwork… and pick `cover.jpg` in the app home above
         (`~/Library/Caches/MusicPlayer/tag-editor-check`, ⇧⌘G in the panel), and on one track
         of Latoma EP choose Remove Artwork. Then in Finder, open
         `~/Library/Caches/MusicPlayer/tag-corpus` (⇧⌘G) and check each edited file's preview
         pane shows the new album and art. In Swinsian, add those four folders, check the
         same, then remove them from Swinsian's library. Back in the app, choose File ▸ Undo
         Tag Edit six times, once per edit. No alert should appear; if "Couldn't undo the tag edit for …"
         appears, paste its text.
      2. **Copies of NAS files, on the DAC Mac.** This copies one random album folder from the
         library to `/Volumes/music/tag-editor-check` on the NAS, outside the library, makes a
         JPEG to use as art, and makes an app home that watches the copy:
         ```
         bash <<'EOF'
         set -euo pipefail
         library=/Volumes/music/library
         check=/Volumes/music/tag-editor-check
         home=~/Library/Caches/MusicPlayer/tag-editor-check
         # A random album folder with at least two audio files.
         album=$(find "$library" -mindepth 2 -maxdepth 2 -type d -print0 \
           | while IFS= read -r -d '' dir; do
               count=$(find "$dir" -maxdepth 1 -type f \( -iname '*.flac' -o -iname '*.m4a' \
                 -o -iname '*.mp3' -o -iname '*.aif*' -o -iname '*.wav' \) | wc -l)
               if [ "$count" -ge 2 ]; then printf '%s\n' "$dir"; fi
             done \
           | awk 'BEGIN { srand() } { a[NR] = $0 } END { print a[int(rand() * NR) + 1] }')
         [ -n "$album" ] || { echo "no album folder found under $library" >&2; exit 1; }
         rm -rf "$check" "$home"
         mkdir -p "$check" "$home"
         cp -Rp "$album" "$check/"
         icons=/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources
         sips -s format jpeg -Z 600 --out "$home/cover.jpg" "$icons/GenericFolderIcon.icns" \
           > /dev/null
         printf '{"library.watchedFolders": [{"path": "%s", "kind": "network"}]}\n' "$check" \
           > "$home/config.json"
         echo "copied: $album"
         echo "to:     $check"
         ls -l@ "$check"/*
         EOF
         ```
         In Finder, give the first file of the copy a Red tag. Then run:
         ```
         cd ~/projects/music-player
         ./scripts/pull --home ~/Library/Caches/MusicPlayer/tag-editor-check
         ```
         Select every track, press ⌘I, set Comment to "tag editor check", choose Replace
         Artwork… with `cover.jpg` from that app home, Save, then Change Tags. Then edit one
         track's title alone while Swinsian plays that track from the copy. Report
         whether Swinsian and Finder show the new comment, title and art, whether the Red tag
         is still there, the text of any alert, and the output of
         `bash -c 'ls -la@ /Volumes/music/tag-editor-check/*'`, where no `.tagwrite` file
         should be left. Then choose File ▸ Undo Tag Edit twice. SMB may round a file's mtime
         or give it a new file ID on rename; the writer records both as the NAS reports them
         after the rename, so undo should work without "the file changed after the tag
         edit". Report whether it does.
      3. **Real files, on the DAC Mac.** Run `cd ~/projects/music-player && ./scripts/pull`,
         pick one album, press ⌘I, set Comment to "tag editor check", Save, then Change Tags.
         Check Swinsian shows it, then choose File ▸ Undo Tag Edit and check Swinsian shows
         the old comment again. Afterwards,
         `rm -rf /Volumes/music/tag-editor-check ~/Library/Caches/MusicPlayer/tag-editor-check`
         removes the copies.

**Test corpus.** The owner put 159 real files (12 GB) in `/Users/dylanfisher/Music/music-player/test`
to show how real tags are stored, and to try writes on. That folder is the reference copy. Read it,
never write to it. Every write goes to a copy made with `cp -c` (an APFS clone, so it's quick and
takes no extra space) in `~/Library/Caches/MusicPlayer/tag-corpus/`. A copy is recreated from the
reference before each run. The new boundary's ADR names both paths.

What it holds (surveyed 2026-10-30):

- **99 `.m4a`:** 97 ALAC and 2 AAC. 61 have `moov` after `mdat`, and 38 have it before, with
  1.9–4 KB of `free` padding. All use `stco`. Their `ilst` holds `©nam ©ART ©alb aART ©day ©gen
  ©grp ©wrt ©cmt ©too cprt trkn disk rtng soar covr` plus iTunes `----` freeform atoms.
- **24 `.mp3`:** all ID3v2.4 with padding and no ID3v1. Besides the common frames, they have
  `APIC TXXX WXXX TIPL TMOO TMED TPUB TDOR TSO2 TSOP GRP1 PRIV UFID RGAD`.
- **36 `.aiff`:** chunks `COMT COMM SSND ID3 `, with the ID3 chunk *after* the audio.
- **No FLAC, and no ID3v2.2 or 2.3.** Those writers are tested against the generated fixtures only.

How the phase uses it:

1. **Survey first.** Before writing any writer code, `TagCorpus` (Tools, `scripts/tag-corpus
   [folder]`, defaulting to the path above) lists every file's tag layout: atoms and frames, sizes,
   padding, where the audio payload starts and ends, and art. Record the surprises in the phase 11
   ADR.
2. **Writers for these layouts:**
   - MP4 `ilst` both ways round. With `moov` before `mdat`, grow into `free` first. Past that,
     rewrite `moov` and shift every `stco`/`co64` offset.
   - ID3v2.4 in MP3: use the padding first, then rewrite.
   - The AIFF `ID3 ` chunk: fix the chunk and `FORM` sizes and the pad byte.
3. **Keep what we don't edit.** Every atom, frame or chunk the edit doesn't name stays
   byte-identical: `----`, `rtng`, `soar`, `©too`, `PRIV`, `UFID`, `RGAD`, `TXXX` and the rest.
   That includes their order where the format allows it.
4. **Round trips over every corpus file:** `scripts/tag-corpus --round-trip` edits each clone and
   checks it.
   - Edits:
     - a title of the same length, shorter, and long enough to outgrow the padding
     - non-ASCII text ("Perälä")
     - clearing a field, and adding one the file lacks
     - replacing the art with larger and smaller art, and removing it
     - a batch album edit across one album folder
     - undoing each edit
   - Checks after every edit:
     - The audio payload hash is unchanged.
     - Our reader reads back exactly what was written.
     - An independent reader agrees: `AVAsset` metadata, plus `afinfo` for duration and format.
     - Every untouched atom or frame is byte-identical.
     - Undo restores the file byte for byte, compared with `cmp` against the reference.
5. **Failure injection** on clones: a read-only file, a full disk (a small disk image), a crash
   between writing the temp file and renaming it, and a file changed between read and write. Each
   leaves the original byte-identical.
6. **Keep the file's attributes:** permissions (the corpus is `0700`), extended attributes and
   Finder tags. Only mtime changes.
7. `./scripts/check` stays hermetic: the corpus run isn't part of it. The phase gate runs
   `scripts/tag-corpus --round-trip`, and the Result line reports files, edits and failures.

Implementation plan:

1. **Boundary.** ADR 0020 names the writer module, the reference folder and the clone folder;
   AGENTS.md's read-only line is replaced by the new rule.
2. **Metadata** shares its walkers with the writer through `package` access (`ByteReader`,
   `Bytes`, `forEachAtom`, `forEachChunk`, `FileFormat`, `MP4Type`, the field-key tables), so the
   writer removes exactly the keys the reader maps to a field. It reads a 2.3 date from `TYER`,
   `TDAT` and `TIME`.
3. **TagWriter** (Core): `TagLayout` lists every block of a file (MP4, ID3v2 in MP3/AIFF/WAV,
   FLAC) with its range, its kind and the fields that replace it, plus padding and the audio
   payload; `TagCorpus` surveyed the corpus with it before anything was written. `TagEdit`
   holds the fields to set or clear and the art to replace or remove. `MP4File`, `ID3File`
   (with `ID3Tag`) and `FLACFile` plan each edit as segments of new bytes and old ranges.
   `TagWriter` runs one edit over one file or a batch: `FileReplace` writes the temp file
   beside the original (an APFS clone patched in place when nothing moves), copies the
   attributes and flushes it; `FileHash` hashes the payload and the whole file; the temp file is
   read back and checked, journaled, then renamed over the original once the original's identity
   still matches. `TagUndoJournal` keeps, per edit, a folder of per-file JSON records and raw
   old bytes, flushed before each rename and capped at 50 edits and 512 MB; undo goes through
   the same checked write and must match the original's hash. `multiValuedFields` finds fields
   whose frame or item holds several values.
4. **TagCorpus `--round-trip`** runs every edit of step 4 above on clones, with the five checks,
   the attribute checks and the failure injections; `scripts/tag-corpus` makes the clones and
   the full-disk image (HFS+, attached inside the clone folder) and detaches it on exit.
   `--paths` prints the reference and clone folders. Every write is refused outside the clone
   folder and the temp directory, and through a dangling link.
5. **Library:** `LibraryWatcher.rescan(directories:)` queues edited folders, network ones too.
6. **TagEditor** (Features): `TagEditorModel` (one or many tracks, mixed values, which fields
   changed, art, number checks, the note when a field's other values will go), `TagEditorSheet`
   (AppKit) and `TagEditing` (reads off the main thread, one write at a time, a confirmation for
   a batch). Commands: Edit Tags… (⌘I), Undo Tag Edit, Replace Artwork… and Remove Artwork.
   `--snapshot-of tags` draws the editor over every track.
7. **Bench:** the journal's cost for a 1000-file batch with 1 MB art each.
8. **Tests:** MetadataTests, TagWriterTests (every format and edit on generated fixtures and
   hand-built files: co64, FLAC without padding, ID3 chunks before the audio, 2.3 dates; the
   refusals; untouched blocks; attributes; every failure injection; the journal and undo),
   TagCorpusTests (the write guard), TagEditorTests (the model and `TagEditing`'s sessions,
   busy state and confirmation), LibraryTests (edited-folder rescans), MusicPlayerTests (flags).

Result: shipped up to the owner's checkpoint, which is pending. Corpus round trip on fresh clones:
159 files, 1,557 edits, 0 failures; the reference folder's 160 hashes matched before and after
every run. Every failure injection (read-only file, full disk on a disk image mounted inside the
cache folder, a crash before the rename, a file changed between read and write) left the original
byte-identical. Bench on Apple Silicon: the undo journal for a 1000-file batch with 1 MB art
13.5 s (budget 20 s). The review made the journal append-only per file, capped by bytes and
flushed before each replace (it had been re-saved whole after every file), wrote ID3v2.3 dates as
TYER/TDAT/TIME instead of TDRC, warned before an edit drops a field's other values, compared the
inode on undo, refused hard links and dangling links, and threw instead of crashing on frames over
256 MB. Known limits: ID3v2.2, unsynchronised tags and fragmented MP4 are refused; undo is a menu
command, not ⌘Z; the SMB fallbacks are untested until the checkpoint.

### 12. DSD over DoP

- [x] DSF and DFF parsers, and DSD in the library (rate shown as DSD64, DSD128 or DSD256).
- [x] DoP packing in Swift on the decode thread, with markers 0x05/0xFA in the top byte. The IO
      proc stays a byte copy.
- [x] DoP carrier selection: DSD64 at 176.4 kHz, DSD128 at 352.8 kHz, DSD256 at 705.6 kHz. A
      device without the rate is refused, never converted.
- [x] DSD to the Denon over UPnP, if its `GetProtocolInfo` lists it.
- [ ] **Hardware checkpoint (owner):** DSD64, DSD128 and DSD256 on the ADI-2. Its DSD indicator
      lighting is the bit-perfect proof for the whole HAL path.

Implementation plan (ADR 0064):

1. **Metadata:** `DSF.swift` and `DSDIFF.swift` beside `AIFF.swift`, sharing a `DSDStream`
   (rate, channels, where the bits are, block or byte interleaving, bit order) that the reader
   in HALOutput uses too. DSF reads its ID3v2 tag at the header's metadata pointer, DSDIFF an
   `ID3 ` chunk if present, both through `parseID3v2`. Every size and offset is checked against
   the file; DST compression, unknown rates and more than 6 channels are typed `unsupported`
   errors. `FileFormat` gains `.dsf` and `.dff`; `TrackAudio.Codec` gains `.dsd`. One label,
   `sampleRateText`, names a DSD rate DSD64, DSD128 or DSD256 and any other in kHz. The tag
   writer refuses both formats. Fuzz targets `dsf` and `dff`, threat model row 57.
2. **Fixtures:** DSF and DFF writers, and six seeds (DSF and DFF at DSD64, 128 and 256) of 14,112
   bytes a channel of a 1-bit sine, DSF albums untagged more often than others, so the bench
   library stays within the generator and scan budgets.
3. **Library:** `.dsf` and `.dff` join `audioFileExtensions`, so a Swinsian miss in them now
   matches on the next import and through Locate…; the rate column, the now-playing line and
   `--play`'s list use the label. ADR 0059's text follows.
4. **HALRender:** `HALRenderSamplesOpaque`, a sample kind the IO proc never scales, so DoP
   stays at unity whatever the gain.
5. **HALOutput:** `DSDReader`, a sibling of `FileDecoder` behind a `TrackDecoder` protocol,
   packs DoP on the decode thread into the device's 24- or 32-bit integer format: markers
   0x05/0xFA, oldest bit highest, DSF bytes reversed. A DSD stream gets the opaque kind and
   no gain; DoP goes into the ring buffer in pairs of frames, the reader's length rounded up
   with DoP silence, so every track and discard starts on an even frame and the markers stay
   continuous across gapless changes and seeks. A device
   without the carrier rate or a 24-bit integer format is refused through `refuseUntakeable`,
   so a DSD album there stops at `PlaybackEngine.failureLimit`.
6. **Playback and NowPlaying:** `SignalFormat` codes for DSD and DoP, the verdict judging DoP
   at the carrier, the panel's File, Decoder and Volume rows ("digital bypassed for DoP"), and
   "DoP at 352.8 kHz on …" as the output in the now-playing line.
7. **UPnPOutput:** DSF and DFF offered under the DSD types the renderer lists, against the fake
   Denon and Sonos on loopback only.

Result: shipped as planned; `./scripts/check` passes. DSF and DSDIFF are read and indexed, and
the rate shows as DSD64, DSD128 or DSD256 (`sampleRateText`). DST, unknown rates and more than 6
channels are typed `unsupported` errors, and a DSF tag pointer that misses the tag drops the tags
with a warning and keeps the audio. A Swinsian miss in .dsf or .dff now matches on the next import
and through Locate…, and no longer counts as "a format this app doesn't read yet"
(`aSwinsianMissInDSDMatchesOnceTheScannerReadsDSD`,
`aDSDMissUnderAnOldMountIsLocatedNotListedAsUnread`). `DSDReader` packs DoP on the decode thread,
and the IO proc stays a byte copy: a new opaque sample kind that the gain never scales keeps DoP at
unity, and the panel's Volume row says "digital bypassed for DoP". The markers stay continuous
across gapless changes, seeks and a tail cut, because every write and cut lands on a pair of
frames. After the last DSD track the decode thread queues one DoP idle tail (device latency plus
100 ms), so the DAC doesn't drop out on zeros; a mid-stream underrun is still zeros. DoP needs hog
mode and a non-mixable integer format of 24 bits or more at the carrier rate. A device without them
refuses the track through `refuseUntakeable`, so a DSD album there stops at ADR 0063's failure limit
(`aDSDAlbumOnADeviceWithoutTheCarrierStopsAtTheFailureLimit`). The signal path panel and the
now-playing line show "DSD128" and "DoP at 352.8 kHz". UPnP offers DSF and DFF under the DSD type
the renderer lists, and refuses otherwise; it was built against the loopback fakes only. Fuzz
targets `dsf` and `dff` parse every input and read whatever parses through `DSDReader` (threat model
row 57). Fixtures add DSF and DFF at DSD64, 128 and 256, with and without ID3 in the DSF (ADR 0064).
The gate fixed a DSF with a bad tag pointer being dropped, zeros at the end of DSD, DoP over a
mixable format, a second tail delaying `finished`, and a tail cut on an odd frame. Benchmarks with
the DSD fixtures: full scan 1.75 s (budget 5), no-change rescan 0.55 s (1.5), generator 3.49 s,
rerun 1.24 s, parse 1.65 s, playback CPU 2.14 percent. Two budgets miss, and main (912fca5) misses
them the same way, so phase 12 didn't cause either. Scroll-bar drag measures 20.9 ms against 16.
Every commit back to 39a4eca, where 9.8 ms was recorded at 16:52 on 2026-11-02, now runs about
twice as slow on the same macOS 27.2, and the times fall just past one 60 Hz frame where they used
to fall past one 120 Hz frame. The likely cause is the closet Mac's display state, and
`caffeinate -d -u` didn't restore it, so the budget is unchanged until the owner reruns it with the
display awake. Palette opening rows measures 4.10 ms against 4 ms, the same as at its first commit,
6dfb9c6. Launch measures 0.68 s against 0.47 s recorded; main measures 0.68 s too. One run of the
full check failed `aRendererStuckAtTheEndIsMovedOnByTheApp` at 5.1 s against its 5 s limit, and it
passed three reruns. Pending the owner: DSD64, DSD128 and DSD256 on the ADI-2 with the DSD
indicator lit, a DSD album with hog mode off (it should be refused with the hog-mode message and
stop after three tracks), and DSD to the Denon, if its `GetProtocolInfo` lists a DSD type.

### 13. Release readiness

- [ ] Developer ID signing, hardened runtime and notarization in `scripts/bundle release`.
      Secrets come from 1Password at that point, so this phase adds the secrets setup it removed.
- [ ] First-run flow: choose watched folders and the output device.
- [ ] Accessibility pass: VoiceOver labels on the table, transport and palette.
- [ ] An app icon and an About window.
- [ ] Remove the **Pre-release** boundary from AGENTS.md if this is the first public release, and
      decide how stored data will be migrated from then on.
- [ ] **Hardware checkpoint (owner):** a clean install on the 2015 MacBook Pro and the DAC Mac
      from a notarized build.

### 14. Hardening

A sub-plan, written and run after phase 15 and before phase 9. It's a set of separate phases,
14a onward, each run and gated like any other. Each one gets a goal, a scope, a method, the tools it uses, and
an exit criterion that a script or a number can check. A sub-phase finds problems and fixes them
in its own commits. Anything it can't fix goes in its Result line. The sub-plan covers at least:

- **14a Robustness:**
  - Every failure path the app can meet: the NAS dropping mid-scan and mid-playback, the DAC
    unplugged at each step of a rate switch, a full disk, a locked or corrupt database, a corrupt
    settings file, and killing the process at any point.
  - Each one ends in a reported state the user can recover from, never a crash or a silent loss.
  - Soaks under load: hours of playback while scanning and searching.
- **14b Single source of truth and DRY:**
  - A sweep across modules for re-declared constants, re-derived facts, repeated literals, and
    near-duplicate code that has reached its third occurrence.
  - Turn the checks that caught them into a script in `./scripts/check`, so they stay caught.
- **14c Security:**
  - A threat model in an ADR covering:
    - tag and container parsers fed hostile files
    - the tag writer
    - SQL built from smart-playlist rules and search text
    - paths from settings and from files
    - the phase 9 HTTP server's exposure on the LAN
    - the crash-restore and settings files
    - hardened runtime and entitlements
  - Each threat gets a test or a check.
- **14d Adversarial testing:**
  - Coverage-guided fuzzing of every parser and the tag writer, with a corpus seeded from the
    fixtures and the tag corpus.
  - Address, thread and undefined-behavior sanitizer runs of the whole test suite.
  - Property tests for the queue, the scanner's rescan rules and writer round trips.
  - Mutation testing on the core state machines, to find tests that pass no matter what.
- **14e Performance:**
  - Profile the hot paths (launch, search, sort, scroll, scan, decode) with Instruments.
  - Idle CPU and timer wakeups, memory growth over a long session, and energy impact.
  - Re-check every budget on Apple Silicon and, at a checkpoint, on the 2015 MacBook Pro.
  - Tighten any budget the code now beats by a wide margin.
- **14f Architecture and docs:**
  - `docs/map.md`, the ADRs, the README and AGENTS.md checked against the code.
  - Module boundaries and public surface cut to what's used.
  - Dead code removed.

Each sub-phase runs on its own branch (`phase/14a-robustness` and so on) through the full
[phase gate](#phase-gate), in the order below. A sub-phase may add tools under `Sources/Tools`
and scripts under `scripts/`, but no dependencies: everything it uses ships with Xcode or macOS.
Long runs (soaks, fuzzing, sanitizers, mutation) live in their own scripts and stay out of
`./scripts/check`, which must stay hermetic and fast. Every sub-phase reports its exit numbers in
its Result line.

Known items carried in from earlier phases:

- Playback CPU sits at 2.8% against its 3% budget, and the metadata parse at about 4.75 s
  against 5 s; both have gone over once on a busy machine (14e).
- Commands on timeline rows whose files are all missing do nothing, silently (14a).
- A test that started two `async let` searches in either order failed one gate run (14d).
- The MediaPlayer adapters' off-main path and the tag writer's SMB fallbacks are only exercised
  at owner checkpoints (14c and 14d say how far a test can reach them here).

#### 14a. Robustness

- **Goal:** every failure the app can meet ends in a reported state the user can recover from.
  Nothing crashes, hangs or loses data silently.
- **Scope:** the NAS dropping mid-scan and mid-playback; the DAC vanishing at each step of a rate
  switch (stop, write format, start); a full disk for the database, the state file, the config
  file and the tag journal; a database locked by another process or corrupt; a corrupt or
  half-written config and state file; the process killed at any point during a scan, a tag write,
  a playlist edit and a state save.
- **Method:**
  - A failure table in an ADR: each failure, where it's detected, what the user sees, how they
    recover. Every row gets a test that injects the failure and checks the reported state and that
    nothing else changed.
  - The NAS and the DAC are simulated with the existing fakes (the simulated NAS from the scan
    benches, the null and fake HAL devices); the full disk is a small disk image attached with
    `hdiutil attach -nobrowse -mountpoint` inside `~/Library/Caches/MusicPlayer`, never `/Volumes`.
  - A kill harness (`scripts/kill-test`) runs the app or a Tool with `--home` in a temp folder,
    sends `SIGKILL` at random points in each operation (seeded and repeatable), relaunches, and
    checks the database passes `PRAGMA integrity_check`, the config and state files decode or are
    reported, and no music file differs from its clone's reference hash.
  - Soak under load: `./scripts/bench --soak 3600` with a concurrent fixture rescan every 5
    minutes and a scripted search every second.
- **Exit:** every row in the failure table has a passing test; the kill harness passes 500 seeded
  kills across the operations with 0 integrity failures; the 1-hour loaded soak has 0 underruns and
  memory growth under 10 MB from minute 5 to the end.

Implementation plan (ADR 0023, written first):

1. **Survey and failure table.** ADR 0023 lists each failure, where it's detected, what the user
   sees, how they recover, and the test that injects it. It matches ADRs 0009 (missing and
   vanished volumes), 0011 (device loss), 0015 (the config banner, the state file discarded
   whole), 0020 (the tag journal) and 0022 (the discard notice), and records what this phase
   changes.
2. **DAC at each step of a rate switch** (HALOutput, Fixtures). `NullDevice` can go away during
   its next stop, configure or start, as a real device does: the call fails and the device
   reads as gone. `DeviceOutput` reports a device error while the device is gone as
   `deviceLost`, with where to resume, instead of a track failure or an output failure, so the
   engine pauses and offers to resume once it's back.
3. **NAS dropping** (Fixtures, Library, HALOutput). `SimulatedNAS` can drop after a number of
   operations, failing every listing and read after it as a dead SMB mount does. A rescan through
   it keeps every track and reports the issues; the next scan restores the rest. Mid-playback,
   a file cut short while it plays used to end as if finished; audio that stops more than half
   a second before the header's length now reports a track failure and moves on.
4. **Full disk and a locked database** (Library). A failed scan of a local folder is retried as
   a whole scan a minute later, instead of losing its changes until the next launch. Tests fill
   the database with `PRAGMA max_page_count`, which showed SQLite's own rollback on a full disk
   hiding `SQLITE_FULL` behind a failed second rollback (fixed in `Database.transaction`), and
   hold its lock from a second connection.
5. **Corrupt database and state file** (Library, Settings, App). A library file SQLite can't read
   at all is moved aside, a new one is made, and a discard notice says where the old one went.
   `StateStore` keeps why it discarded a file, and the window shows it in the config banner.
6. **Timeline rows whose files are all missing** (LibraryBrowser). Play, Play Next, rating,
   playlists and the tag editor beep and say so in the status bar, instead of doing nothing.
7. **`FailureDrill` tool** (Tools). Drives the Core APIs with `--home`: `run <operation>` loops a
   scan, a tag write and undo, a playlist edit or a state save until killed; `verify` reopens
   everything as the app does (`PRAGMA integrity_check`, the config and state files, the tag
   journal, undoing every journaled edit) and prints any integrity failure; `full-disk <mount>`
   fills a disk image under each of the database, the state file, the config file and the tag
   journal, and checks each failure is reported and nothing else changed.
8. **Scripts.** `scripts/kill-test [--kills N] [--seed S]` generates fixtures under
   `~/Library/Caches/MusicPlayer/kill-test`, clones the tag-write files with `cp -c` into
   `~/Library/Caches/MusicPlayer/tag-corpus/kill-test`, hashes every music file, and sends
   seeded `SIGKILL`s across the five operations (config saves added after review), checking
   after each and counting the kills that landed during a write. `scripts/full-disk` attaches a
   small image with `hdiutil attach -nobrowse -mountpoint` under `~/Library/Caches/MusicPlayer`,
   detached and removed by a trap on every exit. Both share `scripts/drill-fixtures`, and
   `scripts/disk-image` with `scripts/tag-corpus`. Neither is in `./scripts/check`, which gets
   the deterministic tests above.
9. **Loaded soak** (Bench). The soak plays while a full scan of the fixture library into a new
   index runs every 5 minutes and a search every second, and a second benchmark reports memory
   growth between the footprints 30 s after each scan ends, from minute 5 on, budget < 10 MB.

Result: shipped; all three exits pass. ADR 0023's failure table has 18 rows, each with a passing
test. `scripts/kill-test`: 500 seeded kills over scans, tag writes, playlist edits, state and config
saves, 495 of them during a write, with 0 integrity failures. The loaded hour (`--soak 3600` with 13
full scans and 3,601 searches): 0 underruns; memory measured at the trough 30 s after each scan
settled at 98–101 MB with no growth, peak 121 MB. The tests found and fixed: a DAC lost mid rate
switch reported as a failed track, a full disk's rollback masked by a second error, a file cut
short ending silently, a failed local scan dropping FSEvents changes until relaunch, a failed
layout save dropped, and a corrupt library quitting at every launch (now moved aside at launch
only, the 3 newest kept). The review also made device-loss detection independent of the HAL's
event order, checked MP3s with an exact frame count for ending early, backed off failed local
scan retries to 15 minutes, cleaned up leftover temp files at startup, and fixed a test that could
hang forever on a loaded machine (every HAL test wait is now bounded). Pending for the ADI-2
checkpoint: the order the real HAL reports a device lost mid switch.

#### 14b. Single source of truth and DRY

- **Goal:** each fact is defined once, and a check keeps it that way.
- **Scope:** every module: literals, constants, SQL fragments, user-facing strings, symbol names,
  key spellings, budgets, paths, and near-duplicate code at its third occurrence.
- **Method:** a `scripts/dupes` check (a Swift script like `scripts/arch.swift`) that lists string
  literals of 4+ characters appearing in more than one file under `Sources`, and near-duplicate
  blocks of 8+ lines, with a reviewed allowlist (`scripts/dupes-allow.txt`, each entry with a
  reason). Fix what it finds, then wire it into `./scripts/check`.
- **Exit:** `scripts/dupes` reports nothing outside the allowlist, runs in `./scripts/check` in
  under 5 s, and has a test that a planted duplicate fails it.

Implementation plan (ADR 0024, written with the script):

1. **The check.** `scripts/dupes.swift`, Foundation only and run as `swift scripts/dupes.swift`
   like `scripts/arch.swift`, lexes every `.swift`, `.c` and `.h` file under `Sources`: comments,
   raw and multi-line strings and interpolations, whose own literals count too. It reports each
   string literal of 4 or more characters of its own (interpolations, format specifiers and
   escapes taken out) found in more than one file, with every `file:line`. Programmer-error
   messages (`fatalError`, and the message after `precondition`'s or `assert`'s condition) are
   skipped. Blocks: windows of 8 lines that aren't only punctuation, compared with identifiers
   and literals normalized, fail at a third copy; a second copy of 20 lines or more prints as
   advisory. `scripts/dupes-allow.txt` holds `literal "…" | files … | reason`,
   `block <fingerprint> x<copies> | files … | reason` and `oracle <dir> | checks <dir>… | reason`
   (a Tools module that re-types the checked modules' format facts on purpose, like a test, so
   what it shares with them is hidden); an entry without a reason, or one that matches nothing,
   fails.
2. **Survey and ADR 0024.** What counts as a literal worth flagging and what's excluded, the
   oracle rule, the block rule, and every category the first run found with its count.
3. **Fixes, one commit per module group,** each fact moved to the lowest module its users share:
   - Metadata and TagWriter: ID3 frame IDs, Vorbis keys, MP4 atom and item types, AIFF and WAV
     chunk IDs, and the error details both sides write, as `package` constants in Metadata
     beside `MP4Type`.
   - SQLite, Library and Bench: the WAL and shared-memory suffixes in `Database`, the library
     file name, the history insert and the checkpoint, which Bench takes from Library.
   - Settings and Commands: setting keys in the menus from `AppSettings`, the view toggles'
     titles from `AppState`, a public `AppCommands.title(of:)`.
   - Features: the smart field titles move from the rule editor to Library, beside the column
     titles, and the tag editor and the browser panes read them; buttons that run a command take
     its title; the bit-depth text joins `kilohertz` in DisplayText.
   - App: the command-line flags named once, one error printer.
   - What stays is allowlisted with its reason: the same word for different things (the SF
     Symbols among them), standard AppKit button titles, flags and keys Tools use from outside
     the app, separate executables' own messages, second copies of behavior, and the
     strict-decoding shape.
4. **Tests.** `scripts/dupes-test` builds fixture trees under `.build/dupes-test` and runs the
   script on each: a clean tree passes; a planted literal, a third copy of a block, a stale
   entry and an entry with no reason each fail with the expected line. Tests that assert a
   user-facing string import it where the module exposes it.
5. **Wire it in.** `./scripts/check` runs `dupes` and `dupes-test` and lints the script; time
   `dupes` on the whole tree (budget 5 s), then `./scripts/bench` and `./scripts/bundle release`.

Result: shipped; the exit passes. `scripts/dupes.swift` (Foundation only, ADR 0024) runs in
`./scripts/check` in 0.94 s over 262 files and reports nothing outside its 46-entry allowlist; each
literal and block entry names its files (and a block its copy count), so a new reuse fails, and a
stale entry fails. `scripts/dupes-test` covers every failure mode, each confirmed by breaking the
rule. The first run found 160 literals in two or more files and one block with three copies. Fixed
in Sources: 44 tag format IDs and 9 error messages shared by the tag reader and writer, 9 CLI flags,
5 database names and SQL statements in Bench, 4 setting keys, 17 titles and 2 format strings, with
no behaviour change (the tag IDs were checked byte for byte). The fixture generator stays an oracle
that spells 64 format IDs from the spec. The review fixed multi-line strings compared with their
indentation, assert and precondition conditions skipped along with their messages, line numbers
drifting after a line continuation, and allowlist entries that covered every file. Known limit:
repeats within one file aren't checked.

#### 14c. Security

- **Goal:** a written threat model, and a test or check for every threat in it.
- **Scope:** tag and container parsers fed hostile files; the tag writer (path handling, symlinks,
  hard links, TOCTOU between read and replace); SQL from smart-playlist rules and search text;
  paths from settings, from files and from the state file; the crash-restore, config, state and
  journal files as inputs; hardened runtime and entitlements on the bundle; phase 9's HTTP server
  and receiver control on the LAN, as requirements phase 9 must meet since it isn't built yet.
- **Method:** an ADR with one row per threat: asset, attacker, entry point, mitigation, and the
  test or check that proves it. Gaps get fixed in their own commits. `scripts/bundle` signs with
  the hardened runtime (`--options runtime`), and a check reads the entitlements back with
  `codesign -d --entitlements -` and fails on any it doesn't expect. Every SQL string built at
  runtime is audited to bind its values; a test feeds every rule field and the search box
  `'`, `"`, `;`, `--`, `%`, `_`, `\` and NUL.
- **Exit:** every row in the threat model names a passing test or check; `scripts/bundle release`
  produces a hardened-runtime app whose entitlement check passes; phase 9's section lists its
  security requirements.

Implementation plan (ADR 0025, written first):

1. **Survey and threat model.** ADR 0025 has one row per threat: asset, attacker, entry point,
   mitigation, and the test or check. It covers each parser's sizes, offsets, nesting and text,
   the tag writer's links, races and temp files, SQL from rules, search and the database's own
   schema, paths from settings, files, the state file, the journal and the device record, each
   file read at launch, the bundle's signature, and phase 9's LAN surface as requirements. It
   records the SQL audit and what the owner must do for distribution.
2. **Art reads bounded** (Metadata). An art length comes from the file and is checked only
   against the file's size, so `readArt` refuses one past a fixed maximum as unsupported, before
   allocating it. Test: a sparse file whose art claims more than the maximum.
3. **Writer nesting bounded** (TagWriter). `MP4Box` opens its containers recursively at whatever
   depth the file nests them, so a file of nested `udta`s overflows the stack. It refuses
   nesting past a fixed depth as malformed. Test: hand-built hostile MP4s for the writer.
4. **Temp file not followed** (TagWriter). Opening the cloned temp file follows a symbolic link
   planted at its name after the clone; it's opened with `O_NOFOLLOW`. Tests: the open refuses a
   link, and a link planted at the temp name before a write is removed with its target unchanged.
5. **Text with NUL** (SQLite). Text is bound with `-1` and read with `String(cString:)`, so a NUL
   in a tag, a rule or the search cuts it short: a rule matches too much and a search fails.
   Bind and read by byte count. Test: a NUL round trip and a NUL in a LIKE pattern.
6. **Quoted identifiers** (SQLite, Library). Table names read back from `sqlite_master` are put
   in `DROP TABLE "..."` without doubling quotes, and `execute` runs every statement it's given.
   A `quotedIdentifier` function doubles them. Test: a library file with a table named to break
   out is rebuilt with nothing else dropped.
7. **Rule text bounded** (Library). SQLite refuses a LIKE pattern over 50,000 bytes, so a long
   rule fails when listed, not when saved. `SmartRule.problem` refuses text over 10,000 UTF-8
   bytes. Injection test: a hand-built library whose tags and file names hold `'`, `"`, `;`,
   `--`, `%`, `_`, `\`, NUL and a 10,000-character string, each text rule field with each
   comparison, and the search box, each checked against the expected tracks.
8. **Terminal output** (DisplayText, App). The command line prints paths and tag warnings,
   which a file can fill with escape sequences. Control characters print as `\u{..}`. Test:
   each C0 and C1 control and DEL is escaped, and other text is unchanged.
9. **Hostile files per parser** (Metadata, Library). A test per parser (MP4, ID3v2, FLAC and
   Vorbis comments, WAV, AIFF, MPEG audio and the AAC config) with declared sizes that
   overflow or run past the end, sizes that would drive a huge allocation, deep nesting, and
   Unicode in text frames (invalid UTF-8 and UTF-16, unpaired surrogates, NUL, bidi controls),
   each a typed error or warning. A scan of them beside a good file reports each per file and
   indexes the good one.
10. **Hardened runtime.** `scripts/bundle` signs ad hoc with `--options runtime`, and
    `scripts/check-signature` (run by `scripts/bundle`) reads `codesign -dv` and
    `codesign -d --entitlements -` and fails without the runtime flag or with any entitlement.
    `scripts/check-signature --launch` also runs the bundled app with `--snapshot` and `--home`
    in a temp folder and fails unless it draws the PNG.
11. **Phase 9 requirements.** Phase 9's section gets the LAN requirements from ADR 0025: bind
    addresses, serving only indexed files by ID, request limits, and SSDP and receiver input
    treated as hostile.
12. `./scripts/check`, `./scripts/bench` and `./scripts/bundle release`.

Result: shipped; all three exits pass. ADR 0025's threat model has 35 rows, each naming a passing
test or check; row 35 (line breaks in `os.Logger` entries) is accepted, as the log keeps them
private. Review gaps fixed: the tag writer's temp file is made from the open original with
`fclonefileat`, or with `O_EXCL` under a random name, and checked for type, owner, link count
and inode before the rename, with tests for a swapped file, a hard link and a swapped original;
`FileSource` refuses FIFOs and links; a file's walks stop at 100,000 steps and keep 100
warnings, a scan keeps 100 walk problems; `/`, the home folder and system roots are refused as
watched folders; the terminal escapes line breaks too. Release bundles are hardened with no
entitlements and pass `check-signature --launch`; debug bundles keep `get-task-allow` for
lldb. Corpus round trip on fresh clones: 159 files, 1,557 edits, 0 failures, reference hashes
unchanged. Bench: metadata parse 4.79 s of 5 s (96%, a 14e target), playback CPU 2.33%, launch
0.61 s, tag journal 12.1 s of 20 s. Distribution (Developer ID, notarization) is phase 13's,
with the exact commands in the ADR.

#### 14d. Adversarial testing

- **Goal:** find the inputs and interleavings the hand-written tests missed.
- **Scope:** every parser (MP4, ID3v2, FLAC, AIFF, WAV, Vorbis comments, the config text, the
  state file, the undo journal, smart-playlist rules) and the tag writer; the whole test suite
  under sanitizers; the queue, the scanner's rescan rules and writer round trips as properties;
  the core state machines under mutation.
- **Method:**
  - **Fuzzing:** Xcode's toolchain has no libFuzzer, so `Sources/Tools/Fuzz` is a small
    coverage-guided fuzzer: targets are built with `-sanitize-coverage=edge,trace-pc-guard` and
    AddressSanitizer, the tool implements the `__sanitizer_cov_trace_pc_guard` callbacks in C to
    see new edges, and mutates a corpus seeded from the generated fixtures and the tag-corpus
    clones (never the reference). `scripts/fuzz <target> <seconds>`. Crashes are minimised and
    each one becomes a regression test with its file under `Tests/`. If the coverage hooks
    can't be built with SwiftPM, fall back to a seeded mutation fuzzer without coverage and record
    that in an ADR.
  - **Sanitizers:** `scripts/sanitize` runs `swift test --sanitize=address`, then `thread`, then
    `undefined`.
  - **Properties:** a seeded generator in the test target (no library): random queue edits
    against a reference model; random file trees mutated between rescans against a full scan;
    random tag edits and undos against a byte compare.
  - **Mutation:** `scripts/mutate` copies the tree into a git worktree under `.build/`, applies one
    mutation at a time (flip a comparison, swap `&&`/`||`, drop a statement, change a constant by
    one) to a listed set of files (the playback engine and queue, PlayCounter and PlayTracker,
    ConfigStore, the scanner's rescan rules, the tag writer's checks), runs the matching tests, and
    lists the survivors. Each survivor gets a test or a written reason.
  - Concurrency tests that depend on start order are found by running the suite 20 times under
    TSan and fixed.
- **Exit:** each fuzz target runs 10 minutes with no open crash; ASan, TSan and UBSan runs of the
  whole suite pass; property tests run 1,000 seeded cases each in `scripts/sanitize` and 50 in
  `./scripts/check`; mutation score of 90% or more on the listed files, with every survivor
  explained.

Implementation plan (ADR 0027, written first):

1. **ADR 0027.** A spike showed SwiftPM builds the coverage hooks: `swift build --sanitize=address
   -Xswiftc -sanitize-coverage=edge,trace-pc-guard` into its own scratch path instruments every
   Swift module and leaves C targets alone, so no `unsafeFlags` and nothing in the app build
   changes. The ADR records the design: targets, seeds, the supervisor, minimising, and the
   property and mutation runners.
2. **Coverage hooks** (`Sources/Tools/FuzzCoverage`, C). The `trace_pc_guard` callbacks count
   hits per edge; after each input the driver asks for new (edge, hit-count bucket) features. A
   crash handler and ASan's death callback write the input being run to a file opened up front.
3. **Fuzzer** (`Sources/Tools/Fuzz`). One target per parser: `mp4`, `mp3` (ID3v1, ID3v2 and
   MPEG frames), `flac`, `vorbis`, `wav`, `aiff`, `config-file`, `state-file`, `undo-journal`,
   `smart-rules`, and `tag-writer` (edit, undo and byte compare on a temp file). A supervisor runs workers as child processes, restarts
   one after a crash, minimises the crashing input and saves it under `.build/fuzz/<target>`.
   Seeds: a generated fixture library under `~/Library/Caches/MusicPlayer/fuzz`, and the
   tag-corpus clones `scripts/fuzz` makes again with `cp -c`; the reference is never read by the
   tool. `scripts/fuzz <target> <seconds>`. Tests (`FuzzTests`): the coverage bookkeeping, the
   mutators stay inside the size cap and repeat with the seed, minimising keeps the crash, and
   the supervisor reports a planted crash.
4. **Ten minutes per target**, in the background. Each crash becomes a minimised file under
   `Tests/<Module>Tests/Crashes/` with a test, and a fix, in its own commit.
5. **Properties** (`Fixtures.PropertyCases`, seeded with SplitMix64; `PROPERTY_CASES` sets the
   count, 50 by default; a failure prints its seed): random queue edits against a reference
   model (PlaybackTests); random file trees changed between rescans against a full scan of the
   result (LibraryTests); random tag edits and undos against the original bytes (TagWriterTests).
6. **`scripts/sanitize`**: the whole suite under ASan, TSan and UBSan, each in its own scratch
   path, with 1,000 property cases; `--thread-runs <n>` repeats the TSan run. Tests that depend
   on start order, found by 20 TSan runs, are fixed in their own commits.
7. **`scripts/mutate`** (`scripts/mutate.swift`, Foundation only): lists mutants in the files and
   line ranges named in `scripts/mutate-files.txt` (flip a comparison, swap `&&` and `||`, drop a
   statement, a constant plus or minus one), applies each in turn in a git worktree under
   `.build/`, runs that file's tests and lists the survivors. The worktree is removed on exit.
   Each survivor gets a test or a reason in ADR 0027.
8. `./scripts/check`, and `./scripts/bundle release` for the new targets.

Result: shipped; the fuzz, sanitizer and property exits pass, and mutation passes in aggregate
(353 of 385, 91.7%) with every survivor explained in ADR 0027. Per file: PlayQueue and the tag
writer's checks 100%, PlayCounter 93.8%, PlaybackEngine 91.8%, LibraryScanner 89.2%, ConfigStore
86.8%, PlayTracker 6 of 7; the survivors under 90% are tuning constants and changes no test can
observe. Fuzzing uses SanitizerCoverage with ASan (no fallback): 11 targets ran 600 s each; the
config file target found a crash on a doubled comma and quadratic problem reporting, both fixed
and re-fuzzed clean. The tag edit property found that a second Undo on one file was always
refused; fixed. ASan, UBSan and 20 TSan runs of the whole suite pass with no warnings; property
tests run 1,000 cases each in `scripts/sanitize` and 50 in `./scripts/check`.

#### 14e. Performance

- **Goal:** know where the time goes on every hot path, and give the tight budgets headroom.
- **Scope:** launch, search, sort, scroll, scan, decode, the palette, History and the timeline;
  idle CPU and timer wakeups; memory over a long session; energy impact.
- **Method:** profile each hot path with `xctrace record --template 'Time Profiler'` on the
  release build with `--home` and the fixture library; fix what the profile shows. Idle: run the
  app idle for 10 minutes and sample CPU and idle wakeups with `top -l` (`-stats
  pid,cpu,idlew`); playing: the same with the null device. A long-session run scrolls, searches
  and plays for 30 minutes and records resident memory every minute. Add the idle numbers to
  the budget table as benches. Tighten any budget the code now beats by more than 3x, with the
  reason in the Result line.
- **Exit:** playback CPU and the metadata parse each measure at most 85% of their budget across
  3 runs; idle CPU under 0.1% with fewer than 1 wakeup a second; memory growth under 10 MB over
  the 30-minute session; every budget passes; the old Mac re-check is listed as a pending
  checkpoint.

Implementation plan:

1. **Profile first.** Time Profiler traces of the release Bench and app under `.build/traces`,
   summarised by self and inclusive samples per frame, by thread and by core type.
2. **Metadata parse.** Fix what its trace shows, with the existing parser tests green and a test
   for any helper rewritten.
3. **Playback CPU.** The same for the decode thread, the control thread and the null device.
   Samples stay bit-identical: the gapless, rate-switch and soak benches must still pass.
4. **Idle.** The control thread stops waking while stopped with nothing to decode. Two window
   benches launch the app on the indexed fixture library with `--home` and read its CPU time and
   idle wakeups with `proc_pid_rusage`; they join the budget table, replacing the idle row.
5. **Long runs.** The app idle for 10 minutes (`top -l`, `-stats pid,cpu,idlew`), and a
   30-minute `./scripts/bench --soak 1800` for memory under playback, scans and searches.
6. **Budgets.** `./scripts/bench` three times; any budget beaten by more than 3x is tightened.
7. **Checkpoint** for the 2015 MacBook Pro, below.

- [x] **Hardware checkpoint (owner):** on the 2015 MacBook Pro, after pushing, run every budget
      on the old Mac and send back the file it writes:
      `cd ~/projects/music-player && git pull --ff-only && ./scripts/bench 2>&1 | tee ~/Desktop/bench-14e-old-mac.txt`

      Done on 2026-11-01 from a universal release build copied to the 2015 MacBook Pro (its
      Xcode 14 can't build Swift 6): every old-Mac budget passes. Launch 1.01 s, search keystroke
      18 ms, sort 73 ms, full scan 7.2 s, no-change rescan 1.7 s, scroll memory 79 MB, playback
      2.3% with no gaps or underruns, idle 0.02% and 0.18 wakeups a second once the bench waited
      for the launch rescan (a fixed 20 s settle had measured 4%).

Result: shipped up to the owner's checkpoint, which is pending. Playback CPU 2.00, 2.10 and
1.99% of 3% (70% at worst; the gate's own runs 2.04 to 2.13%), from an 8 s ring whose longer
refills the scheduler keeps on a fast core (ADR 0029) and a null device paced with
`mach_wait_until`. Metadata parse 4.01, 4.00 and 4.24 s of 5 s (85% at worst, the gate's run
4.00 s), from a one-pass Latin-1 decode and URLs built without a stat; the rest is `open` and
`pread`. The same stat fix took a full scan from 1.80 to 1.56 s. Idle: 0.00% CPU and 0 wakeups a
second over 10 minutes, as the control thread no longer ticks while stopped; two idle benches
join the table. Memory over a 30-minute soak of playback, scans and searches: -3.8 MB; it doesn't
scroll, which the window memory bench covers. Eleven Apple Silicon budgets the code beat by more
than 3x are now about 2x the worst of three runs; the old Mac's column waits for its checkpoint.
The ring costs twice the memory: 16 MB at 192 kHz, 64 MB at 768 kHz.

#### 14f. Architecture and docs

- **Goal:** the docs describe the code, and the code exposes only what's used.
- **Scope:** `docs/map.md`, every ADR, the README, AGENTS.md, the plan's Result lines; module
  boundaries and public surface; dead code.
- **Method:** list every `public` and `package` symbol and its callers outside its module
  (`swift-symbolgraph-extract` or a grep script under `scripts/`); narrow or delete each that
  has none. Delete code with no caller. Read each doc against the code and fix drift. A
  `scripts/surface` check fails when a `public` symbol has no caller outside its module, wired
  into `./scripts/check`.
- **Exit:** `scripts/surface` reports nothing and runs in `./scripts/check`; every ADR's status is
  current; AGENTS.md is 50 lines or fewer; a final `./scripts/check` and `./scripts/bench` pass.

Implementation plan:

1. **`scripts/surface.swift`** (Foundation only, like `scripts/dupes.swift`): lexes every Swift
   file under `Sources`, lists each `public` and `package` declaration, and fails on each whose
   name no file of a module that sees it uses, and no other public signature in its own module
   names. Tests don't count as callers: they use `@testable import`. Framework protocol
   witnesses the compiler requires to be public go in `scripts/surface-allow.txt` with a reason.
   ADR 0030.
2. **Narrow** every declaration it reports to internal, until it reports nothing; tests that
   reach a narrowed symbol switch to `@testable import`. Delete what has no caller in `Sources`
   at all.
3. **`scripts/surface-test`** plants each finding and each bad allowlist entry, like
   `scripts/dupes-test`. Both run in `./scripts/check`.
4. **Docs:** `docs/map.md`, the README, AGENTS.md, every ADR's Status line and the Result lines
   read against the code; drift fixed, superseded ADRs link their successor.
5. A final `./scripts/check` and `./scripts/bench`.

Result: shipped; the exit passes. `scripts/surface.swift` (Foundation only, ADR 0030) runs in
`./scripts/check` in 0.95 s and reports nothing outside its 11-entry allowlist, all AppKit
delegate methods the compiler needs public. The first run flagged 154 of 1,648 public and package
declarations; the tree now has 1,402, each called from another module, and tests reach the rest
with `@testable import`. One deletion, `KeyBindings.menuChord`, which only tests called. Drift
fixed in ADRs 0011 and 0012, "Amended by" lines on 0009, 0011, 0012, 0015 and 0022, map.md
states the surface rule, and AGENTS.md is 50 lines. Matching is by name, so a member name shared
across modules can hide an unused declaration. Final bench: every budget passes; playback CPU
2.03%, metadata parse 4.17 s, launch 0.61 s, idle 0.00% CPU with 0 wakeups.


### 15. Stable track identity and full play history

Stats key on the file's path (ADR 0008) because `files.id` is a row number that every index
rebuild, and every file leaving and coming back, hands out again. That costs three things today:

- **Space.** `history` stores the full path in every row and again in its index, about 250 bytes
  a play. Measured: 100k plays take 24 MB, and 1M would take about 250 MB.
- **Date Added.** `files.added_seconds` is lost on every rebuild, so each track shows the rebuild
  time.
- **Joins.** Every stats join matches long path strings.

This phase gives each path a permanent ID kept with the stats, uses it as `files.id`, keys every
stats table on it, and adds a paged timeline of every play. It supersedes ADR 0008's "key stats by
path" and amends ADR 0018. Write the ADR first, at the next free number.

- [x] **Identity:** a stats table `paths` (`id INTEGER PRIMARY KEY`, `path TEXT UNIQUE NOT NULL`,
      `added_seconds REAL NOT NULL`). The scanner looks a path up there, or inserts it, and uses
      that ID as `files.id`. `added_seconds` moves off `files`. Rows are never deleted, so a file
      that leaves the index and comes back gets its old ID and Date Added. A renamed or moved file
      is still a new path, as now.
- [x] **Stats by ID:** `plays`, `ratings`, `history` and `playlist_entries` key on `path_id`
      instead of `path`. Joins from `files` become `files.id = path_id`. Smart rules, sorts,
      playlist entries whose file left the index (still counted on the status line) and the
      `files.path IN (…)` conditions all move over. The stats SQL changes, so the owner's
      current stats are dropped once, which the pre-release rule allows.
- [x] **History shape:** `history (id INTEGER PRIMARY KEY, path_id INTEGER NOT NULL, played_at
      INTEGER NOT NULL)` in whole seconds, with an index on `path_id`. Rows are append-only, so
      `id` order is time order and no index on `played_at` is needed.
- [x] **History view** (one row per track) reads `plays` where `last_played_seconds` is set, so
      its cost follows the number of tracks played rather than the length of the log.
- [x] **Play timeline:** every play, newest first, loaded 200 at a time by key
      (`WHERE id < :last ORDER BY id DESC LIMIT 200`), never `OFFSET`. A new play is added to the
      top of the loaded rows; a library change re-resolves only the loaded rows. Plays of files
      no longer in the index show as missing rather than being hidden, so pages stay full. The
      track table identifies rows by track ID (ADR 0018), and the timeline repeats tracks, so its
      rows need their own identity (the history ID). Plan how selection, play, drag and ⌘⌫ act
      on a timeline row before building the UI, and record the choice in the ADR. Where it lives
      (a second History mode or its own sidebar item) is the implementer's call, per ADR 0012.
- [x] **Tests:** IDs and Date Added survive an index rebuild and a file leaving and coming back;
      stats, ratings and playlist entries follow the ID; the timeline pages are stable while new
      plays arrive; missing files show as missing.
- [x] **Bench**, with the budgets added to [Performance budgets](#performance-budgets): with 1M
      synthetic plays over the 43k fixture library, one timeline page p95 < 5 ms, the one-row-
      per-track History view p95 < 30 ms, recording a play < 2 ms, and the history table plus
      its index < 40 MB. Measured on a scratch database before the phase (100k plays, Apple
      Silicon): a page 0.5 ms, the current History view 25 ms, about 27 bytes a play.

Implementation plan (ADR [0022](decisions/0022-stable-track-identity-and-play-timeline.md)):

1. **Library schema.** `paths` is a stats table; `files.id` refers to it and no longer holds
   `added_seconds`; `plays`, `ratings`, `playlist_entries` and `history` key on `path_id`, and
   `plays_last_played` indexes the History order. A stats rebuild counts the old rows and
   records them in `schema_discards`; the window reads them with `discards()` and deletes them
   with `forgetDiscards(_:)` once shown. The scanner's upsert and `recordPlay` share `pathID`,
   which traps outside a transaction.
2. **Queries.** `trackJoins`, `rowSelect`, Date Added, playlist order, the History, playlist and
   smart rule sources, the missing-entry count, and the rating and playlist APIs use IDs.
   `timeline(before:limit:)` and `timeline(after:limit:)` return light `PlayEntry` rows,
   `playedTracks(ids:)` reads what they show, and `loggedPlayCount()` counts them. `IN` lists
   are read 500 IDs at a time. `LibraryReader` passes them through.
3. **BrowserSource.timeline** (Settings) is saved as `timeline`. `BrowserModel` runs no pane or
   track queries for it and passes track IDs, not paths, to the library.
4. **LibraryBrowser:** `TimelineModel` pages by key, puts new plays on top, keeps selection by
   history ID, drops stale results by session, and reads rows through a 20-page cache.
   `TimelineController` and `TrackTableController` share `RowListController`. The browser swaps
   the timeline in for the panes and track table, routes play, drag, Go to Item and the
   selection commands to it, turns ⌘⌫, search and sorts off there, and reports the first rows
   drawn from the timeline's own page.
5. **App:** the sidebar row, the Go to Item rows (`goToItems`, `goToRow`), the sort commands'
   `canSort`, and the discard notice. The timeline is checked with `--snapshot` from a home
   whose saved source is `timeline`.
6. **Bench:** 1M synthetic plays under `.build/bench-plays`, four benchmarks with the budgets
   above, and the smart playlist, sort, search and launch numbers before and after.
7. **Tests:** LibraryTests (IDs and Date Added across a rebuild and a file leaving and coming
   back, stats, ratings and entries following the ID, the discard record, Last Played ties,
   `IN` lists past SQLite's limit, timeline paging while plays arrive, missing files, `pathID`
   outside a transaction), SettingsTests (the `timeline` source), LibraryBrowserTests
   (`TimelineModel`, its bounded cache, and the browser on the timeline), MusicPlayerTests (Go
   to Item over repeated plays, ⌘⌫ off on the timeline).

Result: shipped as planned. Bench on Apple Silicon with 1M synthetic plays over the 43k fixture
library: a timeline page 1.39 ms (budget 5 ms), History with every track played 18.5 ms (30 ms),
recording a play 0.23 ms (2 ms), history plus its index 28.7 MB (40 MB). The join change sped up
the smart playlist (38 → 29 ms), sort (42 → 37 ms) and search (12.4 → 9.4 ms). The review got
History under budget with a `plays` index on last played, bounded the timeline's memory to a
20-page row cache, chunked `IN` lists under SQLite's variable limit, fixed the window reporting
itself drawn before the timeline's first page, and kept the one-time stats-discard notice until
it's shown. Known limits: paths are byte-exact, so a Unicode or case variant reached another way
gets a second ID; commands on timeline rows whose files are all missing do nothing.

### 16. Album artist and every metadata column

The Artist pane lists track artists, so a compilation or an album with guest artists spreads
across many entries, and albums that share a title by different artists repeat by name in the
Album pane (the known limit in phase 5's Result).

- [x] A setting `library.groupByAlbumArtist`, on by default: the Artist pane lists album
      artists, using the track artist where a track has none, and compilations without an album
      artist under one "Various Artists" entry. Off, the pane lists track artists as now. It's in
      the Settings window and ⌘K like every other setting.
- [x] The Album pane tells albums with the same title apart: it shows the album artist beside
      the title wherever two entries would otherwise read the same.
- [x] Sorting by Artist or Album with the setting on orders by album artist, then album, disc
      and track, so an album's tracks stay together.
- [x] **A column for every piece of metadata**, each one optional, sortable, and a smart-rule
      field where that makes sense. The list matches Swinsian's column menu:
      - Already read, not yet a column: composer, comment, track total, disc total, compilation,
        channels.
      - From the file and the index: file size, bit rate, file name, file type, date created and
        date modified (from the file system at scan time), and "#" (the row's position in the
        list as shown).
      - Display forms: "track of total" (3 of 12) and "disc of total", which sort as the
        track and disc numbers do; Album Art, a thumbnail through `ArtworkLoader`, sorting by
        whether a track has art.
      - New tags for the tag reader to index, for every format it reads: grouping, catalog
        number, barcode, BPM, key, conductor, lyricist, publisher, copyright, encoder,
        description, disc subtitle, work, movement number and movement name, and original
        release date. Each format's key for each field follows MusicBrainz Picard's tag mapping
        table; record the mapping in the tag-reader ADR. A field missing from a file is empty,
        never guessed.
      - Loved: a yes/no stat kept in the database beside ratings (Swinsian's heart), with a
        command to toggle it, so phase 18 can import it.
- [x] The default columns stay as they are; every new column is off until chosen from the
      header's menu. The owner will turn on #, Album Art, Title, Artist, Album, Track of Total,
      Time, Year, Genre, Grouping, Catalog Number, Bit Rate, Sample Rate, Size, Play Count and
      Date Added, so those must work first and be tested.
- [x] The tag editor (phase 11) stays as it is; editing the new fields is a later change.
- [x] Tests: the pane with the setting on and off, compilations, same-title albums, the sort
      order, each new tag read from every format, and each new column's sort.
- [x] Bench: the pane, re-sort, scan, and database size budgets still hold.

Implementation plan (ADR [0031](decisions/0031-album-artist-and-metadata-columns.md); the tag
mapping is in ADR [0006](decisions/0006-tag-reader.md)):

1. **Metadata.** `TrackTags` and `TagField` gain the sixteen fields. Vorbis, ID3v2 (2.2 to 2.4,
   with `TXXX` and `GRP1`), MP4 (with integer items and iTunes freeform items) and RIFF INFO map
   Picard's keys onto them; `DESCRIPTION` becomes the description rather than the comment.
   Tests read each field from every format; the four parser fuzz targets run 120 s each.
2. **Library index.** `tracks` stores the fields and `group_artist_id`; `files` stores the
   creation date the walk already fetches with each listing (`creationDateKey`, no new call
   per file). `loved` is a schema part of its own, so adding it keeps the plays, ratings and
   playlists. `TrackRow` carries every field; bit rate, file name and file type are SQL
   expressions the rows select and the sort uses, so each is defined once.
3. **The owner's columns first:** `#` (the row's position, not sortable), Album Art (an image
   cell fed by `ArtworkLoader` off the main thread, a bounded request queue, sorting by whether
   a track has art), Track of Total, Grouping, Catalog Number, Bit Rate, Size, beside the
   existing ones. Default widths per column, checked with `--snapshot` at 1440x900 with the
   sixteen on. Then every other column, each sortable and, where it makes sense, a smart-rule
   field.
4. **`library.groupByAlbumArtist`** in `AppSettings` (so the Settings window and ⌘K list it).
   `TrackFilter` carries it; the Artist pane, its selection and the Artist and Album sorts read
   `group_artist_id`. The Album pane shows the album artist beside titles that repeat.
5. **Loved:** `track.toggleLoved` loves the selection, or unloves it when all of it is loved.
6. **Bench:** the sort benchmarks skip `#`; the pane benchmark adds the grouped Artist pane;
   the window memory benchmark scrolls with the Album Art column shown.
7. **Tests:** MetadataTests (every field from every format, warnings), LibraryTests (the new
   columns' sorts and values, created dates, grouping with compilations and same-titled albums,
   loved surviving an index rebuild, the new rule fields), LibraryBrowserTests (row numbers,
   album names, the setting's reload, the art queue), SettingsTests (the setting).

Result: shipped. Sixteen new tags read from FLAC, MP4, ID3v2.2 to 2.4 and WAV, keyed by
MusicBrainz Picard's mapping (ADR 0006, written without the web; keys marked † are unverified);
each parser target fuzzed 120 s with no crash. Every column is optional and sortable, most are
smart-rule fields, and the owner's sixteen fit at 1440x900 with every panel open (1,029 points).
`library.groupByAlbumArtist` is on by default; compilations without an album artist group under
Various Artists, and an album with no artist that isn't a compilation shows its title alone.
Loved is its own stats part and survives an index rebuild. Choices in ADR 0031: a Vorbis
`DESCRIPTION` is the description, not the comment; the old "#" header is "Track", as "#" is
the row's position; Album sorts by title, then album artist; bit rate is size without art over
length. Bench: parse 4.10 s, scan 1.86 s, database 45.3 MB (from 42.7), sort 41.4 ms and re-sort
42.1 ms (from 37.0, the added joins and the grouped order), window memory 57.4 MB, launch 0.64 s;
every budget holds.

### 17. Playlist files

- [x] **Export** a manual playlist, or a smart playlist's current tracks, as M3U8 (UTF-8, `#EXTM3U`
      with `#EXTINF` length and "artist - title"), paths absolute or relative to the file's folder,
      chosen in the save panel.
- [x] **Import** M3U and M3U8 (and PLS if it's cheap) as a new manual playlist. Paths may be
      absolute, relative to the playlist file, or `file://` URLs. Entries the index doesn't hold
      are counted and listed in a report after the import, never added silently or dropped
      silently.
- [x] Playlist files are hostile input: a size cap, a line-length cap, no URL schemes but
      `file`, and no reads of the paths they name beyond an index lookup. Add the rows to
      [ADR 0025](decisions/0025-threat-model.md).
- [x] Commands in the registry (Import Playlist…, Export Playlist…) and dragging an `.m3u8` onto
      the sidebar.
- [x] Tests: round trip, relative and absolute paths, non-ASCII names, CRLF, a BOM, missing
      entries, and hostile files.

Implementation plan:

1. **`PlaylistFile` in Core/Library**, pure: bytes, a format (M3U, M3U8, PLS) and the file's
   folder in; absolute paths plus typed problems out, each with its line. 16 MiB and 4 KiB a
   line caps, 100,000 entries, 100 problems listed then a count. `.m3u8` is UTF-8; `.m3u` and
   `.pls` are UTF-8 when valid, else Windows-1252. A BOM and CRLF are dropped. Only `file:`
   URLs; relative paths are joined to the folder and `..` folded by text, never the disk.
   Writing: `#EXTM3U`, `#EXTINF:<seconds>,<artist> - <title>`, NFC paths, absolute or relative.
2. **Index lookup** `LibraryIndex.trackIDs(atPaths:)`: the path as written, then compared in
   NFC, since a share's names are NFC under a root kept NFD. Import makes a manual playlist and
   returns what was added, missing, listed twice and unreadable. Export reads the playlist's
   rows in the table's sort, skips paths a line can't hold and reports them.
3. **Browser:** import and export through the reader, the import report in the Problems
   window; dropping `.m3u`, `.m3u8` or `.pls` files on the sidebar imports them.
4. **Commands** `playlist.import` and `playlist.export` in the registry and File menu, no
   default chords; the App opens the panels (export with a "Relative paths" checkbox).
5. **Fuzz target** `playlist-file`: every format parses without a trap, entries are absolute
   and NUL-free, and written entries parse back the same. ADR 0025 rows; ADR 0032 for the
   choices (encoding, NFC, order, what's reported).
6. **Tests:** LibraryTests (round trip, relative and absolute paths, `file://`, non-ASCII in
   both forms, CRLF, BOM, Windows-1252, missing, duplicates, hostile files, caps),
   LibraryBrowserTests (import report, export file, the drop's pasteboard); the menu and
   registry tests already cover every new command.

Result: shipped. M3U, M3U8 and PLS import as a new manual playlist, and M3U8 export of the shown
playlist in its current order (a manual playlist opens in its own order, so a round trip keeps
it), with absolute paths by default and relative ones by choice (ADR 0032). Import caps a file
at 16 MiB, 4 KiB a line, 200,000 lines and 100,000 entries, takes only `file` URLs, and looks
paths up in the index as written, then as NFC, never on disk. A `.m3u` or `.pls` that isn't UTF-8
is read as Windows-1252. Missing, repeated and skipped entries are counted on the status line and
listed in the Problems window, escaped. The `playlist-file` fuzz target found that Foundation
drops a leading U+FEFF from a line; lines are now decoded by hand. ADR 0025 rows 36 to 40.

### 18. Import from other players

Bring plays, ratings, dates and playlists across from the player someone used before. The owner
comes from Swinsian; most other Mac users come from iTunes or Music.

- [x] **Swinsian:** read its library database (`~/Library/Application Support/Swinsian/`),
      opened read-only from a copy, never the live file. Bring across play counts, last played,
      ratings, date added, and manual playlists. Smart playlists whose rules map onto ours come
      across as smart playlists; the rest are listed in the report. Loved (the heart) comes
      across too. Swinsian identifies a track by a row ID, its path, and a macOS bookmark that
      only resolves on the machine that made it, so the import matches by path. It can hold one
      path in more than one row (the owner's library has 32 extra rows); the import merges them,
      adding plays and keeping the latest last played and the highest rating, and the preview
      counts them.
- [x] **iTunes and Music:** read an exported `Library.xml` (File ▸ Library ▸ Export Library)
      with `PropertyListSerialization`. The same fields, plus skip counts. Smart playlists are
      encoded in a private format, so they come across as manual playlists of their current
      tracks, which the report says.
- [x] Other players are added when their library format is documented; until then, M3U8
      (phase 17) carries their playlists.
- [x] **Matching:** tracks match by path. When the other library lived at another mount point,
      the import asks for one path prefix to replace with another. Anything that doesn't match is
      counted and listed in the report.
- [x] **Merging:** a preview shows what will change before anything is written: counts per field,
      unmatched tracks, and playlists that already exist by name. Play counts add to ours, last
      played and date added take the earlier or later value as each field needs, and ratings come
      across only where we have none. One confirmation writes it all in one transaction. Imported
      plays raise counts; they don't add rows to the timeline, since the other player kept no
      dates for each play. Record the merge rules in an ADR.
- [x] Both formats are hostile input: rows to [ADR 0025](decisions/0025-threat-model.md) and
      tests with corrupt and oversized files. Music files are never touched.
- [x] Tests run against generated Swinsian databases and `Library.xml` files, never a real
      library.
- [ ] **Hardware checkpoint (owner):** on the DAC Mac, import the Swinsian library and report
      the preview's counts, the unmatched list, and whether ratings and playlists look right.
      The schema dump is done: the reader uses the schema read from the owner's library
      (ADR 0033). What remains is running the import and checking the preview's counts.
      Its tracks are at `/Volumes/music/library`, so if the preview shows them unmatched, put
      the prefix Swinsian's paths start with in "Replace the path prefix" and
      `/Volumes/music/library` in "with".

Implementation plan:

1. **ADR 0033 first**: the merge rules, how a second import of the same library adds nothing,
   and the Swinsian schema the reader assumes, marked unverified.
2. **`Database(readOnlyAt:)`** in SQLite: `SQLITE_OPEN_READONLY`, `query_only` and
   `trusted_schema = OFF`, for a copy of another app's database.
3. **Readers in Core/Library**, each giving one `PlayerLibrary` (tracks by path with plays,
   skips, last played, date added, rating and loved; playlists as paths, rules, or what didn't
   map; typed problems, 100 listed then a count). `SwinsianLibrary` copies the database and
   its WAL to a temp folder through `FileSource` (`O_NOFOLLOW`, a regular file, a size cap),
   checks the copy wasn't torn, opens it read-only, and checks every table and column it reads
   against `sqlite_master` and `PRAGMA table_info`, failing with each one missing. Rows for one
   path merge (plays added, latest last played, highest rating). Rules that fit `SmartRule`
   map; the rest are listed. `ITunesLibrary` reads `Library.xml` with
   `PropertyListSerialization` under a size cap; `Location` goes through phase 17's `file:`
   decoding; smart playlists become manual ones of their tracks.
4. **Plan and apply** in `LibraryIndex`: one optional prefix replacement, then phase 17's
   `trackIDs(atPaths:)` (as written, then NFC). The plan counts each field's changes,
   unmatched tracks, merged rows and playlists that exist by name. Apply recomputes the plan in
   one transaction and writes it. A new schema part, `imports`, records each source's imported
   counts per path, so a second import adds only what grew.
5. **Browser and App:** `library.importSwinsian` and `library.importITunes` in the registry and
   File menu; an open panel, then the preview as an `NSAlert` sheet (ADR 0012) with the prefix
   fields, sized for 1440x900, whose updates carry a session token; one confirmation applies
   it; the report goes to the status bar and Problems window like phase 17's.
6. **Fuzz targets** `swinsian` and `itunes-xml`; ADR 0025 rows; the checkpoint's schema
   command.
7. **Tests** (LibraryTests, SQLiteTests, LibraryBrowserTests): generated databases and XML in
   temp folders only; schema problems, corrupt and oversized files, duplicates, the prefix,
   NFC, every merge rule, a second import, rules that map and don't.

Schema fix, once the owner's schema was read:

1. **Real tables:** `track` (`favourite` for loved, `rating` 0 to 5 in half steps rounded half
   up and counted in the preview, `lastplayed` 0 as never), `playlist` (`smartpredicate`,
   `folder`, `limited`) and `playlisttrack` by `tindex`; `smartrule` and `matchall` go.
2. **`SwinsianPredicate`** in Core/Library: the archived `NSPredicate` under a byte, object and
   depth cap, read from its property list by `SwinsianArchive` (never `NSKeyedUnarchiver`,
   whose exceptions end the app), never evaluated; its structure (AND, OR, NOT by De Morgan, the seven keys and four operators the
   owner's rules use) maps onto `SmartRules`.
3. **Fixtures:** the real schema and the 18 rule shapes with generic genres, shared by the tests
   and the fuzzer; a `swinsian-predicate` fuzz target and an ADR 0025 row.
4. **ADR 0033** records the verified schema; the checkpoint keeps only the import itself.

Result: shipped up to the owner's checkpoint, which is pending. Swinsian's database is copied
with its WAL, checked unchanged by size, mtime and inode, and opened read-only from the copy; the
schema was read from the owner's library on 2026-11-01 (ADR 0033), and a missing table or column
fails with each one named. Smart rules are Swinsian's archived NSPredicate, walked from its plist
without NSKeyedUnarchiver (which raises on malformed archives) under caps on bytes, objects, depth
and reads; all 18 of the owner's rule shapes map. Half-star ratings round up.
Library.xml is read with `PropertyListSerialization` under a 256 MiB cap. Matching is by path
with one prefix replacement, through phase 17's NFC lookup. The preview sheet is recomputed
inside the one transaction that writes plays, last played, Date Added, ratings where we have
none, loved and new playlists; duplicate Swinsian rows for one path merge. A re-import adds only
the plays a player gained since the last one (`imported_plays`, per player and track). Smart
playlists with an unmapped rule, and playlists whose name exists, are skipped and listed. ADR
0025 rows 41 to 45; the `swinsian` and `itunes-xml` fuzz targets found no crash in 120 s each.

### 19. Finder, folders and library health

- [x] **Reveal in Finder** (⇧⌘R) for the selected tracks, from the menu, the context menu and ⌘K.
- [x] **Folder browsing:** a sidebar mode that shows each watched folder as a tree of its
      subfolders, built from the paths the index already holds. Selecting a folder lists the
      tracks under it, and the panes narrow to them as they do for any source.
- [x] **Library health report**, as a sidebar source, each group listing its tracks so they can be
      selected, played, revealed or fixed in the tag editor:
      - files the scanner couldn't read, and its warnings;
      - playlist entries whose file left the index;
      - likely duplicates: the same album artist, album, disc and track number, or the same
        title and artist within a second of the same length;
      - albums with gaps in their track numbers, more than one album artist, or mixed sample
        rates;
      - tracks with no art, no album or no album artist.
      It runs off the main thread on request and when a scan ends, never on a timer.
- [x] Tests: each group against crafted fixtures, and the folder tree.
- [x] Bench, with the budget added to [Performance budgets](#performance-budgets): building the
      report over the fixture library p95 < 1 s on Apple Silicon.

Implementation plan (ADR 0034):

1. **Reveal in Finder:** the registry's `track.revealInFinder` gains ⇧⌘R, keeping Searcher's
   ⌥⌘R (ADR 0012). One `revealInFinder(_:)` in LibraryBrowser calls
   `NSWorkspace.activateFileViewerSelecting`; the command and a new item in `RowListController`'s
   context menu (the clicked row or the selection, so the track table and the timeline both get
   it) use it.
2. **Folder tree:** `FolderTree` in Library, built on the reader from the paths of the index's
   tracks and the watched folders: the distinct folders, each with its subfolders, and no
   AppKit. The sidebar's watched folders expand into it, a row made only when its parent
   expands. A subfolder is a `.folder` source like a watched one, so the panes and sort work
   as they do. It's rebuilt after each library refresh, and before the first sidebar show when
   the saved source is a subfolder, whose ancestors expand to select it.
3. **Health report:** `HealthCheck` (Settings, beside `BrowserSource`, which gains
   `.health(HealthCheck)`, saved as `health:<check>`), and `LibraryIndex.healthReport()` in
   Library: one `HealthFindings` (track IDs, and lines for what isn't a track, 100 then a
   count) per check, each check one function in a switch so a later check joins by adding a
   case. Title and artist duplicates are sorted by title, artist and length in SQL, then swept.
   The report is built on a second `LibraryReader`, so it never holds up the window's queries,
   and the window's reader keeps the shown IDs in a temp table that the `.health` source
   condition reads, so panes, search and sort work on a check as on any source.
4. **HealthModel** (LibraryBrowser, no AppKit): runs a build on request, when a scan ends and
   when a check is shown with no report yet; each run takes a session number and a result from
   an earlier one is dropped. The sidebar's Library Health row expands into one row per check
   with its count; the track table lists the check's tracks, and the status bar counts the rest,
   which the Problems window lists. `library.checkHealth` ("Check Library Health") in the
   registry and the File menu.
5. **Bench:** `library: build the health report (p95)`, budget 1 s (old Mac 3 s, an estimate),
   added to the table above with it.
6. **Tests:** LibraryTests (each check against crafted rows, the duplicate sweep's edges, the
   folder tree, the `.health` source), SettingsTests (`health:` sources), LibraryBrowserTests
   (HealthModel's stale runs, the sidebar's folder tree and health rows, the context menu's
   Reveal), CommandsTests (⇧⌘R bound, no collision).

Result: shipped. Reveal in Finder is on ⇧⌘R, with ⌥⌘R kept as the alternate, in the menus, the
track and timeline context menus and ⌘K. Watched folders open into their subfolders, built from
index paths only, one level as each opens (ADR 0034). Library Health is a sidebar group of 11
checks listed through the shared track table, built off the main thread after a scan that
changed something, after playlist edits and imports, and on request, never on a timer; a stale
run is dropped. Album checks key on the album and its folder, so two releases of one title don't
merge, and Track Gaps counts each disc from its lowest number; Same Title needs a known length.
Title duplicates are sorted in SQL and swept once. Bench: the report builds in 0.20 s (budget
1 s; the old Mac's 3 s is an estimate), the folder tree in 62 ms on its own connection. The
longest check name truncates in a sidebar at its narrowest, with the full name in its tooltip.

### 20. Signal path panel

- [x] A panel, hidden by default, that shows what happens to the samples between the file and the
      DAC: the file (codec, rate, bit depth, channels), the decoder's output, the device (name,
      nominal rate, physical format, bit depth), whether hog mode is held, and whether digital
      volume is at unity. A line at the top says "Bit-perfect" or names each thing that changes
      the samples.
- [x] It follows the device's property listeners, so another app changing the rate or taking the
      device shows at once. Nothing polls.
- [x] A command and a menu item show and hide it; whether it's shown is saved in the state file.
- [ ] When phase 9 lands, a renderer shows its own path (original bytes sent, and what it reports).
- [x] Tests: the verdict for each case (rate mismatch, volume below unity, hog mode lost, a
      device change mid-track) against a fake device.
- [ ] **Hardware checkpoint (owner):** on the DAC Mac with the ADI-2, play 16/44.1 and 24/192,
      then change the rate in Audio MIDI Setup while playing, and report what the panel shows.

Implementation plan (ADR 0035):

1. **Snapshot and verdict** (Playback, no CoreAudio): `SignalPath` holds the track's file and
   decoder formats and a `SignalSink`, an enum whose one case today is the device (its name,
   whether it's connected and readable, nominal rate, physical format, hog owner, volume
   controls, and the IO proc's gain). The renderer becomes a second case in phase 9.
   `signalVerdict(_:)` returns idle, bit-perfect, or each `SignalChange`: decoder or device
   resampling or remixing, a format that can't hold the file's samples, a mixable format, hog
   mode not held or held by another process, a volume control or the digital volume below
   unity, and the device missing or unreadable.
2. **Listeners** (HALOutput): `PropertyListeners` keeps one block's HAL listeners equal to a
   wanted set, so a device's new object ID or quitting removes exactly what was added. The
   provider follows the device's rate, hog mode, streams, virtual main volume and per-channel
   volumes, and the stream's physical format, on its device-watch queue, and reports the
   device's state through `watch`. Nothing polls and the IO proc is untouched.
3. **Output:** `DeviceOutput` keeps the latest device state and, on its control thread, publishes
   a `SignalPath` on `signalPaths` whenever the audible track, the gain or the device changes.
   `NullDevice` reports a state too, and tests can change its rate, take hog mode or lower its
   volume, as another app would.
4. **Panel** (NowPlaying): `signalPathLines(_:)` turns a path into the verdict line and the rows
   (file, decoder, device, hog mode, volume); `SignalPathPanel` shows them in a strip under the
   now-playing bar. `view.toggleSignalPath` ("Show Signal Path", ⌥⌘S) in the registry and View
   menu, and `window.signalPathVisible` in the state file, off by default. The app only hops
   `signalPaths` to main and toggles the view.
5. **Tests:** PlaybackTests (each verdict case), NowPlayingTests (the lines), HALOutputTests
   (listener balance across a device change and stop with a fake HAL; with the null device: a
   rate mismatch, volume below unity, hog mode lost, the device going and coming back mid-track,
   another app changing the rate), CommandsTests (the chord doesn't collide).

Result: shipped up to the renderer line, which waits for phase 9, and the owner's checkpoint,
which is pending. A strip under the now-playing bar (⌥⌘S, View ▸ Show Signal Path, saved in the
state file, off by default) shows file, decoder and device formats, hog mode and every volume
control, and says "Bit-perfect" or names each change: a rate, channel or precision change, a
mixable format, hog mode free or held by another process, any volume control or the app's gain
off 1.0, or a missing device (ADR 0035). A 16- or 24-bit source padded into a 32-bit integer
stream counts as bit-perfect. It follows the HAL's property listeners on the device-watch queue,
with HAL reads outside the provider's lock; the control thread rebuilds the snapshot only when
something changed. Mute and DSP inside the DAC aren't visible to it. Playback CPU after the gate
fixes: 1.27 to 1.51% of 3%.

### 21. Scripting

- [x] **Command line:** a `music-player` tool in the bundle that runs registry commands in the
      running app (`music-player play`, `music-player next`, `music-player play "album:Kind of
      Blue"`, `music-player status --json`), and starts the app if it isn't running.
- [x] **URL scheme:** `music-player://` runs the same commands, for Shortcuts, Raycast and links.
- [x] Both reach the app over a local channel only (Apple events or a socket readable by the user
      alone; the ADR picks). A web page can open a URL, so the URL scheme runs playback and
      navigation commands only; commands that change the library, playlists or files need the
      app in front and a confirmation. Add the rows to
      [ADR 0025](decisions/0025-threat-model.md).
- [x] Commands, their arguments and their help text come from the registry; nothing is declared
      twice. `music-player help` lists them.
- [x] Tests: argument parsing, each command routed to the registry, refused commands, and status
      output.

Implementation plan (ADR 0036):

1. **Registry** (Commands): each `Command` gets `runsFromLinks`, true for the playback commands
   and Back, Forward and Show Current Track, and `argument`, the help for what it takes (Play's
   search). They are the only list: the URL check, the help and the tests read them.
2. **Socket** (new primitive `LocalSocket`): a Unix-domain socket server in a 0700 folder the
   user owns, the socket 0600, `getpeereid` checked on every connection against an injected
   uid, frames a 4-byte length then the bytes, capped, read under a deadline. A client that
   checks the server's uid too. One thread blocked in `poll`, so idle costs no wakeups.
3. **Scripting** (new Core module): the request and reply JSON (strict keys), the status shape,
   command names derived from the registry (the ID, or its last part when no other command has
   it), the command-line parser and help, the URL parser (length cap, one percent-decode,
   unknown hosts, paths and keys refused, only `runsFromLinks` commands), and a router that
   runs a request through the `CommandDispatcher`. The socket lives at
   `<data folder>/scripting/socket`, so `--home` moves it.
4. **Play a search** (LibraryBrowser): `play "<text>"` shows the whole library with that
   search and plays it; `album:`, `artist:` or `genre:` and a name shows that entry, as the
   palette does, and plays it.
5. **App:** start the server once playback is ready, route requests and `music-player://`
   links (queued until then) to the router; refused links are reported in the status bar.
6. **Tool** (new App-tier executable `ScriptTool`): bundled as `Contents/MacOS/music-player`,
   signed with the hardened runtime before the app. It starts the app with `NSWorkspace` when
   the socket doesn't answer and waits up to 20 s. `scripts/bundle` adds `CFBundleURLTypes`
   with the scheme read from Swift; `scripts/check-signature` checks every executable.
7. **Tests:** LocalSocketTests (permissions, a refused uid, oversized and slow frames, a stale
   socket, the next client served), ScriptingTests (parsing, help, URL refusals, every command
   routed, status JSON), CommandsTests (the link list), LibraryBrowserTests (play a search or
   an entry). ADR 0025 gets rows for the socket and the URL scheme.

Result: shipped. A `music-player` tool in the bundle (`Contents/MacOS/music-player`, signed with
the hardened runtime and covered by `check-signature`) and `music-player://` links both run
registry commands in the app over a Unix-domain socket in a 0700 folder under the data folder,
checked by peer uid before any byte is read, with 4 KiB length-prefixed JSON, 2 s deadlines and
at most 16 pending replies (ADR 0036). Apple events were passed over for their entitlement,
Automation prompts and no sender uid. The tool starts the app and waits one 20 s deadline; a
retry after a lost reply can run a command twice. Links run 18 playback and navigation commands
(`runsFromLinks`, one flag on the command), never Volume Up, at most 5 a second; every other
command is refused from a link rather than confirmed. Commands, arguments and help come from the
registry. ADR 0025 rows 47 to 50.

### 22. Per-device profiles

Each output device remembers its own settings, with nothing for the user to set up. A profile is
keyed by the device's UID (a renderer's UDN once phase 9 lands) and kept in the state file.

- [x] The volume level, and whether digital volume and hog mode are on, are remembered per device.
      A device seen for the first time starts from the `output.*` settings in the config file;
      after that, changing one while that device is in use changes it for that device only.
      The ADR says how an edit to those settings in the config file meets the profiles.
- [x] Each profile records the rates and formats the device reported, so a track the device can't
      take is refused before playback starts, and the signal path panel can show them.
- [x] When the device last chosen reconnects (the DAC switched back on), output returns to it, as
      long as nothing is playing elsewhere.
- [x] Tests: two fake devices with different settings, a first-seen device, switching between
      them mid-queue, and a reconnect.
- [ ] **Hardware checkpoint (owner):** on the DAC Mac, set different volumes on the ADI-2 and the
      built-in output, switch between them, then power the ADI-2 off and on, and report what the
      app does.

Implementation plan:

- `refactor`: move `PhysicalFormat` to Playback (its CoreAudio inits and `summary` stay in
  HALOutput) and `kilohertz(_ range:)` to DisplayText, so the signal path can carry formats.
- Playback: `DeviceFormats` (the HAL's available nominal rates and the first output stream's
  physical formats) on `DeviceSignal`, and the device's UID on `DeviceSink`. HALOutput reads
  them in `readSignal` and listens for both properties; NullDevice reports settable ones.
- HALOutput: `DeviceChoice` (provider, digital volume, gain, recorded formats). `DeviceOutput`
  takes one, switches to another with `use(_:)` mid-queue at the same position, refuses a track
  no reported format takes with `DeviceOutputError.deviceCannotTake`, and returns on its own to
  a device that went away and came back, reported on `returns`.
- Settings: `DeviceProfiles` in the state file (`output.profiles`), at most 32, least recently
  used evicted, with the config-edit rule as pure functions. Settings imports Playback.
- App: choose the profile at launch and on an output setting change, write it before the change
  it protects, mirror it into the config, record volume changes and reported formats.
- NowPlaying: a "Takes" row in the signal path panel.
- Tests: DeviceProfilesTests (Settings: first seen, config edit, switch, eviction, strict
  decoding), DeviceSwitchTests (HALOutput, two null devices: first seen, switch mid-queue,
  reconnect paused and while playing elsewhere, unsupported format refused), SignalPathLines.
- ADR 0037.

Result: shipped up to the owner's checkpoint. Volume, digital volume and hog mode are kept per
device UID in `output.profiles` in the state file, at most 32, least recently used evicted, each
written before the change it protects. A first-seen device starts from `output.*`, which always
shows the device in use; the app writes it back on a switch, and an edit made with the app closed
counts as an edit for the device in use at launch (ADR 0037). Output settings now switch mid-track.
Each profile records the rates and formats the device reports; a track none takes fails with
`deviceCannotTake` before the device is configured, and the signal path panel has a "Takes" row.
A device that comes back gets output back unless a track plays on the device chosen since, and
the check runs again on pause, stop, queue end and a failed track; no polling. The profile save
on an automatic return lands after the switch, an accepted exception. CPU while playing 2.21%.

### 23. Sync across machines

Two or three Macs play the same NAS library, and each keeps its own index. Plays, skips, ratings,
loved, playlists and Date Added are shared through a sync folder on the NAS. Each machine appends
its own changes to its own log there and reads the others' logs. No file has two writers, so SMB
locking never matters. The library index, the layout state and the config file are never synced.
Write the ADR first; it amends ADR 0022.

- [x] **Boundary first.** AGENTS.md gains one exception: the app may write its own log, and
      nothing else, in the sync folder the user chose, which must be outside every watched folder.
      Music files stay as they are. Tests use a temporary folder, never the NAS.
- [x] **Track identity** ([ADR 0026](decisions/0026-sync-identity-is-the-relative-path.md)). A
      synced track is its path relative to the library root, normalized to NFC; each machine maps
      it to its own `paths` row. Every machine plays the same files on the NAS, so no audio is
      hashed. Machines pointed at separate copies don't share stats, and settings say so.
      - **Moves.** A scan matches `paths` rows with stats whose file has gone against the paths it
        added, on codec, sample rate and length in frames, then on title when several match.
        `paths` gains those four facts, set by each scan, because a gone file can't be read. A
        match gives the old row the new path and removes the new, stat-less row. Ambiguous and
        unmatched pairs wait in the library health report (phase 19), where the user picks or
        dismisses them. This fixes phase 15's known limit locally too.
      - **Sync** carries a match as a `move` event with both relative paths. A machine that already
        made the move, or has no row for the old path, ignores it; one with stats on both paths
        merges them by the rules below.
- [x] **Network folders by share** ([ADR 0028](decisions/0028-network-folders-by-share.md)). A
      watched folder on a network volume is stored as its share's URL and the path inside it. The
      app finds the share's current mount point at launch, before each scan, on wake and on a
      network change, and rewrites the `paths` prefixes in one transaction when the mount point
      moved (`/Volumes/music` to `/Volumes/music-1`). An unmounted share leaves the folder offline,
      as now. This helps a single machine too, so it can land before the rest of the phase.
- [x] **Library root.** `sync.folder` in the config file. The library root is the watched folder,
      stored by share, so it's the same on every machine; relative paths start there.
- [x] **Logs.** One append-only file per machine (`<machine id>.log`, the ID minted on first run
      and kept in the state file), one event a line: play, skip, rating, loved, Date Added, and
      playlist create, rename, delete and entry changes. Events carry a hybrid logical clock, not
      just wall time, so a machine with a wrong clock can't win every conflict. Each machine
      records how far it has read each other log.
- [x] **Merging.** Plays and skips are a union, so none is lost or counted twice. Ratings, loved,
      playlist names and playlist contents take the latest change by clock, then by machine ID.
      Date Added takes the earliest. Phase 18's import runs on one machine and reaches the others
      as events.
- [x] **Offline.** With the NAS away, the app works as now and appends to a local copy of its log,
      which goes to the NAS when it's back. A log that ends mid-line (a machine died while
      writing) is read up to its last complete line.
- [x] Logs from other machines are hostile input: line and file size caps, strict decoding, rows
      in [ADR 0025](decisions/0025-threat-model.md).
- [x] Tests: two and three simulated machines in temporary folders, with interleaved and
      conflicting edits, skewed clocks, the library mounted at a different path on each, a share
      remounted at `-1`, the same share reached by host name and by IP address, a renamed
      and a moved file, a move with a retag, two gone files of the same length (ambiguous, so
      reported), a move event arriving after the new path was played, a decomposed and a
      precomposed accented name, a truncated log, and the NAS going away and coming back.
- [x] Bench: merging 1M play events, the full scan and no-change rescan budgets still holding, and
      move matching after every fixture file is renamed.
- [ ] **Hardware checkpoint (owner):** with two Macs on the NAS, play and rate on each, rename a
      folder of a test album, and report whether both machines show the same plays, ratings and
      playlists. Then eject the share on one Mac, remount it at `/Volumes/music-1` (leave an
      empty `/Volumes/music` folder behind), and report whether the library and its stats came
      back.

Implementation plan, part 23a: the two local items (ADRs
[0026](decisions/0026-sync-identity-is-the-relative-path.md),
[0028](decisions/0028-network-folders-by-share.md)). Part 23b does the boundary, `sync.folder`,
the logs, merging, the clock and `move` events.

1. **Schema** (Library): `paths.path` holds the path in NFC, which `pathID` looks up, so a name
   listed decomposed and precomposed is one row; `files.path` stays as listed, to open it.
   `paths` gains `codec`, `sample_rate_hz`, `length_frames` and `title`, which each stored read
   sets, and `lost_dismissed`. A stats table `share_roots` keeps where each share folder's paths
   were last rooted. The stats SQL changes, so the old stats are discarded once with a notice.
2. **Move matching** (Library): after a finished walk's removals, `matchMoves()` pairs gone
   stats rows with every stat-less track, one to one on codec, rate and frames, then title. A match moves the files row
   to the old ID and deletes the new paths row, in one transaction; `ScanSummary.moved` counts
   them and each is logged with both paths.
3. **Lost Stats** (Library, Settings, LibraryBrowser, App): a `HealthCheck.lostStats` lists each
   unresolved gone stats row as a line and its candidate tracks; `lostFiles()`,
   `moveStats(from:to:)` and `dismissLost(_:)` back a sheet, opened by
   `library.resolveLostStats`, where the user gives a lost file's stats to a candidate or
   dismisses it. `LostStatsSession` holds its logic, without AppKit.
4. **Shares** (Settings, Library): `WatchedFolder.share`, the share's URL, with `path` then the
   path inside it. `ShareMounts` lists mounted shares (`SystemShareMounts` reads
   `volumeURLForRemountingKey`); `ShareURL` holds the host and share rule; `FolderLocator` turns
   the configured folders into folders at their mount points, rewriting the `files` and `paths`
   prefixes in one transaction when a mount point moved. An unmounted share keeps its last root,
   so it shows offline as now.
5. **Watcher and app:** the watcher locates at start and before each scan, and on
   `sharesMayHaveMoved()`, which the app calls on wake, on a network change and on a mount; a
   new location reaches the window as `WatcherEvent.folders`. Adding a folder on a share stores
   it by share; removing one and `--scan` match it by its located path.
6. **Bench:** `library: match moves after renaming every fixture file`, its budget in the table
   above; the full scan and no-change rescan rerun.
7. **Tests:** LibraryTests (NFC spellings, facts, a rename, a move, a move with a retag, two
   gone files of one length, lost files and their resolution, the locator with a share
   remounted at `-1`, by host name and by IP, unmounted, the prefix rewrite and its
   conflicts, the watcher relocating), SettingsTests (`share` decoding and problems),
   LibraryBrowserTests (`LostStatsSession`), CommandsTests (the new command).

Result, part 23a: shipped. Paths are keyed in NFC and carry codec, rate, frames and title from
each read. After a complete walk a scan matches lost paths with stats to stat-less ones 1:1, on
those facts and then on title, across folders in either scan order; the rest wait under Resolve
Lost Stats… in the health report. A network folder is stored as its share URL and inner path.
Mounts come from `getmntinfo(MNT_NOWAIT)`, read only on a trigger or before a scan, so a hung
mount can't stall quit; one volume that won't read is skipped. A share with another host matches
only for an IP literal with one candidate, or a `.local` or case difference; otherwise it stays
offline (ADR 0028). Existing network folders must be re-added, and the stats schema change
discards the index once. Rescan after renaming every file: 5.19 s, budget 10 s.

Implementation plan, part 23b: the boundary, `sync.folder`, the logs, merging, the clock and
`move` events ([ADR 0038](decisions/0038-sync-logs.md), written first with the AGENTS.md
boundary).

1. **Settings:** `SyncFolder` (a path, or a share and the path inside it, as 0028 stores a
   watched folder) as `sync.folder`, null by default. A schema-wide check refuses a sync folder
   inside or equal to a watched folder, in the config file and in `set`.
2. **Schema** (Library): a `sync` part: `sync_state` (this machine's ID, minted by the part's
   SQL, its clock, its log's size and how much of it reached the folder), `sync_outbox` (its
   log, one line a row, written in the transaction of the change it records), `sync_logs` (how
   far each other machine's log was read and applied), `sync_items` (the clock of the change
   each rating, love and playlist field holds) and `sync_playlists` (each playlist's sync ID,
   kept as a tombstone once deleted). Rebuilding the part from an earlier shape rebuilds the
   stats too, so a new machine ID never re-reads its own old log on top of its stats.
3. **Events** (Library): `SyncClock` (a hybrid logical clock with a per-item step and a skew
   bound), `SyncEvent` and its line format, strict at every level; sync paths (share name, the
   folder's path in the share and the path under it, in NFC) from `share_roots`.
4. **Writes** (Library): plays, skips, ratings, loves, new paths' Date Added, playlist
   create, rename, rules, delete and entries, the import's counts and the scan's and Lost
   Stats' moves each append an event to the outbox in their transaction.
5. **Merging** (Library): every other `<id>.log` in the folder, opened with `O_NOFOLLOW` and
   `fstat`, read from its offset to its last complete line under the caps, the logs merged in
   clock order and applied in batches, each with its offsets; plays and skips once by sequence
   number, last writer wins by clock then machine for the rest, the earliest Date Added, and
   moves as 0026 says, merging a path's stats into the other's. Pushing appends the outbox's
   tail to this machine's log, which is always a byte prefix of the outbox.
6. **Watcher and app:** the watcher syncs on its scan queue at start, after each scan, on the
   share triggers and after a local edit (pushing only), and reports `WatcherEvent.synced`; the
   window refreshes and shows the problems.
7. **Hostile input:** caps per line, file and event count, 100 problems per log then a count,
   only `<32 hex digits>.log` names; ADR 0025 rows; `scripts/fuzz sync-log`.
8. **Tests:** SyncTests with two and three machines in temporary folders: interleaved and
   conflicting edits, skewed clocks, a different mount path on each, a rename, a move, a move
   after the new path was played, NFD and NFC names, a truncated log, the folder going away and
   coming back, the caps; SettingsTests for the folder check. Threaded ones 20 times.
9. **Bench:** `sync: merge 1M play events`, its budget in the table above; full scan and
   no-change rescan rerun.

Result, part 23b: shipped up to the owner's checkpoint. Each Mac appends its events (plays,
skips, ratings, loved, Date Added, playlists, moves and import counts) to `<machine id>.log` in
`sync.folder`, through an outbox written in the same transaction as the change, so the log is
always a byte prefix of it; the machine ID lives in the database, and a `flock` guards the push.
Other logs merge in clock order with their offsets saved in the same transaction: plays and
skips by (machine, sequence), fields last-writer-wins by hybrid logical clock then machine, Date
Added earliest. The clock never runs more than 1 h past wall time (ADR 0038). Edits read before
their playlist's create wait; moves are kept in `sync_moves` so late and out-of-order events
follow them. Hostile logs: 4 MiB lines, 1 GiB and 4M events a log, 64 logs, work counted per
path, 100 problems a log cut to 200 characters, Cf characters refused in names, `O_NOFOLLOW`
and `fstat` on every open (ADR 0025 rows 51 to 55, `sync-log` fuzz target). Nothing from before
this build is sent. Merge 1M play events 11.42 s, budget 20 s.

### 24. Palettes

The owner's notes from 2026-11-02, after using the app on the full library. The rows in phases 24
to 28 run in parallel, one agent each, then merge onto the phase branch and go through the gate
together.

- [x] **24.1 ⌘K opens complete and steady.** With an empty query the palette lists only commands,
      and genres, playlists and outputs show up only once the user types. A genre ("Electronic -
      Glitch, Dub, Experimental, Ambient") was listed first before anything was typed. The panel
      also flashes as it opens, as if it fills after it shows. The empty-query list is all known
      commands, so build it before the panel shows and show it on the first frame.
- [x] **24.2 ⌘P opens instantly after the first time.** It flashes while it fills. The first open
      may build its index; after that, keep the index and reuse it, and rebuild only when the
      library changes (a scan, an import, a tag edit, a removal).
- [x] **24.3 ⌘P goes to the item; ⌘↩ filters to it.** Choosing an artist or an album with ↩ or a
      click shows it in the full track list: clear any browser filter, then select and scroll to
      its first track. ⌘↩ or ⌘-click instead filters the browser panes to it, as ↩ does today. So
      does a key the user sets in Shortcuts, → by default, pressed on an artist or album result.
      Tracks keep today's behavior. A track result's → still moves the text cursor when it isn't
      at the end of the field.
- [x] **24.4 Palette size matches simple-spotlight.** ⌘K and ⌘P use the same width, height, row
      height, field font and corner radius as the panel in `~/projects/simple-spotlight`. Read
      its numbers from its code; don't copy its code (ADR 0012's rule).

Result: shipped as planned; `./scripts/check` passes. ⌘K with an empty query lists only commands
(`rankPalette` takes `emptyQueryKinds`; ADR 0016 amended), and both palettes rank their opening
rows on the main actor before the panel shows, so the first frame has its rows. ⌘P keeps its
rows (artists, albums, every track's prepared row) in `LibraryListing<Value>` and rebuilds them
lazily on the next open after `browser.libraryRefreshed`, so a scan does not prepare 43k titles
every 2 s. ↩ or a click on an artist or album shows the full library with its first track
selected; ⌘↩ or ⌘-click filters the panes. "Filter to Item" (`palette.filterToItem`, → by
default, ADR 0046) is a palette key, refused if it would type in the field, and is taken only
at the end of the field with no marked text. Applying user shortcuts no longer drops a command's
other settings. The panel matches simple-spotlight's size: 680 wide, a 56-point 24-point light
field, 16-point corners, 48-point rows, 8 rows, 453 points tall (ADR 0047). Bench: ranking ⌘P's
cached rows on the main actor takes 2.3 ms on Apple Silicon over 42,964 tracks (budget 4 ms
there, 16 ms on the old Mac, an estimate until run there). Deferred: row 25.3's removal must
call `goToEntries?.libraryChanged()` and `goToTracks?.libraryChanged()` if it does not end in a
browser refresh. Pending the owner: the by-hand checks of 24.1 to 24.4, and the old Mac bench.

### 25. Track actions and navigation

- [x] **25.1 Get Info opens every time.** ⌘I opened the tag editor once; after it was closed,
      ⌘I did nothing. Find why and fix it, with a test that opens, closes and opens again.
- [x] **25.2 Track context menu, grouped as Swinsian groups it.** Groups split by separators:
      Play Next, Add to Playback Queue, Play Now · Show Album, Show Artist · Like, Dislike (the
      loved flag: like sets it, dislike sets a disliked state; add the state if the index
      lacks it, synced as phase 23's loved is) · Rating · Get Info, Reveal in Finder (25.3's
      command) · Remove… · New Playlist with Selected Tracks, Add to Playlist ▸, Show in
      Playlist ▸. Keep any item the menu has today. Every item is a command from the registry,
      so it is in ⌘K too.
- [x] **25.3 Remove from library, or to the Trash.** Remove… (and ⌫ in the track table) asks
      "Remove Track?" / "Remove N Tracks?" with Remove from Library, Remove and Move to Trash, and
      Cancel as the default. Removing from the library keeps the paths in an exclusion table so a
      rescan doesn't add them back; Library Health lists excluded tracks and can restore them. Move
      to Trash uses `NSWorkspace.recycle`, only for the files the user confirmed, and is the one
      exception to the music-file boundary besides TagWriter. Owner's answers, 2026-11-02: allow
      the Trash; keep removed tracks excluded. Write the ADR and the AGENTS.md boundary first.
- [x] **25.4 ⌘R reveals the track.** In Searcher (`~/projects/searcher`; find its bundle ID
      there) when it's installed, else in Finder. A setting picks Finder or Searcher. Bind ⌘R
      unless it's taken, in which case say what moved.
- [x] **25.5 ← and → in the main window.** → plays the next track. ← restarts the track, or plays
      the previous one when the track is within its first 3 seconds, as the transport's back
      button does. Only when the track table, the browser panes or the sidebar has focus and no
      text field is editing; the browser panes keep ←/→ for moving between panes if they use it
      today, in which case say which wins and why in the commit.
- [x] **25.6 Organize by album artist, type-select included.** With organize by album artist on,
      typing "vladislav" in the track table should land on Vladislav Delay's own albums, as
      Swinsian does. It landed on a track of his inside a Various Artists compilation. The sort
      and type-select must both use the album artist (falling back to the artist), so a
      compilation sorts under its album artist and is never found by a track artist's name.
      Check the browser's artist pane follows the same rule.

Result: shipped as planned; `./scripts/check` passes. No benchmarks. 25.1: Cancel and Esc now
release the tag editor (`TagEditorSheet.cancelled`), so ⌘I opens again. 25.2: the track menu is
data in `AppMenus.trackMenu`, shared by the table and the timeline, every item a registry command;
new commands Add to Playback Queue, Show Album, Show Artist, Dislike and Show in Playlist…; a
right-click selects the row under the pointer; Dislike lives in a new `disliked` schema part and
syncs through the `loved` field (ADRs 0048, 0049). 25.3: Remove… (⌫, File menu, ⌘K) removes from
the library into a `removed` table that scans skip, or moves the files to the Trash with
`NSWorkspace.recycle`; Library Health lists Removed; Restore Removed Tracks… brings them back
(ADR 0050; AGENTS.md boundary amended). The refresh after a removal meets phase 24's deferred
note. ⌫ removes only while the track table or timeline has the keys. 25.4: ⌘R reveals in Searcher
or Finder by the `library.fileViewer` setting, with ⇧⌘R the alternate and ⌥⌘R no longer a default
(ADR 0051). 25.5: ← and → are the alternates for Previous and Next Track; the panes keep them for
moving between panes, so Focus Next Pane and Focus Previous Pane have no default key (ADR 0052).
25.6: the sort already used the album artist; type-select now matches it too (`TrackName.sortArtist`),
and the Artist pane needed no change. Not done: Library Health has no Restore action (row 26.1);
removals are not in the sync log; Show in Playlist covers manual playlists only. For 26.4: Swinsian
keeps its table columns in `~/Library/Preferences/com.swinsian.Swinsian.plist` (key
`MainTableColumns-Ver1`, entries with `TableColumnIdentifier`; browser columns under
`BrowserColumns`, sort under keys like `GridSortKey`), not in `Library.sqlite` or its Application
Support folder; this was a look only, nothing was read in code. Pending the owner: the by-hand
checks of 25.1 to 25.6.

### 26. Watched folders and library health

- [x] **26.1 Fix a folder with problems.** The health report's problem rows get actions. The
      owner's case: a Swinsian import listed `/Users/dylanfisher/Library/Application
      Support/Swinsian/Library.sqlite: not in the library:
      /Volumes/music/dsd/Armstrong, Louis - 1952 - Mack The Knife (2017 DSD 128) (DR12)/01-When
      It's Sleepy Time Down South.dsf`, a file under the watched `dsd` folder on the share. Find
      why it wasn't matched (a mount path, the share mapping of ADR 0028, NFC, or the folder not
      scanned yet) and fix the cause. Then give the report "Dismiss" for problems the user doesn't
      care about, "Remove from Library" for missing tracks, and "Locate…" for import misses: the
      user picks the folder the files now live under, the app maps the old prefix to it, checks
      the files are in a watched folder (offering to add it if not), and reruns the import's
      matching for those rows.
- [x] **26.2 Rescan one watched folder.** The Watched Folders table's Rescan Now becomes "Rescan
      All" and gains "Rescan" for the selected folders, and the table's context menu has both.
      The watcher scans just that folder.
- [x] **26.3 Rescan interval in the table.** The Rescans column is editable in place, a popup of
      the allowed intervals (the range in the settings schema) plus "Watch only" for local
      folders if the schema allows it. Writes the same setting the config file holds.
- [x] **26.4 Import column layout from Swinsian.** Find where Swinsian keeps its table columns,
      order, widths and sort: `Library.sqlite`, its preferences plist
      (`~/Library/Preferences/com.swinsian.Swinsian.plist`), or a file in its Application Support
      folder. Read only; never write Swinsian's files. If found, the import (phase 18) gains
      "Import column layout", mapping Swinsian's column IDs to ours and skipping any we lack, and
      reporting what it skipped. If it isn't stored anywhere readable, write down where you
      looked in the phase's Result line so the owner can be told.

Result: shipped as planned; `./scripts/check` passes. Benchmarks: the memory benchmark had
regressed to 1.8 GB since phase 24's playing-row tint (93a24ea), because the track table and the
queue made a new `MarkedRowView` per row with no reuse identifier; `MarkedRowView.reused(in:)` fixes
it, and the benchmark is back to 60 MB (budget under 120 MB), launch to first rows 0.47 s. 26.1: the
owner's .dsf miss was not a mapping, NFC or scan fault; the scanner reads only `audioFileExtensions`
and DSF waits for phase 12, so no .dsf is indexed. Import misses in a type the scanner skips are now
listed apart as "not in the library, a format this app doesn't read yet" and get no Locate…. The
Problems window is a table with Dismiss (kept in `dismissed_problems`), Remove from Library (Lost
Stats rows), Restore (Removed rows, the Restore row 25.3 left here) and Locate… (one import miss: the
user picks the folder it lives in now, the old prefix is found, every miss under it is imported again,
and an unwatched folder is offered for watching and matched after its scan; ADR 0059). 26.2: Rescan
Now is now Rescan All (command id `library.rescanNow` kept), and Settings ▸ Watched Folders has a
Rescan button and a context menu with Rescan and Rescan All; `LibraryWatcher.rescan(folders:)` scans
only the chosen folders, even while polls are paused for playback (ADR 0062). 26.3: each network
folder's Rescans cell is a borderless popup of 1, 5, 15, 30 minutes and 1, 2, 6, 12, 24 hours that
writes `pollIntervalMinutes`; local folders keep "On change", since the schema never polls them, so
there is no "Watch only" choice (ADR 0060). 26.4: Swinsian keeps its table columns in
`~/Library/Preferences/com.swinsian.Swinsian.plist` (`MainTableColumns-Ver1` for order and widths,
`NSTableView Sort Ordering v2 main_track_table` for the sort), not in `Library.sqlite` or Application
Support; the Swinsian import sheet gains "Import column layout", which skips and reports columns we
lack (ADR 0061; `swinsian-columns` fuzz target, threat model row 56). Not done: .dsf matching waits
for phase 12; Locate… works only on the last import of the session; a Locate… hit is not added to the
playlist the import made; Lost Entries rows get only Dismiss (Remove from Library is on Lost Stats
rows, which is how ADR 0059 reads "missing tracks"); dismissals cannot be undone. Pending the owner:
the by-hand checks of 26.1 to 26.4, and confirming the reading of "missing tracks".

### 27. Appearance

The owner wants to match Swinsian's look. Swinsian's track table: an Album Art column on the
left, art filling the column's width and spanning the album's rows; thin vertical lines between
every column; rows about 17 pt with small type; light alternating rows off. Liquid glass means
macOS 26's `NSGlassEffectView`, behind `#available(macOS 26, *)`, with an `NSVisualEffectView`
fallback for macOS 12 to 15.

- [x] **27.1 Appearance settings section.** A new Appearance section in the settings window and
      the config file: vertical column lines, horizontal row lines, alternating rows, row
      height (compact, regular, large), and the art column's art size. The Album Art column, when
      shown, draws the art at the column's full width (minus a small inset), square, spanning the
      album's rows, and resizes with the column. Defaults stay as today's look.
- [x] **27.2 Status bar like Swinsian's.** Stats centered in the status bar, as "43400 tracks,
      1048.1 GiB, 185 days 17 hours 29 minutes 26 seconds", with the selection appended as
      "(1 track selected, 303.5 MiB, 1 hour 2 minutes 2 seconds)". Clicking the stats cycles
      through: all with selection, all only, selection only (falling back to all when nothing is
      selected). The choice persists. The bar uses liquid glass.
- [x] **27.3 Customizable header toolbar.** The header becomes an `NSToolbar` the user customizes
      with the standard sheet (Customize Toolbar… in View and the toolbar's context menu): items
      for transport controls, volume, the now-playing status, search, shuffle, repeat, the
      queue toggle, the output picker, the signal path, flexible space and space. Every item can
      be removed, down to an empty toolbar. A second status style, "Centered", draws Swinsian's
      header: "Title by Artist from Album" centered in bold, under it a rounded capsule with
      elapsed time, a thin progress bar and total time, no art. Today's style stays as the
      default "Detailed". The header uses liquid glass.
- [x] **27.4 Compact signal path panel.** The bit-perfect panel uses the window's width: the
      verdict and the rows laid out in two or three columns (File, Decoder, Device on one side;
      Takes, Hog mode, Volume on the other), so it's about half as tall. Tidy its spacing,
      alignment and type to match the rest of the header; the verdict reads as a small colored
      badge.

Result: shipped as planned; `./scripts/check` passes. The owner's screenshots weren't available and
nobody ran the app, so the look is checked only by unit tests and off-screen renders. 27.1: five
settings (`appearance.columnLines`, `rowLines`, `alternatingRows`, `rowHeight`, `artSize`) in a
new Appearance pane and a View ▸ Track Table submenu; Full Width art is drawn once per album,
square, as one slice per row (`AlbumArtCell`, `ArtRun`); defaults keep today's table; "art size" is
read as thumbnail or full width, not points (ADR 0053). 27.2: centered totals in the status bar
with the selection appended, a click cycles the three choices, saved as `window.statusTotals`;
glass on macOS 26 with a title bar material fallback (ADR 0054). The totals come from a size and
length map the index keeps and are added up after the rows show. 27.3: the header is an
`NSToolbar` with eleven items, saved as `window.toolbarItems`, Customize Toolbar… in View and the
context menu, and a Centered now-playing style (`appearance.nowPlaying`); the glass is the system's
own toolbar glass on macOS 26 and the title bar material on 12 to 15, not a backdrop of ours
(ADR 0055). 27.4: the signal path panel is two columns with a colored verdict badge, about 77 pt
tall at 720 pt wide against about 124 pt. Bench on Apple Silicon, main to branch: search keystroke
p95 6.1 to 5.9 ms, sort p95 27.7 to 25.7 ms, re-sort 28.7 to 26.2 ms, launch to first rows 0.37
to 0.40 s, memory at first rows 46 to 45 MB. The gate also fixed a memory growth after scrolling
every row (about 1.8 GB to 62 MB; the track table and queue now reuse row views), a state file
listing a toolbar item twice crashing at launch, and Find with Search removed from the toolbar.
For 26.4: Swinsian keeps its table columns in `~/Library/Preferences/com.swinsian.Swinsian.plist`
(key `MainTableColumns-Ver1`), not in `Library.sqlite`; row 26.4 is not part of this phase. Not
done: scrolling with the art column is left to row 28.3. Pending the owner: the by-hand checks of
27.1 to 27.4, on macOS 26 and on the 2015 MacBook Pro (glass, Full Width art, Customize Toolbar…
drag, the Centered style, the signal path panel in light and dark), and `./scripts/bench` on the
2015 MacBook Pro.

### 28. Queue, history and scrolling

- [x] **28.1 The queue shows what plays next.** Today it lists all 3,229 tracks of the context,
      and Play Next doesn't show at the top. It should list, in order: tracks added with Play
      Next, then those added with Add to Playback Queue, then the rest of the context after the
      playing track (playing an artist under Z shows the tracks after it, not the whole list).
      Played tracks leave it. Find whether the model or only the view is wrong, and fix both if
      needed, with tests on the order.
- [x] **28.2 History shows only plays.** With nothing played it showed the whole library. History
      lists tracks with at least one recorded play, newest first, and says "Nothing played yet"
      when there are none.
- [x] **28.3 Scrolling as smooth as Swinsian's.** Scrolling, and dragging the scroll bar above
      all, lags. Profile the track table on the fixture library and fix what costs per row: cell
      reuse, row height fixed and not measured, no per-row queries or string formatting on the
      main thread at scroll time, art decoded off the main thread at the cell's pixel size and
      cached, layer-backed views with `canDrawSubviewsIntoLayer`, responsive scrolling on, and
      no work in `tableView(_:viewFor:row:)` that a prefetch can do. Add a bench, "scroll every
      row by scroll-bar drag", with a budget in the table above, and record before and after.

Result: shipped as planned; `./scripts/check` passes. The owner's screenshots weren't available and
nobody ran the app, so the look is checked only by unit tests and off-screen renders. 28.1: both the
model and the view were wrong. The queue marks each entry the user queued (Play Next or Add to
Playback Queue) and Add to Playback Queue now lands after the Play Next tracks, so the order is Play
Next newest first, then the adds in order, then the rest of the context. The panel lists from the
current track on, played tracks hidden but kept in the engine for Previous and repeat-all; each row
maps to its engine position for play, remove and drag, and drops land just below the current track
(ADR 0056). Shuffle still mixes queued tracks into the shuffled rest, and a queued track keeps its
mark after it plays. 28.2: the cause was the data. An import sets Last Played without history rows
(ADR 0033), so History listed nearly the whole library. History now needs a recorded play, read from
a new `recorded_paths` table the schema fills from `history` (no stats discarded), and an empty
History says "Nothing played yet" (ADR 0057). The History source bench measured 49.78 ms against the
30 ms budget with a per-track `history_path` lookup and 11.94 ms with the table. 28.3: a new bench,
"scroll every row by scroll-bar drag", p95 per step over 1,386 steps on Apple Silicon: 15.2 ms before,
9.8 ms after (median of three; budget < 16 ms, < 33 ms estimated for the old Mac). Profiling showed
AppKit, not our row work (about 4%), so the track table and timeline use `TextCell`, which draws its
line itself, art cells position by autoresizing mask, and each row draws into one layer (ADR 0058).
Launch 0.47 s, memory after scrolling 82 MB. The gate fixed the cached current-track position in the
queue, and anything drawn over the track table must be laid out without constraints. For 26.4:
Swinsian keeps its table columns in `~/Library/Preferences/com.swinsian.Swinsian.plist` (key
`MainTableColumns-Ver1`), not in `Library.sqlite`; row 26.4 is not part of this phase. Not done:
prefetching rows and off-main formatting (under 2% of samples); the next scrolling gain would come
from fewer columns or cached drawn text. Pending the owner: the by-hand checks (queue order and
double-click, Delete and drag on queue rows; "Nothing played yet" centered in light and dark and
gone after one play; text truncation, right-aligned numbers, selected-row color focused and
unfocused, playing-row mark, grey missing rows, Full Width art and thumbnails while scrolling,
Compact and Large heights, VoiceOver, and a scroll-bar drag against Swinsian on macOS 26 and the
2015 MacBook Pro), and `./scripts/bench` on the 2015 MacBook Pro for "scroll every row" and the
History source.

### 29. Art, status bar, selection and palette

The owner's feedback from 2026-11-02, given during phase 12's run.

- [x] **29.1 Album art.** The thumbnail / full-width option has no effect: art is always full
      width. Replace it with a choice between art scaled to fit the view and art always full
      width, cropped at the bottom on short albums. Art fills its cell edge to edge, so no row
      highlight shows behind it. Hovering art brings it to the top layer at full width; clicking
      it opens it centered, as large as the screen allows, and a click anywhere or Esc closes it.
- [x] **29.2 Now-playing style in the toolbar.** The now-playing style is chosen by customizing
      the toolbar, as in Swinsian, not in Appearance. The signal path badge isn't cut off.
- [x] **29.3 Status bar.** Translucent gray glass like the table headers, the same height, its
      text centered vertically in the tables' compact font size.
- [x] **29.4 Selection and keys.** After any sort or column change, the selected item scrolls
      to the center. With nothing playing, ⌘L focuses the selected item if there is one. The
      playing row's highlight is light gray, not light blue. Ctrl+Option+Up/Down scroll without
      changing the selection.
- [x] **29.5 Palette.** ⌘K keeps its width but gets back its old height and item count, and uses
      Searcher's selection highlight instead of bright blue.

Plan:

1. **29.1** `ArtSize` becomes `fit` and `fullWidth` (default fit; a config with `thumbnail`
   no longer matches and is discarded with a problem, pre-release). `ArtFrame` (pure, tested)
   places an album's art in its run of rows: fit scales it into the column's width and the
   run's height, full width fills the column and is cut off at the run's last row. Art cells
   draw edge to edge across the column's spacing. `RowArt` loads at the column's pixel width.
   Hovering an art cell shows `ArtHover`, the whole art at full width over the rows, laid out by
   frame (ADR 0058); clicking it opens `ArtViewer`, the art decoded off the main thread at the
   screen's size, centered, closed by a click or Esc. Tests: `ArtFrameTests`, the controller's
   run and hover geometry. ADR 0065.
2. **29.2** The now-playing styles become two toolbar items, Now Playing and Now Playing
   (Centered), each its own view; `appearance.nowPlaying` is removed. The signal path badge's
   label goes in the box's content view so it isn't clipped. ADR 0055 amended.
3. **29.3** The status bar uses the table header's material and the track table header's
   height, with the lists' font (`TextCell.font`), centered vertically.
4. **29.4** A sort or column change centers the selected row; ⌘L with nothing playing reveals
   the selection (`LibraryBrowser.showCurrentTrack`); the playing row's tint is light gray, in
   `MarkedRowView`; Scroll Up and Scroll Down commands on ⌃⌥↑ and ⌃⌥↓ scroll the track table a
   row without moving the selection.
5. **29.5** The palette's rows go back to 32 points and eleven rows (360 points of rows, as in
   b3d9988), at 680 wide; the selection uses the system's inset row highlight, emphasized, as
   Searcher's does. ADR 0047 amended.

Result: shipped as planned; `./scripts/check` passes. 29.1: the "no effect" report wasn't
reproduced: the setting was read and applied at launch and on every config change, and the owner's
config on the 2015 MacBook Pro holds no art size (ADR 0065 lists the checks). The setting is now
Scaled to Fit (the default) or Full Width, cut off at the album's last row, and art draws edge to
edge with no highlight behind it. Hovering art shows it whole at full width, and clicking opens it
centered at screen size, decoded off the main thread; a click, Esc, closing the window, the app
going inactive or a reload closes it. 29.2: Now Playing and Now Playing (Centered) are toolbar
items, `appearance.nowPlaying` is gone, and the signal path badge is no longer clipped. 29.3: the
status bar uses the header's material, the header's height and the lists' font. 29.4: a sort or
column change centers the selection; ⌘L with nothing playing shows the selection; the playing row
is light gray (its accent bar stays blue); ⌃⌥↑ and ⌃⌥↓ scroll without moving the selection.
29.5: the palette is back to 420 points, eleven 32-point rows at 680 wide, with Searcher's inset
selection highlight. The gate fixed the art hover staying put through a scroll, a late decode
reporting after the viewer closed, the viewer outliving its window, and recentering once per moved
column. Benchmarks against main measured the same evening (both inflated by this Mac's display
state, see phase 12): scroll-bar drag 12.6 ms (main 20.9), launch 0.66 s (0.68), memory after
scrolling 76.6 MB (budget 120), palette opening rows 4.08 ms (4.10; over its 4 ms budget as on
main). A config that still holds `appearance.nowPlaying` or `artSize: "thumbnail"` shows the
config problem banner until the line is removed (pre-release, no migration). Pending the owner:
trying 29.1 to 29.5 in the app, and saying whether the playing row's blue accent bar should go gray
too.

### 30. Owner feedback, 2026-11-02 evening

The owner's feedback from trying phase 29 on the 2015 MacBook Pro. Screenshots are in
`~/.claude/projects/-Users-dylanfisher-projects-music-player/feedback-2026-11-02/`: `s1144`,
`s1147`, `s1152`, `s1201` and `s1204` are Swinsian's settings, `s1300` is ours, `s2010` the art
hover, `s2016` the status bar, `s3548` Swinsian's column browser menu and `s4053` the toolbar
customization sheet. The three batches run in parallel worktrees.

#### 30a. Settings window

- [x] **30a.1 Layout like Swinsian's.** Checkbox labels go to the right of the checkbox, as the
      checkbox's own title; only pop-ups and fields keep a short label on the left. Settings are
      grouped into titled boxes or separated sections, with short help text under each. Receiver
      settings are the worked example: they need clear grouping and order. No label is cut off
      (`s1300` cuts "Pause Network Rescans While Playing").
- [x] **30a.2 Network Scan Readers.** An empty number field no user understands. It leaves the
      window and stays a config-file setting.
- [x] **30a.3 Sync folder.** The path label pushes the row too wide and hides its button. Show
      the folder's name, truncated, with a Change… button and an Open button that shows it in
      Finder.
- [x] **30a.4 File viewer.** The Searcher choice shows only when Searcher is installed; otherwise
      the setting isn't in the window and stays in the config file.
- [x] **30a.5 Played threshold.** A track counts as played once a set share of it has played,
      not only at the end. A setting, default 75%. Check what counts as played today first.

Plan:

1. **30a.5** Today a play counts after half the track or 240 s, whichever is first (ADR 0018),
   so long tracks count after 4 minutes and nothing waits for the end. A new
   `playback.playedPercent` (1 to 100, default 75) replaces both: a track counts once that share
   of its length has played, not paused; a track of unknown length still needs 240 s. A track
   that reached its end counts with a second's slack, so 100% works. `PlayCounter` takes the
   fraction, `PlayTracker` takes changes and reschedules its wake; the app sets it at launch
   and on every change. Tests: `PlayCounterTests`, `PlayTrackerTests`.
2. **30a.2, 30a.4** `GeneralModel` keeps some settings to the config file: Network Scan
   Readers always, File Viewer unless Searcher is installed (the app passes whether it is).
   Choosing one in ⌘K opens the config file. Tests: `GeneralModelTests`.
3. **30a.1** Sections become titled boxes with one label column for the whole pane. A checkbox
   carries its setting's title to its right, with the summary under the title; only pop-ups and
   fields have a label on the left. Sections: Audio Output (`output.`) and Play Counts (`playback.`)
   in a new Playback pane; Library, Sync and Receiver in General; and Network Folders, whose
   two settings move to a box under the Watched Folders list, as in Swinsian. Receiver Control comes first in its box, and the receiver's
   other rows are disabled while it's off. Tests: sections, dependent rows, the label column
   holding the longest title, the network folder settings in the Folders pane.
4. **30a.3** The sync folder row shows the folder's name, truncated, with its full place as a
   tooltip, and Change…, Open and Clear. Open finds the folder where its share is mounted now
   (the watcher's lookup, made public in Library) and opens it in Finder, or says the share
   isn't mounted. Tests: the name, the buttons' actions.
5. ADR 0067; README; snapshot of each pane at 1440x900.

Result: shipped as planned; `./scripts/check` passes. 30a.5: a play used to count after half
the track or 4 minutes, whichever came first, so long tracks counted early; it now counts at
Count as Played At (Settings ▸ Playback, 75% by default), 4 minutes only for a track of unknown
length, and a track played to its end counts even at 100%. 30a.1: checkboxes carry their titles
on the right with the summary underneath; pop-ups and fields share one label column per pane;
sections are titled boxes. General has Library, Sync and Receiver; a new Playback pane has Audio
Output and Play Counts, so General fits the 2015 MacBook Pro's screen; the two network rescan
settings sit in a box under the Watched Folders list. Receiver Control heads its box and the
address and volume keys rows are disabled while it's off. 30a.2 and 30a.4: Network Scan Readers,
and File Viewer when Searcher isn't installed, have no row; ⌘K opens the config file for them.
30a.3: the sync folder row shows the folder's name, truncated, with its place as a tooltip, and
Choose…/Change…, Open (in Finder, where its share is mounted now) and Clear. `--snapshot-of`
takes playback, appearance and folders. No benchmark: no budgeted path changed. Pending the
owner: the window on macOS 12, and whether the titles should be sentence case as Swinsian's are
(ADR 0067 keeps title case, since they're also the palette's command names).

#### 30b. Track table, browser and navigation

- [x] **30b.1 Centered landing.** Type-to-select centers the found row, as ⌘L does. Every action
      that lands on a row of the track table centers it.
- [x] **30b.2 Row height and type.** Taller row heights get larger type, as large as fits;
      Large at least.
- [x] **30b.3 Art hover.** The hover always draws above every other art cell and above the
      scaled-to-fit art (`s2010`: only the lowest album's hover shows on top). The hover's
      hot area is the album's own rows: moving onto the next album's rows ends the hover there
      and starts the next one, without leaving the art column first.
- [x] **30b.4 Rating in the cell.** Clicking a star in the Rating column sets the rating.
- [x] **30b.5 ⌘R.** Reveal in Finder opens the file in iTunes; it must reveal it.
- [x] **30b.6 Back to the library.** ⌘K and ⌘P offer Clear Filter / Show All Music when the
      browser has a filter or a playlist is showing; hidden when already on the unfiltered Music
      list.
- [x] **30b.7 Browser columns.** Right-clicking a browser column's header picks what it groups
      by, from Swinsian's list (`s3548`), for each of the three columns.
- [x] **30b.8 Sidebar tooltips.** Music, History, Timeline, Library Health and the default
      groupings get a tooltip saying what each is.

Plan (30b):

1. **30b.5** Reproduced on both Macs: with `NSFileViewer = com.apple.finder` in the argument
   domain, AppKit sends Finder an open-documents event and Finder plays the file in Music. The
   override goes, unless the global key names another viewer; then it's set to an ID no app
   has, which AppKit answers with its own Finder reveal. Test: the override's value for each
   global key. ADR 0051 amended.
2. **30b.1** Type-to-select and a reload that keeps the selection center the row
   (`RowListController.center`), not scroll it to an edge. Tests on the controller.
3. **30b.2** `RowHeight` gives a font size beside its points (11, 12, 13); `TextCell` takes its
   font from the controller, and the track table sets it with the row height. Test: Large
   draws 13-point text that fits the row.
4. **30b.3** The hover is moved to the top of the table's subviews each time it shows, since
   row views AppKit adds later go above it. Its hot area is the album's own rows within its
   frame, so the pointer on the next album's rows hovers that one. Tests: the hover is the top
   subview; moving onto the next album's rows switches. ADR 0065 amended.
5. **30b.4** A click in the Rating column sets the clicked track's rating to the star under the
   pointer; left of the first star, or on the rating it has, clears it. `RatingClick` (pure)
   maps the point; tests for it and the controller. ADR 0068.
6. **30b.6** Show All Tracks becomes Show All Music. ⌘K lists it only while a source, pane or
   search narrows the table; ⌘P puts it first then. Tests on `LibraryBrowser.showsAllMusic`
   and the palette items.
7. **30b.8** Music, History, Timeline and Library Health get tooltips, from one place.
8. **30b.7** `BrowserGrouping` (Settings) lists Swinsian's groupings, and Library gives each
   its SQL over a track. `TrackFilter` holds each grouping's selected value in place of genre,
   artist and album; the columns' queries take the column's grouping. The
   columns' groupings are kept in the state file (`browser.columns`, default Genres, Artists,
   Albums); the header's menu in each column picks one. The palette's genre, artist and album
   and Show Artist / Show Album select in a column that shows that grouping, or else show the
   track in the whole library. Tests: each grouping's entries and filter, the menu, saving.
   ADR 0069.

Result: shipped as planned; `./scripts/check` passes. 30b.5: reproduced with a probe on macOS 12
and 27: `NSFileViewer = com.apple.finder` in the argument domain makes AppKit send Finder an
open-documents event, and Finder opens the track in Music. The override now applies only when
the global key is set, to any app, Finder included, and uses an ID no app has, which AppKit
answers with its own Finder reveal (ADR 0051 amended). The owner's config says Finder and Searcher isn't installed on
the 2015 MacBook Pro, so both settings took that path. 30b.1: type-to-select, and a source, pane
or search change that keeps the selection, center the row. 30b.2: Regular rows draw 12-point
text and Large 13-point; Compact keeps 11 (ADR 0053 amended; the default table's text is a
point larger). 30b.3: the table added row views above the hover, so lower albums' art covered
it; each showing now moves the hover to the top, and its hot area ends at its album's last row
(ADR 0065 amended). 30b.4: a plain click on a star sets the clicked track's rating; left of the
stars, or the rating it has, clears it; a double-click only plays (ADR 0068). 30b.6: Show All Tracks is Show All Music, off
and left out of ⌘K while the table lists the whole library, first in ⌘P otherwise. 30b.7: every
grouping in Swinsian's menu, picked from each column's header menu; a grouping another column
shows swaps places; columns and selections are saved as `browser.columns`, replacing
`browser.genre`, `browser.artist` and `browser.album` (ADR 0069). Text groupings read every
track once: about 4 ms for Composers, 28 ms for Audio Quality and 67 ms for Folders over the
bench library on this Mac, warm. 30b.8: Music, History, Timeline, Library Health and the two
headings have tooltips, on the row's name too. Benchmarks against main measured the same night:
browser pane query 0.52 ms (main 0.66), search keystroke 9.81 ms (13.76), sort by each column
49.2 ms (44.9), scroll-bar drag 13.4 ms (main 18.4, over budget on main from this Mac's display
state, as in phase 29). Pending the owner: trying 30b on the 2015 MacBook Pro.

#### 30c. Window chrome and status bar

- [x] **30c.1 Toolbar customization.** Every toolbar item shows an icon or a drawing of itself in
      the customization sheet (`s4053`: Playback Controls, Volume, Now Playing and Search show
      none). The default set shows what it will look like.
- [x] **30c.2 Status bar as now playing.** Now Playing (Centered) goes. The status bar becomes
      the now-playing area, as in Swinsian, in a minimal or a taller style, built from parts the
      user arranges (art, artist and title, format and bit rate, seek bar, counts) in an easy
      editor in Settings.
- [x] **30c.3 Seek bar.** A click jumps straight to the position, with no animation. The playhead
      is a thin vertical bar, not a round knob.
- [x] **30c.4 Status bar color and glass.** The status bar is the header's gray. The glass on
      the status bar and table headers doesn't show on macOS 12: check and fix.
- [x] **30c.5 Glass everywhere.** An Appearance option puts the sidebar's translucent material
      behind the whole window: toolbar, table, status bar.
- [x] **30c.6 Hide the header, distraction-free mode.** A toggle for the toolbar like the sidebar
      and status bar ones, and one shortcut that hides all three and then restores what was
      showing.
- [x] **30c.7 App icon.** The icon has a white square behind it in the app switcher; it needs a
      transparent background and the standard macOS icon shape.

Plan:

1. **30c.7** `scripts/bundle` cuts Quick Look's 1024 px render (always on white) to the tile
   shape the SVG's `tile` clip path names, with a Swift script on CoreGraphics, so the icon's
   corners are transparent on macOS 12 and later.
2. **30c.3** A `SeekBar` view in NowPlaying replaces the sliders: a mouse down moves the playhead
   there at once and seeks, a drag follows the pointer and seeks on release, and the playhead is
   a thin vertical line. The position shown holds the seek's target until the engine reports it.
   Tests: the fraction under a point, a click seeks once with no drag.
3. **30c.1, 30c.2** The customization sheet's items get drawings: the transport's buttons, the
   volume slider, a miniature of the now-playing status and a search field, so the default set
   reads as the toolbar it makes. `centeredStatus` goes.
4. **30c.2** `statusBar.parts` (art, track, format, seek bar, totals; default totals alone) and
   `statusBar.style` (minimal, tall) in Appearance. NowPlaying makes a view per part, the browser
   lays the parts out in the bar in the user's order with the seek bar taking the free width, and
   the app wires them. Settings ▸ Appearance gets a parts list: a checkbox each, drag to reorder.
   Tests: the model's order and toggles, the setting rejects a part listed twice, the bar's
   height per style.
5. **30c.4** The status bar uses the toolbar's title bar material, so it's the header's gray.
   Record why the material looks solid on macOS 12 (nothing in the window behind it).
6. **30c.5** `appearance.glass`: the window's content sits on a behind-window material, the
   toolbar is transparent over it, and the lists, headers and status bar stop drawing their
   backgrounds. ADR 0072.
7. **30c.6** View ▸ Show Toolbar (⌥⌘T) saved as `window.toolbarVisible`, and Distraction-Free Mode
   (⇧⌘F) hiding the toolbar, sidebar and status bar and restoring what showed. Tests on the
   mode's logic (`ChromeVisibility`).

Result: shipped as planned; `./scripts/check` passes. `./scripts/bundle release` builds
universal. 30c.1: the customization sheet
shows a drawing of the transport, volume, Now Playing and search (a copy of each control wired
to nothing), so the default set reads as the toolbar; on macOS 12 the sheet drew no image for
items that had an image and no view. 30c.2: Now Playing (Centered) is gone. The status bar is
built from `appearance.statusBarParts` (Art, Title and Artist, Format and Bit Rate, Seek Bar,
Track Totals, each once) in `appearance.statusBarStyle` (Minimal at the header's height, or
Tall, 44 points), edited in Settings ▸ Appearance as a checklist dragged into order; the style
is in the View menu too. Defaults keep today's bar (totals alone, minimal), so nothing changes
until the owner picks parts. 30c.3: the seek bars are a view of our own: a click moves the
playhead at once and seeks, the playhead is a 2-point line, and the bar holds the target until
the engine has sought. 30c.4: the status bar uses the title bar's material, the toolbar's gray.
The glass "missing" on macOS 12 is how materials work there: within the window they show only
what's behind them in it, and AppKit draws table headers opaque; the translucency the owner
means is the sidebar's, behind the window, which 30c.5 adds (ADR 0072). 30c.5:
`appearance.glass` (off by default) puts the sidebar's material under the whole window, the
toolbar transparent over it, lists and header cells without backgrounds, alternating rows off,
and the status bar blending behind the window; off puts everything back. AppKit then lines the
toolbar's items up with the sidebar. 30c.6: View ▸ Show Toolbar (⌥⌘T), saved as
`window.toolbarVisible`, and Distraction-Free Mode (⇧⌘F). 30c.7: `scripts/bundle` cuts Quick
Look's render, which is always on white, to the SVG's tile with transparent corners
(`scripts/icon-mask.swift`, ADR 0043 amended). Benchmarks, with other worktrees building (load
average 6 to 10), branch then main in the same hour: launch to first rows 0.68 s (main 0.87 s),
scroll-bar drag p95 13.35 ms (main 16.97 ms), memory after scrolling 78.3 MB, idle CPU 0.01%
and 0 wakeups a second; single runs swung from 13 to 47 ms. The review fixed: the toolbar's visibility
never saving on macOS 12 (`NSToolbar.isVisible` is observable only from macOS 14), a click on
a seek bar with no track length leaving the playhead there, a release after an automatic track
change seeking the new track, the times flickering during a drag, the seek bar shrinking to
nothing (now at least 60 points; checked at the window's 720-point minimum), and the checklist
snapping back when an unticked part was dragged. Not done: glass on a table column added while
it's on keeps AppKit's opaque header cell until glass is toggled. Pending the owner,
on the 2015 MacBook Pro: Customize Toolbar… drawings; Settings ▸ Appearance status bar items
and both styles while playing; clicking and dragging the seek bars; the status bar's gray
against the toolbar in light and dark; Glass on and off; ⌥⌘T and ⇧⌘F; the app switcher icon.

### 31. Output for devices that can't play bit-perfect

Bluetooth AirPods on the 2015 MacBook Pro offer only 2-channel 32-bit float at 48 kHz, and the
output only sends integer PCM at the track's own rate (ADR 0011), so every track fails with
`noBitPerfectFormat`. The app must always be able to play to the chosen device.

- [x] **31.1 Converted output.** When a device has no bit-perfect format for a track, decode and
      convert to the device's best format (float, its sample rate, its channels) and play. Bit-perfect
      stays the first choice wherever the device allows it.
- [x] **31.2 Position, seek and gapless** stay right in the converted path.
- [x] **31.3 Signal path** says the output is converted and to what, not bit-perfect.
- [ ] **31.4 Hardware checkpoint.** The owner plays a 44.1 kHz and a 96 kHz track to the AirPods
      on the 2015 MacBook Pro.

Plan:

1. **31.1** `convertedFormat` in `HALOutput/FormatSelection` picks what a track converts to when
   no format carries it: the device's rate nearest the track's, at or above it first; the
   track's channel count, else the fewest above it, else the most; float before integer, then
   the widest. `HALDevice.configure` and the null device fall back to it for PCM, never for
   DoP, and `DeviceFormat.isConverted` says so. `DeviceOutput` stops refusing PCM tracks up
   front (`deviceCannotTake` goes); a device with no PCM format at all fails the output.
   Tests: `FormatSelectionTests`.
2. **31.1, 31.2** A converted stream whose rate or channels differ from the track's gets a
   `OutputConverter` (AudioConverter, maximum quality) between the decoder and the ring buffer,
   on the control thread. The decoder hands it float at the file's rate. It runs on across
   tracks of the same rate, paused at each track's end, so a gapless join is resampled as one
   signal; the next track's first byte is where its first input frame lands. It's flushed
   only when nothing at that rate follows. Positions count the file's frames at the file's
   rate up to a segment's start and device frames after it, so seeking and the position hold.
   Tests: a null device that offers only 2 ch float at 48 kHz plays a 44.1 kHz 16-bit and a
   96 kHz 24-bit sine album without a seam at the join; seeking lands on the right phase;
   the position reads where it should.
3. **31.3** `TrackSignal.isConverted`, a `SignalChange.converted(to:)` first in the verdict, a
   "Converted" badge, and the now-playing line says "converted for" the device format.
   Tests: `SignalVerdictTests`, `SignalPathLinesTests`, the output's signal path.
4. DSD on a device that can't take DoP still fails, clearly, as it does now (ADR 0071).
5. ADR 0071; playback benches against main.

Result: shipped up to the owner's checkpoint, 31.4, which is pending. A device with no format
that carries a track unchanged now plays it converted to its best format: at least the track's
channels, the nearest rate at or above the track's and never below 44.1 kHz when there's one
above (so AirPods never drop to their 16 kHz call format), then float. A converter on the
control thread runs on across same-rate tracks, so a gapless join is resampled as one signal;
the IO proc is unchanged. Positions and seeks count the file's time. The panel badges such a
track "Converted" and names the format, and the now-playing line says "converted for" the
device. DSD on a device without DoP still fails with its reason; converting it needs a decimation
filter of its own (ADR 0071). Benches on Apple Silicon against main the same day: playback CPU
2.05, 1.89 and 1.28% of a core (main 1.69 and 1.59), no gap between same-format tracks on
either, rate switch 14.7 and 13.2 ms (main 8.0 ms, the null device's stop step varying).
After review: a format that loses neither channels nor depth comes first, then depth before
channels, so a 24-bit 5.1 track on the ADI-2 is downmixed at 32 bits rather than cut to 16; an
ITU downmix replaces AudioConverter's dropping of the extra channels, stereo to mono is (L+R)/2,
and the panel says "downmixed 6→2 channels". A narrower integer output is dithered (TPDF), which
AudioConverter doesn't do by default. Replacing a queued next track keeps the current track's
last frames, and no start is decoded ahead into a converted switch. New benches: converted
playback 0.56% of a core, the converted join 0 samples off, at most 2.2e-5 from the sine.
After the second review: the decoder reads the channel layout each file states and hands the
channels on in the WAV order, so an ALAC or AAC 5.1 file's centre reaches both sides; a file
that names none is mixed in the default order and the panel says "channel order assumed". Only
stereo and mono get a downmix (8→6 is refused by name), the 44.1 kHz floor outranks depth and
channels, a lossy track's precision follows the verdict, and a downmix has a fixed -4.6 dB
headroom, clipping at an integer output. Benches: converted playback 0.59% of a core, the
converted join 0 samples off, at most 2.2e-5 from the sine.

### 32. Speed hardening

The owner's brief from 2026-11-03.

**Goal:** scrolling a 43k-track library is smooth on the 2015 MacBook Pro, and the time from a
play action to sound is as short as the device allows. Phase 14e already profiled the hot paths
and every budget passes, so this phase is about the paths 14e's benches don't exercise. An audit
on 2026-11-03 (static reading plus EXPLAIN QUERY PLAN on a synthetic 43k-track, 1M-play
database) found the suspects below. Treat each one as a hypothesis. Measure it first, fix it only
if the number shows a cost, and record the before and after in the Result line. If a suspect
turns out to cost nothing, say so and drop it. File and line references are from commit 9f49c19.

Rules for the whole phase:
- **Bench first.** Every fix comes with a bench in `Sources/Tools/Bench` and a budget in code
  next to it, with a row added to the budget table. The bench has to show the problem before the
  fix. The phase gate's 10% regression rule applies to every existing budget.
- **The audio boundary stands.** Nothing reachable from the IO proc changes language or
  allocates. Gapless stays at 0 samples, and the rate-switch and soak benches still pass.
- **Single source of truth, smallest change.** No new dependencies. A new pragma, constant or
  limit is defined once.
- **Simulate the NAS.** Reuse the scan benches' latency-injected file access (about 2 ms and
  60 ms per operation), because the real library is on SMB. Never touch the real library or the
  NAS.
- **Old Mac numbers come from the checkpoint.** Every new bench gets an old-Mac budget marked
  "estimate until its checkpoint".

#### 32a. Time to sound

The current benches measure the gap between tracks and the rate switch, but nothing measures
from the user's action to the first sample.
- [x] **32a.1** **Bench:** on the null device (`Sources/Tools/Fixtures/NullDevice.swift`), time from the call
      to the first IO callback for each of these:
      - double-click (`setQueue` plus `play`) while a track is playing, same format
      - the same, at a different sample rate
      - Next, same format
      - a seek while the current track is still being fed
      - a seek in a track's last ~4 s, after the feed has moved on to the next track
      - each case with local files and with simulated NAS latency

      The null device has no close, hog or format-restore cost, so give it injectable delays for
      those HAL steps. Without them the bench can't show suspect 1.
- [x] **32a.2** **Suspect, likely the biggest win:** `PlaybackEngine.setQueue` (PlaybackEngine.swift:103) calls
      `unload()`, which calls `output.stop()`. That closes the device (DeviceOutput.swift:253, 792;
      HALDevice.close at HALDevice.swift:161). Closing restores the old format and rate and waits up
      to 3 s for it, then releases hog mode. The following `play` reopens the device: it enumerates
      devices, writes the restore record, takes hog mode, then sets the rate and format again. So
      every double-click while playing tears the device down and rebuilds it, even when the new
      track has the same format. Next and media keys already take the `restart` path
      (DeviceOutput.swift:297) and keep the device open. Make a queue replacement followed by play
      take the same path. Stop should still close the device as it does today.
- [x] **32a.3** **Suspect:** `LibraryQueries.paths(ids:)` (LibraryQueries.swift:199) runs one
      `SELECT ... WHERE id = ?` per ID. A double-click queues the whole visible list (`playOrder`),
      so that's 43k statements on the shared reader actor before playback starts. Use the file's
      existing `inChunks` IN-list pattern. Also consider resolving only the first track's path
      before starting playback and the rest afterwards.
- [x] **32a.4** **Suspect:** the seek in the last ~4 s reopens the file (`reusableTrack`,
      DeviceOutput.swift:471), which costs a full open and header parse on the NAS.
- [x] **32a.5** **Suspect:** at track start the main actor does synchronous lookups by path:
      `NowPlayingModel.lookUpTrack` (NowPlayingModel.swift:59), `countPlay`
      (PaletteCommands.swift:201) and the queue panel (QueueModel.swift:63). `MediaControls.loadArt`
      reads the file a second time for art. Signpost them and fix whatever shows up as a main-thread
      hitch at track change.

Plan:

1. **32a.1** `NullDevice` takes estimated HAL delays: opening (finding the device, the restore
   record, hog mode), a rate change settling, and releasing hog mode. With them set it also puts
   back the rate it had at its first open when a session closes, as `HALDevice.close` does. It
   times the first IO cycle after an action that carries anything but silence. `DeviceOutput`
   takes an optional per-read file latency for benches: the decoder then opens the file through
   AudioFile callbacks that wait on every read AudioToolbox makes, so a NAS costs what the
   decoder actually reads. A fixture track is 20 s of silence with a ramp from 10 to 12 s.
   `PlayLatencyBenchmarks` gets five cases, each while that track plays its silence: a
   double-click of the same rate, of another rate, Next, a seek while the track is fed, and a
   seek after the feed moved on, each with local files and with the slow simulated NAS's
   latency, the median of five runs. Budgets on the NAS figure, the old Mac's estimates.
2. Run them on the bench commit, before any fix.
3. **32a.2:** a new queue that plays at once (`play(starting:completing:)`) no longer stops the
   output; its `load` reuses the open device, restarting the stream or reconfiguring it. Stop,
   and a queue set without play, still close it. Tests on both the bit-perfect and the
   converted path. ADR 0078.
4. **32a.3, 32a.4, 32a.5:** measure each (the queue's completion time, the NAS seek, the
   main-actor lookups at track start) and fix only what shows a cost. 32a.4 became: a load or
   a seek takes a track the output already has open on the same file, which also covers Next.
5. Rerun the play benches, gapless, rate-switch and soak against main, the same day.

Result: shipped as planned; `./scripts/check` passes. Measured on the build Mac on 2026-11-03,
time from the call to the first IO cycle carrying sound, median of five, slow simulated NAS
then local files, before (the bench commit, 15d3b89) and after. The null device's HAL steps
are estimates (open 10 ms, a rate change 100 ms, hog mode release 5 ms; the device starts at
48 kHz, which a close puts back), so the device share of every figure is a guess until the
ADI-2 checkpoint. 32a.1: the five benches above, with budgets; NAS latency is the slow NAS's,
23 ms per open and 10 ms per 1 MB block first read (ADR 0078). 32a.2: fixed. A double-click on
a track of the same rate took 294 and 244 ms, now 48 and 10 ms; on another rate 297 and
249 ms, now 169 and 107 ms, one rate change. Stop and a queue set without play still close the
device. 32a.3: fixed though off the sound path: the clicked track already played first (ADR
0070, 2.4 ms to its first frame on main and 2.6 ms here), and the whole library's queue was in
place 166 ms after the click, now 67 to 73 ms. 32a.4: fixed. A seek after decoding moved on took
57 and 5 ms, now 10 and 11 ms; Next, which also opened the file again, 57 and 11 ms, now 10 and
5 ms. A seek while the track is decoded was 6 and 11 ms, now 7 and 5 ms, the spread of one
11.6 ms IO cycle. 32a.5: dropped, no cost. A track lookup by path on the main connection, which
Now Playing, the media controls and the play count each make at a track start, took 0.015 ms
(median, 0.17 ms the slowest of 443); the queue panel looks up only rows it shows and caches
them; the palette's visit count is saved on a timer; art reads already run on their own queue
(32b.4). Against main (e7c8097) the same hour: gapless 0 samples and the converted join 0
samples on both, rate switch 8.4 ms on main and 8.3 ms here (15.4 ms in one run, the null
device's stop step), soak 0 underruns on both, CPU at 24/192 1.44% and 1.01%, converted 1.03%
and 0.76%, double-click to first frame 2.4 and 2.6 ms, its main thread 0.77 and 0.89 ms. After
review: the timeline and scripting's `play(_ request:)` also goes through `play(starting:)`,
ADR 0078 records the accepted one-cycle blip and what a stale SMB handle does to a reused
decoder, and the bench decoder closes its file when its init throws. The old-Mac budgets are estimates until the 32f checkpoint, where the owner double-clicks
tracks of the same and of other rates on the ADI-2.

#### 32b. Scrolling with art

The scroll-bar-drag bench jumps a screenful at a time over local files. It never sees
continuous trackpad scrolling, long albums with a wide art column, art over the NAS, or
scrolling during a scan.
- [x] **32b.1** **Bench:** extend the window benches with these scroll cases, each reporting the p95 frame
      time and the worst frame:
      - continuous small-delta scrolling, like a trackpad
      - the smallest row height with a wide art column, on fixture albums of 15 or more tracks
      - art read through simulated NAS latency, also timing when the last visible cover arrives
      - a library refresh during a scan, every 2 s
- [x] **32b.2** **Suspect:** each art cell's `artRow` and `ArtRun.length` walk up to `artRowsTall` rows in
      each direction through `RowCache.row` (TrackTableController.swift:252-295, ArtRun.swift).
      `RowCache` moves the page to the front of its recency list with an O(30) remove and append
      whenever the lookup leaves the last-used page (RowCache.swift:37-44). The walk can also fetch
      off-screen pages synchronously. Compute the album runs once per visible range instead.
- [x] **32b.3** **Suspect:** `isWanted` (TrackTableController.swift:63) recomputes the visible rows and their
      art keys for each queued request, up to 200, every time an image arrives (RowArt.swift:34).
      Build the wanted set once per `next`.
- [x] **32b.4** **Suspect:** art loads one file at a time (`loading` flag, RowArt.swift:79). Each load is a
      blocking read inside the cooperative pool. Load a bounded few at once (3–4, to suit the old
      Mac's 4 pool threads), on a queue that isn't the cooperative pool. ArtViewer, NowPlayingBar
      and MediaControls block the pool the same way.
- [x] **32b.5** **Suspect:** the art key is the path of each run's first track (TrackTableController.swift:
      276), so an album longer than one run reads and decodes the same cover once per run, and each
      copy takes a cache slot. Key the cache by album and art offset, or by content.
- [x] **32b.6** **Suspect:** `AlbumArtCell` draws the whole image with `.high` interpolation into every row
      slice (AlbumArtCell.swift:46). That is likely costly on the Intel GPU. Size the thumbnail to
      the drawn pixels, or draw the art once per run.
- [x] **32b.7** **Suspect:** `refreshNow` (LibraryBrowser.swift:528-569) reloads the panes and the table every
      2 s during a scan, even when nothing changed. That costs a `reloadData`, a cleared row cache,
      synchronous page refetches on the main thread, `readTotals`, and an O(n) `rows(holding:)`.
      Skip the reload when the IDs are unchanged, and otherwise reload only the rows that changed.
- [x] **32b.8** **Suspect:** the queue panel reloads completely on every track start, with an O(queue)
      `firstIndex` (QueuePanel.swift:35, QueueModel.swift:26). A 43k-track queue makes each track
      change cost a full pass.

Plan:

1. **32b.1** The app takes `--measure-scroll trackpad|scan` and `--art-delay-ms <ms>`. A timer
   scrolls the track table 60 frames a second in trackpad flicks from the middle of the list (a
   fling that decays to a point a frame), and a run-loop observer times the main thread's busy
   time between frames. After the last frame it pages down and times until every visible row
   shows its art. `scan` also sends the browser a scan's progress every second, so it refreshes
   every 2 s as during a scan, and notes the frames a refresh lands in. Art reads go through a
   closure the measurement wraps, which counts them and adds the delay. One JSON line,
   `ScrollReport`. Bench gets four cases: the default layout, compact rows with a 256 pt art
   column, sorted by title with the slow simulated NAS's latency (43 ms) on each art read, and
   the scan; and a queue panel track change with the whole library queued, in Bench's process.
   Budgets in code and in the table. ADR 0073.
2. Run each case before any fix, then measure each suspect by the case that shows it, with a
   temporary timer around the code where the frame times can't separate it.
3. Fix only what the numbers show, each in its own commit with a test that fails without it:
   32b.7 (redraw only changed rows when a rescan keeps the list), 32b.4 (art loads at once, off
   the cooperative pool, ADR 0074) and 32b.8 (move the queue's rows up on a track change).
   32b.2, 32b.3, 32b.5 and 32b.6 measured nothing worth fixing and are dropped.
4. Rerun every case, and the existing window benches against main, the same day.

Result: shipped as planned; `./scripts/check` passes. Measured on the build Mac on 2026-11-03,
before (the bench commit, d1a8e24) and after, the same hour. Most of every frame is AppKit
drawing the rows that scroll in and Core Animation's commit, about 8 to 10 ms a frame at the
p95, which no suspect touches and which varies between runs. 32b.1: the benches above. 32b.2:
dropped. Filling every art cell, walks included, took 0.05 ms a cell, 0.06 ms a frame in the
compact, 256 pt column case; the trackpad frames' p95 stayed 8 to 10 ms before and after.
32b.3: dropped. `isWanted` took 0.05 to 0.1 ms a call, 12 ms over the 10 s of the title-sorted
NAS case with 253 calls. 32b.4: fixed. The page down's last cover, sorted by title on the slow
simulated NAS, 641 ms before, 130 to 136 ms after, with `RowArt.loadsAtOnce` (one less than the
active processors, at least 2: 3 on the 2015 MacBook Pro, 9 here) reads on a queue of their
own; the now-playing bar, Now Playing and the art viewer read there too. The frames' p95 in that
case stayed 9.2 to 9.6 ms. 32b.5: dropped. A row below its album's art shows none, so an album
is one run and one key whatever its length: the compact case read 20 covers before and after,
the default case 18. 32b.6: dropped. Drawing a cover slice took 0.04 ms, 13 ms over the whole
compact case. Fixture covers are at most 300 px; 32e.3 brings large ones. 32b.7: fixed. A
refresh during a scan rebuilt and redrew every row on screen: its frame took 49 to 54 ms
(median 50.7) before, 8.1 to 8.8 ms (median 8.2) after, the same as an ordinary frame, and the
launch rescan's refresh no longer leaves a 57 ms frame in the plain trackpad case. The panes
reload only when their entries changed, and the art hover stays up through a refresh.
32b.8: fixed, but not the suspect: finding the current track in a 43k play order took 8 µs.
The whole reload, each row laying out its stacked fields again, took 40.5 ms (p95) before and
3.5 ms after, when the played rows leave the top and the rest move up. A selection in the queue
now stays on its tracks. The existing window benches against main (9cf9665), same hour: launch
0.62 s and 0.61 s, memory 80.3 MB and 80.2 MB, scroll-bar drag 13.3 ms and 12.7 ms, idle CPU
0.02% and 0.01%, search 8.7 ms both, re-sort 43.0 ms and 42.1 ms. No `./scripts/bundle release`:
Package.swift changed only Bench's dependencies, and there's no new `#available`. The old-Mac
figures are estimates until the 32f checkpoint, where the owner scrolls with the art column
while a rescan runs. After review: the rescan redraw compares every row with a view, not only
the visible ones, fills the art column again when a cover or album changed, sets the playing
mark again, and closes the hover and the viewer of an album whose rows changed; the queue's key
cursor moves up with its rows; the art column reads the rows on screen once per pass; and an art
key includes its length. Rerun: a refresh's frame 8.7 ms (median), the page down's last cover
127 ms.

#### 32c. The database

Sorting is fine: 73 ms on the old Mac in 14e. Leave it alone unless a new bench says otherwise.
- [x] **32c.1** **Suspect:** `trackTotals` (LibraryQueries.swift:23) reads 43k rows into a dictionary again
      whenever `changeStamp` moves. `recordPlay` and `setRating` move it too, so every track change
      costs a full rebuild. Key the cache to changes in `tracks` and `files` only, or use a SQL
      aggregate for the whole-library case. Bench: totals right after a recorded play.
- [x] **32c.2** **Suspect:** the connection setup (Database.swift:25-44) sets only WAL, synchronous, foreign
      keys and query_only. `cache_size`, `temp_store`, `mmap_size` and `journal_size_limit` are
      left at their defaults, and nothing ever runs `ANALYZE` or `PRAGMA optimize`. Measure each
      setting against the sort, pane, smart-playlist, history and scan benches. Keep only the ones
      that win, and check `mmap_size` on macOS 12. Run `PRAGMA optimize` after a scan or on close.
- [x] **32c.3** **Suspect:** one `LibraryReader` actor (LibraryReader.swift:8) runs every query in turn: the
      sorted IDs, pane lists, totals, `fileIssues`, the palette's `trackNames`, and play, rating
      and playlist writes. A slow query delays the next keystroke's search and the play write. The
      health report already has its own connection. Bench: two keystrokes 50 ms apart, then the
      p95 of the second, with and without a scan running. If the bench shows contention, split the
      work by kind: visible-result queries, background queries and writes.
- [x] **32c.4** **Check:** the History sort uses a temp B-tree even though `plays_last_played` exists, which
      contradicts the comment at about LibraryQueries.swift:118. Confirm it on the fixture library
      and fix either the query or the comment.

Plan:

1. **Benches**, in Bench's own process on a copy of the scanned fixture index, through the
   app's `LibraryReader` and `BrowserModel`: the list totals of every track right after a play
   is recorded (32c.1), and the second of two search keystrokes 50 ms apart, from typed until
   its rows and totals are read, idle and while a scan rewrites every file with the browser's
   2 s refreshes (32c.3). Budgets in code and in the table, the old Mac's marked as estimates.
2. Run them, and the sort, pane, search, smart playlist, history, palette, health and scan
   benches, before any fix, the same day as main.
3. **32c.1:** fix only if the totals after a play cost more than with no write between. A
   play, skip, rating or opinion changes neither tracks nor files, so it keeps the sizes read.
4. **32c.2:** run the benches above with each pragma on its own (`cache_size`, `temp_store`,
   `mmap_size`, `journal_size_limit`) and after `ANALYZE` and `PRAGMA optimize`, against the
   same build without it. Keep only what wins by more than the run-to-run spread, defined once
   in `Database`. ADR for what is kept and dropped.
5. **32c.3:** split the reader only if the keystroke during a scan waits on other queries
   rather than on its own work.
6. **32c.4:** EXPLAIN QUERY PLAN on the History query over the 1M-play bench index; time both
   orders, keep the faster and make the comment say what the plan does.
7. Rerun every bench touched against main, the same hour.

Result: shipped as planned; `./scripts/check` passes. Measured on the build Mac on 2026-11-03,
before (the bench commit, b1cfcb0) and after, and against main (bf9624f) the same hour. 32c.1:
fixed. The totals of every track after a recorded play took 11.8 ms (p95) before, against
0.87 ms with no write between; a play, skip, rating or opinion now keeps the sizes read, and
they take 0.9 ms. A commit by another connection still has them read again. 32c.2: `mmap_size`
(256 MB) and `temp_store = MEMORY` kept, each run alone and then together against three
baseline runs (ADR 0075): the health report 0.24 s to 0.18 s, a timeline page 2.2 ms to
1.9 ms, a pane query 0.56 ms to 0.47 ms, the smart playlist 33.0 ms to 28.3 ms, recording a
play 0.24 ms to 0.08 ms, the 1M-event sync merge 13.5 s to 10.8 s. A 16 MB `cache_size` and
`ANALYZE` moved nothing past the spread and are dropped, and so is `PRAGMA optimize`, which
would run `ANALYZE`. `journal_size_limit`: no cost, the system SQLite already caps the log at
32 KB. 32c.3: dropped. The second keystroke took 10 to 11 ms (p95) idle and 23 to 24 ms during
the scan. During the scan it is its own work: its rows (about 11 ms for a few thousand matches)
and its totals, read again (about 12 ms) because every scan batch changes tracks. A lookup of
only the listed IDs didn't help, since a keystroke's list holds thousands. The slowest
keystrokes (70 to 100 ms, 2 of 40) waited behind the browser's 2 s refresh, which reloads the
whole list; that is a visible-result query too, so splitting the reader by kind moves neither.
A play write, which a split would move off, takes 0.3 ms. 32c.4:
confirmed; History sorts in a temp B-tree, starting from `recorded_paths`. Forcing
`plays_last_played`'s order took the History benchmark from 20 ms to 30.5 ms, so the query
stays and the comment that said otherwise is gone. Against main, the same hour, everything else
within the spread: History 19.4 ms and 21.2 ms (19 to 21 ms over five runs on both), the scan's
added memory 24.7 to 26.7 MB on main and 25.3 to 25.4 MB here over three alternating runs, launch
0.63 s and 0.61 s, window memory 79.9 MB and 77.9 MB, sort 44.3 ms and 42.5 ms, soak 0
underruns on both. The palette's opening rows read 4.21 ms on main and 4.09 ms here, over their
4 ms budget on both. No `./scripts/bundle release`: no C target, Package.swift or `#available`
changed. The old-Mac figures are estimates until the 32f checkpoint, which also checks the
macOS 12 SQLite's mapping limit.

#### 32d. Parallelism and priority

- [x] **32d.1** **Suspect:** palette ranking (PaletteModel.swift:73) starts a new `.userInitiated` detached
      task on every keystroke and never cancels the old ones, and `rankPalette` never checks
      cancellation. Bench: 8 keystrokes 50 ms apart; measure time to the last result and the CPU
      used.
- [x] **32d.2** **Suspect:** the tag editor reads each selected file three times, one file after another
      (TagEditorModel.swift:143-160). On the NAS, 500 tracks is about 1,500 serial opens before the
      sheet opens. Parse each file once and read a bounded few files at a time. Bench on simulated
      NAS latency.
- [x] **32d.3** **Suspect:** local scans use every core while playing (LibraryScanner.swift:17); the playback
      pause applies only to network scans. Cap the readers while playing. On the old Mac that is 4
      reader threads sharing 2 cores with decode. The soak-under-scan bench must stay at 0
      underruns.
- [x] **32d.4** **Suspect:** the health report runs as a default-priority detached task doing blocking SQLite
      work (LibraryReader.swift:21), and it reruns after every changed scan, removal or sync. Run it
      at utility priority, off the cooperative pool.
- [x] **32d.5** **Suspect:** a pending sync merge runs before the launch scan on the same serial queue
      (LibraryWatcher.swift:92, ~255, ~345), and locating the sync folder can stall on a hung
      share. Bench the time to the first scan's start with a large merge pending.
- [x] **32d.6** **Suspect:** after the first frame, `startPlayback` (AppDelegate.swift:283, 508-552) and
      `watchOutputs` (OutputPicker.swift:24) enumerate HAL devices synchronously on the main actor.
      Bench the first scroll step and first keystroke right after `--report-launch` reports
      interactive. Move whatever hitches off main.

Plan:

1. Measure each suspect first, in Bench where a fix needs a bench, otherwise with a temporary
   timer that isn't committed: the palette's burst of keystrokes (32d.1) and the tag editor's
   read on the slow simulated NAS (32d.2) in Bench's process; the time to the first scan with a
   1M-event merge pending, through `LibraryWatcher` (32d.5); the health report beside a burst
   of browser searches (32d.4); the soak under a local scan (32d.3); and the main actor's
   launch steps (32d.6).
2. Fix only what the numbers show, each in its own commit with a test that fails without it,
   and a budget in code and in the table. Concurrency limits come from
   `activeProcessorCount`, defined once: the art column's limit moves to Metadata as
   `filesReadAtOnce`, and the tag editor reads by it (ADR 0077). The local folders' launch scans
   run before the first sync (ADR 0076). The output picker lists devices off the main thread.
3. Rerun the changed benches and the existing ones they touch against main, the same day.

Result: shipped as planned; `./scripts/check` passes. Measured on the build Mac on 2026-11-03,
before (the bench commit, 3212117, or a temporary timer) and after, the same hour. 32d.1:
dropped, no cost. The last of 8 keystrokes 50 ms apart reached its results in 4.9 ms
(median of 6 bursts, 2.1 to 5.8 ms), the same as one ranking, and a burst used 26 to 48 ms of
CPU: no ranking here takes over 8 ms, so none overlaps the next keystroke. Typed 3 ms apart, so
that all 8 overlap, the last took 8.6 ms. The old Mac searched about 2x slower than this Mac in
14e, so its rankings should still end before the next keystroke; the bench stays, with an
estimated old-Mac budget, so the checkpoint shows it. 32d.2: fixed. 200 fixture files, each
file's three opens costing what they do on the slow simulated NAS (129 ms), took 27.6 s to
read before, 3.2 s after, 9 at once (3 on the old Mac), on a dispatch queue instead of the
cooperative pool. One open per file isn't done: the bench charges every open the same, so it
can't show what it would save (ADR 0077). 32d.3: dropped, no cost here. The soak under a full
local scan with 10 readers had 0 underruns. The decode thread runs at user-interactive QoS and
the scan's readers at utility, so the scheduler serves the decode first on any core count;
this Mac can't reproduce the old Mac's 4 threads, so the checkpoint's soak decides. 32d.4:
dropped, no cost. The browser's search keystroke p95 was 12.0 ms without and 9.6 ms with health
reports built back to back beside it (a report takes 0.25 to 0.30 s), and 9.3 ms and 9.4 ms with
`LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`. 32d.5: fixed. With another machine's 1M plays pending,
the launch scan's first progress came 4.9 s after start, behind the 4.6 s merge; now 0.61 to
0.63 s, and the merge follows the scan. After review, only a local folder's launch scan holds the sync back,
so one hung on a share can't hold it forever. 32d.6: fixed, not the suspect named: `startPlayback`
took 1.7 to 1.9 ms on the main thread before and after, so it stays. The output picker's first
device list and its watch, the run's first CoreAudio calls, took 24 to 26 ms on the main thread
before the first rows; now 0.04 ms. Launch to the first rows, median of 3: main 0.63 s, this
branch 0.60 s. The existing benches against main (bf9624f), same hour: memory 77.0 MB and
79.9 MB, scroll-bar drag 13.6 ms and 13.3 ms, idle CPU 0.03% and 0.02%, search 8.8 ms both,
re-sort 42.2 ms and 41.5 ms, trackpad frames (second runs) 8.8 and 8.9 ms, 10.5 and 10.7 ms,
9.2 and 9.3 ms, a refresh's frame 8.1 and 8.4 ms, sync merge 14.3 s and 12.7 s. The palette's
opening rows measured 4.07 ms on main and 4.20 ms here against a 4 ms budget, with other
worktrees building; nothing here touches it. No `./scripts/bundle release`: Package.swift
changed only Bench's dependencies, and there's no new `#available`. The old-Mac figures are
estimates until the 32f checkpoint.

#### 32e. Field data, the NAS, and the old Mac's hardware

- [x] **32e.1** **Signposts and a hang log.** Nothing in `Sources` uses `os_signpost`. Add intervals, defined
      once, to the paths in 32a to 32d: play to first sample, art load, page fetch, refresh, query,
      palette rank and scan batch. Then a Time Profiler or os_signpost trace from the old Mac lines
      up with the code. Add a main-thread stall detector: when the main run loop is blocked over
      ~100 ms, it logs the duration and what was running to the app's existing log. It must cost
      nothing when idle (the idle-wakeup budget). That way the checkpoint brings back real hitches
      from the real library, not only bench numbers.
- [x] **32e.2** **A persistent thumbnail cache.** Art is cached only in memory: 64 images in `ArtworkLoader`
      and 40 in `RowArt`. Every launch, and every scroll back past the cache, reads embedded art
      from the NAS again and decodes it again. Weigh a thumbnail table in the index, keyed by album
      and art offset or by content hash, and checked against the file's stored stats so a tag
      edit's new art replaces it. Weigh it against the database size budget. Bench: scroll the
      whole art column once after a fresh launch, on simulated NAS latency.
- [x] **32e.3** **Large embedded art.** Fixture art may be smaller than the real library's: covers of 3000
      px or more, and PNGs, where ImageIO's thumbnail call still decodes the whole image. Add
      fixture covers of that size and bench the decode on Intel.
- [x] **32e.4** **A hung or dropped share.** Unplug the NAS mid-playback, in simulation. The control thread
      blocks in a read, and the main thread must never wait on it. Check every file-system call
      reachable from the main actor, for example the sync folder's `resourceValues` and
      `fileExists` (AppDelegate.swift:670, 698, 723) and Reveal in Finder. Move the ones that can
      block onto a background queue. Test with file access that never returns.
- [x] **32e.5** **The discrete GPU.** `Support/Info.plist` has no `NSSupportsAutomaticGraphicsSwitching`. If
      the 2015 MacBook Pro has two GPUs, the app may keep the AMD one on, which costs heat,
      battery and fan noise. Checked 2026-11-03: the 2015 MacBook Pro is a MacBookPro12,1 (13-inch,
      Intel Iris 6100 only), so it has no second GPU. Add the key anyway, since dual-GPU Macs
      need it; no checkpoint step.
- [x] **32e.6** **Hidden windows.** No code watches window occlusion. While the window is hidden, minimized
      or under a locked screen, the 0.5 s position timer and table updates keep running during
      playback. Pause UI updates while the window is occluded. Bench: CPU and wakeups while playing
      with the window hidden, against the 3% playback budget.
- [x] **32e.7** **Cold launch.** ADR 0007 measures warm. After a reboot the old Mac launches from a cold
      page cache, and that is the launch you actually wait for. Measure it at the checkpoint
      (`sudo purge`, then launch) and fix what the trace shows.
- [x] **32e.8** **Big selections and live resize.** Bench ⌘A over 43k tracks, then Play Next, Add to
      Playlist and Get Info. Also bench live window resize, column resize and a row height change
      with the art column shown (art runs depend on the column width).

Plan:

1. **32e.5:** `NSSupportsAutomaticGraphicsSwitching` in `Support/Info.plist`.
2. **32e.1:** the intervals are one enum in Log, each with its `OSSignposter` name, and a
   recorder of the intervals open and just ended. They go on an art load, a row page fetch, a
   browser refresh, the reader's list, totals, pane and palette queries, a palette ranking and
   a scan batch. After 32a merged, a play to its first sample too. A
   main-thread stall detector in Log: run-loop observers note each pass's marks, and a pass
   over 100 ms logs its length, the intervals that ran in it, the last command run and the
   event type being handled. No timer, so an idle app pays nothing. ADR 0080.
3. **32e.4:** the main actor's file-system calls that can block on a hung share go to a
   queue: the sync folder's `fileExists` and Finder open, the volume checks when a folder or
   the sync folder is chosen, and every Reveal in Finder. Tests hold a file access that never
   returns and check the main actor carries on. Quitting waits on the output's close, which
   waits on the control thread, so the wait gets a bound. ADR 0081.
4. **32e.3:** fixture covers of 3000 px, JPEG and PNG, made in Bench, and a bench of their
   decode to the art column's thumbnail.
5. **32e.2:** a bench pages through the art column sorted by title on the slow simulated NAS
   after a fresh launch, then again after a second launch. If the second costs what the first
   did, a thumbnail cache in `~/Library/Caches/MusicPlayer`, keyed by the file's path, size
   and modification time and the art's place and size, capped by bytes. ADR 0079.
6. **32e.6:** measure the CPU and wakeups the now-playing bar costs while playing, the window
   shown and hidden, with a temporary harness. Pause on occlusion only if it costs.
7. **32e.8:** benches for ⌘A over the fixture library then Play Next, Add to Playlist and Get
   Info up to the editor's read, and live window resize, column resize and a row height change
   with the art column. Fix only what they show.
8. **32e.7:** `--measure-launch` prints the launch time to the first rows and quits, and the
   steps for the owner's cold launch at 32f, tested under bash 3.2.
9. Rerun the touched benches against main, the same day.

Result: shipped as planned; `./scripts/check` and `./scripts/bundle release` pass. Measured on
the build Mac on 2026-11-03, before (a bench commit or a temporary harness) and after, and against
main (591ff4d) the same hour. 32e.1: done, no before. `Interval` in Log defines each signpost once
(art load, page fetch, refresh, query, palette rank, scan batch, play to first sample), in
Instruments' Points of Interest. The play interval begins at `play(starting:)`, and at Next or a
seek while playing, and the output's control thread ends it once the IO proc's count of bytes
passes the new audio's start; the IO proc marks nothing. A run-loop observer logs each main-thread
stall over 100 ms with the intervals that overlapped it, the last command and the event type, and
has no timer: idle wakeups 0.00 a second against 0.02 on main, idle CPU 0.02% on both. Each launch
here logs one 160 ms stall before the first rows, with no marked interval (ADR 0080). 32e.2:
fixed. Paging 30 screens by title on the slow simulated NAS after a relaunch waited 2.87 s with 292
art reads before, the same as the first launch; after, 0.57 to 0.60 s with 2 reads, about one 60 Hz
tick a screen. Thumbnails are files in `~/Library/Caches/MusicPlayer/Thumbnails`, not a table in the
index, capped at 100 MB and 20,000 files (ADR 0079). 32e.3: measured, fixed by 32e.2. A 3000 px
cover decodes to a 256 px thumbnail in 21.6 ms as a 3.5 MB JPEG and 123 ms as a 12 MB PNG here;
the store decodes each once. 32e.4: fixed. Open Sync Folder's `fileExists` and Finder open, the
volume check when a watched folder or the sync folder is chosen, and Reveal in Finder ran on the
main actor; they run on a dispatch queue now, and tests hold a file access that never returns.
Quitting waited without a bound on the output's close, which a read stuck on a share holds; it
now gives up after 6 s and leaves the device to the restore record (ADR 0081). 32e.5: done; no
checkpoint step. 32e.6: fixed. With the position ticking and nothing playing, the app used 0.43 to
0.62% of a core with the window shown or covered, against 0.00% without the ticks; AppKit draws a
covered window, so the bar now stops while the window's occlusion state isn't visible. This Mac's
display sleeps, so no occlusion change reached the app here; the unit test covers the switch and
the checkpoint the effect. 32e.7: `--measure-launch` prints the launch time and memory and quits;
the owner's cold launch is a 32f step. Here, warm in a scratch home: 0.41 s. 32e.8: Play Next with
every fixture track selected reads the files to queue in 85 ms and Add to Playlist takes 105 ms,
both off the main thread: dropped, no cost. Get Info reads every selected file before the editor
opens, 0.06 ms a file here, 2.4 s for the library, but minutes on the NAS: not fixed, since
capping the editor's selection is the owner's call. Live resize of the window and the art column
measured 29.5 ms a frame (p95), over its 16 ms budget: 26 ms with the column fixed, 15.6 ms with
the window fixed, so mostly the window's relayout; not narrowed further, so its budget stays
missed until a trace from 32e.1 places it. A row height change's frame takes 30 ms. Against
main, the same hour: launch 0.57 s and 0.59 s, memory 78.0 MB and 79.6 MB, scroll-bar drag 13.1 ms
and 12.9 ms, trackpad frames 8.4, 10.8 and 9.0 ms against 7.9, 10.2 and 8.3 ms, a refresh's frame
8.7 ms and 8.3 ms, last cover 123 to 129 ms and 107 to 127 ms, search 8.9 ms and 8.8 ms, re-sort
41.5 ms and 39.5 ms, scan 2.06 s and 2.05 s, playback CPU 1.93 to 2.09% and 1.50 to 1.97% (24/192,
alternating runs), gaps 0 samples on both, soak 0 underruns on both. The palette's opening rows
measured 4.19 ms here and 4.22 ms on main against their 4 ms budget, as in 32c and 32d. The old-Mac
figures are estimates until the 32f checkpoint, which adds the cold launch below.

After review: the play-to-first-sample interval is begun by `DeviceOutput.load` and `seek`, so a
renderer output, and a seek held for a resume, never open one. The control thread arms its end
at the new segment's start byte when it processes the command, so the old track's audio can't
end it early; a pause, stop, failed load, `cannotPlay`, lost device, close or a seek while paused
cancels it without logging a time (`PendingInterval.cancel`), and a begin that replaces an open
one cancels that one. A tick costs one optional check. Choosing the sync folder twice applies
only the last pick. Quit closes the renderer output, whose HTTP server stop can wait on a hung
share's read, together with the device output inside the same 6 s bound. Get Info on more than
200 files asks first (ADR 0081). The interval's cancel paths and early end have tests on a
`DeviceOutput` with its own interval; the sync-folder pick and the quit bound have no seam in
`AppDelegate`, so they have none.

#### 32f. Checkpoint and budgets

- Run `./scripts/bench` three times. Tighten any new budget the code beats by more than 3x, as
  14e did.
- [x] **Hardware checkpoint (owner), bench part:** on the 2015 MacBook Pro, from a universal
  release build (its Xcode can't build Swift 6), the full bench, a cold launch after
  `sudo purge` (32e.7), the stall log and the mmap check. Done 2026-11-03; results below
  ("Old Mac checkpoint") and the fixes queued as phase 33.
- [ ] **Hands-on check (owner), later:** on the 2015 MacBook Pro, from the same build:
  - scroll the real library with the art column shown, by trackpad, while a track plays and a
    rescan runs
  - double-click tracks of the same rate and of different rates on the ADI-2, and say whether
    the start feels instant (this replaces the null device's estimated HAL times)
  - play a 44.1 kHz and a 96 kHz track to the AirPods; each plays and the signal path shows
    Converted (31.4)
  - try phases 30a–30c: the Settings layout, clicking stars, ⌘R reveal, the status bar's
    now-playing parts, the toolbar and distraction-free toggles, the column browser's groupings

Old Mac checkpoint (2026-11-03, MacBookPro12,1, macOS 12.7.6, real library for the launches):
- Launch to first rows: warm 0.86 s, cold after `purge` 3.52 s. Memory 72–77 MB.
- `MAX_MMAP_SIZE=1073741824`, so 32c's 256 MB mmap applies.
- Stall log: every launch stalls 100–196 ms with no marked interval; one 100 ms stall on
  `view.toggleSidebar`.
- Bench: every budget passed except two, and four did not run:
  - over: the second of two search keystrokes during a scan, p95 265 ms (slowest 365 ms)
    against 150 ms; idle it is 20 ms
  - over: idle CPU 0.11% of a core against 0.10% (wakeups 0.25 a second, fine)
  - did not run: the four history benches, which need Bench inside a `.build` folder
  - close: live resize 61 ms a frame against 70 ms
  - tag editor on the slow simulated NAS: 129 ms a file's opens, so 32e's 200-file Get Info
    prompt still allows about 26 s here
- Within budget, for the record: double-click same rate 46 ms and another rate 152 ms on the
  slow simulated NAS (estimated HAL), Next 9 ms, seeks 11 ms, trackpad scroll with art p95
  8–11 ms, playback CPU 2.5% at 24/192 and 1.3% converted, gaps 0 samples, soak 0 underruns.

Plan:

1. Profile the two benches over budget, live resize and the palette's opening rows, with
   `sample` on the app or Bench during the bench, and fix what's contained.
2. `./scripts/bench` three times; tighten each phase 32 budget beaten by more than 3x to about
   2x the worst of the three runs, as 14e did, in code and in the table.
3. The owner's checkpoint steps, tested under `/bin/bash` 3.2 with a scratch `--home` and
   `purge` skipped.

**Checkpoint steps for the owner.** Copy two files from the build Mac's
`.build/out/Products/Release/` after `./scripts/bundle release`: `MusicPlayer.app` to
`~/music-player-smoke/MusicPlayer.app` and `Bench` to `~/music-player-smoke/Bench` on the 2015
MacBook Pro. Both are universal. Bench is its own executable, not part of the bundle; it launches
the app for the window benchmarks from `MusicPlayer.app/Contents/MacOS/MusicPlayer` beside
itself, and builds its fixture library (under 1 GB) in `~/Library/Caches/MusicPlayer`.

First, with the app open as usual:

1. Scroll the real library with the art column shown, by trackpad, while a track plays and a
   rescan runs.
2. Double-click tracks of the same rate, then of a different rate, on the ADI-2, and say whether
   the start feels instant.
3. The AirPods test from 31.4: play a 44.1 kHz and a 96 kHz track, and check the signal path
   shows Converted for each.

Then paste this into Terminal. It quits the app, asks for your password once for `purge`, and
writes everything to `~/music-player-smoke/checkpoint-results.txt`, which is the file to send
back. The stall log covers the steps above. The full bench takes about 10 minutes on the build
Mac, so expect longer there.

```bash
dir=~/music-player-smoke
app="$dir/MusicPlayer.app/Contents/MacOS/MusicPlayer"
out="$dir/checkpoint-results.txt"
cd "$dir" || exit 1
{ date; sw_vers; sysctl -n hw.model; /usr/bin/file "$app" "$dir/Bench"; df -h ~ | tail -1; } > "$out"
# A second copy of the app waits on the index's lock, so quit the one that's open.
if pgrep -x MusicPlayer >/dev/null; then
  osascript -e 'tell application id "com.dylanfisher.MusicPlayer" to quit'
  while pgrep -x MusicPlayer >/dev/null; do sleep 1; done
fi
echo "== warm launch" >> "$out"
"$app" --measure-launch >> "$out" 2>&1
sudo purge
echo "== cold launch after purge" >> "$out"
"$app" --measure-launch >> "$out" 2>&1
echo "== SQLite mmap limit (needs MAX_MMAP_SIZE >= 268435456)" >> "$out"
/usr/bin/sqlite3 :memory: 'PRAGMA compile_options;' | grep -i mmap >> "$out"
echo "== main-thread stalls, last 7 days" >> "$out"
/usr/bin/log show --last 7d --style compact \
  --predicate 'subsystem == "com.dylanfisher.MusicPlayer" AND eventMessage CONTAINS "stalled"' >> "$out"
echo "== bench" >> "$out"
"$dir/Bench" >> "$out"
echo "bench exit $?" >> "$out"
echo "Done. Send $out"
```

The warm launch comes first so the cold one, right after `purge`, doesn't also pay for a first
launch of this build on the owner's index. Bench exits 1 when a budget is missed; the file says
which.

Result: the build-Mac part is done; `./scripts/check` and `./scripts/bundle release` pass, and the
bundle and Bench are universal (arm64 and x86_64, macOS 12). Measured on the build Mac on
2026-11-03, three full runs of `./scripts/bench` from 08:32 to 09:01, about 10 minutes each.

Live resize: a contained fix wasn't there, so its budget is now set from measurement. The three
runs measured 27.7, 27.6 and 27.5 ms a frame (p95) against 16 ms. A `sample` of the app during
the bench put the main thread's busy time per frame at: 55% Core Animation's commit, drawing
every visible row's layer again (the rows draw their cells into one layer each, for scrolling, so
a row redraws as a whole when any cell moves), a tenth of it waiting on the window server; 31% the
window's `setFrame` layout pass, mostly NSTableView updating each row view's cell widths and, for
every width change, building the header's cell views and tearing them down again; and 11% the art
column's width change, the same row updates. The app's own code is about 6%: `refitArt` 2%,
`KeyTableView.frameOfCell` 3%, and `AlbumArtCell.setFrameSize` 1%. No constraint of the app's and
no status bar part showed up. Only the Title column autoresizes with the window. Cutting the
redraw would mean giving up each row's single layer, which the rows have for scrolling (trackpad
frames are 9 ms here), so it stays. The budget is 35 ms here and an estimated 70 ms on the old Mac, about 1.25x
the worst run (32e measured 29.5 ms).

The palette's opening rows: fixed. A `sample` put about 40% in the frecency lookups and most of
the rest in binding each `PaletteItem` in the empty query's loop, which retains its key, title,
detail, chord and fuzzy candidate. The loop now reads the kind and key by index: 4.13 ms before,
2.05 to 2.11 ms after, and 2.05 to 2.06 ms in the three runs, against 4 ms. Checking a full
list's last entry without copying the list in `offer` saved only 0.25 ms more, so it was left out.

Also over in all three runs: the palette's last of 8 keystrokes 50 ms apart, 21.1, 22.8 and
20.7 ms against 15 ms, and 20.1 and 21.1 ms with main's ranking code, so not this branch's change.
32d measured 4.9 ms on this Mac earlier the same day. Each of the eight rankings takes 2 to 5 ms
when run back to back, but 13 to 29 ms when run alone after a 50 ms sleep, on the main thread or
detached alike; the signpost around the ranking isn't it either (20.4 ms without). So this Mac now
runs a ranking after a short idle several times slower than when busy, which looks like its clock
or core choice, not the code. The budget stays at 15 ms, so it shows if this persists or appears on
the old Mac. A check against e7c8097, alternating three runs each, gave 16.1 to 20.2 ms there and
14.5 to 20.9 ms here, so no commit since slowed it; the Mac had background load at the time
(Safari's SafeBrowsing service near 92% CPU). The gap between keystrokes is how people type, so
waking the core is part of what the user feels and the bench keeps its 50 ms sleep; the old Mac's
run decides the budget.

Tightened to about 2x the worst of three runs, each beaten by more than 3x; the old-Mac figures
stay estimates until this checkpoint:

| Benchmark | Runs | Before | After |
|---|---|---|---|
| Totals right after a play is recorded (32c) | 0.85, 0.85, 0.85 ms | < 4 ms | < 2 ms |
| Add to Playlist with every track selected (32e) | 102, 103, 102 ms | < 500 ms | < 200 ms |
| Get Info's read of a file (32e) | 0.06, 0.06, 0.06 ms | < 1 ms | < 0.12 ms |
| Next to its first sound (32a) | 11.0, 9.4, 10.0 ms | < 40 ms | < 25 ms |
| A seek while decoded to its first sound (32a) | 10.6, 10.0, 11.9 ms | < 40 ms | < 25 ms |
| A seek after decoding moved on to its first sound (32a) | 11.0, 11.9, 8.0 ms | < 40 ms | < 25 ms |

The other phase 32 budgets are within 3x of their worst run. Every other benchmark passed in all
three runs.

Orchestrator notes on 32e:
- 32e.1: a run-loop watchdog can't sample the main thread's stack cheaply. Have it log the
  open signpost intervals and the last command or event dispatched, which is enough to place
  the hitch.
- 32e.2: a thumbnail cache is a cache, not app state. Weigh a file under
  `~/Library/Caches/MusicPlayer` against a table in the index; the index's size budget and
  backup weight argue for the cache folder. Record the choice in an ADR.
- 32e.4: line numbers in AppDelegate moved with phase 30a's sync folder buttons, which added
  more `fileExists` and `locate` calls on the main actor; cover those too.
- Concurrency limits (32b.4, 32d.3) scale with the Mac they run on: derive them from
  `ProcessInfo.activeProcessorCount`, defined once, never a fixed number. The old Mac
  (2 cores, 4 threads, 16 GB) is the floor that must stay smooth while playing, and benches
  check both ends.

Overlap: the play-latency change (ADR 0070, merged as b6d2a74) already starts the clicked track
before the queue's paths are read, with a double-click bench, which covers most of 32a.3. 32a
extends that bench rather than redoing it.

### 33. Old Mac follow-ups

**Done; old Mac checkpoint pending.** Ran after 34, alongside 35 and 36. From the 32f old Mac checkpoint on
2026-11-03.
Phase 32's rules apply: bench first, the audio boundary stands, the NAS is simulated, and the old
Mac's numbers come from its next checkpoint.

- **33.1 History benches outside `.build`.** `buildDirectory()` in
  `Sources/Tools/Bench/HistoryBenchmarks.swift` throws unless Bench runs inside a `.build`
  folder, so the four history benches can't run from `~/music-player-smoke`. Put their scratch
  database where the other fixtures live, in `~/Library/Caches/MusicPlayer`, defined once.
- **33.2 Search during a scan on two cores.** The second of two keystrokes 50 ms apart during a
  scan is p95 265 ms on the old Mac against 150 ms, and 20 ms idle. Find what the keystroke
  waits on: CPU taken by the scan's readers and parsers, the SQLite write lock or checkpoint, or
  the main actor. The concurrency limits derive from `ProcessInfo.activeProcessorCount`, so check
  the floor they pick on 2 cores, 4 threads, and the scan's QoS against the search's. Fix it
  without slowing the scan benches by more than 10%.
- **33.3 Cold launch and launch stalls.** Cold launch is 3.52 s against 0.86 s warm, and every
  launch logs a 100–196 ms main-thread stall with no marked interval. Mark the launch's steps
  with the 32e signposts. Find what the cold launch reads from disk before the first rows: the
  index's pages, the dylibs, the art or the config. Then move or shrink what runs on the main
  actor. The bench's launch is from a warm cache, so add a check that drops the index's pages
  from the cache before it, if one can without `sudo`. Otherwise say so and leave the cold number
  to the checkpoint.
- **33.4 Idle CPU.** 0.11% of a core against 0.10% on the old Mac, with 0.25 wakeups a second.
  Find what still runs when idle, and fix it or set the budget from measurement with the reason.
- **33.5 Get Info cutoff.** The old Mac's tag editor takes 129 ms a file on the slow simulated
  NAS, so 32e's 200-file prompt allows about 26 s. Set the cutoff from the old Mac's number so
  the editor opens within a few seconds before the prompt. Keep it defined once
  (`TagEditing.confirmReadAbove`) and update ADR 0081.
- **33.6 Stall on toggling the sidebar.** 100 ms on the old Mac. Profile it, and fix it if the
  cause is contained.
- [ ] **Hardware checkpoint (owner):** rerun the 32f block on the 2015 MacBook Pro and send back
  the file.

Plan:

1. 33.1: one Bench function names a scratch folder beside the fixtures in
   `~/Library/Caches/MusicPlayer` and empties it; the history benches and the four benches that
   already build that path by hand use it, and `buildDirectory()` goes.
2. 33.2: measure first, comparing against `main` in the same session. A keystroke that lands
   during a refresh waits in `LibraryReader` behind the refresh's queries, which take hundreds
   of milliseconds under a scan. Give the reader a second connection for what a library change
   rereads (`refreshes`): `BrowserModel` runs a `.libraryChanged` reload there, and
   `LibraryBrowser` reads that change's totals and the issue count there. Record the floors the
   reader counts pick on 2 cores, 4 threads, and the scan's QoS, in ADR 0086. Test: a search
   typed while the refresh connection is held finishes before the refresh. Check the scan
   benches stay within 10%.
3. 33.3: launch intervals in `Interval` for the steps before the first rows (settings and state,
   the window, the services started after the first rows), so the stall log names them. Find
   what the launch reads from a cold cache with `mincore` on a cloned index; make the launch
   bench say how much of its index was resident, since APFS clones start uncached. Move or
   shrink what the measurement shows on the main actor.
4. 33.4: sample the idle app here, find what wakes, fix it or set the budget from measurement.
5. 33.5: `TagEditing.confirmReadAbove` from the old Mac's 129 ms a file, so the editor opens
   within about 3 s before it asks; update ADR 0081.
6. 33.6: time the sidebar toggle here, and fix the cause if it's contained.
7. Benches: the named ones each item touches, against `main` measured the same session; the old
   Mac's numbers are pending its checkpoint.

Result: shipped, measured on the build Mac against `main` in the same session. A keystroke
during a scan waited behind the browser's refresh in the one reader; refreshes now use a second,
read-only connection (second keystroke p95 23 ms against 24–97 ms). The launch stall and the
empty-list sidebar toggle were AppKit drawing the default system background's alternating rows;
the table now holds that color resolved for its appearance (launch 0.47 s against 0.60 s, toggle
11–45 ms against 130–160 ms). That costs memory: after scrolling every row 111 MB against 81 MB,
under the 120 MB budget, kept as a trade-off in ADR 0086. Glass now restores the color as set,
not a resolved guess. The old Mac's idle budget is 0.15% from its checkpoint, and Get Info asks
above 25 files. `./scripts/check` passes; one correctness review and a fix round. The 2015
MacBook Pro checkpoint is pending: the 32f block, the stall log, the empty-list sidebar toggle
and a cold launch after `purge`.

### 34. Config safety

**Done.** From the mbp2026 test run (Mac17,6, M5 Max, 18 cores, macOS 26.6.2, Xcode
27.2) on 2026-11-03: the owner's feedback on the release build at c4c8c65, like phases 35 to 37.
A config that doesn't parse must never cost the library or the rest of the settings.

- **34.1 A bad config never empties the library.** At launch, a config that fails to parse leaves
  every setting at its default, and `library.watchedFolders` defaults to `[]`. That empty list
  reaches `LibraryWatcher.start` (`Sources/Core/Library/LibraryWatcher.swift:109`), where
  `removeFiles(outside: [])` treats every file in the index as outside and deletes it. On mbp2026
  a stale `appearance.nowPlaying` line (the key was removed in 4d0a177) failed the parse. The
  owner then saw no music in the track list, but the index still had all 43,382 tracks, 11,169
  plays and 149 ratings. Find out why nothing was deleted and why the list was empty. Then make
  both impossible: write a test that launches with a broken config and an indexed library and
  checks that no file is removed and the rows show. Don't start the watcher on, or remove files
  for, folders that come from defaults while the config has problems. Record the decision in an ADR.
- **34.2 An unknown key doesn't block the rest.** A key the app doesn't know, such as an obsolete
  one, is reported in the banner and skipped, and every other valid setting still applies and
  saves. Real errors (bad JSON, a bad value for a known key) keep today's behavior, unless 34.1's
  ADR decides to apply the valid keys there too.
- **34.3 The banner fixes it.** For an unknown or obsolete key, the banner offers "Remove
  Obsolete Setting". It deletes that key's line and the comment lines above it, and leaves the
  rest of the file byte-for-byte, including comments and the trailing comma rules. Test it on a
  file with comments around the key and with the key last.
- **34.4 "Never" for watched-folder rescans.** The rescan interval popup (ADR 0060) gets a Never
  option: the folder is not rescanned on a timer, only by Rescan or by file events where those
  apply. Say in the ADR whether Never also skips the launch rescan.

Implementation plan:
- Settings: `ConfigFile.parse` returns the valid keys when its only problems are unknown keys,
  each tagged with its key path (`ConfigProblem.obsoleteKey`); any other problem still applies
  nothing. `ConfigStore` writes patches over such a file (they touch only their own key's text),
  keeps which keys the file gave, and offers `fileValue(_:)` for a value only when the file or
  the app set it, never a default.
- App: the watcher starts only on `fileValue(\.watchedFolders)`; without one it stays off and
  says so. A test in MusicPlayerTests launches that path over an indexed fixture library with a
  stale key and with broken JSON, and checks no file is removed and the rows show.
- Remove Obsolete Setting: `ConfigText.remove` also takes the comment lines directly above the
  member, `ConfigStore.removeObsoleteKeys()` edits the file, and `ConfigBanner` gets the button
  and wording for problems that don't block. Tests: comments around the key, key first, middle
  and last, trailing commas, a nested key.
- Never: `WatchedFolder.pollIntervalMinutes` becomes optional, null for never; `WatchState`
  schedules no poll for it; the Rescans popup gets Never.
- ADR 0082 for all four, and a note in ADR 0015 and 0060.

Result: shipped as planned, with one finding: the unfixed app did delete the tracks. Over a copy
of the bench index with a stale key, they went from 42,964 to 0 within seconds; the rows keyed by
path (plays, ratings, loved, history, playlist entries) survived, so mbp2026's next launch
rescans and they reattach. Review then closed two more paths to the same loss, both fixed and
tested: an in-app change while the file is blocked (now refused), and a deleted config whose new
default file gave `[]` (an empty list never prunes; Stop Watching the last folder prunes
explicitly). `./scripts/check` and `./scripts/bundle release` pass; launch to first rows 0.64 s
against 1 s on the build Mac. A correctness review and a re-review of the fix round ran; no
security or full bench, since nothing parses outside input beyond the config and only the launch
path is budgeted.

### 35. Seek, progress bar and buffering

**Done.** Ran after 34, alongside 33 and 36.

- **35.1 Optimistic seek.** A click on the bar jumps there, then jumps back to the old position
  for about a second, then comes back. The audio is right; only the playhead lags. ADR 0072 says
  the bar keeps the target until the engine reports the seek done, so find where that breaks
  (a position tick arriving before the seek's report, or a second view drawing the old time),
  and add a test that clicks and asserts the drawn position never goes back to the old time.
- **35.2 A standard progress bar.** Draw the bar like the owner's reference: elapsed time on the
  left, total on the right, a rounded track with an accent-colored fill for the part played, in
  a rounded inset box. No vertical-line playhead.
- **35.3 Dragging the bar never moves the window.** In the toolbar and in the status bar, a
  mouse down on the seek bar must not start a window drag (`mouseDownCanMoveWindow` false, and
  check the full-size content view in glass mode). Test it with both locations.
- **35.4 Buffering review.** Write up how a track is read and decoded today: read sizes, how far
  decoding runs ahead, what's kept, when the next track starts reading, and what happens on a
  seek, for local files and the slow simulated NAS. Compare with reading the whole file into
  memory, reading the next track ahead near the end, and keeping recently played or seeked
  regions. Weigh memory on the 2015 Mac, NAS load while browsing, gapless, and seek latency
  when scrubbing quickly. Recommend, record an ADR, and bench any change against the 32 budgets
  (time to sound, seek to first sound, soak memory).
- **35.5 The art viewer stays open during a scan.** Clicking album art opens the viewer, and a
  scan that adds tracks closes it, probably because the list reloads. Keep it open across a
  refresh as long as its track is still in the list.

Implementation plan (ADR 0083; ADR 0072 amended for the seek bar):
1. 35.1: `DeviceOutput.position()` and `RendererOutput.position()` report a posted seek's
   target from the moment `seek` returns until the output has sought, so the bar's read after
   the seek, its ticks and the system's Now Playing get the new time. The `Output` protocol
   states it. Tests: a seek on the slow simulated NAS reads the target at once and never the
   old time (HALOutputTests); the same for a renderer (UPnPOutputTests); a click on the
   toolbar bar over a real `DeviceOutput` on a null device never draws the old time
   (NowPlayingTests).
2. 35.2 and 35.3: a `SeekBox` view in NowPlaying holds the elapsed time, the `SeekBar` and the
   total in a rounded inset box, replacing the two stacks in `NowPlayingBar` and
   `StatusBarParts`. `SeekBar` draws a rounded track with an accent fill, no playhead. Both
   views return false from `mouseDownCanMoveWindow`, and the box takes clicks on its times.
   Tests: the box's and bar's `mouseDownCanMoveWindow`, and a hit test on each place, in the
   toolbar and in the status bar of a full-size content view window. Snapshots in both places,
   light and dark, at 1440x900.
3. 35.5: `TrackTableController` keeps the viewer's track ID; a reload closes the viewer only
   when that track has left the list, and a redraw only when its row's art or album changed.
   Test: a reload that keeps the track keeps the viewer; one that drops it closes it.
4. 35.4: the buffering review in ADR 0083, from the code and from benches of seeks on the slow
   simulated NAS. A change only if a bench shows it pays against the phase 32 budgets.

Result: shipped as planned. The playhead lag came from the outputs: `position()` kept the time
from before a seek until the control thread got to it, behind any refill already reading, and
UPnP did the same. Both now report a posted seek's target until it's done. A seek 20 ms after
another went from 204 to 4.3 ms on the slow simulated NAS (146 to 3.4 ms local); soak memory
growth −0.23 MB, 0 underruns. `./scripts/check` and `./scripts/bundle release` pass. One
correctness and real-time review ran, with a small fix round (UPnP's held target clamped, two
tests ordered by signals); no security or full bench, since only the playback path is budgeted
and nothing parses new input. Owner check pending: click and scrub the bar on the 2015 MacBook
Pro, in the toolbar and the status bar, glass on and off.

### 36. Window chrome and glass

**Done; owner checks pending.** Ran after 34, alongside 33 and 35.

- **36.1 The status bar centered on the window.** Its middle content stays centered on the
  window's full width, lined up with the window title. It doesn't move when the scan progress
  appears or changes width, or when the sidebar shows, hides or resizes. If that's simpler with
  the status bar spanning the whole window, sidebar included, do that.
- **36.2 Liquid glass on the status bar.** The owner has asked for this several times. ADR 0072
  explains why it looks solid: it uses the title bar material, and nothing scrolls behind it. Fix
  that: on macOS 26 use `NSGlassEffectView`, with the bar laid over the bottom of the table so
  rows scroll under it (the scroll view's bottom inset matching the bar's height), and keep a
  material fallback on 12 to 15. Say in an ADR how this fits with 36.1's full-width option.
- **36.3 Status bar art is clickable** and opens the same viewer as row art.
- **36.4 Toggling a status bar part never resizes the window.** With only Art ticked, toggling it
  shrinks the window and changes the sidebar's width. No status bar change may change the
  window's frame or the split view's positions. Test it for each part alone and together.
- **36.5 Art-column hover covers the whole cell.** Hovering anywhere in a row's art cell enlarges
  that row's art, not only over the image (ADR 0065).
- **36.6 Glass mode's wording.** In Settings it describes turning the whole player into
  translucent glass, not "the sidebar's material".
- **36.7 Alternating rows in glass mode.** Draw them with translucent tints so they work over
  the material, instead of turning them off.
- **36.8 Grid lines left behind by glass.** After turning glass on and off, every row has faint
  lines between it and the next; Row Lines only makes them darker, and turning glass off makes
  them fainter without removing them. Glass must put back exactly what it changed. Add a test
  that toggles glass on and off and compares the tables' grid, background and row settings with
  a fresh window.

Implementation plan:
- Probe first: a MusicPlayerTests helper builds the real main window (browser, toolbar, queue,
  status bar parts) over a fixture library in a temporary home, to find what changes the frame
  and the splits and what glass leaves behind, and later to compare with a fresh window.
- Glass (App, `WindowGlass`): the window keeps a full-size content view whatever the glass, so
  turning it on or off changes no style mask, which resized the window and its splits; glass
  changes the title bar's transparency, the backdrop and the lists only. Fix what the 36.8 probe
  finds, and test that glass on then off leaves the frame, the split positions and every table's
  grid, background, row and alternating settings as a fresh window has them.
- Status bar (LibraryBrowser): the bar's scan progress on the leading side, the problems button
  trailing, and the parts in a middle centered on the window's content view by a constraint
  below the window's size priority, so no part can resize the window (36.4) and nothing beside
  it moves it (36.1). A `CenteredRow` view holds the three, for phase 37's columns to reuse. The
  bar lies over the bottom of the track table and the timeline, whose bottom content insets
  follow its height and visibility, on `NSGlassEffectView` from macOS 26 and the title bar
  material before (36.2). Tests: centering with the sidebar's width and the scan text changing,
  window frame and split positions unchanged for each part alone and together, insets.
- Art (LibraryBrowser): a click on the status bar's art opens the playing track's art in the
  `ArtViewer` (36.3); the hover shows anywhere in an album's art cells (36.5). Tests for both.
- Stripes (36.7): in glass the lists that had alternating rows draw translucent stripes of
  their own instead; test the colors' alpha. Wording (36.6) in `AppSettings`.
- `--snapshot` at 1440x900, light and dark, glass on and off, rows scrolled under the bar;
  `./scripts/bundle release`; the scroll and live resize benches by name against main.
- ADR 0084, amending 0072 and 0065.

Result: shipped as planned (ADR 0084). The status bar is centered on the window through
`CenteredRow`, lies over the bottom of the rows with the scroll inset matching it, and is
`NSGlassEffectView` on macOS 26+ with the title bar material on 12–15. Toggling a part shrank the
window because nothing in the bar could stretch; no bar constraint now outranks the split panes,
tested alone and together, at the default size, 720 wide and 1440x900 with every panel open.
36.8's cause: the glass style-mask toggle shrank the frame by the toolbar's height and the splits
shared out the change; glass now restores the frame and dividers, and a fresh-window comparison
(light and dark, alternating on and off) found and fixed wrong alternating colors after glass.
Scrolling costs nothing measurable on an idle Mac (scroll-bar drag p95 13.4 against 13.0 ms,
compact rows 10.8 against 10.7, live resize 30.2); an earlier +18% reading ran beside CPU
burners. `./scripts/check` and `./scripts/bundle release` pass. A correctness and performance
review, a fix round and a re-review ran. Owner checks pending: dark mode, the real blur, 36.8's
drawn lines, glass in full screen, and that the material bar blends on the 2015 MacBook Pro.
Known limitation for phase 37: on glass, AppKit centers the title beside the sidebar, so the bar
sits left of the title by half the sidebar's width.

### 37. Toolbar and status bar builders

**Done; owner check pending.** Builds on 36. Reverses ADR 0072's rejected "free-form status bar
editor" and "now-playing parts as toolbar items", so it needs a new ADR that supersedes those
parts.

- **37.1 Status bar builder.** The status bar is built from columns the owner adds: fixed or
  flexible width, each with its own alignment (leading, center, trailing), like flexbox. Parts
  go into columns. The goal is a middle column that stays centered on the window (36.1), with
  the left and right columns aligned however the owner likes. The builder opens in its own
  window or popover from Settings ▸ Appearance, with drag and drop and a live preview.
- **37.2 Tall mode stacks.** In the tall style, a column can stack parts vertically (title over
  artist over format, say), and the bar grows to fit, within a maximum height.
- **37.3 Header status builder.** The same builder, as its own instance, lays out the header's
  now-playing status: art, text lines and seek bar in columns and stacks. It can rebuild today's
  detailed layout exactly, and that layout is the default.
- **37.4 A modular toolbar like Swinsian's.** Customize Toolbar offers separate items: Controls
  (previous, play/pause, next), Volume, Status (the 37.3 layout), Search, Shuffle, Repeat, Mini
  Window when it exists, Output (AirPlay/UPnP), Flexible Space and Space. Its default set is
  Controls, flexible space, Volume, flexible space, Status, flexible space, Shuffle, flexible
  space, Search. It replaces the single pre-made now-playing item.
- [ ] **Owner check:** build the current header and a centered-status layout with each builder
  on mbp2026 and on the 2015 MacBook Pro.

Implementation plan, part 37a (37.1 and 37.2; ADR 0085, superseding 0072's rejected free-form
editor):
- Settings: a `BarLayout<Part>` value, generic over its parts: `leading` and `trailing` lists of
  columns and one `center` column, each column with its `parts`, a `width` (`"flexible"` or a
  number of points), an `alignment` (leading, center, trailing) and `stacks`. Decoding rejects
  unknown keys at every level; `problems` lists typed `BarLayoutProblem`s (an empty column, a
  part twice, a width out of range, a part that fills the bar's height in a stacked column).
  `appearance.statusBarLayout` replaces `appearance.statusBarParts`, with a default of the
  totals alone in a flexible centered column, today's bar. A `.barLayout` setting kind carries
  the parts' choices.
- LibraryBrowser: `StatusBarLayout` holds the columns and the style. The bar builds a view per
  column (a stack of its parts, aligned in it, fixed or flexible, flexible columns sharing the
  free width equally); the leading columns follow the scan progress, the trailing ones precede
  the problems button, and the center column is `CenteredRow`'s middle, centered on the window.
  In the tall style a stacked column lays its parts out vertically and the bar grows to the
  tallest stack, up to a maximum height. On glass the middle centers on the area beside the
  sidebar, where AppKit centers the title, if a probe confirms that's where the title is.
- SettingsWindow: Settings ▸ Appearance shows an Edit Layout… button for a `.barLayout` row,
  which opens a `BarBuilder` window for that key: a preview of the bar's columns, drawn by the
  layout's rules, whose parts drag between columns and to and from a tray of unused parts; Add
  Column, Remove Column, width, alignment and stacking for the selected column; arrows select
  parts, ⌘ arrows move them and Delete removes one. Its logic is a `BarBuilderModel` with no
  AppKit, which saves each change as a patch to its own key, holding back a layout with an empty
  column. The checklist control loses its only setting and goes.
- 37b plugs in as a second `BarLayout` setting with its own part type (the header's art, text
  lines and seek bar): the builder opens for it from its own row, unchanged, and the column
  views move down a tier when the toolbar needs them too.
- Tests: decoding and every problem; the default reproduces today's bar (same views, fill and
  centering); column order, alignment, fixed and flexible widths and the window centering in
  the real window; tall stacks' height and its cap; no layout resizes the window; the builder
  model's operations, saves and keyboard moves. `--snapshot` at 1440x900, both styles, a few
  layouts and the builder; the live resize bench by name; `./scripts/bundle release`.

Result, part 37a: shipped 37.1 and 37.2 (ADR 0085). `appearance.statusBarLayout` replaces
`appearance.statusBarParts`, which is now reported as obsolete; the default reproduces the old
bar. The builder opens from Settings ▸ Appearance with drag and drop, a live preview and keys,
saves each edit as a patch, and goes read-only with the banner's wording while the config is
blocked. Stacked columns grow the tall bar to 80 pt and clip past it. On glass the center column
now sits under the title, fixing ADR 0084's limitation. Review found a crash on a reload that
removed the selected part, a stale tall height, builder/file drift, and a crash on a `-1e400`
value in any setting; all fixed and tested, and a re-review's two leftovers fixed.
`./scripts/check` and `./scripts/bundle release` pass; live resize p95 30.5 ms against 35 ms.
Part 37b (37.3, 37.4) and the owner check follow.

Implementation plan, part 37b (37.3 and 37.4; ADR 0085 amended, superseding 0072's rejected
"now-playing parts as toolbar items"):
- BarView, a new Core module (AppKit and Settings): `CenteredRow` and `StatusColumn` move out
  of LibraryBrowser, with `BarColumns`, which lays a `BarLayout`'s columns into a row (side
  columns, the center, flexible columns' equal widths, the fills, each part's hugging and its
  text giving way). The status bar keeps its views and constraints; its tests stay as they are.
  The row gains two choices the header needs: a flexible middle that fills the width the sides
  leave before it centers, and no clearance beside an empty side.
- Settings: `HeaderPart` (art, title, artist and album, format, seek bar) and
  `appearance.headerStatusLayout`, a `BarLayout<HeaderPart>`, whose default is today's
  detailed header: the 48-point art in a fixed leading column, and the three lines over the
  seek bar stacked in a flexible center column, aligned leading. Its row in Settings ▸
  Appearance opens the builder, unchanged.
- NowPlaying: `HeaderStatus` lays out the header's art, labels and `SeekBox` by that layout in
  its own `BarColumns` and row, stacks always stacking, at the tallest column's height; the
  status keeps its window-drag and seek-hold behavior. The sheet's drawing of the status is a
  `HeaderStatus` of the current layout with placeholder text.
- App: Customize Toolbar offers Controls (today's transport item, renamed), Volume, Status,
  Search, Shuffle, Repeat, Output, the queue and signal path toggles, Flexible Space and Space;
  the default set is Controls, flexible space, Volume, flexible space, Status, flexible space,
  Shuffle, flexible space, Search. The items stay in `state.json`'s `window.toolbarItems`
  (ADR 0055) with their raw values, so no saved item goes away. A layout change sets the
  status item's height again. `--snapshot-of headerStatus` and `toolbarSheet`.
- Tests: the header default's frames match today's detailed layout (art, each line, the seek
  bar, the height); a centered layout centers on the item; a fixed center column centers; no
  window drag and the seek hold still pass; the setting's default and decoding; the toolbar's
  default set, labels, every item's drawing, a saved toolbar from before; a layout change
  resizes the item. `--snapshot` at 1440x900 short and tall, glass on and off, the sheet and
  the builder; the live resize bench by name; `./scripts/bundle release`.

Result, part 37b: shipped 37.3 and 37.4 (ADR 0085 amended, superseding 0072's rejected
now-playing toolbar parts). `CenteredRow` and `StatusColumn` moved into `Sources/Core/BarView`,
the one Core module allowed AppKit, which `scripts/arch.swift` now enforces. The toolbar status
is laid out by its own builder from `appearance.headerStatusLayout`, whose default matches the
phase 35 header frame for frame. Customize Toolbar offers Controls, Volume, Status, Search,
Shuffle, Repeat, Output, Flexible Space and Space, with the default set asked for; saved toolbars
restore whole, and the status caps at 560 pt only while a flexible space shares the toolbar. One
review, a fix round (preview height and wording per builder, the cap, the import rule) and a
re-review. `./scripts/check` and `./scripts/bundle release` pass; live resize p95 31.3 ms against
35 ms. The owner check below stays pending.

Still open from the mbp2026 test run, for later: the manual checklist (scrolling with art during
a rescan, start time at the same and another rate, built-in and Bluetooth output, the UI pass,
Get Info over 200), the `sudo purge` cold launch, and the stall log.

### 38. Owner feedback, 2026-11-04

The owner's feedback from trying phase 37b. The screenshots it referred to (our progress bar
against Swinsian's, the header layout wanted, the tag-write error) didn't reach the session, so
38.2 takes Swinsian's colors from its own app bundle on mbp2015 (a temp copy, read only) and
38.11 waits for the error text. The two batches run in parallel worktrees.

#### 38a. Toolbar, status and window title (ADR 0087)

- [x] **38.1 No art placeholder.** With nothing playing, the toolbar status and the status bar
      hide the art; no gray box. The rest of the layout doesn't jump when art appears.
- [x] **38.2 Swinsian's progress bar colors.** The seek bar's track, fill, buffered part and
      knob match Swinsian's in light and dark, on glass and off.
- [x] **38.3 A truly centered status.** With the toolbar's flexible spaces, the status (seek bar)
      stays centered on the window whatever sits on either side, and with nothing on the left:
      the owner's layout is nothing on the left, the status in the middle, Search on the right.
- [x] **38.4 Window title template.** A new `appearance.windowTitle` setting sets the window's
      title (the name at the very top, today always "MusicPlayer") from a template such as
      `{title} — {artist}`, with tokens for the playing track's fields. With nothing playing the
      title is the app's name. Its row in Settings ▸ Appearance has a ? button whose popover
      (and tooltip) lists every token. The tokens are defined once and shared with the help.
- [x] **38.5 Glass headers.** In window glass mode the table headers are more translucent.

Implementation plan, part 38a (ADR 0087):
- 38.1, NowPlaying: with no current track the toolbar status's and the status bar's art views
  go transparent (alpha 0), keeping their place, so nothing beside them moves when art comes;
  a track without art keeps the gray box. Test: alpha with and without a track, and the other
  parts' frames the same in both.
- 38.2, NowPlaying: `SeekBar` draws Swinsian 3.1's `ProgressControl` colors, read from its
  binary on mbp2015 (a copy in the scratchpad): the track calibrated white 0.86, the played
  part calibrated RGB 0.266/0.512/0.910, dark gray with the graphite accent, the same in light
  and dark and on glass. Swinsian draws no knob and no buffered part, so neither do we. Test:
  pixels of a drawn bar in both appearances.
- 38.3, App: the toolbar centers the status on the window with
  `NSToolbar.centeredItemIdentifiers` on macOS 13 and `centeredItemIdentifier` on 12; a probe
  here showed both center it on the window, glass or not, whatever sits on either side, while
  the status at its width fits centered. Test: the status's middle on the window's for the
  owner's layout (nothing, status, search), the default set and a lopsided one.
- 38.4, Settings: `TitleToken` (title, artist, album, album artist, composer, genre, year,
  track and disc number, format), each with its help line, and `WindowTitle`, the template
  `appearance.windowTitle` holds, which rejects an unknown token or a stray brace with the
  tokens in the message. Its kind, `.template`, carries the tokens to Settings ▸ Appearance,
  which shows a text field and a ? button whose tooltip and popover list them. NowPlaying
  fills it from the playing track (nil with nothing playing, ends trimmed of separators); the
  app sets the window's title to it or the app's name, on a track change and a setting change.
  Tests: parsing and every problem, filling with missing fields, the row's control and help,
  the window's title in the real window glass on and off.
- 38.5, App: on glass `NSTableHeaderView` fills itself opaque behind any header cell that isn't
  its own (measured: 0.97 white light, 0.26 dark), so the glass swaps each list's header view
  for one that draws a translucent tint under the cells, and puts the original back. Test:
  header pixels translucent on glass, and the header and its menu back after.
- Checks: `./scripts/check`, `--snapshot` at 1440x900 glass on and off, the live resize bench
  by name, `./scripts/bundle release` for the `#available` guard.

Result, part 38a: shipped 38.1 to 38.5 (ADR 0087). With nothing playing the art is transparent
in its place. The seek bar takes Swinsian 3.1's `ProgressControl` colors, read from its binary
(white 0.86 track, 0.266/0.512/0.910 played, dark gray under graphite); the owner's eye against
Swinsian still decides them. The toolbar centers the status with NSToolbar's centered item
identifiers, on the window plain and beside the sidebar on glass, under the title. The window
title follows `appearance.windowTitle`, ten tokens listed by a ? button in Settings; review
found the end-trimming cut fields' own punctuation and left doubled separators, so the fill
now keeps fields as tagged and drops text beside empty ones, and an empty template is refused.
On glass the lists' header views draw a translucent tint, and a column added meanwhile is
cleared too. `./scripts/check` and `./scripts/bundle release` pass; live resize p95 31.7 ms
against 35 ms. The macOS 12 to 15 paths wait for the owner check.

#### 38b. Table, navigation and palette (ADR 0088)

- [x] **38.6 Album lines.** An option draws a line between albums in the track table, and both
      row lines and album lines take a color (with alpha) from Settings ▸ Appearance, so they can
      be as faint or heavy as the owner likes.
- [x] **38.7 Art column background.** The album art column draws a plain white (the table's
      background in dark mode) background, without grid lines or alternating rows.
- [x] **38.8 ⇧⌘L Reveal Selected Track.** Scrolls the table to center the selected track, as
      ⌘L does for the playing one. In the menus, the shortcuts pane and ⌘K.
- [x] **38.9 Settings in ⌘K.** The palette has an entry that opens Settings, and one that opens
      the config file if there isn't one already.
- [x] **38.10 Back to all music centers on the playing track.** Leaving a browse or filter for the
      whole library centers the playing track, as ⌘L does; with nothing playing, the selection.
- [ ] **38.11 Tag-write error.** Waiting on the error text from the owner.
- [ ] **Owner check:** each item on mbp2026 and the 2015 MacBook Pro.

Plan:
- A `HexColor` setting value in `Core/Settings` (`"#RRGGBB"` or `"#RRGGBBAA"`, kind `.color`),
  and `appearance.albumLines`, `appearance.rowLineColor` and `appearance.albumLineColor`, both
  colors optional (null is the system's grid color). Settings ▸ Appearance shows a color well
  with alpha and a Default button for `.color`; ⌘K lists the colors as it lists other settings.
- `MarkedRowView` draws its own bottom line in a color it's given and paints one column plain
  in the table's background; the track table gives each row the album line at an album's last
  row (the art column's `albumID` runs), the row line elsewhere, and the art column. Column
  lines are drawn by the rows too, in the row lines' color.
- `showSelectedTrack` (⇧⌘L, View menu) centers the selected rows, as ⌘L does with nothing
  playing.
- `showSettings` becomes a command (⌘,) so ⌘K, the menu and the Shortcuts pane have it; Open
  Config File is already in ⌘K.
- `BrowserChange` says when a user change widened the table back to everything; the browser
  then selects and centers the playing track, as ⌘L does. The selection is centered already.
- Tests: the color's parsing, the setting rows, the row lines given per row, the art column
  plain, the commands and chords, and the return to all music, in the existing suites.

Result, part 38b: shipped 38.6 to 38.10 (ADR 0088); 38.11 waits on the owner. The color kind
is `HexColor`, a color well with opacity and a Default button that sets null, the system's grid
color. The rows draw every line, row, album and column, so each row can carry its own and none
crosses the plain art column; the table draws no grid, so nothing shows below the last row. An
album ends where the art column's `albumID` changes, adjacent rows without an album are one
group, and a row whose next row isn't cached has no album line until that row's view is made.
The art column is the table's background, white in light, dark in dark, the glass on glass;
review found it black on glass (a clear fill in copy mode), the column lines showing through
it there, and the rows not asked to redraw when a column shows or hides, all fixed. ⇧⌘L is Show
Selected Track; Settings… is a command on ⌘, so ⌘K and the Shortcuts pane list it. Back at all
music from a source, pane or search, the playing track is selected and centered, the keys left
where they were. `./scripts/check` passes; `--snapshot` with album lines in red, light, dark and
glass; trackpad scroll with art p95 10.4 ms, compact rows 11.4 ms, against 16 ms. ⌘, from the
palette and the Settings window is checked in code only (neither takes the chord before the
menu bar); the owner checks each item on both Macs.

### 39. Owner feedback, 2026-11-03 evening

**Done; owner check pending.** `./scripts/check` passes clean on main after all three parts.
The gate also fixed two tests that were failing on main: a glass toggle saved the sidebar width
it passed through (172 for 180), and the status bar's art skipped its click recognizer when
AppKit's own was already there. Still for the owner to check in the running app, in light and
dark and on and off glass: the row lines, the status bar border's color off glass (the header's
bottom line is darker than the separator color), the art margin, the builder with a real mouse,
and the title line with a track playing. To decide: whether selected rows should show their row
line, and whether "the first column on the right" should count from the center, as now, or
from the window's edge.

The owner's feedback from trying phase 37. `s1205`, the toolbar status with nothing playing, is
in `~/.claude/projects/-Users-dylanfisher-projects-music-player/feedback-2026-11-03/`. The other
four screenshots were in a temporary folder and are described where they're used. 39a and 39c
run in parallel worktrees; 39b follows 39c, since both change `BarLayout` and the builder.

Answered, not a phase item: a reveal in Searcher opens a new window unless a window's focused
pane already shows the folder. That's Searcher's `WorkspaceWindows.reveal`, answering the
open-documents event every app's Show in Finder sends, so revealing in the active pane is a
Searcher change.

#### 39a. Track table and status bar

- [x] **39a.1 Row lines come back.** Double row lines are drawn again. They get darker, and Row
      Lines off doesn't remove them all. Reproduce it first (Row Lines, Alternating Rows and
      glass on and off, toggled several times), find what draws the second line, and fix that.
- [x] **39a.2 No lines over art.** Row lines show through the album art in the art column
      (owner's screenshot: the lines run across a snow photo, row by row). The art covers the
      lines of the rows it spans.
- [x] **39a.3 Status bar border.** The bottom status bar gets a top border of the same gray as
      the table header's bottom border.
- [x] **39a.4 Status bar art margin.** The art's leading margin equals its top and bottom
      margins, which makes it smaller than it is now.
- [x] **39a.5 Dismiss All.** The Library Problems window gets a Dismiss All button, which
      dismisses every row, selected or not.

Plan, part 39a:
- Probe (done before this plan, in a throwaway test rendering the rows' layers): AppKit gives
  each row view its row line as a subview of its own, set up only when the row is added. A
  change of `gridStyleMask` reaches no row already made, so Row Lines on shows nothing until
  rows are made again, and off leaves the lines on the rows made while it was on. That subview
  also lies over the cells, so it crosses the art.
- Row lines (39a.1, 39a.2): `MarkedRowView` (DisplayText) draws a 1-pt line in the separator
  color at its bottom edge, in its background, when told to, so the cells and the art draw
  over it. The track table stops asking AppKit for horizontal grid lines; `apply` and each row
  view the table makes take the setting, and a toggle redraws the rows on screen. Column Lines
  stay AppKit's. Tests: in a window, toggling Row Lines several times with Alternating Rows and
  the glass's translucent rows gives every row on screen exactly the line the setting says,
  read from the drawn rows; art spanning rows covers their lines; the row view draws its line
  only when set.
- Status bar border (39a.3, LibraryBrowser): a 1-pt separator-colored line along the top of the
  status bar's material, inside its height, in both styles and on glass. Tests: the line is
  there at the top at 1 pt in minimal, tall and glass, and the bar's height doesn't change.
- Art margin (39a.4): when the bar's leading side starts with the art (no scan progress
  showing, the art first in the first leading column, aligned leading), the bar's leading inset
  is `StatusBarLayout.artInsetPoints`, the art's top and bottom inset, instead of the spacing.
  `CenteredRow` (BarView) gains a settable leading inset. Tests: the art's leading margin equals
  its top margin in both styles; with the scan progress showing, or the art elsewhere, the
  inset stays the spacing.
- Dismiss All (39a.5): `ProblemAction.dismissAll`, whose rows are all the window's rows rather
  than the selection, enabled while there are any; `LibraryBrowser.fix` dismisses them as
  Dismiss does. Tests: the button acts on every row with none or some selected, and it
  dismisses them in the library.
- Order: row lines, border, art margin, Dismiss All, each its own commit through
  `./scripts/check`, then the Result.

Result, part 39a: shipped 39a.1 to 39a.5. Cause of 39a.1 and 39a.2: AppKit's row line is a
subview each row view sets up only as the table adds it. Toggling Row Lines reached no row
already made, so on showed nothing and off left lines behind. Rows reused from the pool got the
line on top of their cells, across the art. `MarkedRowView` now draws the line in its background
and the table sets it on every row. Rendered-layer tests cover both. A second line one point
above, the reported double line, didn't show in any toggle sequence the tests ran, glass
included. With AppKit's horizontal grid gone, no AppKit line is drawn now, and none is drawn
below the last row either. The status bar's top border uses the separator color. That matches
the header's line on glass. Off glass, macOS 26 draws the header cell's line about twice as
dark (measured 204 against 230 on white), in a color AppKit doesn't name, so the owner should
compare the two. Art that starts the bar now sits 3 pt from its left, top and bottom. Dismiss
All dismisses every listed row (ADR 0059 amended). `./scripts/check` passes except
`glassLeavesTheSavedLayoutAsItWas` (sidebar width 180 saved as 172), which fails the same way on
`main` on this Mac. `theStatusBarsArtOpensTheViewer` fails when run alone, on `main` too, and
passes in the full suite. Pending: checking these on screen in the app, light and dark, glass
on and off.

Rebased onto phase 38 on 2026-11-04: phase 38b's `decorate` already draws every row's lines in
its background, so the row-line commits of 39a.1 and 39a.2 were dropped for it.

#### 39b. Toolbar status

- [x] **39b.1 Empty when nothing plays.** With nothing playing, the toolbar status shows no art
      box, no "Not Playing" and no seek bar (`s1205`), only the toolbar's own background. The item
      keeps its size, so the toolbar doesn't move when a track starts.
- [x] **39b.2 A title line like Swinsian's.** A Title Line part shows one line built from a
      template, `appearance.headerTitleFormat`, default `{title} by {artist} from {album}`,
      as Swinsian's toolbar does ("FI3AC2384210 by Aleksi Perälä from Alithia E'"). Its fields
      are those the header already shows. When a field is empty, the text before it goes too, so
      no "from" is left hanging. An unknown field is a problem with the setting. The part is in
      the tray, and the default layout doesn't change.
- [x] **39b.3 Order.** In Settings ▸ Appearance, Toolbar Status Layout comes before Status Bar
      Layout.

Plan, part 39b (ADR 0085 amended):
- 39b.3 first: the Appearance pane lists its rows in schema order, so `headerStatusLayout`
  moves above `statusBarLayout` in `AppSettings`. A test checks the order.
- 39b.1: `NowPlayingModel.title`'s "Not Playing" stays, since the dock menu, Now Playing info
  and the status bar read it. Only `HeaderStatus` changes: with nothing current and no message
  to show, it hides its row, which keeps its constraints, so the item keeps its size. A message
  with nothing current (no output, a failed track) still shows. The sheet's drawing is
  unchanged. Tests: hidden with nothing playing, the same fitting size, shown on a track and
  on a message.
- 39b.2: `TitleFormat` in Settings, a string setting value like `ReceiverAddress`: it parses
  `{field}`s, with the fields `title`, `artist` and `album`, the header's own text, and
  reports an unknown field or an unclosed brace as its `problem()`. Its line drops an empty
  field with the literal text just before it, and trims the ends. The setting
  `appearance.headerTitleFormat` gets a text row in Settings ▸ Appearance with no UI code.
  `HeaderPart.titleLine` ("Title Line"), a semibold label truncating at its tail, in the tray;
  the default layout is unchanged. `NowPlayingBar` fills it from the model and the format, and
  the app passes the format at launch and on a change. The sheet's drawing fills it from the
  default format with the placeholder track.
- Tests: parsing, every problem, the dropping and trimming rules, the setting's default and a
  bad value refused in the config file; the part's title and that the default leaves it out;
  the bar's line for a track with and without an artist; a format change redraws it.
- Then the ADR amendment, `--snapshot-of headerStatus` and `toolbarSheet`, and the result.

Result, part 39b: shipped 39b.1 to 39b.3 (ADR 0085 amended). With nothing playing the toolbar's
status hides its row and shows only the toolbar's background, at the same height; a message
such as no output device still shows it. The model's "Not Playing" stays for the dock menu, Now
Playing info and the status bar. The Title Line part reads `appearance.headerTitleFormat`
(`TitleFormat` in Settings; fields `{title}`, `{artist}`, `{album}`; `{{` and `}}` for braces).
An empty field drops the text before it, and at either end of the line the text after it too,
so nothing dangles; an empty line hides the part. An unknown field, an unpaired brace or an
empty format is a setting problem. Settings ▸ Appearance shows the format as a text row, and
lists Toolbar Status Layout and Toolbar Title Line before Status Bar and Status Bar Layout. A
review round fixed the no-output reason being blanked by a redraw, the dangling text, the
braces, empty formats and lines, and the sheet's drawing ignoring the owner's format.
`./scripts/check` passes. Checked in `--snapshot` (the empty status, the sheet with a Title
Line layout, the Appearance pane) before the review round; the Title Line with a track playing
was checked by tests, not on screen.

#### 39c. Layout builder

- [x] **39c.1 Colors.** The preview's columns and parts are too dark (`s4118`). They take the
      settings window's own colors: the sunken box's background, and lighter part tokens.
- [x] **39c.2 Live drag.** While a part is dragged, the others move aside to show where it will
      go, before it's dropped.
- [x] **39c.3 Move columns.** Each column has a handle that drags the whole column, parts and
      settings, to another place, moving the others aside as in 39c.2.
- [x] **39c.4 Empty columns save.** A column with no parts is allowed. It takes its width and
      draws nothing. "Drag a part into leading column 1 to save the layout" goes.
- [x] **39c.5 Plain errors.** Problems read in plain words, naming the column by where it is
      ("the first column on the left"), without the file path or key in the builder. Art alone in
      a stacked column isn't a problem; that's the error the owner hit, from the default header
      layout with Stack Parts on. The builder refuses a change that would make a problem, and says
      why in its hint line.
- [x] **39c.6 Reset to Default.** Each builder has a Reset to Default button that puts its
      setting back to its default.

Plan, part 39c (ADR 0085 amended):
- Settings: `BarLayoutProblem` loses the empty column. The art is a problem only in a stacked
  column that holds other parts too. `BarPlace` reads by position ("the first column on the
  left", "the center column", "the second column on the right", counted left to right on each
  side), and problems name parts by their titles, so they read as sentences. `problems` takes
  which parts fill the height, so the builder can check its `BarLayout<String>` with the parts
  `SettingKind.Bar` marks.
- SettingsWindow: `BarBuilderModel` checks every edit before it saves and refuses one that
  would make a problem, keeping the layout and saying why in the hint line, without a path or
  key. The empty-column hold-back goes, so an added column saves at once. Reset to Default
  saves the setting's default, which the row carries, through the same patch. A side column
  moves to another place; the center column stays where it is, and a column dropped past it
  goes to the other side. `BarBuilderView` draws in the settings boxes' colors (their fill
  and separator border, chips like the shortcut recorder's), draws a dragged part's or
  column's layout as it would be if dropped, and gives each side column a grab handle.
- Renderers: an empty column keeps its width and draws nothing in the status bar and in the
  toolbar's status; tests check both, and that the art alone in a stacked column lays out.
- Tests: the problems' wording and the art rule; a refused edit leaves the layout and says
  why; an empty column saves; Reset to Default saves the default; part and column drags, live
  and on drop, across the center; the preview's colors. Order: 39c.4, 39c.5, 39c.6, 39c.1,
  39c.2, 39c.3, then the ADR. `--snapshot` of the builder for the colors.

Result, part 39c: shipped 39c.1 to 39c.6 (ADR 0085 amended). The preview is drawn in the
settings boxes' colors with light part fields. A dragged part moves the others aside before the
drop, and each side column drags by a handle; the center column stays put, and a column dragged
past its middle goes to the other side. Empty columns save and keep their width in both bars.
Problems read in plain words with the column by position; the art alone in a stacked column is
allowed; the builder refuses an edit that would make a problem and says why in its hint line.
Reset to Default saves the default through the same patch. `./scripts/check` passes except
`glassLeavesTheSavedLayoutAsItWas`, which fails the same way on `main` before this part. The
drags were tested through the view's drag and drop calls and checked in `--snapshot`, not by
hand with a mouse.

Plan: written by the orchestrator under each part before it runs, as in phase 37.

## Later

Not phases yet. Each becomes one when the owner asks.

- **Mini player:** a small window with art, transport and seek.
- **Library quality audit:** a background pass that finds upsampled "hi-res" files, lossy files
  transcoded to FLAC, clipping, true peak and a dynamic range score, stored in the index and
  usable in smart playlists. The same pass could draw a waveform for the seek bar.
- **Discogs lookup:** fetch release data from the Discogs API and offer it as a tag edit the user
  confirms in the tag editor, written through `TagWriter` (ADR 0020). Start with files that
  already carry `DISCOGS_RELEASE_ID` (39 of the 159 reference files), which need one
  `GET /releases/{id}` and no matching. Searching for other files needs a Discogs token, which
  breaks the no-secrets rule, so the owner decides how a user-supplied token is stored first.
  Candidates are matched per album by track count and durations, with Discogs positions
  (`A1`, `CD2-4`), headings and `Artist (2)` names folded. It is the app's first outbound
  internet connection, so ADR 0025 gains rows for it; responses are paced by the rate-limit
  headers and cached in the index, and tests use recorded JSON. MusicBrainz with AcoustID is the
  alternative to weigh: no key, and it matches by fingerprint.
