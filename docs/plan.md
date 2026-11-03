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
| Resident memory with the library loaded, after scrolling every row with art | < 120 MB | < 250 MB |
| Scroll every row by scroll-bar drag, a screenful a step with the Album Art column shown, time to scroll and draw a step (p95; phase 28); the old Mac figure is an estimate until its checkpoint | < 16 ms | < 33 ms |
| CPU while playing 24/192 FLAC | < 3 percent of a core | < 5 percent of a core |
| Underruns in a 1-hour playback soak (`--soak 3600`; 20 s by default), with a full fixture scan every 5 minutes and a search every second | 0 frames | 0 frames |
| Memory growth in that soak, from the first scan trough after minute 5 to the last (30 s after each scan ends) | < 10 MB | < 10 MB |
| Gap between same-format tracks | 0 samples | 0 samples |
| Track change that switches sample rate | < 500 ms | < 500 ms |
| CPU when idle, the library window open and nothing playing, over a minute after the app reports its launch rescan done (`--report-launch`) and a 5 s settle; the old Mac figure is an estimate until its checkpoint | < 0.1 percent of a core | < 0.1 percent of a core |
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
