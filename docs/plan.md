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

Set by the owner on 2026-10-30 and 2026-10-31:

1. Finish phase 5. Its 2015 MacBook Pro checkpoint stays pending.
2. Phases 6, 7, 8, 11 and then 15, each through its gate.
3. Write the [hardening sub-plan](#14-hardening), committed as `docs: plan phase 14`, then run
   14a onward, each through its gate.
4. Phase 9 last, if time is left, against a simulated renderer only. Nothing contacts the Denon
   or any real device: no SSDP on the LAN, no HTTP or receiver control to real addresses. Its Denon checkpoint stays
   pending.
5. Skip 10, 12 and 13 for now. Phase 10 adds pairing tokens, a secret, so the owner decides how
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
| Search-as-you-type, per keystroke (p95) | < 30 ms | < 80 ms |
| Re-sort the track table by any column | < 100 ms | < 250 ms |
| Full scan of the fixture library, local SSD | < 60 s | < 180 s |
| Rescan with no changes, on the NAS | < 30 s | < 60 s |
| Scan 3,000 fixture files on a simulated NAS (2 ms per operation, 16 at once), tuned readers | < 4 s | < 8 s |
| Scan 2,000 fixture files on a slow simulated NAS (about 60 ms per file with a long tail, 45 ms per listing, 24 at once), tuned readers, ending at 16 or more and within 80% of the best fixed level | < 10 s | < 20 s |
| Rescan with no changes, fixture library, local SSD | < 5 s | < 15 s |
| Library database for the fixture library | < 60 MB | < 60 MB |
| Memory a scan of the fixture library adds, at its peak | < 50 MB | < 50 MB |
| Browser pane query: genres, artists, albums (p95) | < 20 ms | < 60 ms |
| Palette results per keystroke, Go to Item over every fixture track (p95) | < 30 ms | < 80 ms |
| List a smart playlist of six rules over every fixture track (p95); the old Mac figure is an estimate until its checkpoint | < 50 ms | < 150 ms |
| Resident memory with the library loaded, after scrolling every row with art | < 250 MB | < 250 MB |
| CPU while playing 24/192 FLAC | < 3 percent of a core | < 5 percent of a core |
| Underruns in a 1-hour playback soak (`--soak 3600`; 20 s by default) | 0 frames | 0 frames |
| Gap between same-format tracks | 0 samples | 0 samples |
| Track change that switches sample rate | < 500 ms | < 500 ms |
| CPU when idle (not playing) | ~0%, no timers firing faster than settings allow | same |
| Load and validate settings, every key changed | < 5 ms | < 20 ms |
| Generate the fixture library | < 30 s | < 120 s |
| Rerun the fixture generator with nothing to do | < 10 s | < 30 s |
| Parse every fixture file's tags, first read in a fresh process | < 5 s | < 20 s |
| Tag journal: write a 1000-file batch with 1 MB art each, flushed per file | < 20 s | < 60 s |
| Play timeline: one page of 200 plays, 1M synthetic plays over the fixture library (p95) | < 5 ms | < 15 ms |
| History, one row per track played, 1M synthetic plays (p95) | < 30 ms | < 80 ms |
| Record a play, 1M synthetic plays (p95) | < 2 ms | < 6 ms |
| History table plus its index, 1M synthetic plays | < 40 MB | < 40 MB |

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
      network roots use a polling rescan at a configurable interval (default 15 minutes, never
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

- [ ] **HTTP server** primitive on Network.framework: serves files with `Range` support, bound to
      the LAN, and only to paths the library knows about.
- [ ] **SSDP discovery** of MediaRenderers, and fetching each renderer's description and
      `GetProtocolInfo` to learn what formats it accepts.
- [ ] A **UPnP output** that implements the phase 4 output protocol, using AVTransport (set URI,
      play, pause, seek, `SetNextAVTransportURI` for gapless) and RenderingControl (volume). It
      sends original file bytes. Formats the renderer can't take are reported, not transcoded.
- [ ] Renderers appear next to HAL devices in the output picker.
- [ ] Info.plist gets `NSLocalNetworkUsageDescription` and Bonjour entries.
- [ ] **Receiver control** over Denon's AVR control protocol: plain-text commands ending in a
      carriage return, on TCP port 23. It works on any input, not only while the Denon plays the
      UPnP stream. The receiver's address comes from SSDP discovery.
      - Commands in the registry: receiver volume up, down and set (`MV`), mute (`MU`), sound mode
        with Pure Direct, Direct and Stereo (`MS`), input (`SI`), power (`PW`).
      - The receiver pushes a status line whenever its state changes, including from its own
        remote or front panel. The model follows those lines, not what the app last sent.
      - At least 50 ms between commands, as Denon's spec asks, so held volume keys are throttled.
      - Many Denon models accept one control client at a time. When the connection is refused or
        dropped, the UI says the receiver is unreachable; it doesn't retry silently.
      - Tests run against a simulated receiver on loopback.
- [ ] **Hardware checkpoint (owner):** play 16/44.1, 24/96 and 24/192 FLAC to the Denon. Report
      what its display shows, gapless behavior, seek, and volume. With the receiver's Network
      Control set to Always On, switch Pure Direct on and off, change volume and input from the
      app, then from the Denon's remote, and report whether the app follows.

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

- [ ] DSF and DFF parsers, and DSD in the library (rate shown as DSD64, DSD128 or DSD256).
- [ ] DoP packing in Swift on the decode thread, with markers 0x05/0xFA in the top byte. The IO
      proc stays a byte copy.
- [ ] DoP carrier selection: DSD64 at 176.4 kHz, DSD128 at 352.8 kHz, DSD256 at 705.6 kHz. A
      device without the rate is refused, never converted.
- [ ] DSD to the Denon over UPnP, if its `GetProtocolInfo` lists it.
- [ ] **Hardware checkpoint (owner):** DSD64, DSD128 and DSD256 on the ADI-2. Its DSD indicator
      lighting is the bit-perfect proof for the whole HAL path.

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

- [ ] **Identity:** a stats table `paths` (`id INTEGER PRIMARY KEY`, `path TEXT UNIQUE NOT NULL`,
      `added_seconds REAL NOT NULL`). The scanner looks a path up there, or inserts it, and uses
      that ID as `files.id`. `added_seconds` moves off `files`. Rows are never deleted, so a file
      that leaves the index and comes back gets its old ID and Date Added. A renamed or moved file
      is still a new path, as now.
- [ ] **Stats by ID:** `plays`, `ratings`, `history` and `playlist_entries` key on `path_id`
      instead of `path`. Joins from `files` become `files.id = path_id`. Smart rules, sorts,
      playlist entries whose file left the index (still counted on the status line) and the
      `files.path IN (…)` conditions all move over. The stats SQL changes, so the owner's
      current stats are dropped once, which the pre-release rule allows.
- [ ] **History shape:** `history (id INTEGER PRIMARY KEY, path_id INTEGER NOT NULL, played_at
      INTEGER NOT NULL)` in whole seconds, with an index on `path_id`. Rows are append-only, so
      `id` order is time order and no index on `played_at` is needed.
- [ ] **History view** (one row per track) reads `plays` where `last_played_seconds` is set, so
      its cost follows the number of tracks played rather than the length of the log.
- [ ] **Play timeline:** every play, newest first, loaded 200 at a time by key
      (`WHERE id < :last ORDER BY id DESC LIMIT 200`), never `OFFSET`. A new play is added to the
      top of the loaded rows; a library change re-resolves only the loaded rows. Plays of files
      no longer in the index show as missing rather than being hidden, so pages stay full. The
      track table identifies rows by track ID (ADR 0018), and the timeline repeats tracks, so its
      rows need their own identity (the history ID). Plan how selection, play, drag and ⌘⌫ act
      on a timeline row before building the UI, and record the choice in the ADR. Where it lives
      (a second History mode or its own sidebar item) is the implementer's call, per ADR 0012.
- [ ] **Tests:** IDs and Date Added survive an index rebuild and a file leaving and coming back;
      stats, ratings and playlist entries follow the ID; the timeline pages are stable while new
      plays arrive; missing files show as missing.
- [ ] **Bench**, with the budgets added to [Performance budgets](#performance-budgets): with 1M
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
