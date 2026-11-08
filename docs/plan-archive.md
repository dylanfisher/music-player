# Build plan archive

The finished phases of [plan.md](plan.md), moved here as they were when they shipped. Read a phase
here for its implementation plan, its Result line, or the full text of an owner checkpoint that
plan.md lists as pending. Nothing here is open work: what's still to do is in plan.md, and a
checkpoint ticked here only after it's cleared there.

Phase numbers are kept, so "phase 23" in an ADR, a commit or a comment means the phase of that
number here. Phases 10 and 13 aren't built and are still in plan.md.

## Run orders

The run orders the owner set while these phases ran.

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

After the rebase onto phase 38, `TitleFormat` went: the Title Line is a `TitleTemplate`, the
window title's type (ADR 0087), with its ten tokens, its help button and one rule for empty
fields, the text before a field being the field's. The window title changed with it: a run of
empty fields now keeps the separator before the next field shown, not the one after the last.

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

### 40. Owner feedback, 2026-11-04 evening

**Done; owner check pending.** `./scripts/check` passes clean on main after all four parts.
Parts 40c and 40d each wrote an ADR 0089; 40d's became 0090 in the rebase.

The owner's feedback from trying phases 38 and 39. The two progress bar screenshots are in
`~/.claude/projects/-Users-dylanfisher-projects-music-player/feedback-2026-11-04/`. The four
parts run in parallel worktrees and rebase onto main in order a, b, c, d.

Measured from the screenshots: the bar's track (231) and played part (120/170/235) already
match Swinsian's. The box around them is what's darker: ours fills 234 on a 245 toolbar, a
darker box; Swinsian's fills 250 on 242, a lighter one.

#### 40a. Settings that don't apply

- [x] **40a.1 Row Line Color.** Choosing a color doesn't change the row lines.
- [x] **40a.2 Album Line Color.** Choosing a color doesn't change the album lines.
- [x] **40a.3 Default buttons.** The color rows' Default buttons do nothing.
- [x] **40a.4 Window title as you type.** The window title follows its setting as it's typed,
      without pressing Return or leaving the field.

Plan, part 40a:
- Probe (a throwaway test with a real `ConfigStore` behind the pane, the well made active and
  the shared color panel's color set, as a pick in the panel does): the well takes the color
  and shows it, but sends no action, not on the change, not when the panel closes, not when
  the well lets go. `isContinuous = false` on an `NSColorWell` means the panel never reaches its
  target. So nothing is saved: the table's chain (`TableAppearance.keys`, `setTableAppearance`,
  `decorate`) is never started, and a test already covers it from a changed appearance to the
  rows' lines. With the well continuous, the same probe saves the color.
- 40a.3 has the same cause: Default is enabled only while the setting has a color, and none was
  ever saved, so it stayed disabled beside a well showing the picked color. Pressed with a color
  saved, it sets null and the well goes back to the grid color, as the probe showed.
- Colors (40a.1 to 40a.3, one commit, one cause): the well is continuous, and the pane saves its
  color once it has stopped changing for 0.25 s, so a drag in the panel writes the file once
  per pause, not per step; a color equal to the saved one isn't saved, and Default cancels a
  save still waiting. Tests: a color set in the panel with the well active is saved after the
  pause and enables Default; Default then saves null and puts the grid color back in the well.
- Template rows (40a.4): `GeneralPane` saves a template row on each change of its text whose
  template parses (`TitleTemplate`'s `problem()`), so the window title and the Title Line follow
  as they're typed; text equal to the saved template isn't saved, so no write per keystroke
  that changes nothing. While the text doesn't parse, nothing is saved and a red line under the
  field says why; it goes when the text parses or the edit ends, which puts back the saved
  template as now. Tests: typing saves while the field is still being edited, for the window
  title and the Title Line; an open brace saves nothing and shows the problem; unchanged text
  calls no save. The title's following its setting is already tested.
- Order: this plan, colors, templates, each through `./scripts/check`, then the result.

Result, part 40a: shipped 40a.1 to 40a.4. Cause of 40a.1 to 40a.3: the color wells weren't
continuous, and an `NSColorWell` like that takes the panel's color and shows it but sends no
action, so no color was ever saved. The table's lines never changed, and Default stayed
disabled because there was no saved color to clear. The wells are continuous now, and
the pane saves a color once it has stayed the same for 0.25 s, so a drag in the panel writes
the config file once per pause. Default cancels a save that hasn't run yet. A template row
(Window Title and Toolbar Title Line, through the same code) saves on each change whose text
parses and differs from what's saved. While the text doesn't parse, nothing is saved and a red
line under the field says why. Leaving the field with such text puts back the saved template,
as before, with the refusal in the pane's error line. `./scripts/check` passes; one earlier run
failed `glassOnThenOffLeavesTheWindowAsAFreshOne` and two renderer tests, which pass on their own
with and without these changes, and passed in the next runs. Checked by tests only, nothing on
screen: the panel pick with the well active, Default, and typing in both template rows with
the field still being edited. The rest of each chain, a changed setting reaching the rows'
lines and the window title, was already tested. For the owner: pick a color in the panel and
drag the opacity, press Default, and type a title template with an open brace on the way.

#### 40b. Progress box and glass headers

- [x] **40b.1 A lighter progress box.** The box around the toolbar status's seek bar is lighter
      than the toolbar, as Swinsian's is (250 on 242 in light), not darker; dark mode gets the
      same relation.
- [x] **40b.2 Frosted glass headers.** On window glass the table headers are now fully
      transparent. They get a frosted backdrop, blurring what scrolls under them, as Finder's do.

Plan, part 40b:
- 40b.1, NowPlaying: Swinsian's box has no border; its edge goes straight from 242 to 250.
  `SeekBox` fills white at 60% in light, which makes 250 on 242 (and 251 on our 245), and at
  5% in dark, a step of about 13 levels on the dark toolbar, and draws no border. White over
  the bar, not a color of its own, keeps it a step lighter on glass. The status bar's box is
  the same view and changes with it. Test: the box drawn over Swinsian's 242 gives 250, over
  the dark window color a step of 4 to 20 levels, and nothing darker at its edge.
- 40b.2, App: a probe showed `cacheDisplay` draws a visual effect view as a flat fill, so only
  the window as the screen shows it tells a blur from an opaque header; a test's own window can
  be read with `CGWindowListCreateImage` (still exported, though Swift can't call it from the
  macOS 15 SDK on) without the screen recording permission. `GlassHeaderView` holds an
  `NSVisualEffectView`, header material, within window, following the window's active state as
  the glass's backdrop does, and a titles view over it that draws the line and the cells: a
  view's subviews draw over its own drawing, so the header itself draws nothing. The header
  takes every click, and any redraw of it redraws the titles. The material goes with the header
  view when the glass goes off. Test: over red under a cleared list, the header's pixels on
  screen change the red and let it through, in light and dark, over a column added on glass
  too; the header and its menu back after.
- Checks: `./scripts/check`, `--snapshot` light and dark, glass on and off (the box against
  the screenshot), the live resize bench by name with the glass on, against main.

Result, part 40b: shipped 40b.1 and 40b.2 (ADR 0087 amended). The seek box is white at 60% in
light and 5% in dark, with no border; `--snapshot` measures 250 on the 243 toolbar in light,
Swinsian's 250 on 242, and 66 on 53 in dark, the same on glass, with the track still 231. The
status bar's box is the same view and lightened with it. On glass each list's header holds a
header material within the window under a titles view; read off the screen over red, the
header comes out 0.99/0.87/0.86 in light and 0.35/0.20/0.18 in dark, neither the red nor
opaque. An inactive window's header is a flat color, white in light, as the glass's backdrop
goes flat. `--snapshot` draws the material flat, so the blur itself waits for the owner's eye.
`./scripts/check` passes; live resize with the glass on, p95 20.9, 8.0 and 16.9 ms against
main's 18.0, 17.2 and 17.1 (budget 35), with a few slowest frames over 100 ms against main's 37
at most. The 2015 MacBook Pro and macOS 12 to 15 wait for the owner check.

#### 40c. Builder items in Customize Toolbar

- [x] **40c.1 Custom status items.** Customize Toolbar offers Custom Status 1, 2 and 3 beside
      Status. Each is a now-playing bar with its own layout, built in the same builder from its
      own row in Settings ▸ Appearance, and can go anywhere in the toolbar. AppKit shows each
      custom item at most once, so there are numbered slots rather than one item added many
      times.

Plan, part 40c (ADR 0089, amending 0055 and 0085):
- Probe (done before this plan): the builder, its row and its window work on any `.barLayout`
  setting by key, with no code of their own per bar, and the Appearance pane lists rows in
  schema order. A list of three layouts in one setting would need the builder to edit one
  element of a list and the pane to show three rows for one setting; three settings need
  neither. `NowPlayingBar` follows the engine and owns the timer and the seeks, so a second
  bar on the same model would apply every update twice and tick twice.
- Settings: `ToolbarItem` gains `customStatus1`, `customStatus2` and `customStatus3`, after
  `status`, not in the default set. Three settings, `appearance.customStatus1Layout` to `3`,
  "Custom Status 1 Layout" and on, each a `BarLayout<HeaderPart>` checked as the status's is,
  after Toolbar Status Layout in the schema. Their default is Swinsian's centered line: the
  Title Line over the seek bar, stacked in a flexible center column, centered. The slots' Title
  Line reads `appearance.headerTitleFormat`, the one template for every Title Line.
- NowPlaying: `NowPlayingBar` gains `customStatuses`, one `HeaderStatus` per slot, each with its
  own art, labels and `SeekBox`, filled, seeking and ticking with the status from the one model
  and engine. `HeaderStatus.fixedWidthPoints(of:)` is a layout's width when every column is
  fixed: the widths and the spacing between the columns.
- App: `MainToolbar` takes the slots' views and their layouts. A slot's item is its width when
  its layout is all fixed, and otherwise sized as the status is (280 points up to 560 beside a
  flexible space, or the free width), at its view's height. Only the status is centered. The
  sheet draws each slot with `statusDrawing` from its own layout and the owner's template. The
  app reads the three settings at launch and applies a change to the slot's views, its drawing
  and its size. `--snapshot-of` gains the first slot's builder.
- Tests: the slots are allowed and not in the default set, with labels and drawings; the three
  settings' defaults, order, and a bad layout refused in the config file; a slot's layout is
  drawn in the sheet; a fixed layout sets the item's width and a flexible one the status's
  range; a layout change resizes the slot; the status and two slots showing the same track,
  times and seek fraction at once; a saved toolbar with a slot comes back.
- Order: settings and items, the bar's slots, the toolbar and app wiring, then the ADR,
  `--snapshot` of the sheet, the toolbar with slots placed and the slot's builder, and the
  result.

Result, part 40c: shipped 40c.1 (ADR 0089, amending 0055 and 0085). Customize Toolbar offers
Custom Status 1, 2 and 3 after Now Playing, none in the default set; each lays out from its own
setting, `appearance.customStatus1Layout` to `3`, whose rows follow Toolbar Status Layout in
Settings ▸ Appearance and open the same builder, unchanged. The default is the Title Line
centered over the seek bar. Every slot's Title Line reads `appearance.headerTitleFormat`. The
slots' views hang off the one `NowPlayingBar`, so one engine follower fills, ticks and seeks
them all. A slot of fixed columns is exactly their width; one with a flexible column is sized
as the status is. Only the status is centered. The sheet draws each slot from its layout, at its
width when fixed, which now holds for the status's drawing too. In one commit rather than
three, since `scripts/check`'s surface step fails a public setting no other module reads yet.
`--snapshot-of` didn't gain the slot's builder: it is the same builder window as the status's,
reached the same way. Checked in `--snapshot`: the sheet with all three slots drawn (the
default, a fixed art beside title and format, and the default again), the Appearance pane's
three new rows, and the window with two slots placed, empty since nothing plays in a snapshot.
The slots with a track playing were checked by tests, not on screen. `./scripts/check` passes.

#### 40d. Undo and redo plays

- [x] **40d.1 One history for plays and places.** ⌘[ and ⌘] (Back and Forward) step through
      one history whose steps are the sources visited and the tracks played, each kept with
      the window's state at that moment: source, browse and search, selection and scroll. Back
      over a play puts the previous track back, at the position it had when it was replaced,
      playing if it was playing, and the window as it was. Forward redoes it. So an accidental
      play is undone with ⌘[.

Plan, part 40d (ADR 0090):
- Probe (done before this plan): `PlayCommand` is the `--play` terminal player; the window's
  plays reach the engine through `LibraryBrowser.play` and `playStart`, which the app wires to
  `PlaybackEngine.play(starting:)`. Those come from a double-click or Return in the track table
  or the timeline, Play (the menu and its key), and `music-player play`. ⌘K only shows things.
  Next, Previous, the media keys, a double-click in the queue panel and the end of a track move
  within the queue the engine already has, and none goes through the browser. `BrowserModel`
  keeps `SourceHistory`, the sidebar sources shown, which a change appends when it's applied.
  The window's selection and scroll aren't kept anywhere.
- What a step is (the ADR): a source shown, as now, or a play that replaces the queue, from
  the browser. Advances at a track's end, Next, Previous, the media keys and queue panel jumps
  are no steps of their own: they fold into the play that started the queue. What a step
  replaced is whatever played when the next step was taken, so Back after an album has played
  on goes to the track it had reached, at the place it had reached. Steps of their own would
  make an accidental play take a press per track it had advanced through to undo, and put
  every track of an evening's album between a source and the one before it.
- Playback: `PlaybackSpot` (Playback) is a queue, the entry in it, seconds in, and stopped,
  playing or paused. `PlaybackEngine.spot()` reads it; `restore(_:)` replaces the queue and
  loads the entry at those seconds, playing or paused, keeping the device open as
  `play(starting:)` does, or stops on the queue for a stopped spot. Tests: restore playing,
  paused and stopped, with the calls the output gets.
- History: `StepHistory` (LibraryBrowser) replaces `SourceHistory`. Each step keeps the window
  as it was left (`WindowPlace`: the filter's source, column selections and search, the
  selected track IDs and the first visible row with its offset), and a play also what it
  replaced and what it played. Leaving a step, by a new step, Back or Forward, saves the
  window into it; crossing a play also saves the playback on the side being left, so Forward
  replays B from where Back left it. A new step after Back drops the steps ahead. Showing the
  source already shown adds nothing, and a deleted playlist's places go as before. In memory
  only; the saved source still starts it at launch.
- Browser: `BrowserModel` records a place when a change that visits a source is applied, with
  the list's selection and scroll read from the table first, and shows a step's window by
  setting the source, the column selections still shown, and the search. `LibraryBrowser`
  records a play before handing it to the app, with the playback read from
  `currentPlayback`, and on Back or Forward restores the window (sidebar, search field,
  selection, scroll) and hands the playback to `restorePlayback`; the app wires both to the
  engine. Back, Forward and recording run one after another, so a quick second ⌘[ reads the
  playback the first one put back. The timeline keeps its source only; its rows are plays,
  and it loads afresh when shown. Menu titles stay Back and Forward; their enabling reads the
  merged history.
- Tests: the history's steps, crossing, dropping and removal as values; in the browser with
  stand-ins for the engine: play A, play B, Back restores A where it stopped, playing, with the
  window's search, selection and scroll as they were, Forward plays B again; a source change
  between them is a step of its own and leaves playback alone; a new play after Back drops
  Forward; `canGoBack` and `canGoForward` follow plays too.
- Order: the engine's spot and restore, the history and the browser together (one change,
  since `SourceHistory` goes), the app's wiring, then the ADR and the result.

Result, part 40d: shipped 40d.1 (ADR 0090). ⌘[ and ⌘] step through one history of sources
shown and plays from the browser: a double-click or Return in the track table or the timeline,
Play, and `music-player play`. Track ends, Next, Previous, the media keys and queue panel jumps
fold into the play that started the queue, so Back over a play puts back whatever was playing
when it started, at the place it had reached, playing or paused as it was, and one ⌘[ undoes
an accidental play however far it had advanced. Back over the first play of a session stops.
Each step keeps the window as it was when last left (source, search, column selections,
selected tracks, first visible track), so Back over a play shows the window as it was just
before it, and a source shown again returns to where the user got to in it; the timeline keeps
its source only. Forward plays an undone play again from where Back left it. A new step after
Back drops the steps ahead. `PlaybackEngine.restore` loads the track at its place without
closing the device; with shuffle on, the rest of the restored queue is shuffled again. The
history is in memory only. Menu titles are unchanged; their enabling follows the merged
history. `./scripts/check` passes. Found on the way, not fixed: the LibraryBrowserTests process
exits with status 0 partway through a full run (about 70 of its 198 tests report), on `main`
too, so the gate doesn't see the rest; run alone, `aRefreshKeepsTheSelectedRowsByID` fails on
`main` (a sort reports `.sorted`, the test expects `.user`). The new browser tests pass when
run by name. Not checked in the running app with a real output device.

### 41. Owner feedback, 2026-11-04 night

**Done; owner check pending.** All six parts are on main (ADRs 0091 to 0095). The parallel
parts each took the next free ADR number, and the rebase renumbered them 0092, 0093 and 0095.
`./scripts/check` on main fails only tests that don't come from this phase:
`theGlassHeadersAreFrosted` reads the screen and fails on `main` before 41b too, from the
second run of the night on, likely because the display slept.
`aPeerOfAnotherUserIsRefusedBeforeItsRequestIsRead` failed once in the final run with "Broken pipe" in place of "closed" and passed five times
run by name; nothing in phase 41 touches LocalSocket. Upgrading resets the window layout
once: `browser.source` left state.json for `playback.resume` (41f), and a state file of
the old shape is discarded.

The owner's feedback from trying phase 40. The screenshots weren't kept; what they showed is
written into each item. Part 41a runs on main first. Parts 41b, 41c and 41d then run in parallel
worktrees and rebase onto main in order b, c, d. Parts 41e and 41f run after them, also in
parallel. The owner's answers: Swinsian's Library Folder (copy added tracks, keep the folder
organized, Move and Consolidate) is not built, since it would move and rename music files (see
Later). Play state is restored paused, on every Mac. Sonos is the speaker family the output
names come from. Soft undo steps over the selection and the view it was in.

#### 41a. Crash and sidebar

- [x] **41a.1 Crash in the browser.** An arrow key in a browser column stopped the app
      (`MusicPlayer-2026-11-04-230450.ips`, an exclusivity violation in
      `PanesController.tableViewSelectionDidChange`).
- [x] **41a.2 Plain All rows.** The columns' All (1234) rows aren't bold.
- [x] **41a.3 No rename on click.** A click on a selected playlist's name in the sidebar doesn't
      start a rename; its context menu's Rename (or Return) does.

Result, part 41a: shipped 41a.1 to 41a.3. Cause of 41a.1: `routeKey` took the list's
`TypeSelect` as `inout` and ran the key command inside that access. The command moved the
column's selection, and the selection change reset the same `TypeSelect`, a second access while
the first was open. Any arrow key in a column did it, not a track change. `TypeSelect` is a class
now, so the reset doesn't overlap anything. The track table had the same shape. Test: a key
command that moves a column, routed through the column's key handler; it stops with "Fatal
access conflict detected" on the old code.

#### 41b. Track table rows

- [x] **41b.1 Shorter compact rows.** Compact rows are 17 pt apart (34 px at 2x); Swinsian's
      are 16 pt (32 px). Text stays centered.
- [x] **41b.2 Album lines across the art.** The album line runs under the Album Art column too,
      the only line that does, so albums stand apart; with art hovered, the line stays under
      the art.
- [x] **41b.3 Playing triangle.** A play triangle before the playing track's title.
- [x] **41b.4 Now Playing column.** An optional narrow column, empty except on the playing
      track, which shows a play triangle.
- [x] **41b.5 Playing row color.** A setting for the playing track's row background.
- [x] **41b.6 Timeline columns.** The timeline shows the library's columns, with Played first,
      until the owner changes the timeline's own columns.

Plan, part 41b:
- Probe (done before this plan): Compact is `RowHeight.points` in `TableAppearance.swift`; its
  text is the lists' 11 pt font, one line 14 pt tall, so a 16 pt row still holds it centered,
  and the art's rows follow the row pitch. `MarkedRowView` draws every line from its background,
  clipped out of the art column, and the art cells draw over the row's background, so a line
  drawn there would go under the art wherever an album's art reaches its last row. The hover is
  a subview of the table above the row views. The timeline's columns aren't stored anywhere:
  `TimelineController` builds Played, Title, Artist, Album and Time in code, with no header menu.
- 41b.1: Compact is 16 points. The test that the text fits each height already runs at Compact.
- 41b.2: `AlbumArtCell` draws a line along its bottom, over its art, in the album line's color
  where its row ends an album; the controller sets it with the row view's line, and on the row
  above when the next page is read, as now. Row and column lines stay out of the art column.
  The cell is inside its row view, so the hover still covers it. Tests: an album's last art cell
  has the album line and draws it over its art; with only row lines it has none; the hover stays
  the table's top subview, over the row that draws it.
- 41b.3 and 41b.4 (one change): `TrackColumn.nowPlaying`, "Now Playing" in the header's menu,
  an empty header, 20 points wide, not sortable, not in the default layout. Its cell shows `▶`
  on the playing track's row and nothing elsewhere. The Title cell starts with `▶ ` on the
  playing row only while the Now Playing column is hidden, so the mark shows once. A change of
  the playing track, or showing or hiding the column, redraws those two columns' cells. Tests:
  the mark follows the playing track in Title; with the column shown it moves there.
- 41b.5: `appearance.playingRowColor`, "Playing Row Color", optional like the line colors and
  after them in the schema, so the Appearance pane lists it after Album Line Color with its
  Default button. Null keeps the light gray tint. `MarkedRowView.markTint` replaces the tint
  when set; the bar at the row's edge stays. Test: the playing row's background takes the color,
  and goes back to the gray with null.
- 41b.6: one state key, `browser.timelineTable`, a `TimelineLayout` (Played's width and the
  track columns after it), null by default. Null means the library's columns: Played, then the
  track table's columns in their order and widths, without Album Art, Order and Now Playing,
  which mean nothing for a play; it follows the track table's changes. The timeline gets the
  header's column menu, moving and resizing; the first change the owner makes there (a column
  shown or hidden, moved, or resized by its header) saves its columns, and from then the timeline
  keeps them. A resize by the window's width isn't a change of the owner's. Played stays first.
  Tests: the timeline shows the library's columns and follows them; after a change of its own
  it reports its layout and stops following; a saved layout is shown; the setting refuses an
  album art column, a duplicate and a bad width.
- Order: this plan, then 41b.1, 41b.2, 41b.3 with 41b.4, 41b.5, 41b.6, each through the tests,
  `./scripts/check` at the end, then the result.

Result, part 41b: shipped 41b.1 to 41b.6 (ADR 0092, amending 0088). Compact rows are 16 points;
the 11 pt text is 14 pt tall and stays centered. The album line runs on across the Album Art
column, drawn by the art cell over its art where its row ends an album; row and column lines
still stay out of the column, and the hover, over the row views, covers the line. The playing
track's Title starts with `▶`. Now Playing is a track column, off by default, in the header's
menu, 20 points wide with an empty header, not sortable, showing `▶` on the playing row only;
while it's shown the Title drops its mark, so the mark shows once. `appearance.playingRowColor`
(Playing Row Color, after Album Line Color in Settings ▸ Appearance, with Default) colors the
playing row; null keeps the gray, and the bar at the row's edge stays. The timeline shows Played
and then the track table's columns, without Album Art, Order and Now Playing, following its
changes, until the owner shows, hides, moves or resizes a column in the timeline's header; that
saves `browser.timelineTable` and the timeline keeps it from then. Null is the "follow" state,
so there's no flag. A resize from the window's width doesn't count, and Played stays first.
Checked by tests only, nothing on screen: the row pitch, the line over the art and under the
hover, the triangle's look (a text triangle, `U+25B6 U+FE0E`, in the cell's font), the playing
row color and the timeline's header menu, drag and resize. For the owner: Compact against
Swinsian, album lines with art hovered, whether the triangle reads well at 11 pt, and that a
window resize leaves the timeline following the library. `./scripts/check` passes except two
tests that read a window on screen, `theGlassHeadersAreFrosted` and
`theArtHoverDrawsOnTopAndEndsAtItsAlbumsLastRow`, which fail the same way on `main` in this
session.

#### 41c. Navigation

- [x] **41c.1 ⌘L to where it started.** Show Playing goes to the source the playing track was
      started from (library, playlist, timeline), even when the current source lists it too.
- [x] **41c.2 Soft undo.** ⌘U steps back over selection changes, as in Sublime Text, and ⌘⇧U
      forward. Each step is the selection and the view it was in. ⌘L is a step: play a track,
      click another, ⌘L, then ⌘U selects the clicked one again.

Plan, part 41c (ADR 0091):
- Probe (done before this plan): Show Current Track (`view.showCurrentTrack`, ⌘L) calls
  `reveal(trackID:)`, which selects the track in whatever the table lists, and shows the whole
  library only when the source, a pane or the search hides it. The browser's plays (track
  table, timeline, Play, `music-player play`) all pass `recordPlay`, which takes a step in
  `StepHistory` with the window it was started from; that window is overwritten when the step
  is left (ADR 0090), so the source a play came from isn't kept anywhere. Selection changes
  aren't kept either. ⌘U and ⌘⇧U are bound to nothing; ⌥⌘U is Show Queue.
- 41c.1, where a play came from: `StepHistory.Play` keeps the filter it was started from
  (source, search, column selections), and `playSource` is that of the latest play at or
  before the history's place, so Back over a play gives the one before it. ⌘L, with a track
  playing, goes there: the track's row where the window shows that source and lists it;
  otherwise the source with the play's search and column selections; otherwise the source
  alone; otherwise, or when the playlist is gone or no play was recorded, the whole library,
  as now. On the timeline, the newest loaded play of the track, after the timeline's load;
  when it lists none, the library. Tests: a track played in a playlist and also in the
  library: ⌘L from the library shows the playlist, and played from the library, ⌘L from the
  playlist shows the library; a play's search comes back; the track taken out of the playlist,
  or the playlist deleted, falls back to the library; Back over a play makes ⌘L follow the
  play before; a play from the timeline goes back to the timeline's row.
- 41c.2, soft undo: `SelectionHistory` (LibraryBrowser), in memory, holds `WindowPlace`s, the
  same capture Back uses. A step is recorded when the track table's selection changes to a
  non-empty one that differs from the current step's selection or source. An unchanged
  selection under a new search or pane keeps its step as it was. Consecutive moves by key
  (the selection commands: arrows, Shift-arrows, ten rows, page, first and last) in one source
  coalesce into one step, as in Sublime; a click, ⌘L, a reveal or a jump each start a step. A
  new step after undo drops the redo steps; 100 steps at most, the oldest dropped. ⌘U first
  returns to the current step when the window has moved off it (another source shown, the
  selection cleared), else the one before; the step left keeps the window as it was left, so
  ⌘⇧U returns there. Restoring shows the step's filter, selection and scroll through the code
  Back uses (one `show(_ place:)` in `LibraryBrowser`, which part 41f can call), records
  nothing, and runs in turn with Back and Forward. Playback is never touched. Steps of a
  deleted playlist go, as Back's do. The timeline's rows are plays, which a place doesn't
  keep, so its selections aren't steps.
- Commands: `go.undoSelection` "Undo Selection" ⌘U and `go.redoSelection` "Redo Selection"
  ⌘⇧U, in the View menu after Back and Forward, rebindable in Settings ▸ Shortcuts as every
  command is; not from links, since they need the window.
- Tests: `SelectionHistory` as values (recording, coalescing, the cap, dropping redo, moving
  off a step, removal); in the browser: the owner's example (play, click, ⌘L, ⌘U selects the
  clicked track, ⌘⇧U the playing one again), a run of arrow keys undone in one step, a step
  from another source shows that source again, undo leaves playback alone; the commands' chords
  and menu places.
- Order: this plan, 41c.1, 41c.2 with its commands, then the ADR and the result.

Result, part 41c: shipped 41c.1 and 41c.2 (ADR 0091). A play's step keeps the filter it was
started from, and ⌘L goes there: the row in place when the window shows that source and lists
the track, else the source with the play's search and column selections, else the source alone,
else the library. A deleted playlist, a track taken out of it, or no recorded play ends at the
library; a play from the timeline goes back to the timeline's newest loaded play of the track.
Back over a play makes ⌘L follow the play before. Undo Selection (⌘U) and Redo Selection (⌘⇧U)
are in the View menu after Back and Forward, rebindable like every command, with a row in ADR
0012's table. A step is the track table's selection with its `WindowPlace`, restored through
the one `LibraryBrowser.show(_:)` Back now uses too, which part 41f can call. Arrow and
Shift-arrow runs in one source are one step; a reload's selection gives way to the next change,
so ⌘L into another source is one step; empty selections and the timeline's aren't steps; 100
steps, in memory; a new selection after undo drops redo; playback is never touched. Checked by
tests only, nothing on screen: the owner's example (play, click, ⌘L, ⌘U, ⌘⇧U), a key run, a
step in another source, ⌘L from a playlist, the library, a search and the timeline, and the
fallbacks. For the owner: ⌘L after starting a track in a playlist and moving to the library and
back, and ⌘U after a few clicks, a held arrow key and a source change. `./scripts/check` passes
but for `theGlassHeadersAreFrosted`, which reads the screen and fails the same on `main` here.
The LibraryBrowserTests process exits partway in a full run, as 40d found, so its tests were
also run by name in chunks of 15: all pass but `aRefreshKeepsTheSelectedRowsByID` (40d's),
`aSavedCheckRunsTheReportAndListsItsTracks` and `theArtHoverDrawsOnTopAndEndsAtItsAlbumsLastRow`,
which fail the same on `main` in this environment.

#### 41d. Signal path, outputs and receiver

- [x] **41d.1 Wording.** Where the signal path says "not bit perfect" while streaming to a DAC,
      it says "not guaranteed bit perfect": usually only this app plays, and then it is.
- [x] **41d.2 A plainer signal path.** The signal path is still hard to read. No device IDs,
      four-character codes or sample formats in raw form (it showed `44.1 kHz 16-bit PCM →
      ADI-2 DAC (57850288): 'lpcm' 2 ch 32-bit int @ 44.1 kHz`). Friendly names, and a more
      graphical layout of the stages.
- [x] **41d.3 Sonos names.** The output menu names Sonos players and groups as the Sonos app
      does: a group that plays on two players shows as one entry with its group name (the
      owner's phone and Spotify show "Top Floor").
- [x] **41d.4 Receiver volume.** In signal mode, with a receiver connected, a volume slider
      sets the receiver's volume.
- [x] **41d.5 Receiver settings.** The address is a fallback for when the search can't find the
      receiver, and the settings say so instead of looking required. The section reads as one
      choice: media keys control the receiver's volume while it's connected.

Plan, part 41d (ADR 0093, amending 0035, 0039 and 0041):
- Probe (done before this plan): "Not bit-perfect" is one string, the signal path badge, and
  the owner's case gets it only for "the format is mixable" and "hog mode isn't held", which
  change nothing while no other app plays. The status line's
  `44.1 kHz 16-bit PCM → ADI-2 DAC (57850288): 'lpcm' 2 ch 32-bit int @ 44.1 kHz` is the
  file's format, then `DeviceFormat.summary`, made for the log. The app appends no ID: the
  RME DAC names itself `ADI-2 DAC (57850288)`, its serial number, in
  `kAudioObjectPropertyName`, and the Output menu shows that name too.
- 41d.1 (NowPlaying): a verdict whose changes are only ones another app could make (mixable
  format, hog mode free) reads "Not guaranteed bit-perfect"; a change the app or macOS makes
  to the samples still reads "Not bit-perfect" or "Converted". Test: each badge from its
  changes.
- 41d.2: `deviceDisplayName` (HALOutput) drops a trailing serial in parentheses, six or more
  digits, unless another device's name would then read the same, and the provider's
  `deviceName`, the Output menu and Settings use it; `--list-devices` keeps the full name.
  `formatText` (DisplayText) is "44.1 kHz · 16-bit", "32-bit float". The panel becomes a row
  of stages, each a rounded box with a title, a value and a note: "File" with "44.1 kHz ·
  16-bit" and "FLAC · stereo", a decoder box only when the decoder changes something, then the
  device by name with its rate and depth and "Exclusive" or "Shared" and its volume, or the
  renderer by name; arrows between them, a box tinted where a change happens. The verdict's
  reasons are sentences without PIDs; the device's list of formats goes. The status line's
  output half is `DeviceFormat.shown`, "ADI-2 DAC: 44.1 kHz · 32-bit". Tests: stages for PCM,
  a resampling decoder, DoP, a renderer and a missing device; the name rule; the status line.
  `--snapshot` shows nothing playing, so a throwaway test draws the panel with sample paths
  to look at.
- 41d.3 (UPnP, UPnPOutput, App): `XMLTree` keeps attributes. Discovery reads a Sonos
  player's room (`roomName`) and its ZoneGroupTopology control URL from the root device, then
  asks one player for `GetZoneGroupState`. A group's renderer is its coordinator, named as the
  topology gives it: the room name when every visible member shares it (a stereo pair, or a
  room with a sub), else the coordinator's room "+ N" for the other rooms. Members that aren't
  the coordinator are kept, marked, and left out of the picker; a stored member's UDN plays to
  its group's coordinator. A player not in the topology is named by its room. A failed
  topology call leaves the rooms. `--capture-renderers` saves the topology reply. Tests with
  XML in Sonos's documented shape: the parse, the names for a pair, a two-room group and a
  single player, the picker's entries, the coordinator redirect, and discovery against a
  loopback stand-in.
- 41d.4 (NowPlaying, Receiver, App): with receiver control connected, the panel shows a
  volume slider from −80 to 0 dB, its value from the receiver's `MV` lines, and dragging it
  sends `MV` levels. A level waiting to be sent is replaced by the next, so a drag sends at
  most one line per 50 ms and ends on the last. The slider ignores status lines while it's
  dragged. Tests: the slider shows and follows the state and sends levels; the connection
  replaces a waiting level.
- 41d.5 (Settings, SettingsWindow, App): `receiver.volumeKeys` folds into `receiver.enabled`,
  titled "Volume Keys Control the Receiver": on, receiver control runs and, while it's
  connected, the volume and mute keys set the receiver's volume; while the app plays to the
  Denon as a renderer they do whatever the setting. The address row sits behind a "Can't find
  the receiver?" disclosure, open when it has a value. Breaking: a config's
  `receiver.volumeKeys` is skipped as an unknown key, which Remove Obsolete Setting takes out. Tests: the keys'
  rule, the disclosure, the schema.
- Order: this plan, then each item through `./scripts/check`, then the ADR and the result.

Result, part 41d: shipped 41d.1 to 41d.5 (ADR 0093, amending 0035, 0039 and 0041). The badge
says "Not guaranteed bit-perfect" when the only changes are a mixable format and hog mode free;
a change to the samples still says "Not bit-perfect" or "Converted". The signal path is a row of
boxes joined by arrows, the file, the decoder only when it changes something, then the device or
renderer, each with "44.1 kHz · 16-bit" and a short note, tinted where the samples change; no
codes, channel counts in raw form, format lists or PIDs. The status line reads
`44.1 kHz 16-bit FLAC → ADI-2 DAC: 44.1 kHz · 32-bit`. The `(57850288)` was the RME DAC's own
name, its serial, not an ID the app appended; a trailing serial of six or more digits is
dropped unless another output device would then read the same. Sonos players are named by room
and groups as the Sonos app names them (a pair's room, else "Kitchen + 1"), offered once by the
coordinator, and a member picked earlier plays to its coordinator; `--capture-renderers` saves
the topology reply. With receiver control connected, the panel has a slider from −80 to 0 dB
that follows the receiver's `MV` lines; a drag sends one level per 50 ms. `receiver.volumeKeys`
is folded into `receiver.enabled`, "Control the Receiver with the Volume Keys": while receiver
control runs, the volume keys go to the receiver, now also with the DAC into the receiver.
Breaking: `receiver.volumeKeys` in a config file is skipped as an unknown key until Remove
Obsolete Setting takes it out. The address sits under "Can't find the receiver?", open when set.
Looked at: the panel drawn by a throwaway test, light and dark, with the receiver row, and
`--snapshot-of settings` for the Receiver box. Checked by tests only: the status line with a
real device, the Sonos rule (against replies in Sonos's documented shape, not the owner's
players), the slider against a real receiver, the disclosure's click. For the owner: the panel
on the 2015 MacBook Pro, whether "Top Floor" shows as one entry (if not, send the
`<n>-zonegroupstate.xml` from `--capture-renderers`), the slider with the receiver on, and that
the volume keys reach the receiver with the setting on. `theGlassHeadersAreFrosted` fails in
this environment on `main` as well as here (it reads the screen); everything else passes.

#### 41e. Toolbar status and Settings

- [x] **41e.1 Help popover padding.** The template rows' ? popover has top and bottom padding
      equal to its side padding.
- [x] **41e.2 Outlined status items.** While the toolbar's customize sheet is open, each status
      item has an outline, so an empty Custom Status item can be seen and removed.
- [x] **41e.3 One item fills the row.** In flexible width, a status item alone on its row (the
      Now Playing bar, or any other) stretches to the full width.
- [x] **41e.4 Watched folder options.** Swinsian's two options, if we lack them: remove tracks
      from the library when they disappear from watched folders, and rescan tags when files in
      watched folders are modified.
- [x] **41e.5 Appearance page.** The Appearance pane has grown to 20 rows in one box. Group it
      into sections a reader can scan.

Plan, part 41e (ADR 0094):
- Probes (done before this plan): the tokens popover is as tall as its label, 160 points for
  160, with 10 points at each side: `NSPopover` takes the content view's frame, the label's,
  and the stack's insets show only across. The status item, centered by AppKit
  (`centeredItemIdentifier`), stays at its 280-point minimum alone in the toolbar or beside
  fixed items, whatever its `maxSize`; it grows only to a `maxSize` that fits centered, the
  560 it has beside a flexible space. Not centered, it fills the room, as a Custom Status item
  does (1184 of a 1200-point window). A Custom Status item alone between flexible spaces stops
  at 560. Scanning: every scan already removes the tracks of files gone from a walk that
  finished and reads files whose size or mtime changed, unconditionally (ADR 0009). A folder
  that is missing, lists nothing while the index holds its files, or vanishes or changes
  device during the walk removes nothing; that stays whatever the settings say.
- 41e.1: the popover's content view is sized to its fitting size before it shows, so the
  12-point insets hold on all four sides. Test: the label's margins in the popover are equal.
- 41e.3: a status item (the status or a Custom Status item with a flexible column) fills the
  room when no flexible space is in the toolbar or when no other item but spaces is: no
  `maxSize` cap, and the status isn't the centered item then, since AppKit won't widen a
  centered item past what fits centered. With another item and a flexible space it stays at
  most 560 and centered, as now. Tests in a window: the status alone, beside fixed items, and a
  Custom Status item between flexible spaces fill the width; the default set keeps 560 and
  centers.
- 41e.2: `MainToolbar` watches its window's sheets; while `customizationPaletteIsRunning`, the
  status's and each Custom Status item's view draw a 1-point rounded outline in the separator
  color on their layer, gone when the sheet ends. Both are AppKit API since 10.x, so macOS 12
  has them. The status bar isn't in the toolbar and keeps no outline. Test: run the palette on
  a window, the items' views have the outline; end the sheet, they don't.
- 41e.4: two settings, default on: `library.removeMissingTracks` ("Remove Missing Tracks")
  and `library.rescanModifiedFiles` ("Rescan Modified Files"), in a new "Folder Changes" box
  above Network Folders in Settings ▸ Watched Folders. The scanner takes `ScanOptions`: with
  removal off, a finished walk leaves the tracks of gone files in the index (no files are
  touched in either case); with rescanning off, a known file whose size or mtime changed is
  counted unchanged and keeps its stored size and mtime, so turning it on reads it at the next
  scan. An unreadable file is still read again. The watcher's jobs carry the options: Rescan,
  Rescan All and the tag editor's own writes read changed files whatever the setting, since
  someone asked for them; removal follows the setting everywhere. A change of either restarts
  the watcher, as the other library settings do. Tests: the scanner with each off; the watch
  state's jobs with rescanning off (a launch scan and FSEvents don't read, an edit and a
  Rescan do); the pane shows both rows.
- 41e.5: Appearance splits into two panes. Appearance keeps "Theme" (Appearance, Window Glass)
  and "Track Table" (lines, line colors, Playing Row Color, Alternating Rows, Row Height,
  Album Art). A new Toolbar pane after it has "Titles" (Window Title, Toolbar Title Line),
  "Toolbar Status" (Toolbar Status Layout, and the three Custom Status layouts on one row of
  three buttons, Edit 1… to Edit 3…, under one label and summary) and "Status Bar" (style and
  layout). Sections list their keys, as Network Folders does, since all share `appearance.`;
  `appearance` itself makes Theme the place for a new appearance key. Summaries get shorter
  where the title says it, and the color wells get a fixed width instead of stretching. Tests:
  sections and their rows, the palette opens the Toolbar pane for its settings, the Custom
  Status row's buttons each open their own builder, labels fit; snapshots of both panes.
- Order: this plan, 41e.1, 41e.3, 41e.2, 41e.4, 41e.5, each through its tests,
  `./scripts/check`, then the ADR and the result.

Result, part 41e: shipped 41e.1 to 41e.5 (ADR 0094, amending 0009, 0067, 0087 and 0089). The
tokens popover is sized to its fitting size, so its 12-point insets hold above and below too. A
status item with a flexible column fills the toolbar when no flexible space is in it or nothing
but spaces is beside it; the status stops being AppKit's centered item while it fills, since
AppKit never widens a centered item, and with another item and a flexible space it stays
centered at 560 points. While Customize Toolbar's sheet is open the status and the Custom Status
items have a 1-point rounded outline, from the window's sheet notifications and
`customizationPaletteIsRunning`, both on macOS 12; the status bar has none. We did both of
Swinsian's folder options unconditionally; Remove Missing Tracks (`library.removeMissingTracks`)
and Rescan Modified Files (`library.rescanModifiedFiles`), both on, now sit in a Folder Changes
box in Settings ▸ Watched Folders and in the File menu. Off, a gone file's track stays, and a
modified file keeps its track and stored size and time until the setting is on again. Rescan,
Rescan All and the tag editor's writes read modified files anyway; a missing, empty or vanished
folder removes nothing whatever the setting, as before, so an unmounted NAS keeps its tracks.
Files are never touched. Settings ▸ Appearance has Theme and Track Table; a new Toolbar pane has
Titles, Toolbar Status (with the three Custom Status layouts on one row, Edit 1… to Edit 3…) and
Status Bar. Sections list their keys, since all share `appearance.`. Summaries are shorter and
the color wells no longer stretch. `--snapshot-of toolbar` draws the new pane; the Appearance,
Toolbar and Watched Folders panes were checked in snapshots. Checked by tests only, nothing on
screen: the popover's padding, the status filling the toolbar, and the outlines in the sheet.
For the owner: the status alone in the toolbar and beside fixed items (it's no longer centered
there), the outlines while customizing in light and dark, and the two folder options with a
file edited or deleted in Finder. `./scripts/check` passes but for `theGlassHeadersAreFrosted`,
which reads the screen and fails the same on `main` here, as 41b and 41c found.

#### 41f. Play state across quits

- [x] **41f.1 Resume.** Quitting and opening the app again puts back the playing track and how
      far it had played (paused), the source it was playing from, the selected item, and the
      track list's scroll. Kept in the config so it syncs to other Macs, in as few keys as it
      takes.

Plan, part 41f (ADR 0095):
- Probe (done before this plan): the window's source is `browser.source` in `state.json`, read
  by `WindowSettings` and passed to `LibraryBrowser.load`; `browser.columns` beside it keeps
  each column's grouping and selection by name. The state file is per Mac and never synced;
  the config file syncs when the owner links it into a synced folder (ADR 0012). The engine
  starts after the first rows draw, holding no device until something plays. `restore(_:)`
  loads the track into the output, which opens the device (hog mode included) and reads the
  file. Sync names a track by its sync path, the share's name and the path inside the share
  (ADR 0026, 0038), which `SyncRoots` maps to this Mac's path through `share_roots`; folders
  stored by path aren't synced. A playlist's sync ID is in `sync_playlists`.
- The key: `playback.resume` in the config, one object, null until something is saved:
  `{"track", "seconds", "from", "source", "selected", "top"}`. `track`, `selected` and `top`
  (the first visible row) are a track's sync path, or its absolute path for a folder stored by
  path, which starts with `/` and only finds the track on a Mac with the same path. `from` is
  the source the track was played from, `source` the one the window shows; each is a
  `BrowserSource` text with a playlist named by its sync ID, null for the library. The
  Settings window and the palette list no row for it (`.windowState`). A value of another
  shape is read as null and logged, not a config problem, so a Mac on another build never
  blocks the file over it. `browser.source` goes from the state file: one source, the
  config's. The column selections, search and the scroll's offset aren't kept.
- Writing: a `ResumeSaver` (MusicPlayer) writes the key when a track starts, playback pauses
  or stops, a seek ends, the source changes or the selection changes: 5 s after the first
  change, and at least 30 s after the last write, reading the engine and the window when it
  writes. No write while playing on, so the file changes a few times an hour at most. At quit
  the app waits up to 1 s for the engine's place (`terminateLater`) and writes it at once. An
  unchanged value isn't written. A config that refuses changes (ADR 0082) is logged. Last
  writer wins, by the config's read-before-write.
- Launch: `LibraryBrowser.load` takes the key: its source (a playlist by sync ID, through the
  main thread's index, one lookup) replaces the saved source, and once the first list loads
  the selected track and the first visible row come back through `show(_:)` (41c). After the
  engine starts, the browser reads `from`'s list off the main actor as the queue and the app
  cues the track: `PlaybackEngine.cue` sets the queue, the track paused at its seconds, and its
  length from the index, loading nothing, so no device opens and no file is read until Play,
  which loads there. A seek while cued moves the place. A cue after the user started
  something is ignored. A track this Mac can't find starts with nothing loaded and logs a
  line saying which; a source it can't find shows the library, logged.
- ⌘L after a resume goes to `from`, as after a play (41c).
- Tests: the engine's cue (nothing loaded, Play loads at the seconds, a seek moves it, `spot()`
  reads it); shared names (a track found on a second Mac with the share mounted elsewhere, a
  playlist by sync ID, a local path); the key's decoding (null, a value, another shape read as
  null); the round trip (a browser's place and playback written to a config file, read by a
  new store, and a new browser shows the source, selection and first row and gives the track
  paused at its seconds in `from`'s queue); a missing track starts clean and logs; the saver
  writes once for many changes and at once at quit.
- Order: this plan, the engine's cue, shared names, the key, the browser, the app, the ADR and
  the result.

Result, part 41f: shipped 41f.1 (ADR 0095). `playback.resume` in the config holds the track by
its sync path (or absolute path for a folder stored by path), its seconds, the source it was
played from, and the window's source, selected track and first visible track; `browser.source`
left the state file. At launch the window shows the saved source with the selection and first
row, and once the engine starts the track is cued paused at its place, in its source's list as
the queue, showing its length; no device opens and no file is read until Play, which plays from
there. ⌘L goes to the source it was played from. A track start, pause, stop, seek, source or
selection change writes the key 5 s later, at most every 30 s; quitting writes at once, waiting
up to 1 s for the engine. A track or source this Mac lacks starts without it, logged; a value of
another shape reads as null without blocking the file. Two rows in ADR 0023's table. Checked by
tests only, nothing on screen: the engine's cue, shared names across two Macs' mounts, the key's
decoding, a round trip through a config file into a second browser (source, selection, first
row, the track paused at its seconds in its source's queue, ⌘L), a missing track, and the
saver's throttle. Left out: the search, the column selections (still per Mac in the state file)
and the scroll offset within the top row. For the owner: quit while a track is paused partway,
reopen, check the toolbar shows it paused at that time and Play resumes there; then the same on
the second Mac with the config synced. The first launch of this build discards the old state
file once (it names `browser.source`), so the window layout starts from its defaults.
`./scripts/check` passes but for `theGlassHeadersAreFrosted`, which reads the screen and fails
the same on `main` here (41c).

### 42. Owner feedback, 2026-11-05

The owner's feedback from trying phase 41. Parts 42a to 42d run in parallel worktrees and
rebase onto main in order a, b, c, d. Parts 42e (Get Info) and 42f (Listening Stats, phase 43,
which uses 42d's panel) then run in parallel; 42g runs after 42e, since both change Get Info. Each part keeps the owner's window layout, column widths, toolbar and settings:
a state or config key changes only by adding an optional key, and the owner's current
`state.json` and `config.json` still decode after the part (checked against a copy, not the
files themselves). The owner's answers: Ctrl+Left and Ctrl+Right seek even though macOS binds
them to Spaces by default; the owner turns those off if they clash.

#### 42a. Focus and seek keys

- [x] **42a.1 Shift-Tab back a column.** From the second browser column, Shift-Tab focuses the
      first column at once; today focus leaves the columns and a second Shift-Tab is needed.
- [x] **42a.2 Tab and Shift-Tab are inverses.** Shift-Tab visits the same views as Tab, in the
      reverse order, everywhere in the main window.
- [x] **42a.3 Columns open focused.** Showing the browser columns focuses the first column.
- [x] **42a.4 Tab into the filtered tracks.** With a track playing from All Tracks and another
      column item selected, Tab from the columns still reaches the track table below.
- [x] **42a.5 Seek keys.** Ctrl+Left and Ctrl+Right seek back and forward 10 s; Ctrl+Shift+Left
      and Ctrl+Shift+Right by 5% of the track's length. Commands in the registry, rebindable.

Plan, part 42a (ADR 0096):
- Probe (done before this plan): Tab is Focus Next Area (`focus.nextArea`), which the lists
  (sidebar, panes, track table, timeline, queue) take from their key presses and pass to the
  registry; its handler in `CommandHandlers` builds the order (the browser's `focusAreas`, less
  the sidebar when hidden, plus the queue when shown) and steps forward, starting at the first
  area from anywhere else. ⇧Tab is bound to nothing, so the lists hand it to AppKit, whose
  automatic key-view loop walks every view that can take the keys, scroll views and the
  toolbar's controls among them, in its own order: from the second column it lands on a view
  that shows no focus before the first column. Showing the columns leaves the keys where they
  were. After a column change that drops the selected track (the playing one, selected from
  All), the track table reloads with nothing selected; Tab does give it the keys, but a table
  with no selection and no focus ring shows nothing, so focus looks lost. Seek Forward and Seek
  Back step 10 s on ⌥⌘→ and ⌥⌘←; nothing seeks by a share of the track.
- 42a.1 and 42a.2: one ordered list. `MainWindow.focusAreas` is the order Tab walks (sidebar
  when shown, columns when shown, track table or timeline, queue when shown), and one
  `focusArea(after:of:forward:)` steps it either way, wrapping, so ⇧Tab is the same list
  backward by construction. A new command, Focus Previous Area (`focus.previousArea`, ⇧Tab),
  in the View menu after Focus Next Area, rebindable as every command is. From outside the
  list Tab enters at the first area and ⇧Tab at the last, the search field included (its Tab
  and ⇧Tab go to the commands instead of AppKit's loop).
- 42a.3: showing the columns gives the first column the keys, unless the timeline shows.
- 42a.4: an area given the keys by Tab or ⇧Tab that has rows and no selection selects its
  first row, so the move shows.
- 42a.5: Ctrl+Right and Ctrl+Left become Seek Forward's and Seek Back's second chords (10 s,
  the same commands). New commands Seek Forward 5% and Seek Back 5%
  (`playback.seekForwardPercent`, `playback.seekBackPercent`) on ⌃⇧→ and ⌃⇧←, in the Controls
  menu after Seek Back, from links as the other seeks are, a twentieth of the playing track's
  duration; nothing with no known duration. Rows in ADR 0012's table.
- No state or config key changes; a shortcut override in `config.json` still names commands
  by the same IDs.
- Tests: the order walked forward then backward visits the same views reversed, with the
  sidebar, columns and queue each shown and hidden; ⇧Tab from the second column gives the
  first column the keys at once; the search field's Tab and ⇧Tab; showing the columns focuses
  the first; Tab into a track table left with no selection by a column change selects its first
  row; the commands' chords, menu places and link set; the seek step for 5% of a duration.
- Order: this plan, the focus order and Focus Previous Area, showing the columns, the
  selection on Tab, the seek commands, then the ADR and the result.

Result, part 42a: shipped 42a.1 to 42a.5 (ADR 0096). Tab and ⇧Tab walk one list,
`MainWindow.focusAreas` (sidebar, columns, track table or timeline, queue, each while shown),
through one step function, so ⇧Tab is Tab reversed by construction; Focus Previous Area
(`focus.previousArea`, ⇧Tab) is a new command after Focus Next Area in the View menu,
rebindable like every command. The search field's Tab and ⇧Tab enter the list at its first and
last areas instead of AppKit's loop. Showing the columns gives the first column the keys, except
on the timeline. An area Tab or ⇧Tab reaches with rows and no selection selects its first row:
42a.4 turned out to be a table left with no selection after the column change dropped the
playing track, which Tab did reach but which showed nothing. ⌃→ and ⌃← are second chords of
Seek Forward and Seek Back (10 s); Seek Forward 5% and Seek Back 5%
(`playback.seekForwardPercent`, `playback.seekBackPercent`) are new on ⌃⇧→ and ⌃⇧←, after Seek
Back in the Controls menu and from links; rows in ADR 0012's table. No state or config key
changed. Checked by tests only: the list walked both ways with each part shown and hidden, ⇧Tab
from the second column, the search field's keys, showing the columns, Tab into a table emptied
by a column change, the chords, menu places and link set, and the 5% step. For the owner: ⇧Tab
from the second column and around the whole window with the queue open, ⌘B to show the
columns, Tab into the track table after picking an album that doesn't hold the playing track,
and ⌃→ once the Spaces shortcuts are off. `./scripts/check` passes but for its test step, where
window tests (`noStatusBarPartResizesTheWindowOrItsSplits`,
`glassOnThenOffLeavesTheWindowAsAFreshOne`, `aColorRowIsAWellWithADefaultButton`) fail in the
full run on a loaded machine and pass when MusicPlayerTests and SettingsWindowTests run alone.
LibraryBrowserTests, run by name in chunks of 15 as in 41c, all pass but
`aRefreshKeepsTheSelectedRowsByID`, `aSavedCheckRunsTheReportAndListsItsTracks` and
`theArtHoverDrawsOnTopAndEndsAtItsAlbumsLastRow`, 41c's three, which fail the same on `main`.

#### 42b. Rows and the queue

- [x] **42b.1 Centered triangle.** The Now Playing column centers its play triangle.
- [x] **42b.2 Room after the Title's triangle.** With the Now Playing column hidden, about 4 pt
      more space between the Title's triangle and the title.
- [x] **42b.3 Readable playing row.** When the playing row color is dark enough, the row's text
      turns white.
- [x] **42b.4 Queue times.** A queue row's time is in the small font (as the artist and album
      line), aligned to the top of the row and right-aligned against the row's right edge.
- [x] **42b.5 Enter on the next track.** Enter or a double-click on a track starts it without
      rebuilding the queue when the queue already holds it in the same order (for example the
      track after the playing one), as Next does.

Plan, part 42b (ADR 0097):
- Probe (done before this plan): `TextCell` draws one line, left-aligned or right for numbers,
  and the Now Playing cell is a left-aligned `TextCell`; the Title's mark is the text
  `▶︎ ` before the title. `MarkedRowView` fills the playing row with `markTint` and leaves the
  cells' `backgroundStyle` to AppKit, which sets `.emphasized` only on a selection the table
  has the keys for; `TextCell` draws white then. The queue's `QueueCell` puts the title and
  detail stack and the length in a horizontal stack centered on the row, so the length follows
  the text's width and sits halfway down. A play from the track table goes through
  `PlayStart` and `PlaybackEngine.play(starting:completing:)`, which replaces the queue every
  time; Next goes through `move(to:)` and `load`, and the device output reuses an open track,
  the next one among them, whose URL matches the load (`openTrack`), so a load of the next
  track keeps its prebuffer.
- 42b.1: `TextCell` takes an alignment, and Now Playing's is centered. Test: the triangle's ink
  is as far from the cell's left edge as from its right.
- 42b.2: `TextCell.mark`, drawn before the text with a space 4 points wider than a plain one;
  the Title gets the playing mark there instead of in its text. Test: the drawn line is 4
  points wider than the mark, a space and the title.
- 42b.3: `MarkedRowView` reports `.emphasized` as its cells' style while it's marked with a
  `markTint` dark enough for white text, by WCAG contrast (white's against the tint over the
  table's background beats black's), and not while it's selected. Every `TextCell` draws white
  for `.emphasized`, whatever its own color, so every column follows. Tests: a dark tint makes
  every text cell on the playing row draw white and a light one doesn't; a selected playing
  row keeps the selection's style; the contrast function's threshold.
- 42b.4: `QueueCell` lays out by constraints: the length is pinned to the row's right edge,
  in the detail line's font, on the title's baseline, and the title truncates before it. Test:
  short and long titles put the length's right edge at the same place, on the title's
  baseline, in the detail's font size.
- 42b.5: `BrowserModel` keeps the list its last play queued (the track IDs in play order) and
  that queue. A play from the same IDs in the same order returns a `PlayStart` that carries
  the queue; the app then asks the engine to play that entry in place
  (`PlaybackEngine.play(entry:ifQueueIs:)`), which does what Next does when the engine's queue
  is that queue, unedited, and otherwise refuses, and the app replaces the queue as before.
  A library change forgets the kept list. Tests: the engine plays the entry in place, keeps
  the queue and hands over the next track, and refuses an edited or other queue; the model's
  second play from the same list carries the queue, and a re-sort doesn't.
- Order: this plan, then 42b.1 with 42b.2, 42b.3, 42b.4, 42b.5, each through the tests,
  `./scripts/check` at the end, then the result.

Result, part 42b: shipped 42b.1 to 42b.5 (ADR 0097, amending 0092). Text cells take their
column's alignment, and Now Playing's is centered. The Title's playing mark is the cell's mark
now, not part of its text, drawn with a space 4 points wider than a plain one; VoiceOver still
reads the mark and the title. A Playing Row Color whose WCAG contrast with white beats black's
(laid over the controls' background when it has opacity) gives the row's cells the emphasized
style, as a selection with the keys does, so every column's text draws white, whatever its
own color; a selected row keeps its selection's style, and the default gray changes nothing.
AppKit didn't pass the style on when the selection or the mark changed, so the row restyles
its cells itself. The queue row's length is pinned to the row's right edge, on the title's
baseline, in the detail line's size, and the title truncates before it. It was already 11 pt
in code, so what looked large was likely its place halfway down beside the 13 pt title. A
play from the track table keeps the queue when the list (its track IDs in play order) is the
one the last play queued and the engine's queue is still that queue, unedited:
`PlaybackEngine.play(entry:ifQueueIs:)` plays the entry as Next does, keeping the shuffle,
and the device output takes the load from its open next track. Anything else replaces the
queue as before, and a library change forgets the kept list. The first play after a launch
still builds the queue, since the model keeps no list until it has queued one. No state or
config key changed. Checked by tests only, nothing on screen: the triangle's centering, the
gap, the white text, the queue rows and the play in place. For the owner: whether 4 points
reads right at each row height, a dark and a light playing color in light and dark mode, the
queue's lengths lining up, and Enter on the next track continuing without the queue panel
rebuilding. `./scripts/check` passes; one run before the last failed
`aColorRowIsAWellWithADefaultButton` on its 5 s wait, which passes alone and in the final run.

#### 42c. Settings, sync and the icon

- [x] **42c.1 Bit-perfect badge in line.** Signal path shows the bit-perfect badge as the first
      item of the row of details, not on a row of its own.
- [x] **42c.2 Change opens the sync folder.** With a sync folder set, Change opens the panel at
      that folder.
- [x] **42c.3 Any receiver.** The receiver setting doesn't name Denon where the feature works
      with other receivers.
- [x] **42c.4 No gap after "Can't find the receiver?".** Closing the disclosure returns the box
      to its height.
- [x] **42c.5 Hog mode off by default.** The default output mode has hog mode off.
- [x] **42c.6 Sync log review.** Check the owner's two logs in `/Volumes/music/music-player`
      (read only): one per Mac, each written only by its own machine, the machine id kept across
      reinstalls. Estimate their size with hundreds of thousands of files and years of plays,
      and fix what makes them grow without need.
- [x] **42c.7 App icon.** The ember icon (`music-player-icon-ember.svg`, from the owner) is the
      app icon.

Plan, part 42c (ADR 0098, amending 0037, 0038 and 0043):
- Probes (done before this plan): the badge and the reasons are one row (`verdict`) above the
  stages. Change… opens an `NSOpenPanel` with no `directoryURL`, so it opens where the last
  panel did. The receiver feature speaks Denon's line protocol on port 23; the search keeps
  only renderers whose manufacturer says Denon and whose model says AVR, and the address
  fallback connects to whatever answers there, so a Marantz (same protocol) works only by
  address. The Receiver box's pane measures 141 points closed and 191 open, and 141 again
  after closing, but in a window the window stays 191 tall: it grows to fit a taller pane and
  never shrinks back, so the stack spreads the rows over the old height. `output.hogMode`
  defaults to true, and a device seen for the first time hogs when it's on USB, Thunderbolt,
  FireWire, PCI or AVB whatever the setting; the owner's config sets it false. The machine ID
  is 32 random hex digits minted by the SQL of the database's `sync` part in
  `~/Library/Application Support/MusicPlayer/library.sqlite`. The owner's two logs (read
  only): `030d…` is this Mac's (its `sync_state` names it, and the file is exactly the
  outbox's 16,762,794 bytes); `bae0…` is the other Mac's, read here to its last line. Both
  have sequence numbers 1 to N with no gap. Of 98,431 and 98,190 lines, `added` is 86,750 and
  86,644 (14.3 MB of 16.7 MB, 165 bytes a line): each file twice, once from the first scan
  (43,382 and 43,329 files, `at` the scan time) and once from the Swinsian import (an earlier
  date). `counts` is 11,191 and 11,268 lines (2.4 MB, 212 bytes); plays 111 and 10, about 150
  bytes. The new icon's tile clip path is at 0,0 inside a `translate(100 100)`, so
  `icon-mask.swift`, which reads the clip's rect as canvas coordinates, would cut the wrong
  square.
- 42c.1 (NowPlaying): the badge goes first in a row with the stage boxes; the reasons, when
  there are any, go on a line under it. Test: the badge and the first stage share a row.
- 42c.2 (App): Change… finds where the sync folder is now, as Open does, off the main thread,
  and opens the panel there; a folder that can't be found opens it where macOS would. Test: the
  panel's `directoryURL` is the folder.
- 42c.3 (Settings): the summary says the volume keys set the connected receiver's, and that
  the search finds Denon receivers and a Marantz or other receiver on Denon's protocol needs
  its address; the address row says so too. Problem lines that say "no Denon receiver
  answered" are accurate and stay. Test: the summary names no single make as the only one.
- 42c.4 (SettingsWindow): opening or closing a disclosure sets the window to the pane's
  fitting height, keeping its top. Test: in a window, the pane's height after open and close is
  its closed height, and the window's top hasn't moved.
- 42c.5 (Settings): `output.hogMode` defaults to false, and a device seen for the first time
  hogs only when the setting is on and its kind allows it, so hog mode is off unless asked
  for. The owner's `false` stays. Tests: the default, and an unseen USB device with the setting
  off.
- 42c.6 (Library): a scan batch's new paths log one `addedFiles` event per folder, with the
  folder's sync path, the file names and one `at`, the batch's time, which the rows here take
  too; at most 500 names an event, the batch size. The import keeps `added`, one date per file,
  and `added` lines in the owner's logs read as before. On the owner's logs grouping cuts the
  scan's 7.1 MB to 2.2 MB (51 bytes a file). Tests: the line reads back, a bad name is
  refused, a batch logs one event per folder, and the other machine gets every file's date.
- 42c.7: `Support/AppIcon.svg` is the owner's SVG, with the tile clip path moved to canvas
  coordinates (100, 100) and the group it clips outside the translate, so `icon-mask.swift`
  cuts the right square; nothing else changes. Check: Quick Look's 1024 px master and the
  masked one look the same inside the tile, and the SVG refers to nothing outside itself.
- Order: this plan, each item through its tests, `./scripts/check`, then the ADR and the
  result.

Result, part 42c: shipped 42c.1 to 42c.7 (ADR 0098, amending 0037, 0038 and 0043). The badge
leads the row of stage boxes, centered on them, and the reasons sit on a line under the row.
Change… opens at the sync folder where it is now, found off the main thread; a folder that
isn't there opens the panel where macOS would and is logged. Receiver control speaks Denon's
line protocol on port 23; the search keeps only Denon receivers (manufacturer Denon, model
AVR), and the address reaches anything on that protocol, so the summaries now read "The volume
keys set a connected Denon or Marantz receiver's volume." and "Its IP address: for a Marantz,
or a Denon the search misses." (one sentence of at most twelve words, as the pane's test
asks). Marantz is untested. The problem lines saying no Denon receiver answered are accurate
and stay. The Receiver box's gap was the window: it grows to fit a taller pane but never
shrank back, so the stack spread the rows over 191 points instead of 141; a disclosure now
sets the window to the pane's fitting height, keeping its top. `output.hogMode` defaults to
false, and a device seen first hogs only when the setting is on and its kind allows it; the
owner's config already says false and stays so, and devices with a profile keep theirs. The
logs, read only: each is one Mac's and only that Mac writes it. `030dabf0…` is this Mac's
(its `sync_state` names it, and its 16,762,794 bytes are exactly the outbox), `bae0cca1…`
the other's, read here to its last line, 98,190; both run from seq 1 with no gap, and a Mac
writes only the log its own ID names and only as a byte prefix of its outbox, so they can't
interfere. The ID is 128 random bits minted by SQL in
`~/Library/Application Support/MusicPlayer/library.sqlite`, not tied to the bundle, its path
or its signature: a new build, a new ad-hoc signature, deleting and reinstalling the app all
keep it. It changes only when that database is deleted or its `sync` part's SQL changes (by
design, ADR 0038: a new log, and the old one read back), so nothing needed fixing there. Of
the 98,431 and 98,190 lines, `added` was 86,750 and 86,644 (14.3 MB, 165 bytes each): every
file twice, from the first scan and from the Swinsian import; `counts` 11,191 and 11,268
(2.4 MB, 212 bytes); plays 111 and 10 (150 bytes), skips 193 and 99. A scan batch's new files
now go as one `addedFiles` line a folder, at most 500 names, with the batch's one time as their
Date Added: the owner's first scan comes to 2.2 MB instead of 7.1 MB, 51 bytes a file. With
300,000 files a Mac's log would hold about 15 MB from its first scan (was 50 MB), 50 MB from
an import that dates every file (the import keeps `added`, one date per file, and logs only
dates it changes) and about 16 MB of import counts, plus 150 bytes a play: ten years at 50 plays
a day is 27 MB, far under the 1 GiB and 4,000,000-event caps. The owner's logs need nothing:
`added` reads as before and new lines carry on after them; a Mac on an older build reports
each `addedFiles` line as an unknown event and keeps its own dates, so both Macs need this
build. The icon is the owner's ember SVG with its tile clip path moved to canvas coordinates so
`icon-mask.swift` cuts the right square; it refers to nothing outside itself, and
`./scripts/bundle` renders it through Quick Look to a 1024 px master and all ten iconset sizes;
the mask cuts away the drawn drop shadow, as Quick Look draws it on white. Looked at: the panel
drawn by a throwaway test, the Quick Look master before and after the mask, and the bundle's
256 px icon. Checked by tests only: the panel opening at the folder (not shown on screen), the
window shrinking. For the owner: the icon in the Dock and Finder on both Macs, the Receiver box
after opening and closing the disclosure, and the Change panel with the NAS mounted.
`./scripts/check` passes; the color well tests (`aColorRowIsAWellWithADefaultButton`,
`aColorPickedInThePanelIsSavedAndDefaultClearsIt`) fail about one suite run in three with or
without this part's changes, from the shared color panel, and passed in the final run.

#### 42d. Library Health as a view

- [x] **42d.1 Out of the sidebar.** Library Health leaves the sidebar. It opens from a button in
      Settings ▸ Library and a menu item.
- [x] **42d.2 A health panel.** It shows the track table with a panel above it, placed like the
      browser columns, listing the health filters (unreadable, warnings and the rest) with their
      counts; choosing one filters the tracks below.

Plan, part 42d (ADR 0099, amending 0034):
- Probe (done before this plan): each check is already a source, `.health(check)`, listed
  through `temp.health_tracks` (ADR 0034), so the track table, search, sort, play, Get Info and
  the status bar's problems work on it as on any source; only the sidebar's Library Health row
  and its children reach it. Check Library Health (`library.checkHealth`) is in the File menu
  with the other library items, in the palette and on the command line as `checkHealth`; it
  runs the report and opens the sidebar's rows. Since 41f the window's source is saved as
  `playback.resume.source`, a string read with `BrowserSource(text:)`, and a name that isn't a
  source already shows the library without touching the rest of the file. The browser columns
  are the first subview of the browser's split, at `window.browserHeight`; Show Browser hides
  them. Settings ▸ General's Library section is the `library.` keys' box.
- Commands: `library.checkHealth` keeps its ID, so a rebinding in the config file still holds,
  and is titled Show Library Health: it shows the health view and runs the report again. The
  menu item stays in File beside Watched Folders…; the palette and `music-player checkHealth`
  come from the same entry. Settings ▸ General ▸ Library gets a Show Library Health button,
  a `SettingsActions.showHealth` the app wires to the same command, which brings the main
  window forward.
- Sidebar: the Library Health row and its check rows go. While a health check shows, no
  sidebar row is selected, so a click on Music leaves it.
- The panel slot: the split's first subview becomes a slot that holds the browser columns or,
  while the source has one, a source panel in their place, at the same height and divider,
  resized and saved as the columns are. A panel is an `NSViewController` the browser names for
  a source (`panel(for:)`); the slot shows it whether or not Show Browser is on, and the
  columns come back as they were when another source shows. Phase 43's Stats panel is a second
  case in `panel(for:)`.
- The health panel: a header (Library Health, what the report is, Check Again) over a grid of
  tiles that flows with the width, one per check in `HealthCheck` order, each with its name,
  its count and what it finds; a check with nothing found is dimmed, the shown one is
  highlighted. A click shows that check. Before a report the counts read "–". Showing a check
  clears the column selections, since the hidden columns would narrow it with nothing on
  screen saying why.
- Saved state: a saved `health:<check>` source (the resume point's `source` or `from`) still
  decodes. At launch the window shows the library in its place, logged; `from` keeps naming
  the queue's source. No key changes in either file.
- Tests: the sidebar lists no Library Health; Show Library Health shows the panel in the
  columns' place with the report's counts, a tile's click lists its tracks and highlights it,
  another source puts the columns back; the panel shows with Show Browser off; the divider
  saves its height under the panel; showing a check clears the column selections; a saved
  health source loads the library; the Settings button calls its action.
- Order: this plan, the sidebar and the command, the slot and the panel, settings, the ADR,
  `--snapshot` if it can show the panel, then the result.

Result, part 42d: shipped 42d.1 and 42d.2 (ADR 0099, amending 0034 and 0042). Library Health
left the sidebar, with its count cell. Show Library Health (`library.checkHealth`, the ID Check
Library Health had, so a rebinding holds) is in the File menu where Check Library Health was,
in the palette, on the command line, and a button at the end of Settings ▸ General ▸ Library;
it brings the main window forward, shows the check shown or else Unreadable, and runs the
report. The browser's split now starts with a slot that holds the browser columns or the
source's panel, `LibraryBrowser.panel(for:)`, at the columns' height and divider, saved as
theirs; a panel shows with Show Browser off too. The health panel has a header (when it was
checked, or Checking…, and Check Again) over a tile per check, flowing at 180 points or more
each, with the name, the count and what it finds; zero dims a tile, the shown check is filled
with the accent color, and a click lists it. Showing a check selects All in the hidden columns.
While a check shows no sidebar row is selected. A saved `health:<check>` source shows the
library at launch, logged, and the rest of the play state reads as before; no key in either
file changed. `--snapshot-of health` draws it. Checked in `--snapshot` against the 120-file
fixture library: the tiles, counts and dimming, and a relaunch from a saved `health:unreadable`
showing Music. Not checked on screen: dragging the divider under the panel, glass, dark mode,
and macOS 12. `./scripts/check` passes, `theGlassHeadersAreFrosted` included this time; the
LibraryBrowserTests process still exits partway through a full run (40d), so the new browser
tests were also run by name, and pass. For the owner: Show Library Health from the menu and
from Settings, click through the tiles, drag the divider, then click Music.

#### 42e. Get Info speed and tag writes

- [x] **42e.1 Get Info at any time.** Get Info opens at once on any track or selection,
      including while a tag write is running; more than one info window can be open.
- [x] **42e.2 Rescan after a write.** After a tag write, the track's tags are read again at
      once and the table, info window and columns show them.
- [x] **42e.3 Speed review.** Review the open, edit, write and rescan path for speed on the
      2015 MacBook Pro, with bench rows for opening Get Info and for one write.
- [x] **42e.4 "Something else replaced the temp file".** Writing a FLAC on the NAS failed with
      "something else replaced the temp file while the tags were written". Find why and fix it.

Plan, part 42e (ADR 0100):
- Probe (done before this plan): Get Info is `TagEditing.open`, which refuses while a sheet is
  open or a write runs (`isBusy`), asks first above 25 files (ADR 0081), reads every file, and
  only then shows `TagEditorSheet` as a sheet on the main window, so one editor at a time and
  none while a write runs; ⌘I is disabled meanwhile. Save closes the sheet and writes in a
  detached task; a batch asks in a sheet on the main window. After a write the app calls
  `LibraryWatcher.rescan(directories:)`, which queues the folder behind any running scan and,
  for a network folder with `library.pausePollingDuringPlayback`, waits until playback stops:
  that wait is the slow update. Each file the editor reads is opened three times (tags, art,
  fields holding several values); the writer opens the original five times and the temp file
  four, and reads the whole file three times (hash, copy, read-back), since SMB can't clone.
  The temp-file error comes from `requireUnchanged`, which compares the temp file's device,
  inode, size and mtime just before the rename with an `fstat` taken while it was still open
  for writing. An SMB server sets a written file's last write time when its handle closes
  (MS-FSA 2.1.5.4; Samba also delays it up to 2 s), so on the NAS the mtime moves after the
  `fstat`, and every whole-file write there fails the check. APFS sets the mtime at each write,
  so the build Mac never sees it.
- 42e.4: `writeTemp` closes the temp file first, then takes its identity by name and checks
  the name still holds the file it wrote (device and inode). The check before the rename is
  unchanged: same device, inode, size and mtime, one link. A fault point where the temp file
  closes lets a test move the mtime there, as the server does; the test fails on the old order.
  The two "temp file" failures get details of their own, and a mismatch logs both identities.
- 42e.1: Get Info opens a window (not a sheet) at once, before any file is read, showing the
  heading and "Reading tags…"; the fields fill in when the read ends. Several windows can be
  open; Get Info on the same tracks as an open window brings that window forward. ⌘I is
  enabled whenever tracks are selected. Closing a window that's still reading stops its read
  between files, so the 25-file question goes: nothing waits on the read any more. Save writes
  one file at once; a batch asks in a sheet on the info window, and No leaves the window open
  with what was typed. Writes and undos go to one serial queue in the order saved; the window
  closes at Save and other windows stay usable. Replace and Remove Artwork act on the key info
  window.
- 42e.2: a write's files are read again at once: `LibraryWatcher.rescan(files:)` runs
  `LibraryScanner.rescan(files:)` on a queue of its own, not behind a scan and not waiting for
  playback, storing each file the index knows with its new size and mtime, and sends
  `WatcherEvent.edited`, on which the browser refreshes its rows and columns. The folder rescan
  still follows, as a backstop for a scan that read the file before the write and stores it
  after; it finds nothing changed. An open info window on a written file reads it again,
  keeping what was typed.
- 42e.3: the editor reads each file through one open (tags, art and several values from the
  same descriptor, the first 16 KiB read once); the writer reads the original's tags, layout,
  replaced bytes and art through one open, and the temp file's tags, layout and art through one.
  The hash, the copy and the read-back stay: they are the write's safety (ADR 0020). Writing in
  place within the padding is considered in the ADR and left for the owner to decide. Bench rows,
  on fixture files only: Get Info on one track to its window and to its fields, Get Info on 100
  tracks to their fields, and one FLAC's title written and read back into the index; the slow
  NAS read row counts one open a file.
- Tests: the SMB close (mtime moved when the temp closes, the write succeeds; the swap tests
  still refuse); Get Info while a write is held, two windows, the same tracks focusing the open
  window, writes in order, a batch declined keeping the window, closing a reading window
  stopping its read, a written file re-read in an open window keeping typed text; the scanner's
  file rescan (new tags stored, a file the index doesn't know skipped, a missing file reported);
  the browser refreshing on `edited`; one open per file read.
- Order: this plan, 42e.4, the scanner's file rescan, the editor windows and queue, the reads,
  the bench, the ADR and the result.

Result, part 42e: shipped 42e.1 to 42e.4 (ADR 0100). Cause of 42e.4: the writer took the temp
file's identity with `fstat` while it was still open for writing and compared it, mtime
included, just before the rename; an SMB server sets a written file's mtime when its handle
closes (MS-FSA 2.1.5.4), so every whole-file write on the NAS failed the check, and APFS, which
sets it at each write, never showed it. The identity is now taken after the close, once the
name is known to still hold the file written; the check before the rename is unchanged. Get
Info opens a window at once on any selection, while writes run too, and fills it when the read
ends; several can be open, the same tracks bring their window forward, closing one stops its
read, and the 25-file question is gone. Writes and undos queue one at a time in the order
asked; a batch asks in its own window, and No keeps what was typed. A write's files are read
again at once by `LibraryWatcher.rescan(files:)`, not behind a scan or playback, and the rows,
columns and open info windows show them; the folder rescan follows as a backstop. Each file is
read through one open in the editor, and the original and the temp file once each in the
writer. Bench on Apple Silicon (fixture files, median of 5): Get Info on one track 5.1 ms to
its window and 31 ms to its fields, on 100 tracks 43 ms to their fields, one FLAC title written
and read back 12.7 ms (write 9.9, rescan 2.6); the slow NAS read of 200 files 0.57 s, down from
the 3.2 s of 32d mostly because the model now charges one open a file, not three, which is what
the change saves. Tests: the mtime moved at the close (FLAC, MP4, MP3, written and undone; fails
on the old order), a swap at the close and a change after it refused, the swap tests as before;
Get Info while a write is held, several windows, the same tracks focusing, writes and undo in
order, a declined batch keeping its window, a closed window stopping its read, an open window
read again after a write, the model keeping typed text over a reread; the file rescan (stored,
a folder scan after finds it unchanged, an unknown path skipped, a gone file reported) and
during paused polls; the browser refreshing on `edited`; one open reading what three did. The
one-open count itself isn't asserted, only that it reads the same. Left for the owner: writing
in place within the padding, which would cut a NAS write from about four transfers of the file
to a few kilobytes but gives up ADR 0020's temp file; see ADR 0100. For the owner: on a copy of
a NAS FLAC, edit a tag and check it saves without the error, reads back in Swinsian, and Undo
Tag Edit puts it back; open Get Info on two selections while a batch writes; edit a track while
one plays and watch its row change at once. `./scripts/check` passes clean; an earlier run in
the session failed `glassOnThenOffLeavesTheWindowAsAFreshOne`, which reads the screen, and
`aColorPickedInThePanelIsSavedAndDefaultClearsIt`, a 5 s wait, neither touched here, and both
passed on the run after.

#### 42f. Listening Stats

See phase 43.

#### 42g. Get Info fields as in YATE

- [x] **42g.1 Field review.** Compare Get Info's fields with YATE's panels (Info, Artwork,
      Sorting, Lyrics, Audio, Credits, More Info, Privacy, URLs). Every field YATE edits that
      the tag writer can write is editable, grouped so it's easy to find: the main tags; sorting
      next to the field it sorts; credits; more info (key, language, dates, mood, work and
      movement); rights and label; URLs; lyrics; artwork; and a read-only audio summary.

Plan, part 42g (ADR 0101):
- Probe: the reader already reads 16 fields beyond the editor's (grouping, BPM, key, conductor,
  lyricist, label, copyright, encoded by, description, disc subtitle, work, movement and its
  name, original date, catalog number, barcode) and the index stores them all; Get Info shows
  and the writer writes only title, artist, album, album artist, genre, date, composer,
  comment, track and disc with their totals, compilation, and the front cover. The writer's
  read-back check compares every field of `TrackTags`, so a field added there is covered by it.
- Audit. "Read" is what the reader reads and the index stores today; "Info" what Get Info
  shows; "Write" what this part makes the writer write, in FLAC (Vorbis comments), MP4 (`ilst`)
  and ID3v2.3 and 2.4 (MP3, AIFF, WAV). Keys follow MusicBrainz Picard as ADR 0006 does, and
  Mp3tag's where Picard has none (the `WWW…` URLs); ADR 0101 lists every key.

  | YATE field | Read | Info | Write in this part |
  |---|---|---|---|
  | Title, Artist, Album Artist, Album, Year, Track n of m, Disc n of m, Composer, Genre, Comments, Compilation | yes | yes | as before |
  | Grouping, BPM | yes | no | yes |
  | Rating | app's own (ADR 0068) | no | omitted: ratings are the app's state in the index, and a file write per star click is the opposite |
  | Skip When Shuffling | no | no | omitted: iTunes database only |
  | Artwork: pictures, primary, type, description | front cover | front cover | as before: the front cover replaced or removed; the tab shows its type, pixels and size. Other pictures are kept byte for byte, not listed |
  | Sort Title, Sort Artist, Sort Album Artist, Sort Album, Sort Composer | no | no | yes (`TSOT`…`TSOC`, `…SORT`, `sonm`…`soco`) |
  | Lyrics | no | no | yes (`USLT`, `LYRICS`, `©lyr`) |
  | Encoded By | yes | no | yes |
  | Media Type | no | no | yes, as Picard's Media (`TMED`, `MEDIA`), free text such as "CD" |
  | File Type, Bit Rate, Sample Rate, Channels, Time, File Size, Tag Scheme, Mod Date | from the file | no | read-only in the File tab |
  | Encoder Settings, Encoding Time, Tagging Time, Music CD Identifier | no | no | omitted: set by the encoder or tagger, not edited by hand; no MP4 key |
  | Play Count, Playlist Delay, Reverb, Start Time, Stop Time, Volume Adjustment, Remember Position | no | no | omitted: iTunes database or player settings, not tags the library owner edits |
  | ISRC | no | no | yes (`TSRC`, `ISRC`) |
  | Conductor, Lyricist | yes | no | yes |
  | Remixer, Original Artist | no | no | yes (`TPE4`, `TOPE`) |
  | Original Lyricist | no | no | omitted: rare; `TOLY` has no Vorbis or MP4 key in use |
  | Involved People, Musician Credits | no | no | omitted: one ID3 frame of role and name pairs against a key per role in Vorbis and MP4, so no field maps onto all three; a follow-up could add Producer, Engineer and Mixer as fields |
  | Initial Key, Release Date (our Date), Original Release Date, Description, Set Subtitle, Work Name, Movement Name, Movement n | yes | no | yes |
  | Movement of m | no | no | yes (`MVIN` n/m, `MOVEMENTTOTAL`, `©mvc`) |
  | Language, Mood, Original Album | no | no | yes (`TLAN`, `TMOO`, `TOAL`) |
  | Content Advisory, Category, Show Work Name, Original Filename | no | no | omitted: iTunes and podcast items with no Vorbis key |
  | User Defined Text Info Items | no | no | omitted for now: a list editor of free keys, whose mixed values across a selection need a design of their own; the named fields cover the TXXX and freeform keys Picard writes |
  | Copyright, Label (with Publisher), Catalog Number | yes | no | yes; Label and Publisher are one field, as in the reader since phase 16 |
  | Barcode | yes | no | yes |
  | Owner, Purchase Date, Price Paid, Seller, Radio Station, Station Owner, Produced Notice, Terms of Use | no | no | omitted: ID3-only frames (or iTunes store data) with no Vorbis or MP4 key |
  | Artist, Audio File, Audio Source, Commercial, Copyright, Payment, Publisher, Radio Station webpages | no | no | yes (`WOAR`…, `WWW…`, `----:WWW…`); ID3 URL frames hold Latin-1 only, so other text is refused there |
  | Podcast URL, User Defined URLs | no | no | omitted: podcasts; free keys as above |

- Index: no schema change. A change to the index part's SQL drops and rebuilds that part, which
  means reading every file again (an hour or more over the NAS), while plays, history, ratings
  and playlists are kept by path ID (the stats part). Nothing here needs a column or a search,
  so the new fields live only in the files: the reader reads them into `TrackTags` and the
  index stores the same columns as before. A text frame the reader now maps (`TXXX:DESCRIPTION`,
  `TXXX:MOOD`, `TXXX:ORIGINALDATE`) shows in a column once its file is next rescanned.
- Writer: the fields become table-driven: each text field names its `TrackTags` property and
  its key in each format, next to the reader's maps in `Metadata`, so the reader and the writer
  read one table. ID3 learns to write `TXXX` by description, `USLT` like `COMM`, and URL frames;
  MP4 learns iTunes freeform (`----`) items by name and 16-bit integers (`tmpo`, `©mvi`,
  `©mvc`); the layout and the several-values check name those blocks' fields too, so the round
  trip's untouched-block check covers them. 2.4-only frames use 2.3's spelling in a 2.3 tag:
  mood and disc subtitle as `TXXX`, an original date as `TORY` when it's a year, else `TXXX`.
  Grouping is written to `GRP1` when the file has one (iTunes's grouping), else `TIT1`.
- Get Info: a tab view, with Info (YATE's compact layout: title; artist and date; album artist
  and track; album and disc; grouping and BPM; composer; genre; comment beside the art;
  compilation), Sorting (each sort field above the field it sorts, the latter editable there
  too), Credits, Details (YATE's More Info), Rights & Label, URLs, Lyrics, Artwork (a large
  preview, its type, pixels and bytes, Replace and Remove) and File (read-only). Every field
  shows Mixed across a selection as before, and a dot by its label once it's edited.
- Tests: per format (FLAC, MP4, MP3 2.3 and 2.4, AIFF, WAV) every new field written, read back,
  found in the key the ADR names, and undone; clearing; 2.3's spellings; URL refusal; grouping
  into `GRP1`; the editor model's mixed and edited state for the new fields; the reader reading
  the new keys. Bench rows of 42e re-run; the window checked with `--snapshot-of tags`.
- Order: this plan, the table-driven fields, the writer's new keys, the editor's tabs, the
  snapshot pass, the ADR and the result.

Result, part 42g: shipped 42g.1 (ADR 0101). Get Info edits 38 more fields: grouping, BPM, key,
conductor, lyricist, remixer, original artist, label, copyright, catalog number, barcode, ISRC,
encoded by, description, disc subtitle, work, movement number, total and name, original date
and album, language, mood, media, lyrics, the five sort fields and eight webpages, each written
and read back in FLAC, MP4 and ID3v2.3 and 2.4 through the writer's usual temp file, checks and
undo journal. Each field's keys sit in one table beside the reader's map, which is built from
it. The omissions and their reasons are in the table above and the ADR; the largest are
involved people and musician credits, and user-defined text and URLs. Get Info is now tabs:
Info (compact, as YATE's), Sorting (each sort field above the field it sorts), Credits, Details,
Rights & Label, URLs, Lyrics, Artwork and File (read-only format, rate, depth, length, bit rate,
size, tag kind and dates). Mixed values work for every field, and a dot marks a field once
edited. No index change: the new fields live in the files and are read on Get Info, so the
owner's library isn't rebuilt (a schema change would rescan every file, keeping plays and
history). Bench on Apple Silicon (fixture files, median of 5): Get Info on one track 7.3 ms to
its window and 29.9 ms to its fields, on 100 tracks 51 ms, the FLAC title write and read back
14.4 ms; making every tab at open had cost 55 ms to the fields, so each tab is made when first
shown. Checked with `--snapshot-of tags` against fixture files, one tagged FLAC and a selection
of three, every tab; not checked: dark mode, macOS 12, a real picture in the Artwork tab.
Tests: every new field per format written in its named key, read back, cleared and undone, with
blocks outside the edit unchanged; 2.3's year frame, `GRP1` kept, a described `USLT` kept, a
non-Latin-1 URL refused in ID3 and taken in FLAC; the reader on other taggers' spellings; every
field on a tab and each sort field above its field; the model's mixed and edited state; the File
tab's text. For the owner: on copies of a FLAC, an MP3 and an M4A, fill in a few fields on each
tab, save, and check them in Picard or Mp3tag and in YATE; check Get Info across an album shows
Mixed where tracks differ, and that the tab chosen is the next window's. `./scripts/check`
passes clean.

### 43. Listening Stats

Part 42f. A Stats source for the owner's listening history, with the visual panel above the
table that 42d builds for Library Health. The owner's answers: imported plays (ADR 0033) are a
separate count, not ranked in any period; top lists rank by plays by default, with a toggle to
hours; a Year in Review page is part of this phase; Stats is a sidebar source.

- [x] **43.1 Stats source.** A Stats item in the sidebar's Library group after Timeline, saved as
      a source like the others. A period picker: This Week, This Month, This Year, a chosen year,
      All Time.
- [x] **43.2 Totals.** For the period: plays, approximate hours (the sum of the track's length
      per play, labeled as approximate), distinct tracks, artists and albums, and the share of
      the library played. All Time also shows imported plays without dates as a separate count.
- [x] **43.3 Top lists.** Top artists, albums, tracks and genres, by plays (default) or hours.
      Plays whose path is no longer in the library count toward totals and show as "not in the
      library".
- [x] **43.4 Charts.** Plays per day, week or month as bars, and a weekday × hour grid, drawn in
      AppKit (no Swift Charts, no dependencies). Days and weeks use the local calendar and the
      system's first weekday.
- [x] **43.5 First played.** Albums and artists first played in the period.
- [x] **43.6 Formats.** Plays by codec and by sample rate group (CD quality, hi-res PCM, DSD).
- [x] **43.7 Everything navigates.** An artist or album row shows it as Go to Item does
      (ADR 0046), a bar shows the Timeline for its span, and a top list can be saved as a
      manual playlist.
- [x] **43.8 Year in Review.** A page for one year built on the same queries: the year's totals,
      top lists, its busiest month and day, and what was first played that year.
- [x] **43.9 Command line and palette.** `music-player stats [--period ...] [--json]` and the ⌘K
      rows come from the same command registry entries as the UI.
- [x] **43.10 Speed.** Bench rows with budgets for opening Stats and changing the period with
      1,000,000 history rows generated in the fixture library; queries off the main thread;
      whether an index on `history (played_at, path_id)` is needed is measured, not guessed.
- [ ] **Hardware checkpoint (owner):** open Stats and change periods on the 2015 MacBook Pro
      with the real library; report the times against the bench rows.

Deferred: skip statistics by period (skips have no dates; no new table in this phase).
Read-only: Stats writes nothing but a playlist the owner asks for.

Plan, phase 43 (ADR 0102, amending 0099):
- Probe (done before this plan): only `history` rows have dates, whole seconds since 1970, and
  nothing indexes `played_at` (ADR 0022); `history_path (path_id)` is the one index. An import
  adds to `plays.play_count` and no history row (ADR 0033), so the plays without dates are the
  sum of `play_count` less the history rows. A path no longer in `files` keeps its last codec,
  rate, length and title in `paths`. Measured with `sqlite3` on a copy of Bench's library of 1M
  synthetic plays over the 43k fixture tracks (Apple Silicon): a period's plays per path with
  SQLite's own plan take 0.62 to 0.72 s, since it walks `history_path` and looks up every row;
  the same with `NOT INDEXED` (a scan of the table) 16 ms for a week, 23 ms for a year, 194 ms
  for all time, where the plain plan reads the covering `history_path` in 22 ms; the period's
  plays per hour 19 ms; every path's first play 240 ms. With an index on `history (played_at,
  path_id)` the week takes 0.1 ms and the year 8 ms, and the index takes 16 MB, 55% more than
  the history and its index now. The schema is checked by its SQL text per part
  (`SchemaPart`): a change to `statsSchema` would rebuild the stats and discard the owner's
  history, so an index, if one were needed, would be a part of its own, like `recorded`, whose
  rebuild drops nothing. Decision for now: no index; Bench decides, against budgets set below.
- Settings: `PlaySpan` (start and end seconds, half open) and `StatsPeriod` (`week`, `month`,
  `year`, `year(n)`, `all`), whose span comes from `Calendar` (local time zone, the system's
  first weekday). `BrowserSource.stats(period)`, saved as `stats:week` … `stats:2024`,
  `stats:all`, and `BrowserSource.plays(span)`, the timeline of a span, saved as
  `plays:<start>-<end>`. `window.statsHeight`, an added state key (default 380), the panel's
  height while Stats shows, so dragging it taller leaves the browser columns as they were.
- Library: `StatsReport`, built in Swift from two scans of the period (plays per path, joined
  to `tracks` and `paths`; plays per hour, or per quarter hour in a time zone with an offset
  that isn't whole hours) and the first play of every path: totals, approximate hours, distinct
  tracks, artists, albums, the share of the library, plays not in the library, undated plays
  for All Time, top 25 artists, albums, tracks and genres by plays and by hours, bars per day
  (week, month), week (year) or month (all time), the weekday × hour grid, albums and artists
  first played, and plays by codec and by rate group (CD quality up to 48 kHz, hi-res PCM,
  DSD). Local days come from the zone's offset at each bucket; bars from `Calendar` intervals.
  `StatsReader`, an actor on its own read-only connection, runs the scans and keeps every
  path's first play until `PRAGMA data_version` says another connection wrote. Sources:
  `.stats` lists the period's tracks, `.plays` throws as `.timeline` does; the timeline pages
  and counts with an optional span.
- LibraryBrowser: Stats after Timeline in the sidebar. `StatsModel` (no AppKit) loads a report
  per period and ranking off the main thread, dropping a late one, and answers what a click
  does. `StatsPanel` (`SourcePanel`): a header (Listening Stats, the period picker with a year
  menu, Plays or Hours, Year in Review) over cards that flow as the health tiles do and
  scroll: totals, plays over time (bars), the week's clock (grid), the four top lists, first
  played, formats. A top artist or album shows it as Go to Item does, a genre filters, a track
  selects it in the table below, a bar shows `.plays(span)`, each list's Save as Playlist makes
  a manual playlist of its tracks played in the period. Year in Review is a window of its own
  for one year, from the header or the command, built from the year's report.
- Commands: `library.stats` (Show Listening Stats, argument `period`) and
  `library.yearInReview` (Show Year in Review), in the File menu after Show Library Health and
  so in the palette. `music-player stats [--period <period>] [--json]` runs the first, shows
  Stats and prints the totals and top lists, or the report as JSON; `--period` and `--json`
  go only with it (and `--json` with `status`). `--snapshot-of stats` and `review`.
- Tests that fail without each part: period spans across a year boundary and the first
  weekday; a play at 23:59 and one at 00:01 on two days; a DST day's hours; a 30-minute zone;
  totals, hours, missing plays and undated plays; top lists by plays and hours; first played
  across periods; formats; source texts round-trip and the old ones still decode; the `.stats`
  source lists the period's tracks; the timeline of a span; the panel's cards show the report,
  a bar's click shows its span's plays, an album row shows it as Go to Item, Save as Playlist
  makes the list; the stats height is kept apart from the columns'; the command line parses
  `--period` and `--json`; the router answers `stats` with text and JSON.
- Bench: "stats: open Stats, 1M synthetic plays" (first plays and This Month's report) and
  "stats: change the period, 1M synthetic plays" (each period in turn), p95; budgets set from
  the first measurement with room for the old Mac.
- Order: this plan; Settings; Library with its tests; Bench, and the index decision; the panel,
  sidebar and model; navigation and playlists; Year in Review; commands and the command line;
  snapshots; the ADR; `./scripts/check`; the result.

Result, phase 43: shipped 43.1 to 43.10 (ADR 0102, amending 0099 and 0036). Stats is a sidebar
row after Timeline, saved as `stats:<period>`; its panel takes the health panel's slot at a
height of its own, `window.statsHeight` (380 by default, the one added state key), with a
header (the four period segments, a year menu from the first dated play to now, Plays or
Hours, Year in Review) over cards that flow and scroll: totals (plays, hours marked approximate,
tracks, artists, albums, share of the library, the span, plays not in the library, and for All
Time "+N imported plays without dates, not ranked"), plays per day, week, month or year, a
weekday × hour grid in the calendar's first weekday, the four top 25 lists (missing plays a
dimmed "Not in the library" row), First Played (albums or artists) and Formats (rate groups as
a bar: CD quality, hi-res PCM, DSD and lossy, then codecs). The track table lists the period's
tracks. An artist or album row goes to it as Go to Item does, a genre filters, a track is
selected below, a bar shows `plays:<start>-<end>` in the timeline with the span in the status
bar, and each list saves a manual playlist of its played tracks. Year in Review is its own
window for one year (totals, busiest month and day, new albums and artists, months with the
busiest marked, top tens, first played, clock, formats). Show Listening Stats (`library.stats`)
and Show Year in Review are in the File menu and the palette; `music-player stats [--period
<period>] [--json]` shows Stats and prints the totals and top lists or the report as JSON.
Bench, Apple Silicon, 1M synthetic plays: opening Stats 285 to 366 ms over runs (budget
400 / 1500 old Mac), changing the period 159 to 168 ms p95, All Time the slowest (budget 250 /
900); This Week 26 ms, This Month 25 to 28, a year 57 to 74. No index on `history (played_at,
path_id)`: with one the week and month took 2 ms and a year 35, opening and All Time didn't
change, and it would add 16 MB, so every period is within budget without it; the scans say
`NOT INDEXED`, since SQLite's own plan took 0.7 s a period. Were one added it would be a schema
part of its own, since a change to the stats part's SQL discards the history. Checked on screen
with `--snapshot-of stats` and `review` against a copy of Bench's 43k-track fixture library
with 23k generated plays: the cards, the grid, the lists and the review page (the fixture
tracks have no length, so hours read ≈ 0). Not checked on screen: hover, clicks, dark mode,
glass, macOS 12, and the command line against a running app (the scratch folder's socket path
is too long for a socket; the router, parser and the browser's text and JSON are tested).
`./scripts/check` passes but for `aColorPickedInThePanelIsSavedAndDefaultClearsIt`, which timed
out in the full run and passes alone; the new browser tests were also run by name, and pass.
For the owner: open Stats, change periods and rankings, hover the bars and grid, click a bar,
an album and a track, save a list, open Year in Review, drag the panel's divider and then show
Music to see the columns keep their height, and time it on the 2015 MacBook Pro.

### 44. Owner feedback, 2026-11-05 (second round)

The owner's feedback from trying phases 42 and 43. Parts 44a to 44e run in parallel worktrees
and merge onto main in order a, b, c, d, e. ADR numbers are given out ahead so they don't
collide: 44a 0103, 44b 0104, 44c 0105, 44d 0106, 44e 0107. Each part keeps the owner's window
layout, column widths, toolbar and settings, as phase 42's did: a state or config key changes
only by adding an optional key, and the owner's current `state.json` and `config.json` still
decode after the part (checked against a copy, not the files themselves).

The owner's answers: tag saves write in place when the new tag fits the file's padding and
keep the temp file otherwise; a click in Stats filters the track table under the panel instead
of leaving Stats; each Swinsian track's last-played date counts as one dated play in Stats;
each browser column's grouping lives in `config.json`. Answered without a change: storing the
sync logs compressed (see Later in [plan.md](plan.md#later)).

#### 44a. Keys, Get Info's place and Library Health

- [x] **44a.1 Option-arrow seeks.** ⌥→ and ⌥← seek forward and back 10 s, replacing ⌃→ and
      ⌃←; ⌥⇧→ and ⌥⇧← replace ⌃⇧→ and ⌃⇧←. A text field being edited still takes them to
      move by word (`KeyChord.isTextEditing`).
- [x] **44a.2 Longer step.** ⌥⇧→ and ⌥⇧← seek by 5% of the track or 30 s, whichever is longer.
- [x] **44a.3 Get Info's place.** A Get Info window opens where the last one was moved to,
      across launches.
- [x] **44a.4 Wider health cards.** Library Health's cards are wide enough that a card's
      description usually shows whole.
- [x] **44a.5 Show Library Health toggles.** With Library Health showing, Show Library Health
      hides it and shows the track table, at the playing track when there is one.

Plan, part 44a (ADR 0103, amending 0096, 0099 and 0100):
- Probe: Seek Forward and Seek Back have ⌃→ and ⌃← as second chords, Seek Forward 5% and Seek
  Back 5% ⌃⇧→ and ⌃⇧←, in `AppCommands`; nothing else is bound to ⌥→, ⌥←, ⌥⇧→ or ⌥⇧← (→ and ←
  alone are Next and Previous Track), and `KeyChord.isTextEditing` already gives all four to a
  field being edited, through the app's key monitor, in every window. The 5% step is
  `seekSeconds`, nothing with no duration. An info window opens a cascade step from the last
  one opened, a static point that starts near the main window's top left each launch.
  Health tiles are 180 points or more; at that width four of the thirteen descriptions fit.
  Show Library Health (`library.checkHealth`) only shows the panel.
- 44a.1 and 44a.2: ⌥→ and ⌥← replace ⌃→ and ⌃←, ⌥⇧→ and ⌥⇧← replace ⌃⇧→ and ⌃⇧←, same IDs. The
  step is `max(5% of the duration, 30 s)`, 30 s with no duration; the commands say "5% or
  30 s". ADR 0012's table follows.
- 44a.3: an added optional state key, `tagEditor.place`, the top left corner of the info
  window the user last moved; a new window opens there, a step past any open info window at
  that corner, and near the main window when the key is null or on no screen. Only moves after
  the window shows are saved, through the layout saver.
- 44a.4: tiles of 330 points or more, so ten descriptions show whole.
- 44a.5: the command, with the panel showing, shows the playing track as Show Current Track
  finds it, else the whole library; a play started from a check goes to the library. The menu
  item is checked while the panel shows; Settings' button doesn't hide it.
- Tests: the chords, titles and menu places, the old chords unbound, the four chords
  text-editing, the step for long, short and unknown durations; an info window's start place,
  a move reported and the app's placing and the growth on load not, a second window stepped
  past the first, the place given to the next window and passed on to save, the key saved
  and read back with an older file reading null; most descriptions whole at the narrowest
  tile, failing at 180; the toggle there and back, with and without a playing track.
- Order: the seeks, Get Info's place, the tiles, the toggle, then the ADR and the result.

Result, part 44a: shipped 44a.1 to 44a.5 (ADR 0103, amending 0096, 0099 and 0100). Seek
Forward and Back take ⌥→ and ⌥← as their second chords, and Seek Forward and Back 5% or 30 s
(the same IDs) ⌥⇧→ and ⌥⇧←, which move 5% of the track or 30 s, whichever is longer, and 30 s
when the duration is unknown. The Control-arrows are unbound. An info window opens with its
top left corner where the user last moved one, saved as the optional state key
`tagEditor.place`, a step down and to the right of an info window already there; with none
saved, or on no screen, near the main window as before. Health tiles are 330 points or more:
ten descriptions show whole, the three longest are cut and whole in the tooltip. Show Library
Health, with the panel showing, shows the playing track in what the window showed when the
play started, else the library, or the whole library with nothing playing or a play from a
check; its menu item is checked while the panel shows, and Settings' button only brings the
window forward then. One state key added, no config key changed; the owner's `state.json` and
`config.json`, copied to a temporary folder, decode with the new schema. Checked by tests
only. For the owner: ⌥→ and ⌥⇧→ while playing a long and a short track, and ⌥→ in the search
field moving by word; Get Info moved somewhere, closed, opened again, and opened again after
a relaunch; two Get Info windows at once; Library Health's tiles at the usual window size;
Show Library Health twice while a track plays. `./scripts/check` passes but
for one test, `theGlassHeadersAreFrosted`, whose screen capture came back blank (every pixel
0, the red under the glass too) with the machine idle, in the full run and alone; this part
changes nothing it draws.

#### 44b. Enter on the next track keeps the queue panel

- [x] **44b.1** With the queue panel open, Enter or a double-click on the track after the
      playing one in the track table moves the queue as Next does, without the panel reloading
      every row. A rebuild when the queue does change is fine.

Plan, part 44b (ADR 0104, amending 0097):
- Probe (done before this plan): with the kept queue handed over, the engine's
  `play(entry:ifQueueIs:)` makes Next's calls (`move(to:)` and `load`), so its state is Next's,
  and `QueuePanel.show` drops the played rows as on Next. The model rarely hands it over:
  `BrowserModel.refresh` forgets the kept list, and a counted play, a counted skip, a rating
  and an opinion all refresh, as does every scan's progress, a network folder's empty poll
  included. A track counts a play partway through, and Enter on the next track counts a skip,
  so the list was gone before most Enters. A refresh during the queue read dropped the queue
  read for the play too.
- Edits that move no file (rating, opinion, counted play and skip) run the queries again
  without touching the kept list. A library change checks the kept list instead of forgetting
  it: its files are read again on the refresh connection, and it stays kept while every file is
  where it was. A play keeps it only once checked. A queue read across a change is kept and
  checked the same way.
- Launch: the restored queue (ADR 0095) is kept as a play's, so the first play from the same
  list, the source unfiltered in its sort, plays in it; the engine's check still refuses a
  restored queue that was replaced or edited.
- Tests: a counted skip, play and rating keep the queue, a rescan that moved nothing keeps it,
  and one that moved the files forgets it; a play from the list the play state was restored
  from carries the restored queue.
- Order: this plan, then the change through the tests, `./scripts/check`, then the result.

Result, part 44b: shipped 44b.1 (ADR 0104, amending 0097). The panel already moved as on Next
whenever the play went in place; the play went in place only until the next refresh of the
track list, and a refresh came with each counted play or skip, each rating, and each scan's
progress, so after the first track, or the first Enter, every play rebuilt the queue. Counts,
ratings and opinions keep the kept list now, and a library change reads the list's files again
and keeps it when none moved, which for the whole library (43k tracks on the build Mac) is a
read of under 60 ms off the main thread, once per refresh while a list is kept. The play state
restored at launch counts as the last play, so the first Enter after launch on the next track
plays in place when the table shows the source it was played from, unfiltered. No state or
config key changed, and nothing on the real-time thread. Checked by tests only, nothing on
screen. For the owner: with the queue panel open, Enter on the next track after the playing one
has counted a play, after a rating, during a network folder's poll, and as the first play after
a launch; the panel should move up as on Next. A list narrowed by the columns or a search at
quit is restored as its whole source, so the first play from the narrowed list still builds the
queue.
`./scripts/check` passes but for its test step, where `theGlassHeadersAreFrosted` (which
reads the screen) fails in the full run and alone, the same with this part's change undone.

#### 44c. Listening Stats stays put, and counts Swinsian's plays

- [x] **44c.1 Clicks filter.** A click on an artist, album, genre or track in Stats stays in
      Stats; the track table under the panel shows that item's tracks played in the period,
      with a way to clear the filter.
- [x] **44c.2 Swinsian's last plays.** Each imported track's last-played date counts as one
      dated play in every period, its totals, top lists and charts; the rest of its imported
      count stays undated. The totals say how many plays came from an import.

Plan, part 44c (ADR 0105, amending 0102 and 0033):
- Probe (done before this plan): the index keeps no copy of an import's last played. An import
  sets `plays.last_played_seconds` to the later of ours and theirs, and a play here sets it
  again. Read from a copy of the owner's library: 11,282 `imported_plays` rows for Swinsian,
  11,172 with plays (43,293 in all), 122 history rows, and 70 imported tracks with a history row
  at or after their Last Played. A copy of the owner's Swinsian database has 11,202 tracks with
  plays, each with a last played, the earliest in February 2022. Changing `importsSchema` would
  rebuild the imports part and drop the baseline, and the next import would add every play
  again, which the owner can't undo; the stats part's SQL can't change either (phase 43). A new
  part rebuilds nothing else (`rebuildStaleParts` builds a part with no stored SQL alone).
- Library: a part `importedLastPlays`, `imported_last_plays (path_id, player, played_at)`, its
  SQL filling it from Last Played where one player alone counted plays for the path and no
  history row is at or after it. An import records the source's last played for each track it
  counted plays for (the later of two), the preview counts them, and the counts event carries
  it to the other Macs, which record it; a merge of two paths and a deleted path take theirs.
  `importedLastPlaysSQL`, the recorded last plays whose player still counts a play, is unioned
  with the history in the period scans, the first plays, and the `.stats` source; the report
  gains `importedPlays`. `TrackFilter.stats`, a `StatsFilter` of a list's row or a bar's span,
  narrows the `.stats` source.
- LibraryBrowser: a row's click narrows Stats' table to it, a second click on it clears it; a
  bar's click narrows it to its span, its double-click shows the timeline as the click did. The
  row or bar is marked, and a button in the header names it and clears it. Another period keeps
  a row's filter and drops a bar's; another source drops both. Year in Review's clicks act on
  the main window's Stats for its year. Showing Stats selects All in the hidden columns.
- Bench: the played library imports a last play for each of its 43k tracks; the stats rows
  keep their budgets.
- Tests that fail without each part: an import keeps its own last play apart from Last Played
  and a second import changes nothing; the part fills from Last Played by the rule above and
  keeps the counts; a report counts last plays in periods, lists, bars, the clock, first
  played and the undated count; the `.stats` source lists their tracks; a counts event carries
  one to another Mac; the totals' texts; a filter narrows the source by row and by span; a row,
  a bar, the header's button, a second click, another period and Year in Review act as above.
- Order: this plan; the part, the reads and the import with their tests; Bench; the filter and
  the panel with their tests; the ADR; `./scripts/check`; the result.

Result, part 44c: shipped 44c.1 and 44c.2 (ADR 0105, amending 0102 and 0033). A click on a
top list's or First Played's row keeps Stats on screen and lists that row's tracks played in
the period below it; the row is marked in its card, and a button in the panel's header with its
name and a clear mark lists every track again, as a second click on the row does. A bar does
the same for its span, since going to the timeline left Stats; a double-click on a bar still
shows its plays there. A row's filter stays across periods, a bar's doesn't, and neither is
saved; no key in `state.json` or `config.json` changed, and copies of the owner's two files
decode with no problem and no discard. Each import's last played is kept in a new schema part,
`imported_last_plays`, and counted as one dated play while that player's import counts a play
for the track; the rest stay undated. Built on a copy of the owner's library it filled 11,102
of the 11,172 Swinsian tracks in under 2 s and changed no other part (no discard notice);
importing a copy of the owner's Swinsian database into it again added no plays and dated the
other 69. Against that copy (with the re-import): All Time 11,293 plays (11,171 from the
import), this year 5,075, 2025 3,326, this month 153 (31 imported), the year menu from 2022;
undated plays 75,494, since the owner's `play_count` adds up to 86,787, about twice the
Swinsian counts plus the 122 played here: a doubling from before this part, which it doesn't
touch. The totals' line and the Plays tooltip say "N plays from an import", and the command
line's text and JSON say it too. Bench, Apple Silicon, with a last play for each of the 43k
fixture tracks: opening Stats 384 ms (budget 400), changing the period 223 ms p95 with All
Time the slowest (budget 250), This Week 31, This Month 30, a year 69 to 75; the union adds
about 40 ms to All Time's scans, measured with `sqlite3` on the bench library, and other
agents' runs shared the machine. Checked on screen with `--snapshot-of stats` from a home
folder holding a copy of the owner's library and no config: the month's totals with "31 plays
from an import", the bars and the clock. Not checked on screen: the clicks, the marked rows,
the header's button, double-clicks, dark mode, glass and macOS 12 (the browser tests drive the
clicks). `./scripts/check` passes but for
`theGlassHeadersAreFrosted`, which reads the screen and fails the same here by name (as in
earlier parts), and one run each of `aRendererThatStallsMidTrackIsWaitedForNotCutShort` and
`aColorPickedInThePanelIsSavedAndDefaultClearsIt`, timing flakes with other agents' runs on the
machine, which pass by name. For the owner: run Import from Swinsian once more (it adds no plays, and dates the 70
tracks played here since the first import), open Stats on All Time and a year, click an
artist, an album, a genre, a track and a bar, use the header's button, double-click a bar,
click a row in Year in Review, and time Stats on the 2015 MacBook Pro.

#### 44d. Column groupings in the config file

- [x] **44d.1** Each browser column's grouping is saved in `config.json` and restored at launch;
      the selection in each column stays in the state file. Find out first why the owner's
      `state.json` holds no `browser.columns`.

Plan, part 44d (ADR 0106, amending 0069):
- Probe (done before this plan, on copies of the owner's files and the unified log): the state
  file holds only values that differ from their defaults, and the owner's columns are hidden
  (`window.browserVisible` false), which selects All in each, so default groupings write
  nothing. Groupings picked earlier were lost: until a75656f a column at All was saved without
  its required `selection`, so the next launch discarded the whole state file, which the log
  shows once (2026-11-05 11:49:48, code 3). The 2015 MacBook Pro's state file holds no
  `browser.columns` either, and mbp2021 has none.
- Settings: `browser.columnGroupings`, a list of three groupings, `.windowState` so the Settings
  window shows no row, checked as `browser.columns` is (three, none twice), the check shared.
  `BrowserColumn.restored` gives the launch's columns: the config's groupings when the file
  gives them, a saved selection only where its grouping is the config's. Tests: the key is
  added under its comment to a file without it and reads back, each bad value blocks the file
  and refuses a change, and the restore keeps and drops selections.
- LibraryBrowser: the header menu asks for the groupings through `groupingsChosen` and changes
  nothing itself; `setGroupings` regroups, each changed column at All. Tests: both.
- App: the choice sets the key, then regroups; a refused set shows an alert. A config change of
  the key regroups when the file gives it. `WindowSettings` reads the columns through
  `restored`. Test: a launch's columns with the key, without it, with no file and with a blocked
  file.
- Check the owner's `config.json` and `state.json` copies decode, and that a choice patches the
  config copy with only the key's lines.

Result, part 44d: shipped 44d.1 (ADR 0106, amending 0069). Why `browser.columns` was missing:
the state file writes only values that differ from their defaults; the owner's columns are
hidden, which puts each at All, and at the default groupings that is the default. Groupings
chosen before a75656f (2026-11-05 11:53) were lost when the state file was discarded over a
column at All saved without its `selection`, once in the log at 11:49:48; nothing was chosen
since. Each column's grouping is now `browser.columnGroupings` in `config.json`, a list such as
`["genres", "artists", "albums"]` under a comment, synced with the file; the selections stay in
`state.json`, whose `browser.columns` keeps its shape. At launch the columns take the config's
groupings, and a saved selection stays only in a column still grouped as it was saved; a file
without the key, or a blocked one, leaves the state file's columns. A right-click choice writes
the key and then regroups, so the columns never show groupings the file refused; a hand edit
regroups while the app runs, the changed columns at All; an edit that removes the key leaves
the columns as they are. A bad value (not three, one twice, an unknown grouping) blocks the
file as ADR 0082 has, with the banner naming the line, and a choice is refused with an alert.
The owner's config and state copies decode with no problem; a choice adds only the key's lines
after `library.fileViewer`. Checked by tests only: the app's wiring of the choice and of a hand
edit (the parts each have tests, `AppDelegate` none). For the owner: right-click a column's
header, pick a grouping, quit and relaunch; the config gains the key, and editing it by hand
regroups the columns at once. `./scripts/check` passes but for `theGlassHeadersAreFrosted`,
which reads the window's pixels from the screen and fails the same way on 186df18 without this
part, alone and in the suite, while other agents use this Mac's screen.

#### 44e. Tags written in place

- [x] **44e.1** A tag save whose new tag fits the file's existing padding overwrites only the
      tag's bytes in the original, with the same checks before and the read-back after; one
      that doesn't fit uses the temp file as now. Amends ADR 0020 and 0100.

Plan, part 44e (ADR 0107):
- Probe: every format's rewrite already returns segments, new bytes and ranges of the old file,
  and `writeTemp` already tells when every kept range stays at its offset (it clones then). A
  plan of the original's size with every kept range in place is a write in place; the region is
  the first to the last byte that differs. FLAC rebuilds all its metadata blocks (art included)
  as one segment, so the region is trimmed to the bytes that differ, not the segments. The
  generated MP4 fixtures have no `free`; a first edit past the padding gives them 2 KB.
- Before the write: the checks the temp path makes (writable, unlocked, one link, the identity
  read at the start), one pass hashing the file, its payload and the file as planned, and the
  planned file read back through a source that substitutes the region, so a plan that wouldn't
  read back never opens the original for writing.
- Journal: the record and the old bytes as for any edit, plus the planned file's hash and a
  marker beside the entries, all flushed and then one `F_FULLFSYNC`, before the original is
  opened. The write: `fstat` and a `pread` of the region must match what was read, then one
  `pwrite`, `F_FULLFSYNC` (or `fsync`), `close`. After: the read-back as for a temp file plus
  the whole file's hash; then the record is confirmed and the marker removed.
- A failure after the write started puts the original back through the temp-file path, checked
  by hash. Recovery (each write, each undo, and the app at launch) finishes what a marker names:
  a file hashing as planned keeps the edit, one hashing as the original drops the record, one
  torn is put back. Undo is unchanged.
- Tests (generated fixtures only): in place when it fits for FLAC, MP4, MP3 2.3 and 2.4, AIFF
  and WAV, with and without art (same inode and size, only bytes outside the audio differ,
  undo restores); the temp file past the padding; a crash one byte into the write put back; a
  crash after the whole write kept; a crash before it dropped; a file changed underneath (a tag
  byte with the mtime set back, and the mtime) refused; a read-back failure put back; a put-back
  that fails at once finished by the next call; a plan that wouldn't read back refused before
  the original is touched; a stale marker removed. The temp-path fault tests pin the temp path.
- Bench: the FLAC title row split into in place and through the temp file.

Result, part 44e: shipped 44e.1 (ADR 0107). A tag edit whose new tag fits the padding is
written over the old one in the original with one `pwrite` of the bytes that differ, journaled
and flushed first, checked before on the planned file and read back after; anything else goes
through the temp file as before. ADR 0020's guarantee changes, as the ADR says plainly: for the
moment of that `pwrite` (about 1 ms locally) a crash or a dropped share leaves the original's
tag torn on the disk, the audio untouched, until the next launch, write or undo puts it back
from the journal; if the journal is lost too, the damage stays. Journal records and record
updates now flush their folder before the drive's cache, for every write. Bench on Apple
Silicon (fixture FLAC on APFS, median of 5): written in place and read back into the index 14.8
to 15.8 ms (the write 12.3 to 13.2), through the temp file 12.7 to 13.1 ms (the write 9.9 to
10.5): locally the clone makes the temp file cheap and the write in place pays for its extra
flushes and hash; the saving is on the NAS, two passes over the file instead of four, which
the build Mac can't measure. The corpus run gains a crash one byte into a write in place per
container, not run here (the reference folder isn't on this Mac). `./scripts/check` passes but
for `theGlassHeadersAreFrosted`, a screen test outside this part. For the owner, on copies of
NAS files only: edit a title on a FLAC, an MP3 and an M4A with `moov` first, and check with
`ls -li` that the inode stays and no `.tagwrite` file is left, that Swinsian and Finder read
the new tag, Finder tags and permissions survive, and Undo Tag Edit puts the bytes back
(`cmp` against a second copy); edit one while Swinsian plays it; then pull the network cable
during a batch of small edits, reconnect, relaunch, and check each file reads as before or as
edited, never torn, and that the log shows what recovery found.

### 46. Doubled Swinsian play counts

Found on 2026-11-05 and checked on copies of both Macs' indexes and sync logs. This Mac imported
Swinsian on 2 Nov. mbp2015 imported the same library on 4 Nov, before it had read this Mac's
log. Each Mac then merged the other's `counts` events on top of its own
(`LibrarySyncMerge.swift:45`). That doubled 11,049 tracks on both Macs: 86,792 plays against
Swinsian's 43,293. A `counts` event carries a delta, so a merge can't tell two imports of the
same plays from two real sets of plays. mbp2015's `imported_plays` baseline is now 86,646, so
its later imports undercount.

The rule: a path's imported plays for one player are the highest total that any machine's
import of that player reported, never a sum across machines. `play_count` is the plays recorded
here, plus the synced plays, plus each player's total. Neither the order of the imports nor the
order of the syncs changes the result, and a later import still adds only real growth.

- [x] **46.1 Totals, not deltas.** The `counts` event and the import carry the source's totals
      per path and player. The merge takes the maximum per player and path, so applying an
      event twice changes nothing. Amends ADR 0033 and ADR 0038.
- [x] **46.2 Existing data.** Pre-release, so there is no migration. The deltas already in the
      logs and in `imported_plays` may be discarded and rebuilt (old events ignored when read:
      the app only appends its own log and never rewrites one, ADR 0038), as long as the owner's stats
      come out right without importing again on both Macs. The Result line says exactly what
      the owner has to do on each Mac.
- [x] **46.3 Tests** that fail without the fix: two machines import the same library in either
      order, before and after syncing, and end with the same count; an import after the source
      gained plays adds only the gain; a play recorded here is never lost.
- [x] **46.4 Check on the owner's data.** Against copies of both Macs' indexes and logs, never
      the live files: the imported plays total 43,293 (plus whatever Swinsian has gained since),
      and the plays recorded in this app are added on top.
- [ ] **Hardware checkpoint (owner):** after the steps in the Result line, both Macs show the
      same play count for a few tracks, matching Swinsian plus the plays made in this app.

Answered without a change: Swinsian's database keeps no play history, only a count, a last
played and a date added per track. Its Library Statistics window is worked out from those, so
individual plays can't be recovered from it. The last played already counts as one dated play
(44c); the rest of an import stays undated.

Implementation plan:
- Event (Library, `SyncEvent`): a `totals` event, `path`, `player`, `plays`, `skips`,
  `lastPlayed`, carries the player's totals for the path as this machine holds them, in place
  of `counts`. A `counts` line, which earlier builds wrote with an import's deltas, is read and
  skipped without a problem (`SyncLineProblem.retiredCounts`, skipped by the sync cursor), since
  the app never rewrites a log. The fuzz target's seed line becomes a `totals` one.
- Import (Library, `LibraryPlayerImport`, `ImportPlan`): `imported_plays` holds the highest
  totals any machine's import of a player reported. The plan's gain is the source's total past
  that, never less than 0; `TrackUpdate.totals` replaces `imported` and is recorded when a gain
  is. The import logs `totals` with the recorded totals.
- Merge (Library, `LibrarySyncMerge`): `totals` raises the recorded totals to the event's and
  adds the gain to the path's counts, so applying it twice, or after an import of the same
  library here, adds nothing.
- Existing data (Library, `LibrarySchema`): the `imports` part's SQL changes, so it's rebuilt
  empty, and building it sets each path's play count to its history rows, this machine's and
  the synced plays, discarding what earlier imports added. Skips have no history and stay. The
  owner then imports Swinsian once, on either Mac, and the other reads its `totals`.
- Tests, in `SyncTests`, `PlayerImportTests`, `SyncLogTests` and `LibraryIndexTests`: two
  machines import the same library in either order, before and after syncing, and agree; an
  import after the source gained plays adds only the gain, here and on the other machine; a
  play recorded here survives both; a `counts` line is skipped without a problem; the rebuilt
  part leaves each play count at its history.
- 46.4 on copies in the scratchpad: both Macs' indexes and the sync folder's logs, opened by a
  test-only run of the new build, then an import of this Mac's Swinsian copy.
- ADR 0033 and 0038 amended in place, with their "Amended" lines.

Result: shipped 46.1 to 46.3 as planned, amending ADR 0033 and
0038. An import logs `totals`, the player's totals for each path, and `imported_plays` keeps the
highest any machine's import reported; an import or a merge adds only what passes it. A `counts`
line is skipped without a problem. Rebuilding the `imports` part first sets each play count to
its history rows and takes the recorded import skips off each skip count, so each Mac opens with
its own and synced plays only, and the window shows once that 11,282 import counts were
discarded. From the review: a synced move that merges two paths counts each player's import
once, the higher.

Gate: review fixes in their own commits, simplify and architecture clean, no budget missed.
`./scripts/check` passes but for `WindowGlassTests.theGlassHeadersAreFrosted`, which fails on
main too on this Mac with the display asleep.

Bench: merging 1M events 6.39 s, history 12.11 ms, the database 47.14 MB with the history table
28.61 MB, a stats period change 227 ms. Record a play measured 0.17 ms (p95) against 0.08 ms in
an older record; the phase doesn't touch that path, and it is within its 1 ms budget.

46.4, on copies taken at 20:48 of both indexes, both logs and both Swinsian libraries: opened
with this build, this Mac had 137 plays and mbp2015 135, and 137 each after a sync. Importing
this Mac's Swinsian (43,293 plays, no growth since the copy given at 19:30) with the prefix
`/Volumes/music-1` to `/Volumes/music` matched all 43,368 of its paths and added 43,293 plays to
11,172 tracks: 43,430 here. After the sync mbp2015 had 43,411: the same, less 19 plays on 14
tracks under `music/dsd`, a folder mbp2015 doesn't watch (ADR 0038 skips them). Importing
mbp2015's own Swinsian there as well, which counts 179 plays more on some tracks (43,400 in
all), raised both by those 179: 43,609 here and 43,590 there, the higher of the two Swinsians for
each track. Without the prefix only 12,479 paths match; the owner's first import must have used
it.

What the owner does:
1. **Both Macs, before any import:** install this build and open it once with the share mounted.
   Update mbp2015 first, or keep its app quit until it's updated: a build before this one reads
   the `totals` lines as unknown events and passes them for good. Each Mac shows a notice that
   the import counts were discarded, and its play counts drop to the plays made in this app.
2. **This Mac only:** quit Swinsian, then Import from Swinsian…, with "Replace the path prefix"
   set to `/Volumes/music-1` → `/Volumes/music`, as the first import had. The preview should add 43,293
   plays, or more if Swinsian has gained since.
3. **mbp2015:** nothing to import. Its next sync, on launch or after a scan, brings this Mac's
   totals. Importing mbp2015's own Swinsian there too, with the same prefix, is optional and
   safe: it adds only the plays that library has past this Mac's (179 on 5 November).
4. **Check:** a few tracks show the same play count on both Macs: Swinsian's count plus the
   plays made in this app.

### 47. Faster tag writes

The owner reports that saving tags is very slow, worst with several tracks selected, and asks
for edits in place as Swinsian makes them, without risking the files. 44e already writes in
place when the new tag fits the padding, but each in-place save still reads the whole file
twice to hash it. Swinsian (TagLib) reads the header and writes a few KB. A 40 MB FLAC takes
about 0.7 s over gigabit and 2–3 s over Wi-Fi, so a hi-res album over Wi-Fi takes minutes. A
save that doesn't fit the padding goes through the temp file: about four passes over the file.

The parts, biggest gain first. ADR 0108 records them and amends ADR 0020 and 0107.

- [x] **47.1 No whole-file hashes in place.** A write in place touches only `plan.region`, and the
      code already checks that the region doesn't overlap the audio, so hashing bytes the write
      never touches proves nothing about it. Before the write, keep the checks that exist:
      `fstat` identity, a `pread` of the region matching the journaled old bytes, and the
      planned file read back through `PlannedSource`. After it: reopen with `F_NOCACHE`, so SMB
      can't answer from the client's cache, `pread` the region and compare it to the new bytes,
      then parse the header and check the tags. All of that reads about as much as the tag.
- [x] **47.2 Journal on the region.** The journal and recovery key on a hash of the region, not
      of the whole file. Recovery sorts a file into three cases: the region holds the new bytes
      (keep the edit), the old bytes (drop the record), or neither (torn, put back).
- [x] **47.3 Two flushes a batch.** Write the records, old bytes and markers for all the files,
      then one `F_FULLFSYNC`; then the writes; then one more flush to confirm them all. A
      20-track album goes from about 60 full flushes (three a file) to 2, and the per-file
      markers still cover a crash partway through.
- [x] **47.4 More room.** The padding is 2,048 bytes, defined three times (`FLACFile`,
      `ID3Tag`, `MP4File`); define it once. A save through the temp file leaves much more room,
      for example 16–64 KB, or the art's size plus a margin, so later edits fit. Adding art or
      lyrics then fits, and an MP3 with no padding takes the slow path once instead of every
      time.
- [x] **47.5 MP4 growing at the end.** An MP4 whose `moov` is the last atom grows in place by
      writing past the end of the file: no `mdat` moves and no chunk offsets change. Count how
      many of the 61 "moov after mdat" corpus files this covers.
- [x] **47.6 Several files at once on the NAS.** Write 3–4 files at a time, since SMB is bound by
      round trips. The journal steps of 47.3 stay serial; only the writes and read-backs run in
      parallel.
- [ ] **47.7 Probe: server-side copy.** Find out whether macOS's SMB server-side copy (copy-chunk
      through `copyfile`) works against the owner's NAS. No agent or test touches the NAS
      (AGENTS.md), so the agent writes the probe and the owner runs it on a scratch folder there,
      as a pending checkpoint; the run goes on without it. If it works, the temp file can be the
      new header plus a server-side copy of the audio, which never crosses the network. If it
      doesn't, record that and drop the part.
- [x] **47.8 Less bookkeeping.** `removeLeftoverTemps` lists the folder once per folder per
      batch, not once per file. `rescan(files:)` takes the tags the writer just parsed instead of
      parsing each file again.
- [x] **47.9 Progress.** A batch save shows progress per file, so a slow save doesn't look stuck.
- [x] **47.10 Speed.** Bench rows: a 20-file FLAC batch in place, locally and on the slow
      simulated NAS, and the same through the temp file; the existing FLAC title rows rerun.
      Tests on generated fixtures and corpus clones for each part, including a crash at each
      step of a batch.
- [ ] **Hardware checkpoint (owner):** save a tag edit on a 20-track hi-res album on the NAS over
      Wi-Fi and over Ethernet; report the times. Then add art to a few tracks and edit them again.

Plan (ADR 0108, amends 0020 and 0107). All in `Core/TagWriter` unless named; tests on
generated fixtures and hand-built files only.
- Bench first, so the rows have a before: `WriteFaults` gains a `package` hook told of each
  file system call the writer makes on a music file, its temp file or its folder (metadata,
  open, read and write with their bytes, flush, close, listing, clone), and of each read the
  parsers make through a counting `ByteSource` around `FileSource`. The bench prices each call
  at the slow simulated NAS's 10 ms and its bytes on one shared link at 57 MB/s (the owner's
  40 MB in 0.7 s), and makes 20 copies of a fixture FLAC grown to 40 MB with audio bytes. Rows:
  the batch in place and through the temp file, locally and on that NAS.
- 47.1: the in-place path drops `fileHashes`. Before: the identity, the planned file read back
  through `PlannedSource`, then `fstat` and the region's `pread` at the write, as now. After:
  `FileSource` (which already sets `F_NOCACHE`) reads the region back against the new bytes,
  then `checkParsed` reads the tags, format, art, chunk offsets and payload ranges.
- 47.2: `FileRecord` holds either `originalSHA256` (temp-file writes, unchanged) or `inPlace`:
  the region's offset, and the SHA-256 and length of its old and new bytes. The marker alone
  says a write is unconfirmed. Recovery reads the region: new bytes keep the edit, old bytes
  drop the record, neither puts the original back. Undo and put-back check the temp file's
  region and size, and the journaled old bytes against their hash.
- 47.3: `write(_:to:)` reads and plans every file first (in chunks bounded by files and
  bytes, so a 1000-file art change doesn't hold all its plans), then for the chunk's in-place
  files appends every record, old bytes and marker with `fsync`s and one `F_FULLFSYNC`; then
  the writes with an `fsync` each; then one `F_FULLFSYNC` per volume written; then confirms
  each record (no drive flush) and removes its marker. A lost confirmation leaves a marker
  that recovery confirms. Temp-file files keep their own path. A fault stops the batch after
  each step, for the crash tests.
- 47.4: one `rewritePaddingBytes(tagBytes:)` replaces the three 2,048s: 64 KiB, or as much
  again as the new tag when that's more, so a cover up to twice the old one's size fits.
- 47.5: `InPlacePlan` takes a plan whose kept ranges stay put and which only grows past the old
  end (MP4 `moov` last); `PlannedSource` serves the bytes past the end; recovery and undo take
  the size between the old and the new. The corpus survey notes "moov last" for the count.
- 47.6: the chunk's writes and read-backs run 4 at a time; journal steps stay serial.
- 47.7: `scripts/smb-copy-probe.swift <scratch folder>` makes its own random files in a new
  subfolder, times `clonefile`, `copyfile` with `COPYFILE_CLONE_FORCE` and `COPYFILE_DATA`, and
  a read-write copy, compares them, counts the bytes the network interfaces moved, and removes
  what it made. The owner runs it on the NAS; the temp-file path is unchanged until then.
- 47.8: the batch lists each folder once for leftover temp files (`writeTemp` no longer
  lists); `TagWriteReport.parsed` carries each written file's read-back parse, and
  `LibraryScanner.rescan(files:parsed:)` stores it instead of reading the file again, through
  `TagEditing.written` and `LibraryWatcher`.
- 47.9: `write` reports `TagWriteProgress` (read, written, of total); `TagEditing.saving`
  hands it to the main thread, and the app shows "Saving tags: 3 of 20" in the browser's
  status bar beside the scan's text, with its bar.
- Order: plan, bench and hook, 47.4, 47.1+47.2, 47.5, 47.3, 47.6, 47.8, 47.9, probe, ADR,
  bench after, Result. Tests: reads bounded by the tag (47.1), the three recovery cases on the
  region (47.2), a crash after each batch step leaving every file whole or edited (47.3), the
  padding after a slow save and a second edit in place (47.4), moov-last growth with undo and a
  torn growth (47.5), writes overlapping (47.6), one listing per folder and the parse handed on
  (47.8), progress counts and the status text (47.9).

Gate: two review rounds, every finding above low fixed in its own commit, and two lows
(a flush before a put-back's record goes, the renamed file's stamp); simplify and architecture
clean but for doc fixes; no budget missed, Get Info on 100 tracks at 50.8 ms against 43 ms in
42e is the machine's load (52 ms here against 54–56 ms on the build before, back to back).
`./scripts/check` passes.

Result: shipped 47.1 to 47.6 and 47.8 to 47.10 (ADR 0108, amends 0020
and 0107); 47.7's probe is written and waits on the owner. A save in place no longer hashes the
file: the region is checked before the write and read back uncached after it, with the tags
parsed from it, and the journal and recovery key on the region's old and new hashes. A batch
plans its files a chunk at a time, journals the chunk with one drive flush, writes and reads
back four files at once with an `fsync` each, flushes each volume once and confirms without a
flush: two drive flushes for an album instead of about 60. A rewrite leaves 64 KiB of padding,
or as much again as the tag; an MP4 with `moov` last grows in place past its end, which by ADR
0020's survey covers all 61 corpus files with `moov` after `mdat` (the layout notes "moov last"
for the corpus run to confirm). A batch lists each folder once for leftover temp files, the
rescan stores the writer's read-back parse instead of reading the file again, and a save shows
"Saving tags: 3 of 20" on the status bar's scan line. Bench on Apple Silicon, 20 fixture FLACs
grown to 40 MB in one batch: in place 1.56 s before, 0.04 s after on this Mac's disk; 42.8 s
before (1,602 MB over the link), 4.3 s after (2 MB) on the slow simulated NAS (10 ms a file
system call, 57 MB/s on one link, the journal on the local disk); through the temp file 1.25 s
and 74.5 s before, 1.25 s and 74.2 s after, unchanged as planned. One FLAC's title written and
read back into the index, median of 5: in place 15.0 ms before, 11.2 to 12.0 ms after; through
the temp file 11.9 ms before, 12.8 to 13.3 ms over four runs after, within ADR 0107's 12.7 to
13.1 ms, so the 11.9 was a low run. The rescan stays about 2.5 ms: its cost is the index
store, not the parse, locally. The journal row, 1000 files with 1 MB art flushed per file:
6.5 s. The gate's bench run: tag journal 6.19 s; one FLAC title in place 11.9 ms, through the
temp file 13.09 ms; the 20-file batch in place 0.04 s locally and 4.33 s on the slow NAS,
through the temp file 1.26 s and 73.96 s; Get Info on 100 tracks 50.8 ms, up 18% under load
from other worktrees, and equal to the base when run A/B against e01bd90. The gate's fixes: a
batch whose first files fail before writing goes on writing the rest (the journal makes the
edit's folder again); the rescan uses the writer's parse only while the file's size and mtime
are still the ones stamped right after its write; a failed write in place is put back over
itself with `pwrite` and `ftruncate`, needing no free space, and only while the file is still
the original by inode and size; a path named twice in a batch is written once. Not run here:
`scripts/tag-corpus --round-trip` (the reference corpus isn't on this Mac), `scripts/full-disk`
and `scripts/kill-test`. Deferred: the temp-file path still hashes, copies and reads back the
whole file, and on the NAS it is unchanged until 47.7 reports; the rewrite padding has no cap,
so a file with a large cover grows by as much again once (ADR 0108's choice).
For the owner:
1. **47.7 probe**, on an empty scratch folder on the NAS, over Ethernet:
   `swift scripts/smb-copy-probe.swift /Volumes/<share>/<scratch folder>` (256 MB; add a size
   in MB after the folder for another). Paste back what it prints. It writes only in a new
   folder it makes there and removes it at the end.
2. **Hardware checkpoint**, on copies of a 20-track hi-res album on the NAS: select all, Get
   Info, change the album title, Save; time it over Wi-Fi and over Ethernet, and watch the
   status bar count the files. Check with `ls -li` that each file keeps its inode and that no
   `.tagwrite` file is left. Then add art to a few tracks (the first save goes through the temp
   file and leaves room), edit their titles again and check those keep their inode. Edit the
   title of an M4A with `moov` after its audio and check its inode stays. Report the times.

### 48. Owner feedback, 2026-11-05 (third round)

Get Info, Listening Stats, playback errors, the state across a quit and the receiver moving
on. Parts 48a and 48b touch different windows, so
they can run in parallel worktrees and merge in order a, b. ADR 0109 is given to 48b if it needs
one.

#### 48a. Get Info and Lost Stats

- [x] **48a.1 No layout shift.** The Get Info window opens with its final layout: no flash of
      unstyled content and nothing that moves after it shows. A test checks that the window's
      frame and its fields' frames don't change between the first draw and the fields filled.
- [x] **48a.2 Tab keys.** ⌘[ and ⌘] switch to the previous and next tab (Info, Sorting and the
      rest), wrapping at the ends.
- [x] **48a.3 Resolve Lost Stats says what happened.** The command opens a sheet to move the play
      counts and ratings of files that vanished onto the tracks they probably moved to
      (ADR 0026). With none to resolve it writes "No lost stats to resolve" in the status bar,
      which the owner didn't notice. Disable the command when there are none, and when it can't
      open the sheet, say why where the user is looking.
- [x] **48a.4 Get Info reads every file it can.** Get Info on a DSF file now fails with "files
      can't be edited", because `TagFile` refuses to write DSF and DSDIFF tags and the read goes
      through it (`TagFile.swift:17`). Get Info is for reading tags too: a file the app can read
      but not write opens with its fields shown and read-only, and a line in the window says why
      it can't be saved ("Tags in DSF files can't be written yet"). In a mixed selection, the
      fields of the read-only files can't be changed, and Save writes only the others and says so.
      Only a file that can't be read at all is left out with the alert. Tests: Get Info on a
      generated DSF and DSDIFF fixture shows their tags, and Save never writes them.

Plan, part 48a (ADR 0114):
- Probe: `TagEditorWindow` opens on a small "Reading tags…" view and swaps in the tabs and
  buttons in `load`, resizing to fit, so the window grows and everything moves once the files
  are read. ⌘[ and ⌘] are Back and Forward in the menu, which act on the main window's history
  even while an info window is key. Resolve Lost Stats is always on, and with none to resolve
  writes to the status bar. Get Info reads each file with Metadata's `parse`, which reads DSF
  and DSDIFF, then `editorTagFacts`, which parses a `TagFile` for the tag scheme and the fields
  holding several values, and `TagFile` throws for DSF and DSDIFF: that throw is the whole
  failure.
- 48a.1 (`Features/TagEditor`): the window builds its heading, tabs, the last tab's fields and
  the buttons row in `init`, at the size it keeps; until `load` the fields can't be typed in and
  a spinner and "Reading tags…" sit in the buttons row, where a line of one height says what
  applies once read. Test: the window's frame and the first tab's field frames are equal before
  and after `load`, the window drawn in between.
- 48a.4 (`Core/TagWriter`, `Features/TagEditor`): the formats the writer refuses, and why
  ("Tags in DSF files can't be written yet"), are one fact on `FileFormat` in TagWriter, which
  `TagFile` throws with. `editorTagFacts` checks the format first and, for those files, returns
  that reason without parsing a `TagFile`, so the read uses only Metadata's reader. The
  `EditableTrack` carries the reason; the model shows every track's values, but edits, checks
  and collapse notes cover only the writable ones, and `TagEditing.save` writes and counts only
  their paths. With every file read-only the fields, art buttons and Save are off; in a mix the
  line says which can't be saved and how many Save writes. Tests: a generated DSF and DSDIFF
  read through `readEditableTrack` with their tags and reason; the model's edit over a mix; Get
  Info on a DSF, a DSDIFF and a FLAC fixture writing only the FLAC through a real `TagWriter`,
  the DSD files' bytes unchanged; a window on only DSD files with Save off.
- 48a.2 (`Features/TagEditor`, `App`): `TagEditorWindow.stepTab` moves one tab and wraps;
  `TagEditing.stepTab(_:in:)` acts on the info window that is key. The Back and Forward
  handlers step the key info window's tabs and fall through to the browser otherwise, so the
  keys stay the ones bound to Back and Forward. Tests: stepping wraps both ways, and only a key
  info window steps.
- 48a.3 (`Features/LibraryBrowser`, `App`): `LibraryBrowser.canResolveLostStats` is false once
  a health report has found no lost files (true before the first report), and the command is
  enabled by it. When the sheet can't open (none found after all, or the read fails) an alert
  sheet on the window says why. Tests: the flag follows the report, and an empty run alerts
  instead of writing the status bar.
- Order: this plan, 48a.1, 48a.4, 48a.2, 48a.3, the ADR, the bench and the result.

Gate, part 48a: the review found nothing above low and no way to write a DSF or DSDIFF file;
two lows fixed (the read-only note after a save error, the tab keys under a sheet); the audit's
rewrap fixed. `./scripts/check` passes.

Result, part 48a: shipped 48a.1 to 48a.4 (ADR 0114). Get Info's
window is made whole before it shows, the fields filled in when the read ends, so the window
and its fields keep their frames. Back and Forward (⌘[ and ⌘]) step the key info window's
tabs, wrapping, and act on the main window otherwise. Resolve Lost Stats is off once a health
report finds no lost files, and when its sheet can't open an alert on the window says why. The
formats the writer refuses are one fact in TagWriter, checked before the editor's read parses
anything for writing, so DSF and DSDIFF files open with their tags read-only and the line
"Tags in DSF files can't be written yet"; in a mix, Save checks, counts and writes only the
others and the line says how many. Bench on Apple Silicon (fixture files, median of 5): Get
Info on one track 15.9 ms to its window and 28.4 ms to its fields, on 100 tracks 45.9 ms to
their fields (window 12.2 ms). The window row is up from 42e's 5.1 ms because the first tab's
fields are now made before the window shows, which is 48a.1; the time to the fields is about
the same (31 ms in 42e). Tests: the window's and fields' frames unchanged by the fill; tabs
stepping both ways with wrap, only in the key info window; the Lost Stats flag following the
report, and an empty run alerting on the window, not the status bar; a generated DSF and
DSDIFF read with their tags, scheme and reason, untagged ones as "No tag"; the model over a
mixed selection; a read-only window with Save off; Get Info on a DSF, a DSDIFF and a FLAC
writing only the FLAC, the DSD files' bytes unchanged. For the owner: open Get Info on a track
and watch nothing move as it fills; press ⌘] and ⌘[ in it and past the last and first tabs;
with no lost stats, check Resolve Lost Stats is greyed out in the menu; Get Info on a DSF and
a DSDIFF file (and on one with a FLAC), check the tags show, the line says why, and Save
writes only the FLAC.

#### 48b. Listening Stats

- [x] **48b.1 Rolling periods.** Past Week, Past Month, Past Year and All Time replace This
      Week, This Month and This Year: the last 7, 30 and 365 days up to today. The year menu
      stays as it is. The bench rows rename their periods.
- [x] **48b.2 Totals box height.** When the totals box shares a row with Plays per Day, it fits
      the height of the Plays per Day cards, laid out in columns rather than one tall list.
- [x] **48b.3 Smaller cards wider.** The smaller cards' maximum width goes up slightly.
- [x] **48b.4 Save as Playlist asks first.** A sheet asks for the playlist's name, filled in with
      the name the current logic makes, and creates the playlist only on confirm.

Plan, part 48b (ADR 0109, amending 0102):
- Probe: the periods are `StatsPeriod.week`, `.month` and `.year` in Settings, whose `span`
  is the calendar's week, month or year holding now; the reader, the `.stats` source and the
  command line all take it from there, and their saved text (`stats:week`) stays. A saved list's
  name takes `.year`'s from its span's first day, which a rolling year would get wrong. The
  cards flow in `StatsFlowView` (columns of 270 points or more, so once two columns fit a
  one-column card is 270 to 410 wide); the totals card is 92 high, its figures one
  `NSStackView` row; it shares a row with Plays per Day only at six columns. Save as Playlist
  names the list and creates it at once; the
  name sheet for New and Rename Playlist is `askForName` in the app's `PlaylistCommands`, which
  a feature can't reach.
- Settings: `.week`, `.month` and `.year` span the last 7, 30 and 365 local days, today
  included (midnight of the first to tomorrow's), titled Past Week, Past Month and Past Year.
  Past Year's Year in Review is the year today is in, as This Year's was. The bench rows and
  their names in the budget table say Past Week, Past Month and Past Year.
- LibraryBrowser: a saved list's name takes a rolling period's span ("Nov 7, 2025 – Nov 6,
  2026"). The flow gives a card marked to fill its row (the totals) the height of the row's
  tallest card, and `StatsFigures` lays its figures out by frame: one row, or two rows of
  columns when two fit its height. The columns' minimum goes to 300 points (300 to 455 wide).
  `askForName` moves to LibraryBrowser, its own commit; Save as Playlist opens it over the main
  window with the made name, and creates the playlist on its button only.
- Tests: the spans at a date and across a daylight saving change and the year's end; a list's
  name; the flow's frames with totals beside Plays per Day and alone; the figures' frames in one
  row and two; the column widths over a range of widths; the sheet, its name, a changed name
  saved, and Cancel saving nothing.

Gate, part 48b: two review rounds; the medium (Save as Playlist from Year in Review saved
the panel's list, behind the review window) and three lows fixed (the table's days past midnight,
a failed read narrowing the table, the table listed twice a period change); the audit clean.
Bench, back to back against main at 5294a32: opening Stats 321–322 ms against 325–350 ms,
changing the period 223–227 ms against 222–223 ms, both in budget; the earlier misses were the
machine's load. `./scripts/check` passes but for `aRendererThatMovedIsFoundAgainByItsUDN`, which
passed three runs alone. Open with the owner: 300-point columns (3 columns at 1,200 points, where
280 keeps 4), and Year in Review from Past Year opening the calendar year.

Result, part 48b: shipped 48b.1 to 48b.4 (ADR 0109, amends 0102). Past Week, Past Month and Past
Year are the last 7, 30 and 365 local days, today included; a saved list's name for them is its
days. The totals fill their row beside Plays per Day, their figures in two rows of three; the
columns are 300 points or more (a one-column card 300 to 455 wide once two fit, from 270 to
410). Save as Playlist opens the New Playlist name sheet, moved to LibraryBrowser, over the
window whose list it is, filled with the name made from the report it shows. The table under the
panel keeps the shown report's days. Gate fixes: Year in Review saved the panel's list over the
library window; after midnight the table and the cards counted different days. Bench on Apple
Silicon, with two other agents building on the machine (load about
4): changing the period 226 to 235 ms p95 (budget 250), Past Week 32, Past Month 36 to 37, Past
Year 75 to 81, 2025 76 to 83, All Time 227 to 236; opening Stats on Past Month 332 to 609 ms over
six runs, three over its 400 budget. Phase 44c measured 384 on a quiet machine, and the period
doesn't change the open's cost (every first play, then two scans not indexed), so the budget
stays until a quiet rerun. Owner's check: open Listening Stats and click Past Week, Past Month
and Past Year, the totals under each giving the dates from 6, 29 and 364 days ago to today;
widen the window until the totals sit beside Plays per Day and see them as tall as it in two
rows; see the cards a little wider at the usual window size; click a list's Save as Playlist
button, change the name, Save, and see the playlist under that name; click it again and Cancel,
and see no playlist added.

#### 48c. Playback errors that explain themselves

When a track can't play, the status bar shows "Playback stopped: " and the error's
`description`, which is often a type name or a code, and nothing more. The owner hit it playing
a DSD file with hog mode off, where `DeviceOutput.swift:42` already has the clear reason. 48c
touches playback and the status bar, not the windows of 48a and 48b, so it can run in a third
worktree and merge after them. ADR 0111 records the error model if it needs one.

- [x] **48c.1 Messages people can read.** Every error that can stop playback gives a short
      message for the user, defined once beside the error, such as "DoP needs exclusive access,
      and hog mode is off for this device". The status bar shows that message, not the error's
      `description`. A test walks every case of the playback, output and decoder errors and
      checks that each has a message and that none prints a type name.
- [x] **48c.2 Details on click.** The playback stopped message in the status bar has a small
      question mark icon and is clickable. It opens a Playback Problem window with the message,
      the track and its format, the output device and its format, hog mode, the error's full
      text, and the app's recent log lines about playback. A Copy button copies all of it as
      text for a bug report.
- [x] **48c.3 Fixes offered.** An error the app knows how to fix carries its fix, and the
      details window shows it as a button. The first is hog mode: playing DSD over DoP with hog
      mode off shows a dialog at once, saying that DSD needs exclusive access to the device, with
      a button that turns hog mode on for that device (the per-device setting, phase 22) and
      plays the track again, and a Cancel button. Hog mode held by another app is a different
      message, naming the app, with no button.
- [x] **48c.4 Every track failing.** When tracks fail in a row until playback stops
      (`PlaybackError.failedInARow`), a dialog says why instead of the count alone: if every
      failure has the same cause, that cause and its fix as in 48c.3; if not, the causes with
      the number of tracks each, and a button that opens the details window.
- [x] **48c.5 Tests.** DSD on a null device with hog mode off gives the hog mode message and
      fix, and the fix turns hog mode on and plays; tracks failing in a row with one cause give
      that cause; the details window's text includes the device and the log lines.
- [ ] **Owner check in the running app:** play a DSD file on the ADI-2 with hog mode off; turn
      it on from the dialog and hear it play. Click the stopped message and copy its details.

Plan, part 48c (ADR 0111):
- Probe: the engine turns each output error into `"\(error)"` for `PlaybackEvent.trackFailed`
  and `.failed`, and `NowPlayingModel` prints it after "Playback stopped: " or "Couldn't play".
  The errors that reach it are `PlaybackError`, `DeviceOutputError`, `HALDeviceError`,
  `HALDeviceProviderError`, `HALError` and `OSStatusError` (HALOutput, the last two from
  AudioToolbox decoding too), `MetadataError` (the DSD readers) and `RendererOutputError`.
  The config's `output.hogMode` mirrors the in-use device's profile (`showInUse`), and
  setting it switches that profile through `outputSettingsChanged`. Nothing reads the log.
- 48c.1 (`Core/Playback`, each error's module, `Features/NowPlaying`, `App`): a protocol
  `PlaybackFailure` in Playback asks for `userMessage`, a short lowercase clause in the style
  of `RendererSession`'s reasons, and an optional `fix`. Each error above adopts it, the
  message in a switch beside its `description`; `MetadataError` has its message in Metadata
  by kind, and Playback (which now imports Metadata) declares the conformance. The events
  carry a `PlaybackProblem` (message, the error's full text, fix); another error's message is
  its description. The status bar shows the message; the command line and bench print the
  full text. Tests: every case of each error has a message with no type name or code.
- 48c.2 (`Core/Log`, `Features/NowPlaying`, `App`): `recentLogLines` reads the app's own
  lines from `OSLogStore` for the current process. The status bar's format part gets a
  question mark button, shown with a problem; it and a click on the message call
  `NowPlayingBar.problemOpened`. `ProblemReport` builds the text from the problem, the
  track's path and format, the last signal path's stages (the device and its format), the
  hog mode setting and the playback modules' log lines of the last 10 minutes;
  `PlaybackProblemWindow` (AppKit, as `ProblemsWindow`) shows it with Copy. Tests: the text
  has the device and the log lines; the button shows and opens; Copy copies the text.
- 48c.3 (`Core/Playback`, `Core/HALOutput`, `Features/NowPlaying`, `App`): `PlaybackFix`
  has one case, turning hog mode on for a device by UID. DoP refused for hog mode carries it;
  `hogModeHeld` names the app holding the device from its pid, with no fix. A problem with a
  fix shows a dialog at once (`ProblemDialog`, a model with a thin `NSAlert`), and the
  details window has the fix as a button; both call the app, which sets `output.hogMode` for
  that device when it is the one in use and plays the track again. Tests: DSD on a null
  device with hog mode off gives the message and fix, and with a hog mode provider swapped in
  the replay plays; the dialog's text and buttons; the held message names the app.
- 48c.4 (`Core/Playback`, `Features/NowPlaying`): `PlaybackError.failedInARow` carries each
  failure, and its problem lists the causes with their track counts. One cause: the message
  and dialog say it, with its fix; several: the counts, and a Show Details button. Tests:
  three tracks failing with one cause give that cause and fix; two causes give both counts.
- Order: this plan, 48c.1, 48c.2, 48c.3, 48c.4, the ADR, the result.

Gate, part 48c: the review found nothing above low and the audit was clean; fixed in their
own commits: a mixed-rate DSD album keeps its hog mode fix, the fix replays the failed track when
it's current or nothing plays and says why when it doesn't, and hog mode taken by no one is worded
apart. `./scripts/check` passes but for `WindowGlassTests.theGlassHeadersAreFrosted`, which fails
on main too with this Mac's display asleep.

Result, part 48c: shipped 48c.1 to 48c.5 (ADR 0111). Every error
that can stop playback has a message for people beside its description, and the status bar
shows it: "Couldn't play So What.dsf: DoP needs exclusive access, and hog mode is off for
this device". A question mark follows a problem in the status bar,
and it or the line opens the Playback Problem window with the track and its format, the
device and its format, hog mode, the error's full text and the playback modules' log lines
of the last 10 minutes, which Copy Details copies; log values not marked public read as
`<private>`. DoP refused for hog mode shows a dialog at once whose Turn On Hog Mode button,
and the details window's, set `output.hogMode` for the device in use and play the track
again unless another track plays or is paused, or the queue moved it (then the log says why); hog mode held
by another app names it, with no button, and held by no one says so. Tracks failing in a row stop
on their one cause and its fix (a DSD64 and DSD128 album too), a fix every cause shares, or list each cause with its count and a Show Details button.
`tracks(_:)` moved from LibraryBrowser to DisplayText for the dialog. Tests: every case of
the playback, output, renderer and metadata errors has a plain message; a problem keeps the
message and the full text; the recent log lines come back with their category; the status
bar's question mark and line open the details, and another message has neither; the report
has the track, the device, hog mode, the error and the log lines, and Copy copies it; DSD on
a null device with hog mode off gives the message and fix, and with hog mode on the replay
plays; a DSD album with hog mode off stops on that fix; tracks in a row with one cause give
it, with two give both counts; the dialogs' text and buttons; the details window's fix
button. For the owner: play a DSD file on the ADI-2 with hog mode off, check the dialog
says DSD needs exclusive access, click Turn On Hog Mode and hear it play, and check Hog Mode
is on in the Output menu for the ADI-2 only. Turn it off again, play the file, click the
message in the status bar (or its question mark), check the window names the ADI-2, its
format and "Hog mode: off", then Copy Details and paste it into a note.

#### 48d. The window comes back as it was left

The owner quit and relaunched, and the track list had lost the column it was sorted by. The
goal: quitting and launching again shows the same state. The sort is saved with the column
layout (`TrackTableController.swift:845`), so start by finding where it's lost. 48d touches the
track table and the state file, not the windows of 48a to 48c, so it can run in its own
worktree and merge last. ADR 0113 records the list if it needs one.

- [x] **48d.1 Sort order.** The sort column and direction come back after a quit, per source as
      they are kept now. A test sorts, saves, relaunches the model from the saved state and
      gets the same sort and the same first rows.
- [x] **48d.2 Everything else the window shows.** List every piece of window state and whether
      it survives a quit: the source, the sort, the columns and their widths, the browser
      panes' selections, the search, the selection, the scroll, the split sizes, the queue
      panel, the window's frame. Fix each that doesn't. Per-Mac state goes in the state file;
      `playback.resume` stays as ADR 0095 has it, so the synced key stays small. The list goes
      in the Result line.
- [x] **48d.3 Test.** One round trip that changes each item in 48d.2, saves, restores into a
      fresh window and checks each came back. It fails without the fixes.
- [ ] **Owner check in the running app:** sort by a column, change the window, quit, relaunch;
      everything is where it was.

Plan, part 48d (ADR 0113):
- Probe: the sort is saved only inside `browser.trackTable`, and the table reports that layout
  only when a column moves, resizes, shows or hides; a sort alone reports nothing, so a sort
  with no column change since is lost at quit. A second loss: `BrowserModel.load` shows the
  saved source in the table's sort, so a manual playlist, History or Stats saved as the source
  opens out of its own order; a sort chosen inside one of those is lost too. The other pieces
  as they stand (48d.2):
  - source: `playback.resume`'s `source` (ADR 0095). Survives.
  - sort: lost, as above. Fixed by 48d.1.
  - columns, their order and widths: `browser.trackTable`, saved as they change; the
    timeline's own in `browser.timelineTable`. Survive.
  - the panes' selections and groupings: `browser.columns`, saved at each change. Survive.
  - the search: saved nowhere. Fixed: `browser.search` in the state file.
  - the selection: `playback.resume`'s `selected`, one track, the last selected row. A
    selection of several tracks comes back as that one; left as ADR 0095 has it.
  - the scroll: `playback.resume`'s `top`, the first visible track, at the top. Survives to the
    row; the offset within the row stays out, as ADR 0095 has it.
  - the split sizes: `window.sidebarWidth`, `window.browserHeight`, `window.statsHeight`,
    `window.queueWidth`. Survive.
  - the queue panel: `window.queueVisible` and its width. Survives; so do the sidebar, the
    browser, the toolbar, the status bar and the signal path's visibility.
  - the window's frame: `window.frame`, saved on each move and resize, including the screen-
    sized frame while in full screen, which then opens as a plain window covering the screen.
    Fixed: a frame isn't saved while in full screen, so the window opens at the frame it had
    before. Full screen itself isn't put back.
- 48d.1 (`Features/LibraryBrowser`, `Core/Settings`): `BrowserModel.tableSort` is the sort of
  the sources without one of their own (the one `queueSort` already works out), and the
  table's layout carries it, so a playlist's order is never saved as the table's. The table
  reports its layout after a reload that changed it. `load` enters the saved source as a
  click on it does, so it opens in its own sort. A sort chosen in a source with its own is
  `BrowserState.sourceSort`, saved as `browser.sourceSort` (a new `SourceSort`: the source,
  column and direction), and put back when the loaded source is that one. Tests: a sort saved
  and loaded in a new browser gives the same sort and first rows; a manual playlist loads in
  its order, and in the sort chosen in it once one was, and leaving it goes back to the
  table's.
- 48d.2 (`Features/LibraryBrowser`, `Core/Settings`, `App`): `BrowserState.search`, saved as
  `browser.search` and loaded into the field and the filter; only while the toolbar has the
  search field, since a search no field shows would narrow the table unseen. `MainWindow`
  skips the frame while in full screen. The browser's layout saves move from `AppDelegate` to
  `MainWindow`, beside the split's, so a test window saves what the app does. Tests: the
  search across a load, and none without the field; no frame saved in full screen.
- 48d.3 (`MusicPlayerTests`): `MainWindowFixture` takes a home to reuse and loads what it
  saved. One test changes the source, sort, a column's width, a pane, the search, the
  selection, the scroll, the sidebar, browser and queue sizes, the queue panel and the frame;
  flushes the saver and writes the play state; opens a second window on the same home; and
  checks each came back.
- Order: this plan, 48d.1, the window's saves moved, 48d.2, 48d.3, the ADR, the bench and the
  result.

Gate, part 48d: the audit found one missing ADR line; the review one medium (a saved search
loaded with the toolbar hidden) and two lows (a sort leaking between two sources with their own,
the state file rewritten at each refresh), fixed in their own commits. `./scripts/check` passes
but for `WindowGlassTests.theGlassHeadersAreFrosted`, which fails on main too with this Mac's
display asleep. The launch row hung on main as well, for the same reason; Bench now times such a
run out (60f0264), and the number waits on the owner's run.

Result, part 48d: shipped 48d.1 to 48d.3 (ADR 0113). The table now saves its layout
when the table's sort changes, not only when a column does, and the layout keeps the sort of
the sources without their own; a manual playlist, History and Stats open in their own sort at
launch as on a click, and a sort chosen in one is `browser.sourceSort`, put back with that
source. Every piece of window state and whether it survived a quit before this part: the
source, yes (`playback.resume`); the sort, no, fixed; the columns and widths, yes; the panes'
selections, yes; the search, no, fixed (`browser.search`, loaded only while the toolbar shows
with the field); the selection, one track, the last selected, as ADR 0095 has it; the scroll, to the
row, as ADR 0095 has it; the split sizes, the browser and Stats yes, the sidebar 8 points
narrower at each launch on macOS 26 and the queue a point narrower, fixed by measuring from
divider to edge; the queue panel, yes; the frame, yes except a quit in full screen, which saved
the screen's frame, fixed by not saving it in full screen (full screen itself isn't put back).
The browser's layout saves moved from the app delegate to the main window, so a test window
saves what the app does. Bench: the launch row (launch to the first rows drawn, budget 1 s)
didn't finish on the build Mac this run, on this branch or on main (66ee213): the measuring app
drew its first rows, then sat idle over 15 minutes until stopped, so it waits on the owner's
run. Tests: a header sort saved and loaded in a new table with the same first rows; a
manual playlist loading in its own order, in the sort chosen in it, and leaving it as before;
the search across a load, and none without the field; no frame saved in full screen; split
widths saved as a restored split shows them; one round trip that changes every item above,
saves, opens a second window on the same home and checks each came back. For the owner: sort
by a column, open a manual playlist and sort it by another, type a search, select a row and
scroll, drag the sidebar, queue and browser dividers, move and resize the window, quit,
relaunch; everything is where it was. Quit once in full screen; the window opens windowed at
its earlier frame.

#### 48e. The receiver moves on to the next track

Playing to the Denon, a track ends and the next never starts. The session waits for the
receiver to report the end (`RendererSession.swift`, `poll` and `stopped`), but the receiver's
reports lag: the last position it gave can be more than `endSlackSeconds` (3 s) short of the
end when it stops, so the stop doesn't count as the end, and `holdBack` keeps moving the app's
own deadline later while the receiver reports itself behind. The receiver also seems to ignore
`SetNextAVTransportURI`, so it never moves on by itself. 48e touches only `UPnPOutput`, so it
runs in its own worktree. ADR 0112 records the new timing and amends ADR 0041.

- [x] **48e.1 Find out first.** Log, at notice level, each poll's transport state, position,
      duration and track URI in a track's last 15 s and the 15 s after, and whether a
      `SetNextAVTransportURI` was accepted. The owner's run on the Denon (checkpoint below)
      confirms the cause; the parts below don't wait for it.
- [x] **48e.2 The app's clock decides.** When the next track goes out is worked out from the
      app's own clock: started when the receiver first reports playing, paused and resumed
      with it, and set again by a seek. It no longer waits on a report of the end. A poll may
      move the end later only for a stall the polls show (the position not moving while the
      receiver says it's playing), and by at most a cap defined once, for example 10 s a
      track, so a lagging receiver can't hold the next track back for good. A stop counts as
      the end when the app's clock is within the slack of it, whatever position was last
      polled.
- [x] **48e.3 A receiver that ignores the next URI.** After a track whose next URI was
      accepted, if the receiver stops, or goes on playing the same URI past the end, instead
      of moving to the next one, the session marks that renderer as not honoring it
      (`RendererGapless.afterStop`, with the reason shown in the signal path) and from then
      on starts each track itself with `SetAVTransportURI` and Play at the clock's end. The
      choice is kept per renderer for the session, so the second track in a row doesn't stall
      too.
- [x] **48e.4 Tests,** with the fake renderer the UPnP output tests already use: one whose
      position lags 5 s and that never reports the end; one that accepts and ignores
      `SetNextAVTransportURI`; one that stalls mid-track for 4 s and then catches up (the end
      moves later, by no more than the cap); a renderer that honors the next URI still plays
      gapless. Each of the first two fails without the change: the next track never starts.
- [ ] **Hardware checkpoint (owner):** play the end of three tracks in a row to the Denon,
      with a short track among them; each next one starts within about 2 s. Send back the log
      lines from 48e.1.

Implementation plan (ADR 0112, amending 0041), all in `UPnPOutput` and its tests:

1. **48e.1 trace.** `RendererSession.poll` logs at notice level, with public interpolations so
   `log show` prints them, every poll's transport state and status, the renderer's position,
   duration and `TrackURI`, and the app's clock, while the clock is within 15 s of the track's
   end or less than 15 s has passed since the last track change. `setNext` logs an accepted
   `SetNextAVTransportURI`; the lead, a stop at the end and a renderer marked as ignoring the
   next URI are logged too.
2. **48e.2 clock.** A new value type, `RendererClock` (its own file), holds the app's clock for
   the loaded track: where it was, when, whether it runs, and how far stalls moved the end. It
   starts at the first poll that finds the renderer playing, pauses and resumes with the
   transport (not from the polled position), and a seek or start sets it. A poll moves the end
   later only by how much more the renderer is behind the clock than its least lag, two polls
   running, while the clock is short of the end, and by at most
   `RendererClock.stallCapSeconds` (10 s) a run of the clock. `leadMarginSeconds` and
   `behindToleranceSeconds` move to it. `holdBack` and `Loaded.deadline` go. `stopped` counts
   a stop as the end when the clock or the last polled position is within `endSlackSeconds`
   of the end.
3. **48e.3 ignored next URI.** A stop at the end, two polls running, with the next URI
   accepted, or the clock's deadline passing with it accepted, sets `gapless` to `.afterStop`
   with the reason and publishes the path; the next track then goes with `SetAVTransportURI`
   and Play at once, and every later one too, since `setNext` sends the next URI only while
   `gapless` is `.nextURI`. `findAgain` resets it, as now, for a renderer at a new address.
4. **48e.4 tests.** `FakeRenderer.lagsBy(_:)` reports positions that many seconds behind.
   `RendererOutputTests`: a lagging renderer without the next URI that stops at its end; a
   lagging renderer that accepts and ignores the next URI, three tracks in a row with no
   next URI sent after the first; the mid-track stall test stalls 4 s once the position
   moved; the gapless test plays three tracks with one `SetAVTransportURI`.
   `RendererClockTests`: a poll's noise moves nothing, a hold at the start is waited for, a
   stall moves the end by its length, a long one by the cap, a renderer stuck past the end
   moves nothing, pause and resume, seeks.

Gate, part 48e: three review rounds; every finding above low fixed in its own commit (a
buffering start or late resume taken as lag, the lead acting on the clock alone, then holds after
each resume adding up); one finding left as it can't happen, since one loop runs the session
(`RendererOutput.swift:97`). The audit's points fixed: the reason shown in the signal path, the
renderer's name public in its log lines. `./scripts/check` passes.

Result, part 48e: shipped 48e.1 to 48e.4 as planned, checked
only against the fake renderer (ADR 0112). A track's end is the app's clock's: started by the
first poll that finds the renderer playing, paused and resumed with it, set by a seek. A poll
moves the end later only when the renderer falls further behind than its usual lag, and by
10 s at most from a start or a seek; a lag at the first poll counts for 1.5 s at most, so a
renderer holding where it started while it buffers has the hold waited for. A stop counts as
the end when the clock or the last position is within 3 s of it. A renderer that took a next
URI and then stopped at the end, two polls running with no change of tracks between, or is
at its end when asked at the clock's end, is marked not gapless, the next URI it
holds is taken back, and from then on the app gives it each track with `SetAVTransportURI`
and Play. The signal path panel says why: "Not gapless: it stopped instead of playing the
next track". The two new network tests (a renderer lagging 5 s without a next URI, and one
lagging 5 s that takes and ignores it, three tracks in a row) fail on main with the stop
reported as one on the renderer.

From the gate: a renderer on the next track when the clock runs out keeps gapless; stopped,
transitioning, stopped between tracks isn't taken for ignoring the next URI; a position from
before a seek back starts the lag's measurement again; another app's stream is logged as
another track, without its URL. From the second review: the lag is kept across a pause, so
holds after each resume add up as a stall; at the clock's deadline a renderer still more than
1 s short of the end is waited for, within the cap, rather than marked and cut; a renderer that
doesn't answer the take-back of the next URI isn't reported lost.

Checkpoint steps, once the owner has pushed the branch: on the Mac that plays to the Denon,
`./scripts/pull`, then `./scripts/dev`, and pick the Denon as the output. Queue three tracks,
one of them under a minute, and seek the first to about 20 s before its end. Let all three
ends pass, noting how long each next track takes to start. Then, within 15 minutes, run:

```
/usr/bin/log show --last 15m --style compact \
  --predicate 'subsystem == "com.dylanfisher.MusicPlayer" AND category == "UPnPOutput"' \
  > ~/Desktop/denon-track-changes.txt
```

and send back `~/Desktop/denon-track-changes.txt` with the timings. The lines that matter:
"polled near a track change" (state, the Denon's position and URI, and the app's clock),
"took SetNextAVTransportURI", "hadn't moved on by the track's end", "each track now starts
after the last" with its reason, and "a gap of".

### 49. Click-free play, pause and seek

The owner hears a pop when they play and pause quickly, and asks for the slight fade other
players use, keeping the response immediate and bit-perfect playback unchanged. The same goes
for seeking and for clicking in the progress bar.

- [x] **49.1 Short fades.** Pause fades out and play fades in over a few milliseconds (one
      length, defined once, about 5 ms), as do both sides of a seek and a click in the progress
      bar. The fade runs in the C render path (`HALRender`), with no allocation, locks or
      logging. Every sample outside a fade is passed through unchanged, so playback between
      fades stays bit-perfect; gapless track changes don't fade.
- [x] **49.2 DoP.** A fade would corrupt the DoP markers, so DSD over DoP doesn't fade. Say in
      ADR 0110 how it goes quiet instead (for example DoP silence), or that it doesn't.
- [x] **49.3 Tests.** A sine paused and played has no step larger than the fade allows; the
      samples outside the fades match the file bit for bit; a seek during a fade goes on from
      where the gain is. The seek rows in the budgets still pass, and the soak shows no
      underruns.
- [ ] **Hardware checkpoint (owner):** play, pause and seek quickly on the ADI-2 and say whether
      the pops are gone and it still feels immediate, and that the signal path panel still shows
      bit-perfect while playing.

Implementation plan (ADR 0110):

1. **HALRender.** The fade is a frame counter in the render state, IO proc only, from 0
   (silence) to the fade length (full gain), which `HALRenderFadeFrames` derives from the
   device rate and 5 ms, defined once in `HALRender.c`. At full gain the IO proc doesn't touch
   a sample, so playback between fades stays bit-perfect; inside a fade it scales each frame
   by the counter over the length, on top of the digital volume, through the same per-kind
   sample code. `HALRenderCreate` takes the frame size and rate and allocates a buffer of one
   fade's frames. New calls, all through atomics: `HALRenderSetSilenced` (a counter, odd while
   silenced) makes the IO proc fade to silence and then write zeros without taking audio, so
   the position stays where the pause was; `HALRenderIsSilent` says the IO proc has finished
   that fade for the latest request; `HALRenderPrepareStart`, while stopped, sets whether the
   next start fades in. A discard that drops what's playing (a seek, a track loaded over
   another) moves what the fade-out needs of the old audio, as many frames as the counter
   stands at, into that buffer at once and finishes the skip in the same cycle, as now; the IO
   proc plays the held frames fading out, then the new audio fading in. A newer discard during
   that fade carries on from the counter. A discard ahead of what's consumed (a gapless next
   track replaced) doesn't fade. Opaque streams never fade: DoP, and device layouts the IO proc
   can't scale, which now get the opaque kind instead of an Int32 stand-in.
2. **HALOutput.** `DeviceOutput`'s pause sets the render silenced and leaves the device
   running; the control thread's 10 ms tick stops it once the render is silent and the
   device's latency has passed, so the fade has played. A play during that wait un-silences
   and fades back in from where the gain is. A start fades in when the audio doesn't start at
   a track's first frame (resume, a seek while paused, a load mid-track); a track from its
   first frame, and a format switch between tracks, start at full gain. A load with playing
   false fades out the same way as a pause. DoP and opaque streams stop at once, as before.
3. **ADR 0110** says what fades and what doesn't: DoP doesn't fade or go through DoP silence
   on a pause or seek, and why; a UPnP renderer does its own pausing and seeking, so no fade
   applies there; a stop, a device switch and a double-click on a track of another rate still
   cut, which this phase leaves.
4. **Tests (49.3).** HALRenderTests: a sine paused and played has no step larger than the
   fade allows; frames outside the fades match the source bit for bit, Int16, Int24, Int32 and
   Float32; a seek during a fade-out and during a fade-in carries on from the counter; a
   gapless discard doesn't fade; opaque bytes don't fade. HALOutputTests: pause, play and seek
   on the null device keep every sample outside the fades in order; DoP keeps alternating
   markers through pause, play and seek. Existing tests that expect a seek's first frame
   untouched skip the fade-in. Bench: the seek rows and a soak.

Gate: the real-time audit passed (C only from the IO proc, no allocation, locks, logging or
Swift, every loop bounded, the hold buffer sized by its own stream). The review's low-medium (a
pause with less than a fade queued never went silent and later played a blip) and low (a
position past a track's end at a gapless change inside a refill) fixed in their own commits; the
audit's two notes done. Scrub seek 6.45 ms against phase 35's 4.3 ms: the old audio's 5 ms
fade-out plays first. 20 s soak: 0 underruns, −0.21 MB. `./scripts/check` passes but for
`WindowGlassTests.theGlassHeadersAreFrosted`, which fails on main too with this Mac's display
asleep.

Result: shipped as planned (ADR 0110). Pause, play, a seek and a click
in the bar fade over 5 ms (`HALRenderFadeFrames`: 221 frames at 44.1 kHz, 960 at 192 kHz) in the
IO proc; frames at full gain are untouched, checked bit for bit in Int16, Int24, Int32 and
Float32. A pause stops the device once the fade has played, a few tens of ms later. DoP doesn't
fade and stops at once, as before, with its markers in order through pause, play and seek. The
fade-out delayed a seek's first audio by up to 5 ms, which made the scrub row's published
position wait for the refill (153 ms median, bimodal); the position is now published after each
chunk a refill writes. Bench: seek while decoded 6.6 ms, seek after decoding moved on 5.5 ms, a
seek during the refill after another 6.5 ms (4.3 ms in phase 35: the 5 ms fade-out of the old
audio comes first), Next 11.5 ms, double-click same rate 57 ms, other rate 162 ms; 20 s soak 0
underruns, memory −0.21 MB; CPU at 24/192 1.19%; gaps 0 samples. Deferred: a stop, a device
switch and a double-click on a track of another rate still cut. Owner checkpoint: on the ADI-2,
play and pause quickly, seek with Option-arrow and click and drag in the progress bar, with
PCM at 44.1 and 192 kHz: say whether the pops are gone and it still feels immediate, and that
the signal path panel shows bit-perfect while playing; then the same with a DSD track, which
doesn't fade, to say whether its pause or seek clicks.

### 45. Spectrum and file quality

The owner asked on 2026-11-05 for a way to check that a file is what it says it is (a FLAC that
isn't a lossy file converted to FLAC, a 24/96 file that isn't 16/44.1 underneath) and to compare
several files side by side. This replaces the Later item "Library quality audit".

Read-only: analysis decodes files and writes nothing to them (AGENTS.md). Nothing in it runs on
the real-time audio thread. Accelerate (vDSP) does the FFTs: a system framework, available on
macOS 12, so not a new dependency; AGENTS.md's Stack line gains it when 45a lands.

What a fake looks like, and so what the phase measures:

| Problem | What it looks like | Measure |
|---|---|---|
| Lossy file converted to lossless | A sharp cutoff near 16 kHz (128k MP3), 19 kHz (192–256k) or 20 kHz (320k MP3, AAC), often with holes above 16 kHz | Cutoff frequency and how steep the drop is |
| Upsampled | Nothing above 22.05 or 24 kHz in a 88.2 kHz or higher file | Cutoff against the file's Nyquist frequency |
| Padded bit depth | A 24-bit file whose bottom 8 bits are always zero | Effective bits: trailing zero bits of every sample OR'd together |
| Fake stereo | Left and right identical | Channels compared sample by sample |
| Clipping, brickwall mastering | Runs of samples at full scale, little dynamic range | Peak, true peak, clipped runs, a dynamic range score |

A cutoff is evidence, not proof: old analog masters, quiet music and some mastering roll off
early, and a 320k MP3 can reach 20 kHz. So the cutoff verdicts say "suspect" and the
spectrogram is there for the owner to decide. Effective bits and identical channels are exact.

The owner's answers (2026-11-05): the whole-library pass is wanted, but runs only when the
user starts it. A live visualizer isn't wanted yet; it's in Later. The owner has no
known-good or known-bad files to tune the thresholds on, so they're set from the generated
fixtures (45a.8) and the published cutoffs of common lossy encoders, and the owner's
checkpoint compares flagged files with Spek.

#### 45a. Analysis and the Spectrum window

- [x] **45a.1 Analysis module.** A new Core module, `Analysis`. It decodes a file through
      `FileDecoder` (marked `package` for it), off the main thread at utility priority, and
      runs a short-time FFT with vDSP: 8192 points, Hann window, 50% overlap, per channel. A
      lossless file is read in its own integer format, so effective bits are exact; a lossy one
      as float. DSD files are skipped in this phase and say so. Analysis can be cancelled at
      any FFT frame.
- [x] **45a.2 Results.** One pass gives: a spectrogram reduced to at most 1,000 time columns ×
      512 frequency rows in dB, keeping each cell's maximum so short events survive; the average
      spectrum; and the measures in the table above: cutoff frequency and steepness, effective
      bits, identical channels, peak, true peak (4× oversampled), clipped runs (3 or more
      samples at full scale), and a dynamic range score (per 3-second block, the peak against
      the loudest 20% RMS, as DR meters do).
- [x] **45a.3 Verdicts.** Rules from the measures, with every threshold defined once:
      suspect lossy origin (a lossless codec, a steep cutoff at or under 20.5 kHz, Nyquist at
      22.05 kHz or more), suspect upsampled (a rate over 48 kHz and content stopping at or under
      24 kHz), padded bits (effective bits under the stored bits), fake stereo, clipped. Lossy
      files get measures, not a lossy-origin verdict. Each verdict has one line of text that
      names its numbers: "Cutoff at 16.0 kHz: suspect conversion from a lossy file".
- [x] **45a.4 Spectrum window.** A command, Show Spectrum, on the selected tracks, from the
      track table's menu, the File menu and so the palette. For one track: the spectrogram
      (time across, frequency up, linear to Nyquist, a dB color scale with its legend), dotted
      reference lines at 16, 19, 20, 22.05 and 24 kHz, the average spectrum beside it, the
      format line (codec, rate, stored and effective bits), the measures and the verdicts.
      Hovering shows time, frequency and level. Drawn in AppKit, no Swift Charts, as 43.4.
- [x] **45a.5 Comparing files.** With up to 8 tracks selected, the window stacks their
      spectrograms on one frequency axis scaled to the highest Nyquist, and draws every
      average spectrum on one chart, one color per file, with a legend of title and format. A
      file that's still being analyzed shows its progress; closing the window cancels the work.
- [x] **45a.6 Cache.** Measures go in the index, in a table of their own keyed by path, with the
      file's size and modification time; a row whose file changed is ignored and the file
      analyzed again. The table is a schema part of its own (`SchemaPart`), so changing it drops
      nothing else. Spectrograms go in the Caches folder beside the thumbnails (ADR 0079), as
      8-bit dB, about 0.5 MB each, and are evicted oldest first past a size cap.
- [x] **45a.7 Command line.** `music-player analyze [<path>…] [--json]`, from the same command
      registry entry: the selected tracks with no paths. It prints the format line, measures and
      verdicts, or the results as JSON.
- [x] **45a.8 Fixtures and tests.** The fixture generator adds broadband test audio with known
      properties: full band at 16/44.1; the same through a steep low-pass at 16 and 19 kHz;
      the same encoded to AAC with AudioToolbox and decoded back into a FLAC; 16/44.1 upsampled
      to 24/96; 16-bit padded to 24; identical channels; clipped. Each verdict has a test that
      fails without its rule, and each clean fixture a test that it gets no verdict.
- [x] **45a.9 Speed.** Bench rows with budgets set from the first measurement, with room for
      the old Mac: analyze a 5-minute 24/96 FLAC fixture locally, and the same on the slow
      simulated NAS; the analysis's peak memory. A soak run with analysis going shows no
      underruns.
- [ ] **Hardware checkpoint (owner):** on the 2015 MacBook Pro, show the spectrum of a 24/192
      track and of 8 tracks at once while music plays; report the times and any dropout. Open a
      few flagged and unflagged files in Spek and say whether the verdicts agree.

Implementation plan, part 45a (ADR 0115):

1. **Promotion.** `SignalPathLines`' private codec name (`FLAC`, `PCM`, `DSD`) moves to
   `Playback` as `SignalFormat.codecName`, so the Spectrum window's format line and the signal
   path name a codec the same way. Its own commit.
2. **Library (45a.6).** `FileMeasures`, the stored measures: the format as the decoder read it
   (format ID, rate, stored bits, channels, float, length) and the measures, each nil where it
   doesn't apply. A new `SchemaPart.measures` with its own `measures` table keyed by path,
   with the file's size and modification time, as the walk reads them so 45b can compare them
   with `files` without touching the NAS. Rebuilding it discards no stats. `MeasuresCache`, a
   public actor on a connection of its own, as `StatsReader`: `measures(path:stamp:)` returns
   a row only when the stamp matches, `store(_:path:stamp:)` replaces it. 45b reads the table.
3. **Analysis module (45a.1–45a.3).** `Sources/Core/Analysis`, importing Accelerate, HALOutput
   (`FileDecoder` and `fourCharCode` become `package`), Library, Playback,
   Metadata. `analyzeFile(at:latency:progress:)` decodes in 4096-frame hops as Int32 for
   FLAC, ALAC and integer PCM and as Float32 otherwise, keeps an 8192-frame window per
   channel, and per hop: a Hann window and `vDSP_fft_zrip`, power averaged over channels, the
   spectrogram cell maxima (at most 1,000 columns × 512 rows) and the average; the OR of every
   integer sample (effective bits), left against right, clipped runs, the sample peak, the
   true peak through a 4-phase, 48-tap interpolator with `vDSP_conv`, and 3-second blocks for
   the DR score. `Task.isCancelled` is checked at every hop. DSD throws a skip that says so.
   `Cutoff` finds the highest fall of `cutoffDropDB` across `cutoffSpanHz` in the average
   spectrum, from 5 kHz up, and its steepness. `AnalysisRules` holds every threshold once;
   `verdicts(_:)` turns measures into the five verdicts with their one line of text.
4. **Spectrogram cache (45a.6).** `SpectrogramStore`, files in `Caches/MusicPlayer/Spectrograms`
   (`AppPaths.spectrogramDirectory`): the 8-bit cells and the 512-row average, named by a hash
   of the path, size and modification time, least recently used removed past 100 MB, as
   `ThumbnailStore` does. `FileAnalyzer` puts the two caches in front of `analyzeFile`, at
   utility priority, cancelled with the task that awaits it.
5. **Command (45a.4, 45a.7).** `track.analyze`, "Show Spectrum", in the track menu and the
   File menu after Get Info (and so the palette). `Command` gains `paths`: the command line
   passes the words after its name as absolute paths, in a new `paths` key of a report
   request, and waits `ScriptLimits.fileReplySeconds` for it, as files on the NAS take long.
   `music-player analyze [<path>…] [--json]`: with no paths, the selection. It prints the
   format line, measures and verdicts of each file, or JSON; it opens no window. Up to 8 files
   in both, `AnalysisRules.comparedFiles`.
6. **Spectrum feature (45a.4, 45a.5).** `Sources/Features/Spectrum`: `SpectrumModel` (no
   AppKit) holds each file's progress, result or error, the frequency axis to the highest
   Nyquist, the reference lines, the hover readout and the text lines; `SpectrogramView` and
   `AverageSpectrumView` draw in AppKit as `StatsBarChart` does, with a dB color scale and
   legend; `SpectrumWindow` stacks one row per file and cancels its tasks on close. The app
   wires the command and the analyzer, at most two files at once.
7. **Fixtures (45a.8).** `AnalysisFixtures` in `Fixtures`: broadband noise made by an inverse
   FFT, so a low-pass is exact: full band 16/44.1, low-passed at 16 and 19 kHz, through AAC at
   128 kbps with afconvert (AudioToolbox) and back into FLAC, 16/44.1 content in 24/96,
   16 bits padded to 24, identical channels, clipped, and full band 24/96 (also 5 minutes
   for the bench). Tests: each fixture's verdicts, each rule against measures just either side
   of its threshold, the measures (effective bits, true peak, DR, clipped runs), cancellation,
   DSD, both caches, the command line's parse and reply, the model's layout and text.
8. **Bench (45a.9).** Analyze the 5-minute 24/96 fixture locally and on the slow simulated
   NAS (`FileLatency` as the play latency rows use it), and the peak footprint it adds; the
   soak gains a thread analyzing that fixture again and again. Budgets from the first run,
   with room for the old Mac.

Gate, part 45a: the review's two crashes (a NaN or infinite float sample, a lossless file of
unknown depth), the cache failure that threw away a finished analysis, the time axis of a file
longer than its stated length and a damaged cache header, and the audit's six points, fixed in
their own commits. `./scripts/check` passes but for `WindowGlassTests.theGlassHeadersAreFrosted`
(this Mac's display asleep) and a color test that passes alone.

Result, part 45a: shipped as planned (ADR 0115). Every generated fixture gets
the verdicts it was made for and the clean ones none: low-passed at 16 and 19 kHz, cutoffs at
16.0 and 19.0 kHz (155 dB per kHz); AAC at 128 kbps decoded into a FLAC, cutoff 17.5 kHz, and
the AAC file itself measured with no lossy verdict; 16/44.1 in 24/96, cutoff 22.1 kHz, suspect
upsampled; 16 bits padded to 24, 16 effective; identical channels, fake stereo; clipped, 5,558
runs; full band 16/44.1 and 24/96, none, DR 10. Bench on Apple Silicon: a 5-minute 24/96 FLAC
(157 MB) analyzed in 1.02–1.06 s locally (about 290× real time), 3.91–3.98 s on the slow
simulated NAS (the reads wait in turn), 2.8 MB added at the peak in a fresh process. Budgets:
local < 2 s and < 12 s on the old Mac, about twice the 4–6× an i7 of 2015 is slower at this
decoding and vDSP work; NAS < 6 s and < 20 s, the old Mac's compute plus the same 2.9 s of
waits, with room; memory < 10 MB on both. Soak with analysis of that file one run after
another at utility priority, beside the scan and a search a second: 20 s, 0 underruns over 19
analyses; 180 s, 0 underruns over 161 analyses, memory −7.0 MB. `music-player analyze` opens
no window (ADR 0115) and waits up to 600 s. Gate: the review's five fixed in their own commits
(a NaN or infinite float sample is now the named error "the file holds a sample that isn't a
number or is infinite" instead of a trap; a lossless file of unknown depth is read as float; a
measures cache that fails is logged and the analysis returned; the spectrogram's columns each
hold a whole number of windows and fold in pairs when a file runs past its stated length, so a
5-minute 24/96 file has 879 columns rather than 1,000; a stored spectrogram with a damaged
header is refused); the audit's five done (`trackMouseMoves()` is public in DisplayText,
`kilohertzText` beside `kilohertz`, the CD Nyquist defined once, `clamped(to:)` and the
Accelerate linker setting gone). After the gate: local 1.04 s, NAS 3.94 s, memory 0.13 MB;
20 s soak 0 underruns over 19 analyses, −4.2 MB.
The 20.5 kHz lossy threshold stays until the owner's Spek check: a genuine CD mastered
through a 20–20.5 kHz low-pass will be flagged as suspect lossy. Deferred to 45b: the library pass, which reads
`measures`. Owner checkpoint: on the 2015 MacBook Pro, with music playing, select a 24/192
track and choose Show Spectrum (File menu or the track's menu), then 8 tracks at once; say how
long each window took to fill and whether playback dropped out; run
`./scripts/bench analysis:` there and paste the table. Then choose a few files Show Spectrum
flags and a few it doesn't, open each in Spek, and say whether the cutoff, the spectrogram and
the verdict agree with what Spek shows; `music-player analyze <path>…` prints the numbers to
paste.

#### 45b. The library pass

- [x] **45b.1 Analyze Library.** A command that analyzes every file not yet analyzed, or
      changed, one at a time at background priority, pausing while a scan runs. It runs only
      when the user starts it, from the menu, the palette or the command line: never at launch,
      after a scan, or on a schedule, and files a scan adds aren't analyzed until the next run. It shows
      progress in the status area, can be paused, and resumes after a relaunch from what the
      index already holds. On the NAS the reading is the cost, so it reads each file once.
- [x] **45b.2 Library Health.** Tiles for suspect lossy origin, suspect upsampled, padded
      bits, fake stereo and clipped, over the files analyzed so far; each tile says how many
      that is.
- [x] **45b.3 Columns and smart playlists.** Cutoff, Effective Bits, Dynamic Range and True
      Peak as track table columns and smart playlist fields, read from the index.
- [x] **45b.4 Speed.** A bench row for analyzing 200 fixture files on the slow simulated NAS,
      and the soak run with Analyze Library going: 0 underruns, and search still within its
      budget.
- [ ] **Hardware checkpoint (owner):** run Analyze Library on the real library from the DAC
      Mac; report the time, the counts per tile, and a handful of flagged files checked by eye.

Implementation plan, part 45b (ADR 0116):

1. **Columns and fields (45b.3).** `trackJoins` gains `measures m`, joined by path, size and
   modification time, so a row whose file changed reads as not analyzed. `TrackColumn` and
   `SmartField` gain `cutoff`, `effectiveBits`, `dynamicRange` and `truePeak`, each with its
   expression, title and text once; `TrackRow` reads them in the same select. Cutoff compares
   in hertz as the sample rate does; true peak may be negative and compares unrounded, so
   "is more than 0" finds overs. Tests: each column's sort and text, each field's rule, a
   changed file's row reading as none.
2. **The pending list (45b.1).** `MeasuresCache.filesToAnalyze()`: each track's path and the
   index's stamp for it, with no current measures row, in path order (a folder at a time on
   the NAS), DSD left out. The stamp comes from the index, so the pass stats nothing on the
   NAS, and its row joins the files row it was made for.
3. **The pass (45b.1).** `LibraryAnalysis`, an actor in Analysis: one file at a time, decoded
   at background priority, its measures stored and no spectrogram (100 MB of them would churn
   through the cache). Before each file it asks whether a scan runs and waits a second at a
   time while one does. `pause()` cancels the file under way, which the next run reads again.
   Progress: analyzed, total, failed, waiting or paused, and the status line's text. A file
   that fails is logged and counted, and tried again next run. Tests: pending list, pause and
   resume, a run after a relaunch skipping what's stored, waiting for a scan, a failure.
4. **Command and status (45b.1).** `library.analyzeLibrary` "Analyze Library" and
   `library.pauseAnalysis` "Pause Library Analysis" in the File menu after Show Library
   Health, so in the palette and on the command line; neither from links. The app wires the
   pass to the browser's scan state and to a status part beside the scans and the tag save:
   "Analyzing library: 40 of 1,200". The browser refreshes as during a scan, and refreshes and
   reruns Library Health when the pass ends or pauses.
5. **Library Health (45b.2).** `HealthCheck` gains `lossyOrigin`, `upsampled`, `paddedBits`,
   `fakeStereo` and `clipped`; `healthReport(measuredChecks:)` reads every current measures
   row and asks Analysis's verdicts which checks each earns, so the rules stay in
   `AnalysisRules`. The report counts the files analyzed, and each of those tiles says it:
   "of 1,204 files analyzed". Tests: each tile's tracks from crafted measures, a stale row
   ignored, the count.
6. **Bench and soak (45b.4).** A row analyzing 200 fixture files (no DSD, none malformed) on
   the slow simulated NAS through the pass, budget from the first run with room for the old
   Mac; a reader row for search keystrokes while the pass writes to the same library; the
   soak runs the pass over a copy of the fixture library beside its other load.

Gate, part 45b: the soak's count is its own loop over 7 KB fixtures, not the pass repeating. The
review's low-medium (a scan failing twice in a row left the status bar scanning, and the pass
waiting on it) and low (a busy store dropped a finished analysis) fixed, with the audit's three
points and the DR unit, in their own commits. `./scripts/check` passes but for
`WindowGlassTests.theGlassHeadersAreFrosted` (this Mac's display asleep) and tests that passed
alone.

Result, part 45b: shipped as planned (ADR 0116). Analyze Library and
Pause Library Analysis in the File menu after Show Library Health, so the palette and
`music-player analyzeLibrary` / `pauseAnalysis`; never at launch, after a scan or on a
schedule. One file at a time at background priority, in path order, stored with the index's
stamp and no spectrogram; waits a second at a time while the status bar shows a scan; Pause
cancels the file under way. Library Health gains Lossy Origin, Upsampled, Padded Bits, Fake
Stereo and Clipped, each "of N files analyzed"; Cutoff, Effective Bits, Dynamic Range and True
Peak are columns and smart playlist fields. Bench on Apple Silicon: 200 fixture files on the
slow simulated NAS in 9.53–9.65 s (9.60–9.63 s after the gate) (48 ms a file, 33 ms of it the NAS's waits); budget < 15 s,
< 40 s on the old Mac (the same 6.6 s of waits and five times the compute). The second of two
search keystrokes while the pass runs, 13.5 ms p95 (idle 7.3, during a scan 15.6), within the
idle budget of 20 ms. Soak with the pass beside the scan, the search and the single-file
analysis: 20 s, 0 underruns, 17,929 files analyzed, −2.7 MB; 180 s, 0 underruns, 146,979
files, −9.2 MB. Health report 0.10 s, smart playlist 15.8 ms, re-sort 25.8 ms, as before.
Not done: read-ahead within a file, which the fixtures can't show a gain for. Owner
checkpoint: on the DAC Mac, choose File > Analyze Library with the real library; note the
time from start to the end of the status line (pause and start it again once, and quit and
relaunch once mid-way, to see it carry on); then open Library Health and send the counts of
Lossy Origin, Upsampled, Padded Bits, Fake Stereo and Clipped and the "of N files analyzed"
line; open a few flagged files of each in Show Spectrum (and Spek) and say whether they look
right; and say whether playback or the window stuttered while it ran.

### 50. Owner feedback, 2026-11-06

Listening Stats, the import sheet, the hog mode fix, Analyze Library and Scan Library, the
spectrum window and the log. The four parts touch mostly different modules, so they run in
parallel worktrees and merge in order a, b, c, d; a later part rebases on the earlier ones.
ADR numbers: 0117 to 50a if it needs one, 0118 to 50b, 0119 to 50c, 0120 to 50d.

#### 50a. Library window

- [x] **50a.1 Stats never opens hidden.** Clicking Stats with Show Browser off showed the
      panel at zero height; the owner had to drag it open. Probe: the panel slot is hidden
      for sources without a panel, so the split collapses it, and `fillPanelSlot`
      (`LibraryBrowser.swift`) calls `setPosition` straight after unhiding, with no layout
      between, then records `placedHeight` whether or not it took. `statsHeight`'s range is
      `0...2000`, so a 0 can be saved, and the split has no minimum. Give the stats height a
      range with a real minimum (the header and one row of cards), place the divider after a
      layout pass as `MainSplit.restore` does, set a minimum coordinate while a panel shows,
      and record a height only from the user's drag, not from layout passes.
- [x] **50a.2 Stats keeps its height.** Moving to another source and back, or relaunching,
      opens Stats at the height the user last dragged it to. Test: Show Browser off, Stats
      shown at its saved height, a playlist, Stats again at the same height; and the same
      with Show Browser on.
- [x] **50a.3 A lighter selected row in the Stats lists.** The marked row in Top Genres and the
      other list cards is the selection color at 0.4 alpha (`StatsListView.swift`), too
      dark. Lighter, still clearly above hover's 0.18.
- [x] **50a.4 No "discarded" text in the status bar.** "earlier play counts and playlists
      discarded" leaves the status bar's totals (`LibraryStatus.summary`). The notices stay in
      the Problems list and the problems button, where they already show.
- [x] **50a.5 The import sheet says what will change.** The top of the Import from Swinsian
      sheet becomes a two-column table (`NSGridView`, as in Get Info's File tab): what
      changes on the left, the count on the right, a heading line for how many tracks matched,
      rows with nothing to change grouped in one dimmed line ("No change: last played, date
      added, ratings, loved") instead of "later on 0 tracks", and the notes (playlists
      skipped, rows merged) as a short line under the table. Same width, so it still fits
      1440×900. Tests: the rows for a plan, and the sheet's fit test and its snapshot.
- [x] **50a.6 The stuck row line.** After hours of use a 1-point horizontal line stays at a fixed
      height on screen, across the art column and the rows, while the rows scroll under it.
      Not reproduced yet. Candidates, from reading the code: the split's divider over a panel
      slot shown at 0 height (fixed by 50a.1); an album line set on an art cell drawn into its
      row's layer (`canDrawSubviewsIntoLayer`) without redrawing the row, so a recycled row
      keeps it; the status bar's border. Fix the first two, and try to reproduce with long
      scrolls, source changes and Stats shown and hidden. Owner check: when it shows again,
      whether View > Hide Status Bar or resizing the window clears it.

Plan, part 50a (ADR 0117):
- Probe: reproduced 50a.1 in a test. From the timeline, which hides the whole split, to Stats,
  the split is unhidden and the divider placed in the same pass, in the split's hidden bounds,
  so it ends at 0, and the next layout pass saves that 0 as Stats' height. A plain playlist
  before Stats, with Show Browser on or off, keeps the height.
- 50a.1, 50a.2 (`Core/Settings`, `Features/LibraryBrowser`, `App`): `AppState.statsHeightRange`
  with a least height that holds the header and the Totals card; `fillPanelSlot` and
  `restoreSplit` place the divider after a layout pass and record the height the slot got; the
  split's delegate keeps Stats at least that tall; the split is a `DividerDragSplitView` that
  says while `mouseDown` tracks a drag, and only then is a height saved, the columns' too.
  Tests: Show Browser on and off, Stats after a playlist, the timeline and a playlist again at
  its height; a drag saved and stopped at the least height, layout passes and a window resize
  saving nothing; the panel's header and Totals card inside the least height.
- 50a.3 (`Features/LibraryBrowser`): the marked row at 0.28 alpha, hover's 0.18 kept, both
  named on `StatsListView`. Test: the marked row drawn into a bitmap, its alpha between.
- 50a.4 (`Features/LibraryBrowser`): `LibraryStatus.summary` drops the discard notice; the
  problems list keeps it. Test: the summary without it, the problem still listed.
- 50a.5 (`Features/LibraryBrowser`): `ImportPlan.preview`, an `ImportPreview` of a heading,
  rows of what changes and how many (Skip counts only from iTunes), the fields with nothing
  to change in one "No change:" line, and notes (ratings kept, playlists skipped, rows merged,
  tracks with no file, problems). The sheet shows the heading, an `NSGridView` of the rows,
  the dimmed line and the notes in one wrapping line, at the same width. Tests: the rows for
  a plan from each player; the fit test with the table and the dimmed line, and the snapshot
  it writes.
- 50a.6 (`Features/LibraryBrowser`): the first candidate is 50a.1's fix. For the second, a
  probe drew an art cell in a row view that draws its subviews into its layer: setting the
  album line redraws the row's layer, and clearing it clears the line, so there is nothing to
  fix there. Test: after long scrolls both ways and a change of order, every row view on
  screen has its own row's line and its art cell its own album line.
- Order: this plan, 50a.4, 50a.3, 50a.1 and 50a.2 with the ADR, 50a.6's test, 50a.5, the
  result.

Gate, part 50a: the review found nothing above low. Fixed: Stats' least height gives way
when the window leaves the table less room, so the split's minimum never passes its maximum;
the "No change" names come from the rows' own words, which also cleared the single-source
check's three new repeated literals ("ratings", "loved", "playlists"), with Loved taking the
track column's title; a comment rewrapped. Left: tests of the columns' height saved only from
a drag (the same code path as Stats', covered by the window state test's drag) and of a
Ratings row of one. One full run failed on two tests outside this part, a window centered
on another screen and a Settings wait timing out under load; both pass alone, and the next
run passed. `./scripts/check` passes.

Result, part 50a: shipped 50a.1 to 50a.6 (ADR 0117). Stats opened at 0 after the timeline,
which hides the whole split: the divider was placed in the split's hidden bounds, and the
next layout pass saved the 0. The divider is now placed after a layout pass, a height is
saved only while the user drags the divider (`DividerDragSplitView`), the columns' too, and
`window.statsHeight` takes `130...2000`, the panel's header and Totals card, which the divider
keeps while Stats shows; a saved 0 is discarded and Stats opens at 380 once. The Stats lists'
marked row is at 0.28 alpha, hover's 0.18 kept. The status bar no longer says "earlier play
counts and playlists discarded"; the Problems list does. The import sheet shows a heading of
how many tracks matched, a two-column table of what changes and how many, "No change: …" in
one dimmed line, and what's left out in a line under it, at the same 640 points; Skip counts
show for iTunes only. The stuck line wasn't reproduced: a probe shows an art cell's album
line redraws its row's layer, and a test of long scrolls both ways and a change of order finds
every row view with its own lines; the 0-height panel's divider, the first candidate, is gone
with 50a.1. Tests: Stats at its height after a playlist, the timeline and a playlist again
with Show Browser on and off; a drag saved and stopped at the least height, layout passes
and a window resize saving nothing; the header and Totals card inside the least height; the
marked row's alpha drawn; the status summary without the notice; the preview's rows for
Swinsian and iTunes; the sheet's fit test with the table, and its snapshot. Owner check: (1)
with Show Browser off, open History's timeline, then Stats: it opens at the height last
dragged; drag it, go to a playlist and back, and relaunch: the same height; (2) Import from
Swinsian: the table at the top, nothing listed as "on 0 tracks"; (3) the marked row in Top
Genres reads lighter; (4) when the stuck line shows again, whether View > Hide Status Bar or
resizing the window clears it, and whether the timeline or Stats was shown before.

#### 50b. Playback: the hog mode fix plays the track you chose; the log

- [x] **50b.1 Turn On plays the chosen track.** With hog mode off, double-clicking a DSD
      track and choosing Turn On in the dialog started the first row instead. Probe:
      `play(starting:)` plays a one-track queue until the full list arrives (ADR 0078), and
      DoP's refusal comes before the full queue does, so `FailedTrack.entry` is 0, not the
      clicked row's index. `complete()` moves the cursor to the row but never corrects
      the failure's entry, the DSD album fails three times and stops at entry 0, the dialog's
      replay finds a different track at 0 and only logs `.gone`, and the next Play starts row
      0. Fix: failures recorded against the one-track queue move with it to the row in
      `complete()`, so the event and the dialog carry the right entry; `replayPosition` still
      never plays a different track; and a fix that can't replay says why where the user is
      looking, not only in the log. Test: `play(starting: urls[2])` with a gated fill and a
      refusal before the gate opens, then the fix replaying entry 2.
- [x] **50b.2 Log values in Copy Details.** The owner asked whether playback log lines should be
      public so Copy Details shows their values instead of `<private>`. Decision (the owner can
      overrule it): the log's values that are the app's own or the device's are public: errors,
      OSStatus codes, formats, device and renderer names. Track paths stay private, logged
      with `privacy: .private(mask: .hash)` so the lines about one file can be matched; Copy
      Details already prints the failed track's path and error in plain text. Make
      `renderer.name`'s privacy consistent in `RendererSession`. Update ADR 0025's row 35 and
      its `rg` check.

Plan, part 50b (ADR 0118, amending 0025 and 0111):
- Probe: confirmed by a test before any fix. `play(starting:)` loads the one-track queue, and
  `DeviceOutput.loadTrack` refuses DoP without hog mode synchronously, so `.trackFailed` goes
  out with entry 0 and `.finished` is held for the queue. `complete()` moves the cursor to the
  row, the held end skips on, the album's next two tracks fail too and the engine stops with
  causes `[0, 3, 4]` and the cursor on entry 0. The dialog, shown for the first failure, keeps
  entry 0, and `replayPosition` finds row 0's track there and refuses with `.gone`, which only
  the log says.
- 50b.1 (`Core/Playback`): while `completing`, a failure is recorded but its event is held,
  as the end already is; `complete()` moves every failure recorded so far to the started
  track's entry in the whole queue, and the held events go out first when the hold is
  released, so the event, the dialog and the run's causes carry the row. Abandoned, they go out
  with entry 0, right for the queue that stays. A run of failures that stops playback leaves
  the cursor on its first track, not entry 0, so Play tries the chosen track again.
  `replayPosition` is unchanged and still never plays a different track.
- 50b.1 (`Features/NowPlaying`, `App`): `ReplayRefusal.notice(after:)` says, for a fix made
  whose track isn't played again, why and what to do; the app shows it as an alert sheet on
  the window the fix was asked from (the main window under the dialog, or the details window).
- 50b.2 (`Core/Log`, `Core/Playback`, `Core/HALOutput`, `Core/UPnPOutput`): the decoder's and
  DSD reader's errors (`MetadataError`) name the file's path in their description, so
  `logText(_:without:)` in Log gives an error's text with the track's path replaced by "the
  track's file", logged public beside the path logged with `.private(mask: .hash)`. Errors about no
  track (HAL, OSStatus, SOAP, device description, DeviceOutput's and the renderer's) name no
  path and are logged public, as are device names, UIDs, renderer names and addresses and
  four-character codes. A run's line logs only its count, as a cause's message can be an
  error's whole text; each track's own line has its error. `serving <renderer>: …` stays private: the HTTP server's problems can
  name a served file's path. Every `renderer.name` in `RendererSession` and `RendererOutput`
  is public.
- Tests: `play(starting: urls[2])` with a gated fill and a refusal before the gate opens, then
  two more refusals: the events and causes say entries 2, 3 and 4, the engine stops on entry
  2, and playing it loads the chosen track; a failure before a queue that couldn't be read
  still goes out, with entry 0; the refusal's notice; `logText` removes a `MetadataError`'s
  path; and a line logged as the engine logs a failure reads back in `recentLogLines` with
  the error and a hash, not the path or `<private>`.
- Order: this plan, 50b.1's engine fix, its notice, 50b.2, the ADR and the result.

Gate, part 50b: one review, which found nothing above low. Fixed: the run's log line now logs
only its count, as a cause's message can be a non-`PlaybackFailure` error's whole text; the
log rule also catches camelCase names (`fileURL`, `filePath`); the ADR names `logText`'s
exact-path limit and the short queue that ends rather than stops. Left as accepted: a failure
held while the queue is read waits as long as the read does; a failure of a track removed
during the read still goes out and its fix refuses with `.gone`. `./scripts/check` passes; the
two color-well tests in SettingsWindowTests failed in two of four runs on this loaded machine,
and on the base commit too.

Result, part 50b: shipped 50b.1 and 50b.2 (ADR 0118, amending 0025 and 0111). The cause was
as probed and a test confirmed it before the fix: a play from a list fails its first track
against the one-track queue, so the failure named entry 0, the run's causes read `[0, 3, 4]`
and the engine stopped on entry 0. While the queue is read a failure's event is now held, as
the track's end is, and goes out with the track's entry in the whole queue; a run of failures
that stops playback leaves the cursor on its first track, so Play and the fix play the chosen
track. A fix whose track can't be played again says why in an alert on the window it was
asked from. The playback modules log errors, device and renderer names, UIDs, addresses and
codes public, a track's path as a hash and its error with the path replaced by "the track's
file"; `scripts/arch.swift` fails a path or URL logged public. Tests: the DSD album played
from its third row with the refusal before the queue, events and causes on entries 2 to 4,
stopped on entry 2 and playing it loads that track; a held failure goes out with entry 0 when
the queue can't be read; the refusal's alert text; a failure logged as the engine logs one
reads back from the log store with its error and a hash, no path and no `<private>`; the
arch rule's planted cases. For the owner: with hog mode off, double-click the third track of
a DSD album, choose Turn On Hog Mode, and check that track plays; turn hog mode off again,
play a DSD track, Cancel the dialog, click the status bar's problem to open its details, play
a FLAC track, click Turn On Hog Mode in the details and check an alert says why the DSD track
isn't played; open a problem's details, Copy Details, and check the log lines show
errors and device names, and paths only as `<mask.hash: …>`.

#### 50c. Analyze Library and Scan Library

- [x] **50c.1 Two to four files at once.** The pass analyzes `min(4, max(2,
      activeProcessorCount / 2))` files at once, 2 on the 2015 MacBook Pro, as a sliding task
      group (Spectrum's `filesAtOnce` loop is the pattern); only the pass's actor counts and
      reports. Pause cancels every file under way, and each is read again next run; each file
      is still read once per run. Files are still started in path order.
- [x] **50c.2 Utility priority.** Each file is decoded at `.utility`, not `.background`. Bench
      rows rename "at background priority"; the 200-file row is measured again (the owner's
      guess: 2 to 3 times faster on the NAS).
- [x] **50c.3 Progress in Library Health.** While the pass runs, Library Health shows a
      progress bar with "Analyzing library: 1,240 of 43,368" and the file under way (the
      newest started, its name only), and a Pause button beside it; paused, it shows Analyze
      Library to carry on. The status bar shows the same Pause button beside its bar. Detail
      comes from what the pass already knows, reported at most a few times a second; no new
      reads.
- [x] **50c.4 Carry on after a quit.** A run already skips measured files; what's missing is
      the count. The count is over the whole pass, not what's left: "1,240 of 43,368" after a
      relaunch, the measured files counted as done. After a relaunch with a pass unfinished,
      Library Health says "Library analysis paused: 1,240 of 43,368" and its Analyze Library
      button carries on.
- [x] **50c.5 Start over once done.** Once every file is measured, Analyze Library reads
      "Analyze Library Again" in the menu and Library Health, and asks first, since it reads
      every file again. A run again keeps the measures it replaces until each file's new ones
      are stored, and resumes after a quit the same way: the index records the time the run
      started and each measure the time it was made, and a run lists files measured before
      its start. Stored data has one shape: if the measures table changes, how the owner's
      existing measures are kept, or why they can't be, goes in the ADR; prefer a side table
      over a change that discards them.
- [x] **50c.6 Pause Scan Library.** A Pause button beside the scan's bar in the status bar,
      and wherever scan progress shows (Settings > Folders), pauses the running scan with
      `ScanControl.pause()`, which already exists; Resume carries on where it was. A
      user's pause is held in `WatchState` so the watcher's own `resume()` calls don't undo
      it, and the status bar says "Scan paused: …". While a scan is paused by the user, other
      scans wait behind it as now, and Analyze Library doesn't wait for it (a paused scan
      reads nothing). A pause doesn't outlast a quit; the next launch scans as usual. Tests in
      `WatchState` and the watcher.
- [x] Amend ADR 0116 with ADR 0119.

Plan, part 50c (ADR 0119, amending 0116):

1. **Files at once, utility priority (50c.1, 50c.2).** `LibraryAnalysis.filesAtOnce` is
   `min(4, max(2, activeProcessorCount / 2))`. The pass starts files in path order into a task
   group, at most that many under way, each child decoding at `.utility` and storing its own
   measures (the three tries stay); only the actor counts and reports. Pause cancels the run,
   so every child. Bench rows rename "at background priority" to "two to four files at once".
   Tests: no more than `filesAtOnce` under way, every file started in path order, a pause
   with several under way reads each again next run and none twice in a run.
2. **The count over the whole pass, run again (50c.4, 50c.5).** A new schema part,
   `analysisRun`, beside `measures`, so the measures table and the owner's rows stay as they
   are: `analysis_run` (one row: when the run that's going or last went started, and whether
   it finished), `measured_at` (the time each measures row was stored, by path), and
   `analysis_failures` (the files the last run couldn't analyze, with their stamps). A file is
   done for the pass when it has current measures stored at or after the run's start; rows
   from before this part count as made at 0, so the owner's measures are done. `MeasuresCache`
   gains `analysisFiles()` (pending files in path order, the done count, the last run's
   failures still pending, and whether a run is unfinished), `beginRun(again:)` and
   `finishRun()`. `Progress.analyzed` and `total` count the whole pass. `start(again:)`;
   `standing()` says, while no run goes, whether a run is unfinished and whether every file
   was tried. Tests: a relaunch counting from what's stored, a run again listing every file
   and resuming after a relaunch, keeping the measures it replaces until each is stored, and
   the owner's rows from before the part counting as done.
3. **What the pass reports (50c.3).** `Progress.file`: the name of the newest file started.
   Counts are reported at most every `reportIntervalSeconds` (0.25 s); a change of stage and
   the end always. A run with nothing to do reports only its end, so no "0 of 0".
4. **Pause Scan (50c.6).** `WatchState.pauseRunningScan()`/`resumeRunningScan()`; a user's
   pause makes `holdsRunningScan` true until Resume or the scan's end. The watcher's
   `pauseScan()`/`resumeScan()` send `.scanPaused(folder:, Bool)`. `LibraryStatus` keeps the
   paused folder: "Scan paused: Music: 300 of 1,200 read", and `isScanning` leaves it out, so
   Analyze Library goes on. Commands `library.pauseScan` "Pause Scan" and
   `library.resumeScan` "Resume Scan" after Rescan All. Settings > Folders shows no scan
   progress, so the status bar is the only place. Tests: `WatchState`, the watcher holding a
   paused scan through a playback stop, `LibraryStatus`.
5. **Status bar and Library Health (50c.3–50c.5).** The activity line splits: the scans and a
   save, then a small borderless pause or play button for the scan, then Analyze Library's
   text and its own button; each button runs a command through the browser's `runCommand`,
   so the menu, palette and buttons agree. Library Health's header gains the analysis line:
   a bar, "Analyzing library: 1,240 of 43,368 · name.flac" and Pause while it runs; paused,
   "Library analysis paused: …" and Analyze Library; idle, the button alone, reading "Analyze
   Library Again…" once every file was tried. The menu and palette title follow it through a
   dispatcher `title` hook. Again asks first. At launch the app asks the pass's standing and
   shows a paused run as paused.
6. **Bench.** The 200-file row and the search during the pass, before and after, under the
   load of the other parts' agents.

Gate, part 50c: no separate reviewer pass was run for this part; the implementer reviewed its
own diff. `./scripts/check` passes clean on the last commit; earlier runs under the other
parts' load failed renderer tests that lost their port to another run ("Address already in
use") and a Settings color test, each passing alone and on the rerun. Two dupes findings fixed in the commits that caused them: the failures table's `DELETE FROM`
and the confirmation's "Cancel", both allowlisted as different facts.

Result, part 50c: shipped as planned (ADR 0119, amending 0116). Analyze Library runs
`min(4, max(2, cores / 2))` files at once at utility priority, 4 here and 2 on the 2015
MacBook Pro, started in path order; Pause cancels every file under way. A new schema part,
`analysisRun` (the run's start and whether it finished, when each measures row was stored, the
run's failures), leaves `measures` as it was, so the owner's measures count as done. The count
is over the whole pass and survives a relaunch, which shows the run as "Library analysis
paused: N of M"; a run with nothing to do shows no "0 of 0". Once every file was tried, the
menu, the palette and Library Health read "Analyze Library Again…", which asks first and keeps
each file's measures until its new ones are stored. Library Health shows the bar, the count,
the file under way and Pause or Analyze Library; the status bar has a small pause/play button
after the scans' text and after Analyze Library's. Pause Scan and Resume Scan (File menu after
the analysis commands, the palette, `music-player pauseScan` / `resumeScan`) hold the running
scan in `WatchState` through playback changes; "Scan paused: …", and Analyze Library doesn't
wait for it. Settings > Watched Folders shows no scan progress, so the status bar is the only
place for the button. Bench, Apple Silicon, with three other agents building and testing:
200 fixture files on the slow simulated NAS, 9.38 s before (load 10–12) and 2.11 s and 2.09 s
after (load 4–5), 10 ms a file against 47; budget < 15 s, < 40 s on the old Mac, kept until its
checkpoint. The second search keystroke during the pass, 15.46 ms p95 before, 15.51 and
16.77 ms after (slowest 34 ms in the second run), within the 20 ms budget. Tests: files at once
and in path order, a pause with several under way, the whole count and a run again across a
relaunch, the owner's rows counting as done, throttled reports, `WatchState` and the watcher
holding a user's pause through playback stopping, the status text, the buttons and Library
Health's line, the dispatcher's title hook. Owner checkpoint: on the DAC Mac, with the real
library, choose File > Analyze Library and check that the files already measured count as
done ("N of 43,368" starts near where it stopped), the time to the end, and whether playback
or the window stutter with four files at once; open Library Health during the run (bar, file
name, Pause), pause and quit, relaunch and see "Library analysis paused" there and in the
status bar, and carry on; once done, check the menu reads "Analyze Library Again…" and asks;
during a scan of the NAS, click the status bar's pause button, start and stop a track, and
check the scan stays paused until Resume. Then the 2015 MacBook Pro: the same run, two files at
once, while playing.

#### 50d. Spectrum window

- [x] **50d.1 Album and file size.** Each file's header names its album beside the title and
      ends with the file's size ("So Many Questions — Album · PCM · 44.1 kHz · … · 4:16 ·
      44.8 MB"); the window opens with the `TrackRow`s it already looks titles up in, the size
      from the index, formatted as the track table's Size column formats it.
- [x] **50d.2 What differs, in words.** With two or more files, a "Differences" box under the
      average spectrum explains how each file differs from the first, in plain sentences
      for someone who doesn't read spectra, from the measures and the average spectra the
      window already has, no new reads: a lower cutoff ("B stops at 16 kHz and A goes on to
      22 kHz: B was probably made from an MP3 or AAC"), stored and effective bits ("B is
      24-bit but holds 16 bits of detail: no more detail than A"), a level difference ("B is
      about 3 dB louder overall"), a dynamic range difference ("B's DR is 6 against A's 11: B
      is more compressed, typical of a loud remaster"), true peaks over 0 and clipping, more
      bass or treble (band levels from the average spectrum, matched by frequency, not row),
      length, and format and size. When nothing differs past the thresholds it says "These
      files sound the same as far as these measures can tell" and that identical audio can't
      be proved without comparing samples. Every threshold is one constant in
      `AnalysisRules`; the sentences are built in Analysis's text, testable without a window.
      Tests: the owner's case (a 16-bit WAV and a 24-bit FLAC of one master: format, bits
      and size differ, a little more above 16 kHz in the WAV), a lossy-origin copy, a louder remaster.
- [x] Record ADR 0120, amending 0115.

Implementation plan, part 50d (ADR 0120):

1. **Promotion.** The file size text, `ByteCountFormatter` in `.file` style, written twice now
   (the track table's Size column, the tag editor's `FileRow.sizeText`), moves to
   `DisplayText` as `fileSizeText`, for its third caller. Its own commit.
2. **Header (50d.1).** `SpectrumModel.File` gains the album and the size, made from the
   `TrackRow` the app already looks the title up in (`File(path:row:)`, the file's name when
   the index has no row), so `SpectrumWindows.show` takes paths and rows. The title reads
   "Title — Album", the analyzed status line ends with the size. Each file gets a short name
   for the legend and the sentences: its title, or where titles repeat, its file type ("the
   FLAC"), or else its place ("file 2"). The legend shows the names, not the format lines the
   headers already show.
3. **Differences (50d.2).** `Differences.swift` in Analysis: `ComparedFile` (a name, the
   result, the size) and `differences(_:from:)`, one sentence per difference of a later file
   from the first, in order: cutoff, level, DR, true peak over 0, clipping, bass, treble and
   above 16 kHz (band power from the average spectra, matched by frequency, against the
   overall level), length, rate, bits, format, size; then, when none of the sound measures
   differ, that they sound the same as far as the measures tell and that only the samples
   could prove it. Level is the power summed over the average spectrum from 20 Hz to the lower
   Nyquist, so "about". Thresholds in `AnalysisRules`. Tests: the owner's WAV and FLAC, a
   lossy-origin copy, a louder remaster, and each sentence either side of its threshold.
4. **Window (50d.2).** A "Differences" title and a scrolling text view under the legend and
   the dB scale, sharing the right column's height with the chart, only with two or more
   files; it fills once every file has finished, each later file's sentences in a paragraph.
   Test: the window with 8 analyzed files lays out with the chart and the differences both
   tall enough to read, and writes a picture to `.build/snapshots`.
5. **ADR 0120**, amending 0115: the header, the names, the sentences and their thresholds,
   and why the level is an estimate.

Gate, part 50d: the review's five points, fixed in their own commit: the cutoff and rate
sentences both describing one upsampled file, a lossy file at a higher rate called upsampled,
a 32 kHz file's lost highs called beyond hearing, and the closing line saying a silent file, a
mono one, or a pair whose spectra couldn't be compared sounded the same (now a silence and a
channels sentence, and no closing line without the spectra). Row 0's DC weighting across rates
and the missing bit rate of lossy files are recorded in ADR 0120, not fixed. `./scripts/check`
passes; under the other parts' load, the Settings window's color tests failed twice and pass
alone.

Result, part 50d: shipped as planned (ADR 0120). The header reads "So Many Questions —
Album" and its format line ends with the index's size ("· 44.8 MB"); `fileSizeText` is the
one size text in `DisplayText`. Files of one title are named by type ("the WAV", "(WAV)" in
the header), then by place. With two files or more, a Differences box under the legend
says how each later file differs from the first, in sentences, once all have finished. Tests:
the owner's WAV and FLAC (dither above 16 kHz, 24 against 16 bits, compressed against
uncompressed, size, then "sound the same as far as these measures can tell"), a lossy-origin
copy, a loud remaster (5 dB louder, DR 6 against 12, true peak, clipping, 3 dB more bass),
each threshold either side, padded bits, rates, a lossy file, mono and silence, the fixtures'
16/44.1 noise against its 96 kHz upsampling (the same level once matched by frequency), the
model's names and comparison, and the window with 8 files (picture in
`.build/snapshots/spectrum-window.png`). Owner steps: select the WAV and the FLAC of "So Many
Questions", Show Spectrum, and read the
Differences box (each file against the top one); say whether each sentence matches what you hear, and whether the thresholds
(1 dB level and bands, DR 2, 1 kHz cutoff) say too much or too little. Then try a remaster
against its original.

Gate, phase 50: two Sonnet reviews of the merged branch; nine findings, each fixed in its own
commit. The measures cache opens its connection on first use, on its actor, so the launch's
read of where Analyze Library stands doesn't wait on SQLite on the main thread while the scan
holds the index. A scan the watcher's stop cancels, as a folder removed or a Settings change
does, ends with `scanStopped`, so the status bar drops it and its pause instead of showing
"Scan paused" with a Resume that does nothing. A run carried on keeps its failures, so it
doesn't read those files again and its count doesn't step back; only Again forgets them. A
pause after the last file started, which the file finishes through, ends the run as finished.
Analyze Library counts as running once the user starts it, so a scan's end before the first
report doesn't show it paused (no test: the app delegate holds it). `Stage.isRunning` and
`HealthPanel.analysisCommand(for:)` say once which stages run and which command the buttons
run. A paused scan's bar stands still, empty while it still lists folders. Library Health
opens at 110 points at least, its header, the analysis line and a row of tiles, over columns
dragged shut, and its divider stops there (ADR 0117). A window resize that moves the divider
clears the height last placed, so the next panel is placed again. Accepted, in ADR 0119: a
forgotten Pause Scan holds other scans and sync pushes until resumed, as a playback hold does,
and Resume Scan while playback holds a network scan leaves it held until playback stops.
The Settings window's two color tests failed the first full runs, as on 50c's branch before
its fix; that fix, a 30 s wait for the color saves, is taken onto this branch, and
`./scripts/check` passes.

### 51. Discogs tagger

A window, opened like Year in Review, that matches library albums to Discogs releases and
writes their tags through `TagWriter` once the user has reviewed them. Asked for on 2026-11-07.
This round reads only a local catalog built from the Discogs dumps; the API is phase 52, and an
LLM review of incomplete matches is under Later. The lookup moved out of music-recommender into
the player on 2026-11-07; the service (`~/projects/music-recommender` on mbp2021, whose
`docs/recommendations.md` is the design for it) keeps the recommendations. Workflow and field
names are modeled on YATE's Discogs Wizard
(`https://2manyrobots.com/YateResources/InAppHelp/Discogs.html`), whose tags the owner's
matched albums already carry.

51a (`Core/Metadata`, `Core/TagWriter`, `Core/Library`, `Tools/TagCorpus`) and 51b (a new
`Core` module for the catalog) touch different modules, so they run in parallel worktrees and
merge a, then b. 51c needs both, and 51d needs 51c; 51e needs 51d's import button; 51f runs after the gate, and 51g after 51f. ADR
numbers: 0128 and 0129 to 51a (the survey's findings, custom fields), 0130 to 51b, 0131 to 51c,
0132 and 0133 to 51d (the mapping, one confirmation for a match set), 0134 to 51e (resuming an
import), 0135 to 51f (list fields in smart playlists); 51g needs none.

Decided by the owner on 2026-11-07:

| Question | Answer |
|---|---|
| Where the catalog and the matching live | The player: a local SQLite catalog built from the dumps, matched in Swift; the API (52) reuses the same matcher |
| An album is matched when | Its files carry `DISCOGS_RELEASE_ID` |
| Several releases match a tracklist equally | Tie-break by barcode or catalog number in the tags, then a digital or CD format over vinyl, then the master's main release; still tied, the album drops to Likely |
| A field that already has a different value | Per-field replace or fill-empty, set once in a saved mapping, then applied to a whole match set |
| Which tags are written | A YATE-style mapping the user edits. By default each Discogs field goes one to one to its own tag; the owner configures it to their layout (genre and styles below), saved as a preset |
| Where the dumps are | A folder set in `config.json`, the same one music-recommender reads, so both use one copy of the data; each builds its own database from it |
| zlib | Fine to link (the system library) |
| Agents reading the real library | Allowed, read only, for 51.1's survey, 51.8's tuning and 51.13's budgets: the watched folders and the dumps folder, reports under `.build/`; an ADR records the exception to AGENTS.md's music files boundary |
| The real import | An agent imports the 2026-11-01 dump on this Mac for 51.8 and 51.13 |
| The dumps folder in `config.json` | A share and a path, the shape of `library.watchedFolders`, so a remount elsewhere still finds it |
| MP3's Discogs links and credits | Read and written: YATE stores the `DISCOGS_*_URL` fields as `WXXX` frames and credits as `TIPL` (ADR 0128), so 51.2's custom fields gain both in 51d, and "Like my library" matches YATE in every format |
| Presets that ship (2026-11-07) | None from the owner's library, since the app will be shared: "One to one", "Minimal" and a generic "YATE" (YATE's keys and spellings per format). The owner's YATE layout stays only as a test fixture; their saved mapping is One to one with their own values kept (51.22) |
| Styles (2026-11-07) | One tag, `MOOD`, in every mapping and in the index; no `STYLE` key. `MOOD` is a standard field in all three tag formats, so other apps read it |
| The API token (52.1) | The owner adds one, as `"discogs.token"` in `config.json`, before phase 52 runs |

What the owner's matched albums carry, from a sample on 2026-11-07 (400 random FLAC albums, 90
with a release id; all tagged by YATE): `DISCOGS_RELEASE_ID`, `DISCOGS_MASTER_ID` (as `m744074`),
`DISCOGS_RELEASE_ORDINAL_POSITION`, `DISCOGS_CATALOG_NUMBER` (as `Label: catno`),
`DISCOGS_ARTIST_LIST`, `DISCOGS_IMPORT_SETTINGS`, the `DISCOGS_*_URL` fields (release, master,
artist, album artist, label, artwork), `LABEL`, `CATALOGNUMBER`, `MEDIA` (as
`File (WAV,Album,Remastered)`), `INVOLVEDPEOPLE`, `PRODUCER` and `TRACK_NUMBER_TEXT`. The owner's
own layout, which the mapping must be able to reproduce but doesn't default to: `GENRE` is the
first genre, " - ", then the styles (`Electronic - Ambient, Dub Techno`; some files repeat the
styles twice, a YATE template error not to copy), `MOOD` holds the styles and `GROUPING` the
label. Album titles are Discogs's, with no year added. The survey (51.1) checks this over the
whole library and the other formats.

#### 51a. Survey and fields

- [x] **51.1 Survey (read only, the owner's ask).** A `TagCorpus` mode that reads every file in
      the watched folders and reports, per format: each `DISCOGS_*` and other non-standard key
      with how many files and albums carry it, sample values, and which keys are constant
      within an album. Also how many albums have `DISCOGS_RELEASE_ID` on every track, on some,
      or none, and the conventions around it (the genre, style and grouping layout,
      `Artist (2)` suffixes, ANVs). Written to a file under `.build/`, never to the
      library. Its findings become 51.10's "Like my library" preset and an ADR.
- [x] **51.2 Custom fields read and written.** The tag reader exposes non-standard keys
      (Vorbis comments, ID3 `TXXX`, MP4 `----:com.apple.iTunes:<name>`) by name, and `TagEdit`
      can set or remove a custom key in each format, with tests on generated fixtures and the
      corpus clones. `DISCOGS_RELEASE_ID` and `DISCOGS_MASTER_ID` are stored in the index
      (columns on `tracks`), the rest is read from the file when needed.
- [x] **51.3 Matched albums.** An album counts as matched when every track has the same
      `DISCOGS_RELEASE_ID`; mixed or partial ids are their own state, shown as Incomplete.

Implementation plan, part 51a (ADRs 0128, 0129):

1. **Reader (51.2).** `TrackTags.custom`, the non-standard keys by uppercased name, the first
   value winning as for the other fields: every Vorbis key the reader doesn't map, every
   `TXXX` description it doesn't map, and every `----` item whose `mean` is
   `com.apple.iTunes` and whose `name` it doesn't map, apart from `iTunSMPB`. `filling(from:)`
   fills them too. `DiscogsKey` in `Metadata` names `DISCOGS_RELEASE_ID` and
   `DISCOGS_MASTER_ID` once. Tests in `MetadataTests` on hand-built FLAC, MP3 (2.3 and 2.4),
   MP4 and WAV tags.
2. **Survey (51.1).** `TagCorpus --discogs-survey <folder>…`: walks the folders, reads each
   file once (`FileFormat`, then `parse`, through a read-only `FileSource`), and appends one
   JSON line per file to `.build/discogs-survey/files.jsonl`, so a stopped run resumes where it
   was; progress on standard error. Then `DiscogsSurvey` folds the lines into
   `.build/discogs-survey/report.txt`: per format, each custom key's files, albums, sample
   values and albums where it is constant; albums with a release id on all, some or no
   tracks; and the conventions (`GENRE` as "genre - styles", doubled styles, `MOOD` against
   the styles, `GROUPING` against the label, `Artist (2)` suffixes, artist names against
   `DISCOGS_ARTIST_LIST`). Every write goes through `requireCorpusWrite` with the survey folder
   as its only root. Tests in `TagCorpusTests` fold hand-made lines and run the walk on
   generated fixtures in a temporary folder. Run in the background on `/Volumes/music/library`
   and `/Volumes/music/dsd`.
3. **Writer (51.2).** `TagEdit.custom`, name to text, empty text removing the key; a name
   must be printable ASCII without `=` and not one the reader maps to a field. `TagGroup`
   gains `.custom(name)`, which FLAC writes as a Vorbis comment, ID3 as `TXXX` and MP4 as a
   `----:com.apple.iTunes:<name>` item, each replacing every key of that name. Tests in
   `TagWriterTests` on generated fixtures in each format, and the round trip on the corpus
   clones gains a custom-key edit.
4. **Index (51.2, 51.3).** `discogs_release_id` and `discogs_master_id` on `tracks`, from
   `TrackTags.custom`; the index's changed SQL rebuilds it on open, as any change does.
   `LibraryIndex.discogsMatches()`: each album's state, matched (one release id on every
   track), incomplete (some tracks without one, or several ids) or unmatched. Tests in
   `LibraryTests` through a scan of generated fixtures.
5. **ADRs.** 0128, the survey's findings and the exception that lets agents read the real
   library, with AGENTS.md's boundary pointing at it; 0129, custom fields.

#### 51b. The local catalog

- [x] **51.4 Import.** A streaming import of the releases, masters, artists and labels dumps,
      read in place from the dumps folder in `config.json`, `/Volumes/music/discogs` on the
      owner's Macs (the NAS folder music-recommender reads too, as `~/mnt/music/discogs`; it is
      only read, never written or copied), into `discogs.sqlite` in Application Support (a path in
      `config.json` overrides it; it must be outside every watched folder). The newest complete
      dump set in the folder is used. Gzip read through the system zlib as a stream and XML
      with `XMLParser`; nothing is unpacked to disk, since the gzip is read only once per
      import and the window only ever queries the SQLite catalog. The checksum file is
      checked first. A new import writes a new file and replaces the old one when complete, so
      the window never sees a half-built catalog; a failed import is reported and the old
      catalog stays. Started from the window ("Import Discogs Dump…", choosing the folder),
      with progress, and it can be stopped.
- [x] **51.5 What's kept.** Per release: id, master id and whether it's the main release, title,
      artists (id, name, ANV, join), labels with catalog numbers, formats with descriptions,
      country, release date, genres, styles, barcodes, and the credits the mapping can use.
      Per track: position, title, duration, track artists and credits; headings and sub-tracks
      kept with their type so the matcher can fold them. Per artist: name and name variations.
      Per label: name. Folded keys (lowercased, accents and a leading "The" dropped, `&` as "and",
      `Artist (2)` suffixes and edition words in brackets removed, punctuation and spaces
      removed; the folding the 2026-11-06 coverage count used) indexed for
      artist plus title, barcode, and label plus catalog number.
- [x] **51.6 Tests.** Small fixtures in the dump's format: a release with every optional element
      missing, sub-tracks and headings, vinyl and `CD2-4` positions, a truncated file, a bad
      checksum, a stopped import leaving the old catalog in use.

Implementation plan, part 51b (ADR 0130):

1. **Settings (51.4).** `discogs.dumpsFolder`, a `DumpsFolder` (a path, or a share and the path
   inside it, checked as `SyncFolder` is, through `folderLocationProblem`), null by default;
   `discogs.catalogPath`, an absolute path or null for `AppPaths.discogsCatalogFile`
   (`discogs.sqlite` in the data directory). `AppSettings.conflicts` refuses a catalog path
   inside a watched folder stored by path, as it refuses the sync folder. The Settings window
   hides both, as it hides Network Scan Readers: 51d's window picks the folder. Tests in
   SettingsTests and the hidden-rows test in SettingsWindowTests.
2. **Discogs module.** `Sources/Core/Discogs`, importing Library (for `MountedShare` and the
   share lookup `locate(_:among:)` already finds the sync folder with), Log, Settings and
   SQLite, linking the system zlib, with CryptoKit for SHA-256. In order, each with its tests:
   - `CatalogKey`: the fold (the coverage count's rules, from music-recommender's
     `fold.py`, with the title-only edition words) and the keys built from it: artist credit
     keys (each name, all joined, all joined with "and"), title, barcode, label and catalog
     number. Public, so 51c folds the library's side with the same code.
   - `DumpSet`: the newest date in the folder whose four `discogs_<date>_<kind>.xml.gz`
     files and `discogs_<date>_CHECKSUM.txt` are there and the checksum file lists all four;
     its SHA-256 per file and total compressed size. `locateDumps(_:among:)` finds the
     setting's folder on its share.
   - `GzipStream`: a file descriptor read 1 MB at a time and inflated with zlib, hashing
     the compressed bytes and counting them for progress. A file that ends before its gzip
     trailer, or bad data, fails the read with the file's name; the hash is compared with the
     checksum file when the stream ends. `DumpBatches` cuts the inflated bytes into batches of
     whole records, each parsed by its own `XMLParser` in an autorelease pool (added after
     the first real import held 1.8 GB in `XMLParser`'s autoreleased strings).
   - `DumpParser`: an `XMLParserDelegate` per dump kind, building one record per element
     (`CatalogRelease` with its tracks, headings and index tracks with their sub-tracks,
     artists, credits, labels, formats, barcodes from the identifiers; `CatalogMaster`,
     `CatalogArtist`, `CatalogLabel`), everything optional but the id, checking
     `Task.isCancelled` every few hundred records.
   - `CatalogSchema` and `CatalogWriter`: one row per release, master, artist and label,
     the lists in the row as JSON, and key tables (`title_keys` for masters and releases
     without a master, `barcode_keys`, `catno_keys`). Written with `journal_mode = MEMORY`,
     `synchronous = OFF` and a large page cache, 2,000 records a transaction, the indexes
     built after the last row.
   - `CatalogImport`: `importCatalog(from:to:outsideOf:progress:)` checks the catalog path
     against the located watched folders, picks the dump set, imports labels, artists,
     masters, releases into `<catalog>.importing`, and renames it over the catalog only when
     every file's hash matched and the indexes are built. A failure or a stop removes the new
     file and throws; the old catalog is untouched. `Progress`: the stage, compressed bytes
     read of the set's total, records so far, a line of text.
   - `Catalog`: the read API, opened read-only: a release or master by id, release ids by
     barcode and by label plus catalog number, and title matches (masters and master-less
     releases) by artist and title.
3. **Fixtures and tests (51.6).** `DiscogsDumpFixture` in `Tools/Fixtures`: writes gzipped
   dump files and their checksum file from XML text, and a synthetic dump of N releases for
   the bench. `Tests/DiscogsTests`: every optional element missing, sub-tracks and headings,
   vinyl and `CD2-4` positions, the keys and lookups, a truncated gzip, a bad checksum, an
   incomplete set skipped for an older complete one, a stopped import and a failed one each
   leaving the old catalog in use.
4. **Bench.** `DiscogsBenchmarks`: importing a 20,000-release fixture dump, and its catalog's
   size, with rows in the budget table; 51.13 adds the real dump's numbers.
5. **Tool.** `Sources/Tools/DiscogsImport`, an executable that imports a folder into a catalog
   path (Application Support's by default) and logs progress lines, for the real import of
   the 2026-11-01 dump on this Mac, run in the background with its log under `.build/`.
6. **ADR 0130**: streaming, the schema and why the lists are JSON, the folding, the hash
   checked as the file streams rather than in a pass before it, the atomic swap, the settings
   keys.

#### 51c. Matching

- [x] **51.7 Candidates.** For each album, in order: its release id (refresh); barcode; label
      plus catalog number; folded album artist plus title against masters and against releases
      without a master. Titles are also tried with a leading `[catalog number]` or trailing edition
      words removed (music-recommender's prototype found 390 library titles with the first).
- [x] **51.8 Scoring.** Each candidate scored on track count, the tracklist (folded titles
      compared in order, Discogs positions and headings folded), durations within a tolerance
      where Discogs has them, then the tie-break the owner decided. The result is the file to
      track mapping and a tier:
      - **Exact:** same track count, every title matches in order, durations agree where
        present, and one release wins the tie-break.
      - **Likely:** same track count and the tracklist matches above a threshold, or exact but
        still tied after the tie-break.
      - **Incomplete:** a different track count, a weak tracklist match, or a partial id.
      - **No candidate**, and **Matched** (already has a release id; refresh offered).
      Thresholds are named constants, tuned on the owner's matched albums: run on them with
      their ids hidden, at least 95% of those counted should come back Exact or Likely with
      the same release or a twin of it, and at most 2% Exact with a release that is neither
      (decided by the owner on 2026-11-07). A twin is equal to the tagged release in every
      tag the matcher compares (tracklist, catalog number, barcode, date, `MEDIA`, country)
      and stays Exact. Not counted: albums whose tagged release isn't in the dump or doesn't
      fit the files (another track count, titles changed since the tagging), and albums left
      Incomplete because the owner kept another track count. Albums whose tagged release
      Discogs has changed since (its date or format) are counted, and reported as known
      misses.
- [x] **51.9 Tests.** Albums from fixtures against a fixture catalog for each tier, the tie-break
      order, bonus and hidden tracks, multi-disc sets, vinyl positions, sub-tracks, and
      `Artist (2)` and ANV names.

Implementation plan, part 51c (ADR 0131):

1. **The album side.** `DiscogsAlbum` in `Library`: the album's title and artist (album artist,
   else artist), label, catalog number and barcode, and its tracks (file id, title, seconds,
   disc and track numbers, release id) in disc and track order. `LibraryIndex.discogsAlbums()`
   reads them from the index alone: the `tracks` table already has `publisher`,
   `catalog_number` and `barcode`, the standard fields each reader maps YATE's `LABEL`,
   `CATALOGNUMBER` and `BARCODE` to in every format, beside 51a's two ids, so no file reads
   over the NAS. (As built: the date and `MEDIA` too, `MEDIA` in a new column, for the
   tie-break the tuning found.) Tests in `LibraryTests`.
2. **Catalog.** `releaseIDs(master:)`, over the `releases_by_master` index. Test in
   `CatalogLookupTests`.
3. **Candidates (51.7).** `AlbumCandidates`: the album's release ids, then the barcode's
   releases, then label plus catalog number (the whole `LABEL`, then each label of a
   " & " list), then title matches for the artist and title, each master expanded to its
   releases. Titles are also tried without a leading `[…]` and without trailing edition words
   after " - "; artists also as the first of a "feat."/"&"/","/"vs." list, and Various
   Artists as Discogs's "Various". Each release once, in the order found.
4. **Scoring and tiers (51.8).** `ReleaseTracklist`: a release's playable tracks, headings
   dropped (kept as tracks when no row has a position), index tracks as their sub-tracks or as
   one track, whichever the album's count fits. `ReleaseScore`: titles folded with
   `CatalogKey`, a similarity per pair, an in-order alignment that maps files to tracks when
   the counts differ, durations within a tolerance. `TieBreak`: barcode or catalog number in
   the tags, then File or CD over other formats, then the master's main release. `AlbumMatch`:
   the tier, the chosen release, the other candidates scored, and the file to track mapping.
   `MatchThreshold` holds every threshold once.
5. **The API.** `matchAlbums(_:catalogAt:progress:)`, async: a detached task opens its own
   `Catalog` (so a call after an import reads the new file), checks cancellation before each
   album, and reports albums done of the total. Public only where the tuning tool calls it.
6. **Tests (51.9).** `Tests/DiscogsTests`: fixture dumps imported into a catalog, albums built
   by hand, one test per tier, the tie-break order, bonus and hidden tracks, multi-disc sets,
   vinyl positions, sub-tracks, `Artist (2)` and ANV names, cancellation and progress.
7. **Tuning (51.8).** `SurveyRecord` gains title, numbers, seconds and barcode, so the survey's
   `files.jsonl` is the read-once cache of the watched folders. `TagCorpus --discogs-tuning
   [--catalog <path>]` groups it into the survey's albums, keeps those with one release id on
   every track, hides the ids, matches them, and writes `.build/discogs-tuning/report.txt`:
   tiers, same-release rate, wrong Exacts with examples, time per album and in all.
8. **ADR 0131**: candidates, scoring, tiers, thresholds and their tuning, the inputs from the
   index.

#### 51d. The mapping and the window

- [x] **51.10 Field mapping.** A list of Discogs fields, release-level and track-level, as
      YATE's Release screen shows them. Each has a target tag (a standard field or a custom
      key), a mode (replace, fill empty only, or off) and, where it needs one, a format:
      the join between values, ANV or canonical artist names, `(2)` suffixes kept or dropped,
      full date or year, and a template that builds a tag from several Discogs fields (the
      owner's `GENRE` is `{genre} - {styles}`). The default is one to one: genres to `GENRE`,
      styles to `STYLE`, label to `LABEL`, and so on, each Discogs field to its own tag. Any
      field can be sent to another tag or to several (styles to `MOOD` too, label to
      `GROUPING`). Saved in the settings (ADR 0003), set once and used for every album. Presets:
      "One to one" (the default), "Minimal" (release id, label, catalog number, year) and the
      user's own, saved by name; the owner's layout from 51.1 is saved as "Like my library".
- [x] **51.11 The window.** Toolbar: source (Local catalog; API and Both are shown disabled
      until 52), scope (whole library, the albums selected in the library window, or only
      unmatched albums), Analyze, Field Mapping…. A tab per tier with its count; each tab is an
      album list. The selected album shows the chosen release (artist, title, label, catalog
      number, country, year, format) and, side by side, the album's tracks against the release's
      with each row marked matched, different or missing. "Other Releases…" lists the
      candidates with filters by artist, title, country, label and format (YATE's release
      list), and choosing one rescores the album. For Likely and Incomplete albums, the rows
      can be dragged to change which file gets which track (YATE's mapping screen). Analysis
      runs off the main thread with progress and can be stopped.
- [x] **51.12 Review and apply.** Each album has a "View Changes" sheet: per file and field, the
      current value against the value the mapping writes, with a checkbox each (YATE's import
      screen). "Apply to All in Exact" (and in Likely) opens one confirmation sheet with the
      counts of albums, files and fields changed, then writes through `TagWriter` as a batch with
      the existing progress and undo. Rejected albums and chosen releases are remembered in the
      index, so a second session doesn't redo the review. Nothing is written before the user
      confirms, and an ADR records that one confirmation for a reviewed match set is the
      confirmation AGENTS.md's music files boundary asks for.
- [x] **51.13 Budgets.** Rows for the import's time and the catalog's size, Analyze over the
      whole library, one album's candidates, and opening the window, measured on fixtures and
      on the real catalog on this Mac. On a Mac without a catalog (the 2015 MacBook Pro) the
      window says so and offers the import; nothing falls back silently.
- [ ] **Owner check:** import the 2026-11-01 dump, analyze the whole library, review the Exact
      tab, apply it, and check a few albums' tags in YATE.

#### 51e. An import that resumes

Asked for by the owner on 2026-11-07, after the first real import trapped at 76% of the
releases (a duration too long for an `Int`, fixed in `72960469`) and had to start over.

- [x] **51.14 Checkpoints.** A table in `<catalog>.importing` holds the dump date, the files
      finished, and for the current file the last record committed, its compressed and bit
      offsets, the last 32 KB inflated (zlib's `zran.c` access point) and the SHA-256 state
      (CommonCrypto's `CC_SHA256_CTX`, since CryptoKit's can't be saved). Written in the same
      transaction as its batch, every few minutes of input, so a checkpoint always matches the
      rows.
- [x] **51.15 Resume.** An import that finds a `.importing` file of the same dump date carries
      on from its checkpoint: it seeks to the offset, restores the inflate state with
      `inflatePrime` and `inflateSetDictionary` and the hash, and goes on; one of another date,
      or without a checkpoint, is removed and the import starts over. The window shows
      "Resume Import" and "Start Over" after a stop, a quit or a crash. The hash still covers
      every byte, and the swap is unchanged.
- [x] **51.16 Fuzzing the dump parser.** A `DumpParser` target in `Tools/Fuzz`, so a record that
      traps is found on fixtures, not 20 minutes into a real import: Swift can't catch a trap.
- [x] **51.18 Name variations.** `title_keys` also holds each release's and master's artist
      ANVs, so an album tagged with one is found by title, not only by its barcode or catalog
      number (found in 51c's tuning; the owner chose 51e on 2026-11-07, as it reimports anyway).
- [x] **51.17 Tests.** A stop and a crash (a killed child process) at each stage, resumed to a
      catalog identical to an import run straight through; a checkpoint from another dump date;
      a damaged checkpoint; the bench's fixture import stopped halfway and resumed.

#### 51f. Mood and styles in the library

Asked for by the owner on 2026-11-07: YATE puts a release's Discogs styles in `MOOD`
("Dub Techno, House, Techno"), which the tag reader and Get Info already handle, but the index
doesn't store it, so it has no column and no smart playlist field. And "Genre contains Techno"
also matches "Dub Techno", so no rule can pick out one style. Changing the tracks part rescans
the library once on first launch (pre-release: one shape, no migrations), so 51f ships in the build
that also needs the new catalog; the owner asked for 51f before the real catalog is rebuilt. The
mapping choices (51.22–51.24) were decided by the owner the same day.

- [x] **51.19 Mood in the index.** `MOOD` stored with the other tags, a Mood column in the
      track table (sortable, in the header's menu) and a Mood smart playlist field, its title
      defined once with the tag editor's.
- [x] **51.20 Whole values in a list.** Text rules on Genre, Mood, Grouping and Publisher gain
      "has" and "doesn't have": the value split on ", " and on " - " (Genre's
      `{genre} - {styles}`), each part folded as the column's sort is, and compared whole, so
      "Mood has Techno" matches "Dub Techno, Techno" and not "Dub Techno". Done in SQL, on
      the indexed column, within the smart playlist budgets. ADR 0135 records the split.
- [x] **51.21 Tests.** Mood read from FLAC, MP4 and ID3 fixtures into the index; the column
      sorts; "has" against values at the start, middle and end, a genre with a comma of its
      own (`Folk, World, & Country`), and a value that only contains the word; the smart
      playlist bench row with a "has" rule.
- [x] **51.22 Presets and the owner's mapping.** "Like my library" leaves the shipped presets;
      a generic "YATE" preset (YATE's keys and per-format spellings, plain genres) joins "One
      to one" and "Minimal". Every preset sends the styles to `MOOD` only. The owner's
      `config.json` gets a saved mapping, "Mine": One to one with titles, artists, track and
      disc numbers and totals, composer, conductor, lyricist, remixer and the date set to fill
      only empty tags. The YATE layout moves to a test fixture, which keeps the write-back
      tests. ADRs 0128 and 0132 updated.
- [x] **51.23 Choices in the tagger window.** Next to Field Mapping…, without opening the sheet:
      "Keep existing values" (on: the fields 51.22 lists fill only empty tags, whatever the
      mapping says; off: the mapping's own modes), "Skip Blu-ray, DVD and video" (on by
      default: those releases are never candidates, as YATE's `DiscogsIgnoredMedia`), and
      "Fill sort artist from album artist" (`ARTISTSORT` from the album artist, only when
      empty, as the owner's YATE after-import action). Each a setting (ADR 0003), so it
      persists; changing one rescores or recomputes the open album's changes.
- [x] **51.24 Undo Tag Edit in the Edit menu**, with ⌥⌘Z, out of File.
- [ ] **Owner check:** a smart playlist of one style on the real library, and the Mood column
      on albums tagged by YATE.

#### 51g. The tagger's and the tag editor's rough edges

From the owner's testing on 2026-11-07, before 51 closes.

- [x] **51.25 Template help.** A help button (?) beside Field Mapping's template field opens a
      popover: every token a template can name (from the list `DiscogsMapping` checks
      against, not a copy), that text outside braces is kept as written, how a list field
      joins inside a template, and two examples (`{genre} - {styles}`, the owner's `GENRE`).
- [x] **51.26 Save As says it saved.** After Save As… the new name is chosen in the saved
      mappings menu and the sheet says "Saved as “Name”"; a name already in use asks before it
      replaces that mapping.
- [x] **51.27 Import and export a mapping.** Export… writes the shown mapping as JSON in the
      shape `config.json` keeps it (one encoder); Import… reads a file, and Paste reads JSON from
      the clipboard. Either is checked as the config's mapping is, and a bad one is refused with
      the reason, never half applied. An imported mapping is shown unsaved, for Save As….
- [x] **51.28 Tooltips and the catalog's state.** Tooltips on Import Discogs Dump… and Field
      Mapping… say what each does. With a catalog in place the window says so: the dump date it
      was built from, when it was imported, its size, and its path with a Reveal in Finder
      button; the import button then reads Reimport Discogs Dump….
- [x] **51.29 Tag commands in the tag editor.** While the tag editor is open it shows Undo Tag
      Edit, Replace Artwork… and Remove Artwork as buttons, which run the same commands as the
      menu items and are enabled by the same rules.
- [x] **51.30 Dismissing a config warning.** A problem that doesn't block the config (an
      unknown key such as `discogs.token`, which no build knows until 52.1) gets a close
      button. A dismissed problem stays hidden until the config file changes. A problem that
      blocks the config has no close button.
- [x] **51.31 Tests.** The help lists every token; Save As over an existing name; a mapping
      exported, imported and pasted back is equal to the one exported; a bad import changes nothing;
      the catalog status from a fixture catalog; the editor's buttons follow the commands'
      enabled rules; a dismissed warning returns when the file changes, and a blocking one can't
      be dismissed.
- [ ] **Owner check:** the help, Save As, an export opened in a text editor and imported back,
      the catalog status after the real reimport, and the editor's buttons.

#### 51h. The tagger, second pass

From the owner's testing on 2026-11-08, after 51g ran on the real library.

- [x] **51.32 Asking before a rescan** (moved from 53.9: the first launch after 51f rescanned
      the whole library with no word, which looks like a corrupted library). When a new build
      would drop an index part that a rescan refills, before dropping anything a dialog says
      which part changed and why, in words kept once with the part, that every file is read
      again, and that plays, ratings and playlists stay. It offers Rescan Now or Quit. Quit
      leaves the index as it was and asks again at the next launch. While the rescan runs, the
      status bar says it's a rebuild, not a first scan. An ADR.
- [x] **51.33 A plainer header.** The catalog's state is one short line, "Catalog from the
      2026-11-01 dump · 3.1 GB", with its path and import date in the tooltip and Reveal in
      Finder beside it. The rest of the header's controls on one row; nothing wraps at the
      window's minimum width.
- [x] **51.34 Opening on the selection.** With tracks selected in the library, Discogs Tagger
      opens scoped to their albums and, with a catalog in place, analyzes them at once.
      Without a selection it opens as now.
- [x] **51.35 Why not Exact.** A Likely or Incomplete album says why, under its release title
      and in its row's tooltip: "2 files have no track on the release", "3 durations differ by
      over 5 s", "found by title only". Worded from what the matcher already kept for its tier,
      not scored a second time.
- [x] **51.36 The window's height.** The track tables take all the height the header and the
      buttons leave, and scroll. Right on the first open, after an import, after reopening,
      and after a resize: the owner saw it too short once and right the next time, so a test
      checks the tables' frames in each case.
- [x] **51.37 Viewing a release.** The Other Releases sheet sorts by any column's header and
      gains a Tracks column, the release's track count from the catalog. View Release… beside
      Use Release shows the release before it's used: tracklist (position, title, duration),
      label, catalog number, format, country and year, as YATE's release view. View Changes
      and the release area get Open on Discogs, the URL from `ReleaseFields`'s one builder.
- [x] **51.38 Sheets keep their size.** Each tagger sheet (Other Releases, View Release, View
      Changes, Field Mapping) keeps its last size, column widths and sort, per kind of sheet,
      in `state.json` (`AppState`): this Mac's, not the config.
- [x] **51.39 Undoing a tagger write.** Undo Tag Edit after the tagger wrote 22 MP3s on the NAS
      failed for all of them: "can't copy its extended attributes: Permission denied", from
      `fcopyfile(COPYFILE_ACL | COPYFILE_XATTR)` in `FileReplace.copyAttributes`. Find which
      attribute or ACL the SMB server refuses when the tagger's own write of the same files
      went through, and fix the replace so an undo of any write the app made can run. As
      Undo Tag Edit undoes the newest edit anywhere, it first asks when that edit wasn't
      made in the window it's pressed in: "Undo the Discogs tagger's edit of 22 files?".
- [x] **51.40 Tests.** The rescan dialog's Quit leaves the index untouched; the header at the
      minimum width; scoping to a selection; each reason over crafted matches; the tables'
      frames in each case of 51.36; sorting, the Tracks column and View Release; a sheet's
      frame, widths and sort back after reopening; an undo through a replace whose attribute
      copy is refused, through `faults`, and the question for another window's edit.
- [ ] **Owner check:** the next build that changes the index, the tagger on a selection of
      Likely albums, a sheet resized and reopened, and Undo Tag Edit after a tagger write on
      the NAS.

Implementation plan, part 51h (ADR 0136):

One ADR, 0136, covers the part (52 and 53 number after it): the rescan dialog (51.32), the
attribute copy (51.39) and the undo question (51.39). If the owner wants the attribute copy
recorded apart, it takes 0137 and 52 and 53 shift by one.

1. **The rescan dialog (51.32), Library.** Searched `rg -i 'rescan|stale|rebuildStaleParts'`:
   the only place that drops an index part is `LibraryIndex.rebuildStaleParts()`
   (`Sources/Core/Library/LibraryIndex.swift`), run from `prepareSchema()` inside the init, and
   the parts are `SchemaPart` in `LibrarySchema.swift`.
   - `SchemaPart.rescanWhy: String?`, the words kept once with the part. Set for the parts a
     rescan refills (`.index`, today), nil for every other part (`.scans` rebuilds with the
     index and adds no line; stats-like parts, `.measures` and `.analysisRun` are not refilled
     by a rescan). The text is per part, not per build: the stored SQL is the only identity, so
     the build can't say more than "this part's tables changed". 53.13 adds its albums part
     with its own `rescanWhy` and nothing else in the dialog changes.
   - `RescanNotice` (new file `RescanNotice.swift` in `Library`): `parts: [SchemaPart]` and
     `text`, built only from the parts' `rescanWhy`, plus the fixed sentences "Every file is
     read again. Plays, ratings and playlists stay." Takes any list of parts, so 53.13 reuses
     it as is.
   - `rebuildStaleParts()` is split: `partsToRebuild(stored:)` (read only, the `stale` and
     `rebuilt` computation it already does) and the drop and create. `prepareSchema()` calls
     the first, and when the result has a part with a `rescanWhy` that is already stored
     (`stored[part] != nil`, so a new library never asks) and no stats part (a stats rebuild
     keeps its existing discard notice, ADR 0022, since "plays stay" would be false), it asks
     before the transaction opens. Nothing is dropped before the answer.
   - `LibraryIndex.init(at:movingAsideIfUnreadable:confirmRescan:)`, with
     `confirmRescan: ((RescanNotice) -> Bool)? = nil`. Nil means no question, as today: the
     `music-player scan` command, `LibraryReader`'s connections and every existing test keep
     their behavior. A false answer throws `LibraryError.rescanDeclined`
     (`LibraryError.swift`) before the first statement that changes the file, so the index is
     as it was and the next launch asks again.
   - The index records that it rebuilt (`rebuiltParts`, like `movedAside`), for the status bar.
   - Decision: the rebuild flag is in memory. A quit mid-rescan reads "Scanning" at the next
     launch; a persisted flag would be a part of its own for one status word.
2. **The dialog and the quit, LibraryBrowser and App.** `RescanAlert.swift` in
   `Features/LibraryBrowser` (neighbor: the other small alerts there; the text is the
   notice's, so the file holds no wording): an `NSAlert` with `Rescan Now` and `Quit`, run
   modally because it comes before the window exists. `AppDelegate.openWindow` passes it as
   `confirmRescan` on the one open that already passes `movingAsideIfUnreadable: true`;
   it catches `LibraryError.rescanDeclined` and terminates without the error alert
   (`NSApp.terminate`), where the other errors from that open are reported.
3. **The status bar (51.32).** `LibraryStatus.scanText` (`Features/LibraryBrowser`) says
   "Rebuilding the index: Music: 300 of 1,200 read" in place of "Scanning" while the index
   rebuilt this launch and that folder's first whole scan hasn't ended. `LibraryBrowser` gets
   the flag from the index it is given.
4. **A plainer header (51.33), DiscogsTagger.** `TaggerWindow.build` and `refresh()` (the
   `catalogBox`, `catalogLabel`, `revealButton`, `status.shown`). The label becomes
   "Catalog from the 2026-11-01 dump · 3.1 GB" from `CatalogStatus.dumpDate` and `sizeBytes`
   (size through the formatter the app already uses for sizes: `rg ByteCountFormatter`); the
   path and `importedAt` go in the tooltip, Reveal in Finder stays beside the label, and the
   remaining controls (Import, Mapping, Source, Scope, Analyze, the three choices) go in one
   `NSStackView` row. Compression resistance low on the label (tail truncation), so the row
   fits the window's `minSize` (760 pt) with nothing wrapping. Wording stays in
   `TaggerTitles.swift`.
5. **Opening on the selection (51.34).** `DiscogsTagger.show()` takes the library selection
   (`selectedTracks` is already wired): if it is non-empty, sets `model.scope = .selection`
   and, when the catalog is `.ready`, calls `model.analyze()` after `checkCatalog()` returns.
   The first `show()` runs the check in a `Task` today, so the analyze goes after it in that
   same task. An already open window reopened with a selection does the same; with no
   selection nothing changes. `analyze()` already reports an empty selection.
6. **Why not Exact (51.35), Discogs and DiscogsTagger.** The matcher keeps, for the chosen
   release, `ReleaseScore.mapping`, `durationsCompared`, `durationsAgreeing`, `sameCount`,
   `titlesInOrder`, and `tied` in `choose(...)`. It does not keep how the release was found.
   - `AlbumCandidates.swift`: `candidateIDs(for:in:)` returns each id with the way it was
     first found (`.taggedID`, `.barcode`, `.labelAndCatalogNumber`, `.title`). No second
     search.
   - `NotExactReason` (new, `Discogs`, next to `AlbumMatch.swift`): an enum with counts
     (`filesWithoutTrack(Int)`, `tracksWithoutFile(Int)`, `durationsDiffer(Int)`,
     `titlesDiffer(Int)`, `countDiffers(files:tracks:)`, `tiedAfterTieBreak`,
     `foundByTitleOnly`). `AlbumMatcher.match` fills `AlbumMatch.reasons` from the chosen
     score and the `tied` flag it already has, for tiers Likely and Incomplete only. It scores
     nothing again.
   - The words are in `TaggerTitles.swift`: "2 files have no track on the release",
     "3 durations differ by more than 8 s or 5%" (from `MatchThreshold.durationSeconds` and
     `durationFraction`, so the number isn't written twice; the owner's example said 5 s, the
     threshold is 8 s), "found by title only". Shown under the release title in the
     selected-album area and as the row's tooltip (`TaggerWindow.tableView(_:viewFor:row:)`).
7. **The window's height (51.36), DiscogsTagger.** Read `TaggerWindow.build` (the `split`
   and `detail` stacks, the `for view in detail.arrangedSubviews where view is NSScrollView`
   constraints). The tables must be the one view that takes the spare height: vertical
   content-hugging low and compression resistance low on the tables' scroll views, high on
   the header rows, and no fixed-height constraints on the scroll views. Because the owner saw
   it too short once and right the next time, the likely cause is the window laid out before
   the catalog row (`catalogBox`, hidden while `.checking`) and the resume row showed, with no
   layout pass after: call `window.contentView?.layoutSubtreeIfNeeded()` at the end of
   `refresh()` when a hidden row changes, and test it. If the test finds another cause, fix
   that one and record it in the commit.
8. **Viewing a release (51.37), DiscogsTagger and Discogs.**
   - Sorting: `ReleasesSheet` gets `NSSortDescriptor`s on its columns
     (`taggerTable(...)` builds them, in `TaggerChoices`' neighbor `TaggerTitles`/the table
     helper), `tableView(_:sortDescriptorsDidChange:)`, `shown` re-sorted after a filter.
     Numeric columns (score, tracks, year) compare as numbers.
   - A Tracks column: `ReleaseSummary.trackCount` (`ReleaseSummary.swift`), the playable
     count from `ReleaseTracklist` as the matcher counts it (not Discogs rows with headings),
     in `CatalogRelease.summary`; `TaggerColumn.tracks` and its title.
   - `ViewReleaseSheet.swift` (new, `DiscogsTagger`, a `TaggerSheet` like `ChangesSheet`;
     neighbor `ChangesSheet.swift`): opened by `View Release…` beside `Use Release`. It shows
     the release from the catalog: a header (label, catalog number, format, country, year) and
     a tracklist table (position, title, duration), with Open on Discogs. The data is a
     `ReleaseDetail` read through a new `Effects.release(id)` on the model, which wraps
     `Catalog.release(id:)` off the main thread the way `summaries` does.
   - Open on Discogs: `ReleaseFields.swift` has `private func discogsURL(_ kind:, _ id:)`.
     Make `releaseURL(_ id: Int) -> String` the one `package` builder there
     (`.releaseURL` case uses it), and the sheets and the View Changes sheet call it through
     `NSWorkspace.shared.open`. 53.10 and 53.11 use the same function.
9. **Sheets keep their size (51.38), Settings, App and DiscogsTagger.** `AppState`
   (`Sources/Core/Settings/AppState.swift`; neighbor `infoPlace`/`InfoWindowPlace`) gets
   `taggerSheets = Setting(... default: TaggerSheetLayouts())`, key `discogsTagger.sheets`,
   `kind: .windowState`. `TaggerSheetLayouts` (new in `Core/Settings`, as `InfoWindowPlace`
   is) is a `SettingValue` holding, by sheet kind (`otherReleases`, `viewRelease`,
   `viewChanges`, `fieldMapping`), the size, the column widths by `TaggerColumn` raw value,
   and the sort key and direction, with `rejectUnknownKeys`. `DiscogsTagger` takes it and a
   `layoutChosen` closure, as it takes `choicesChosen`; `AppDelegate` fills it from `state`
   and saves through `saver.set(\.taggerSheets, ...)`, as `infoPlace` is. The sheets apply it
   in `build` and report it in `endSheet()`. A size smaller than the sheet's minimum or
   larger than the screen is clamped, and a column name no longer in the sheet is ignored by
   the decoder's own rule: unknown values are discarded (pre-release, no versions). This
   Mac's state, not the config: `state.json`.
10. **Undoing a tagger write (51.39), TagWriter.**

    What the code says. Undo does not copy attributes from the saved undo copy: the
    journal in `tag-undo` keeps only the old bytes and a JSON record, no attributes.
    `TagWriter.restore` calls `writeTemp(segments, from: path, ...)` with `path` the live,
    edited file, and `copyAttributes(from: source, ...)` copies from a descriptor opened on
    that file. So the quarantine, provenance and local ACL on the undo copy are not the
    difference. The difference is that the forward write took a different path.
    `WriteFaults.writesInPlace` defaults to true, and a tag that fits the padding (22 MP3s
    from the same ripper commonly do) is written in place (ADR 0107): no temp file, no
    `fcopyfile`, the file's attributes never touched. Undo always goes through a temp file
    (`restore` -> `writeTemp` -> `copyAttributes`), so it is the first time `fcopyfile`
    runs on those files. The forward write "went through" because it never made the call.

    The most likely cause is then one attribute or ACL on those NAS files that macOS reads
    but the SMB server refuses to set on a new file: `fcopyfile(COPYFILE_ACL|COPYFILE_XATTR)`
    sets every xattr with `fsetxattr` and the ACL with `acl_set_fd`, and a single `EACCES` or
    `EPERM` fails the whole call with no name. Candidates, in the order I would check:
    (a) `com.apple.provenance`, which macOS 13+ refuses to set outside the kernel's own
    paths; (b) an ACL the server synthesizes from its own permission model, which macOS
    reads as an ACL and the server won't take back on a file it has just created;
    (c) `com.apple.quarantine`, `com.apple.metadata:_kMDItem*`. This can't be proved without
    the NAS, and no agent or test touches it (AGENTS.md), so the first step is an owner
    check, read only, on one of the 22 files:
    `xattr -l <file>` and `ls -le@ <file>`, then the same for a file the app never wrote.
    Whatever it shows picks the list in the fix below. Needs the owner (see Open).

    The fix, in three parts:
    - `copyAttributes` copies the ACL and each extended attribute separately instead of one
      `fcopyfile` call: `COPYFILE_ACL` through `fcopyfile`, then `flistxattr`, `fgetxattr`
      and `fsetxattr` per name (`XATTR_NOFOLLOW` is not needed on descriptors). A failure
      names what failed: "can't copy the extended attribute com.apple.provenance: Permission
      denied" or "can't copy its ACL". That alone fixes the message for every future
      refusal.
    - An attribute the destination refuses (`EACCES`, `EPERM`, `ENOTSUP`) and that is in
      `FileReplace`'s one list `unsettableAttributes` (names macOS itself manages, starting
      with `com.apple.provenance`, plus whatever the owner's output adds) is skipped and
      logged at notice level with the file and name. Any other refusal still fails the write,
      with the name. This keeps principle 5: only named attributes, only the ones the system
      says user code can't carry, and a Finder tag or a user's xattr is never dropped
      quietly. An ACL refusal on SMB is skipped only if the owner's output shows the ACL is
      the server's synthesized one; decided after the check.
    - The forward temp path uses the same function, so a rewrite past the padding on the NAS
      can't fail the same way.
    - Rejected: undoing an in-place write in place. It would avoid the temp file and the
      attributes, but it needs the in-place journal (marker, torn-write recovery, ADR 0107)
      run backwards; a larger change than this one.

    The fault: `WriteFaults.refusingAttribute: (@Sendable (_ name: String) -> Int32?)?`
    (`FileReplace.swift`, beside `beforeReplacing`), asked for each attribute name
    `copyAttributes` is about to set; a returned errno makes that `fsetxattr` fail as the
    server's would. Same for `"acl"`. No real SMB needed.

    Undo question. The journal doesn't record who wrote an edit. `TagUndoJournal` gets an
    `origin` file in the entry's folder (`TagEditOrigin`: `tagEditor` or `discogsTagger`),
    written with the entry; an entry without one is unknown and asks nothing (pre-release:
    no migration). `TagWriter.write(_:to:origin:)` takes it (default `tagEditor`), and
    `TagWriter.newestEdit() -> (origin, fileCount)?` reads the newest entry without
    changing anything. `TagEditing.write(_:over:)` (the Discogs path) passes
    `.discogsTagger`; `save` passes `.tagEditor`. `TagEditing.undo(over:)` takes the
    asking window's kind (`.tagEditor` for the main window and the Get Info windows,
    `.discogsTagger` for the tagger window; `TagCommands.swift` picks it from the key
    window, which today is always the main window's), asks `newestEdit()` on the writes
    queue, and when the origin differs shows `Confirmation.undoing(origin, count)`:
    "Undo the Discogs tagger's edit of 22 files?" with Undo Tag Edit and Cancel (the same
    `Confirmation` and `ask` as the write question). Cancel leaves the journal alone.
    Rule: ask when the origin is known and isn't the window's.
11. **Tests (51.40).** Swift Testing, in the neighbor of each.
    - `Tests/LibraryTests/RescanNoticeTests.swift`: a library built at an older shape
      (`DiscogsMatchTests` lines 96-116 do this with a changed SQL) opened with
      `confirmRescan` returning false throws `rescanDeclined` and the file is byte-identical
      (files table, plays and the identity table unchanged, `discards()` empty); true
      rebuilds as before and `rebuiltParts == [.index]`; a new library never asks; a nil
      closure never asks. The notice's text for a custom `[SchemaPart]` list (the 53.13 use)
      holds each part's `rescanWhy` once.
    - `Tests/LibraryBrowserTests`: `scanText` says "Rebuilding the index" in a rebuild and
      "Scanning" otherwise.
    - `Tests/DiscogsTests`: each `NotExactReason` over crafted matches (a file with no track,
      a different count, durations over the tolerance, a tie, found by title only), the
      `.taggedID` and `.barcode` ways of finding, `trackCount` in the summary, and that
      Exact and Matched albums carry no reasons.
    - `Tests/DiscogsTaggerTests/TaggerWindowTests.swift` (neighbor): the header at 760 pt
      (every control's frame inside the window, none below another); the opening scope with
      a selection, with none, and with no catalog (analyze doesn't start); the tables'
      frames in four cases (first open, after an import, after reopening, after a resize):
      each table's frame bottom is within a few points of the buttons' top and its height
      grows with the window; the reasons in the row's tooltip; sorting each column of Other
      Releases and the Tracks column; View Release's rows against a fixture release; a
      sheet's size, widths and sort back after closing and reopening, through a fake
      `layoutChosen`; the URL from `releaseURL` in both sheets.
    - `Tests/SettingsTests`: `TaggerSheetLayouts` round trips, rejects unknown keys, and a
      bad value is discarded.
    - `Tests/TagWriterTests/UndoJournalTests.swift` (neighbor): write a fixture MP3 in place
      (default `writesInPlace`), set a local xattr, then undo with `faults.refusingAttribute`
      refusing that name with `EACCES`: fails without the change (the old single
      `fcopyfile` can't skip), and after it (a) a name in `unsettableAttributes` is skipped,
      the undo succeeds, the bytes match the original and the other attributes are kept;
      (b) a name not in the list fails the undo with that name in the detail, the file
      untouched, and the journal still holds the edit; (c) the same refusals on a forward
      write past the padding. The existing `theFileKeepsItsAttributes` stays as it is.
    - `Tests/TagWriterTests`: `newestEdit()` returns the origin and count, an entry without
      an origin file reads as unknown.
    - `Tests/TagEditorTests`: the question for another window's edit (asked, with "22
      files"; Cancel leaves the edit undoable; Undo runs it), none for the same origin, none
      for an unknown one.
12. **Commit order**, each green on `./scripts/test --changed`:
    1. `feat(library)`: `SchemaPart.rescanWhy`, `RescanNotice`, `confirmRescan`, tests.
    2. `feat(librarybrowser)`: the alert, the quit, the status bar's "Rebuilding", the
       `AppDelegate` wiring.
    3. `fix(tagwriter)`: per-attribute copy, `unsettableAttributes`, `refusingAttribute`,
       tests (after the owner's output fixes the list).
    4. `feat(tageditor)`: the origin in the journal and the undo question.
    5. `feat(discogs)`: the not-Exact reasons and the ways of finding, tests.
    6. `refactor(discogs)`: `releaseURL` as the one builder (its own commit, per the
       promotion rule).
    7. `feat(discogstagger)`: the header (51.33), opening on the selection (51.34), the
       reasons' words (51.35), the height (51.36), with their tests.
    8. `feat(discogstagger)`: sorting, Tracks, View Release, Open on Discogs (51.37).
    9. `feat(settings)` and `feat(discogstagger)`: the sheets' saved layouts (51.38).
    10. `docs`: ADR 0136 (the dialog and when it is used, why the why is per part, the flag in
        memory, the attribute copy and its cause and list, undoing through a temp file, the
        origin in the journal; rejected: an in-place undo, a persisted rebuild flag, asking
        for stats rebuilds), `docs/map.md` untouched, plan boxes ticked, 53.13 pointing at
        `RescanNotice`.
13. **Gate.** `./scripts/check` once at the end: it reads all of this (`scripts/dupes.swift`
    for the wording and the URL, `scripts/surface.swift` for `package` on `releaseURL` and
    `RescanNotice`, `scripts/arch.swift` for `LibraryBrowser` importing only core).
    The owner check in the part's last item stays: the next index change, the tagger on a
    selection of Likely albums, a sheet resized and reopened, and Undo Tag Edit after a
    tagger write on the NAS.

Open for the owner:
- Output of `xattr -l` and `ls -le@` on one of the 22 files and on a file the app never wrote
  (read only), to settle which attribute the NAS refuses and so `unsettableAttributes`.
  Until then the fix names the attribute and skips only `com.apple.provenance`.
- One ADR (0136) for all of 51h, or a separate 0137 for the attribute copy.

Decided here, no input needed: the why is per part, not per build; the rebuild flag lives in
memory; stats rebuilds keep their discard notice and don't use the dialog; the not-Exact tolerance
text reads the threshold constants (8 s or 5%, not 5 s); the undo question compares origins and
asks only when the origin is known; an undo of an in-place write still goes through a temp file.

Result, part 51h: shipped 51.32 to 51.40 (ADR 0136), with these changes from the plan. The
header's controls measure about 1,600 points against the window's 760, so the catalog line,
Reveal in Finder and the import button share one row and the rest keep two rows, each on one
line at the minimum width. The frame test didn't reproduce 51.36's short tables on the old
layout; the likely causes are fixed anyway (the catalog row no longer hides during its check,
the resume row forces a layout pass, both stacks fill). 51.35 gains a reason for mixed release
ids, and the length tolerance comes from `MatchThreshold` (8 s or 5%), not the 5 s of the ask.
51.39: the forward write of those MP3s most likely went in place (ADR 0107), which never calls
`fcopyfile`, so the undo was the first attribute copy on those files. The copy now goes one
attribute at a time, names the one refused, and skips only `com.apple.provenance`; an ACL or
any other refusal still fails. Undo Tag Edit undoes exactly the edit it asked about, and
refuses if a newer one was written meanwhile.

Gate, part 51h: four Sonnet reviews (correctness, simplify, architecture, performance), 14
findings, 13 fixed in their own commits; the read of the sheets' layouts stays where the
tagger is made, as other windows' state is. A second review of the fixes found one low
regression, an error alert shown on a closed sheet, fixed. `./scripts/check` passes except
`theGlassHeadersAreFrosted`, which fails on main too in an agent session (every screen pixel
reads 0). `./scripts/bench`: 80 rows ran, no budget missed; the closest are metadata parse
(4.94 s of 5), changing the Stats period (217 ms of 250) and the slow NAS scan (7.88 s of 10).
Over 10% against the last recorded: seek while decoded, 6.6 to 10.3 ms (a median of 5 spread
1.5 to 14.8, no playback code changed) and Analyze Library on the NAS, 2.1 to 2.3 s (no
analysis code changed). The 11 window rows that quit the app (launch, scrolling, page down,
resize, row height) didn't run: the app hangs in `terminate:` after printing its measurement,
main's binary too, so they need a run on the owner's Mac. Cost: plan 131k tokens, 31 tool
calls, 4 min; implementation 920k tokens, 427 calls, 69 min; reviews 405k tokens, 88 calls,
63 min (the bench 55 of them).

Owner steps (51.39): `xattr -l` and `ls -le@` on one of the 22 MP3s and on a file the app
never wrote, pasted back, settle whether more than provenance or an ACL needs skipping.

### 52. Discogs API

- [x] **52.1 The token.** An optional Discogs personal access token, the player's first secret:
      an ADR, the AGENTS.md "no secrets" line rewritten for it, kept only in `config.json` at
      mode 0600, never copied elsewhere.
      Without a token the API is used unauthenticated, within its lower rate limit.
- [x] **52.2 The client.** Search and release requests, paced by the rate-limit headers, with a
      size cap, a timeout and typed errors, cached in the index by release id. ADR 0025 gains
      rows for the app's first outbound internet connection. Tests use recorded JSON, never the
      real API.
- [x] **52.3 Sources.** The window's API and Both: Both searches the catalog first and the API
      for albums with no candidate or releases newer than the dump. The matcher and the mapping
      are the same for both.
- [x] **52.4 Artwork.** The dumps have no images; with a token, the mapping's Artwork field
      fetches the release's primary image and writes it as the cover through `TagWriter`.
- [ ] **Owner check:** the same with the token, on this Mac and the 2015 MacBook Pro, which has
      no catalog.

Implementation plan, phase 52 (ADRs 0137, 0138, 0139, 0140):

Phase 51h (ADR 0136) runs first. 53's ADRs then start at 0141.

What I found (so the steps below name real things):

- `config.json` is `~/.config/music-player/config.json`, already mode 0600. It holds a
  `"discogs.token"` key now. No setting by that name exists, so until step 1 lands the config
  check reports it as `unknown setting "discogs.token"` (a non-blocking problem, rest applies).
  `ConfigFile.read` reports unknown keys by key name only, never the value.
- `ConfigStore.write` uses `Data.write(options: .atomic)`, which renames a temp file made with
  the default mode. Whether it keeps 0600 is not something to rely on; step 1 writes the temp
  file itself.
- The settings window lists every setting except `.windowState` and the keys in
  `GeneralModel.isShown`; the token must be added there or it would get a text field.
- The matcher is `AlbumMatcher` (Sources/Core/Discogs/AlbumMatcher.swift), built on one
  read-only `Catalog`. `candidateIDs(for:in:)` (AlbumCandidates.swift) is the only code that
  asks the catalog for ids; `match` then calls `catalog.release(id:)`. Everything after that
  works on `CatalogRelease` (ReleaseScore, TieBreak, ReleaseTracklist, ReleaseFields,
  `changeSet(for:match:mapping:)`), so an API release only has to become a `CatalogRelease`.
- `matchAlbums(_:catalogAt:choosing:skippingVideo:progress:)` is the async entry point;
  `TaggerModel.Source` already has `.catalog, .api, .both` with `isAvailable == (self ==
  .catalog)`, and `TaggerWindow` greys the others ("Comes with the Discogs API").
- `DiscogsMapping` requires a rule for every `DiscogsField`, and a bad value blocks the whole
  config (ADR 0082). So 52.4 must not add a `DiscogsField` case: it would invalidate the
  owner's saved mapping and block the file. Artwork gets its own setting.
- `TagEdit.art: ArtChange?` (`.replace(Data, mimeType:)`, JPEG or PNG) already exists, written
  by `TagWriter`. `AlbumChangeSet.edits(including:)` builds the `TagEdit`s Apply hands to
  `TaggerModel.write`. `thumbnail(of:maxPixelSize:)` (Core/Artwork) is the one image decode
  (ADR 0025 row 4). `TrackMetadata.art` says whether a file has a cover.
- `LocalHTTPClient` (Primitives/LocalNetwork) is deliberately local-subnet only (ADR 0039); it
  can't be reused for the internet. The app makes no other outbound connection today
  (`rg URLSession Sources` finds nothing).
- Cached data in the index is a `SchemaPart` (LibrarySchema.swift); `measures` is the pattern
  for a cache. Adding a part creates only its table and keeps the others (as `analysisRun`
  did), so it does not trigger 51h's rescan dialog.

Needed from 51h:

- 51.33's header (one row, catalog line): Source must stay a control in it, and its catalog
  line must tolerate "no catalog" with Source set to API (step 6 changes what "missing"
  blocks).
- 51.34 (open on the selection and analyze at once): analyze at once only for Source = Local
  catalog. The API source is never started without a click, since it makes network calls.
- 51.35 (why not Exact) words its reasons from what the matcher kept. Step 5 adds one kept
  fact, `AlbumMatch.origin`, so the reason can say "from the Discogs API".
- 51.37 (Other Releases / View Release read `releaseSummaries(catalogAt:)`): step 5 adds the
  cache as a second place those summaries come from. Land 51.37 first so there is one
  summary function to extend.
- 51.39 (undo through a replace): cover art goes through the same replace. Nothing else.
- 51.38 (sheet sizes): the Field Mapping sheet gets one more row (step 7); no conflict.

#### 52a. The token (52.1), ADR 0137

1. **Setting.** `DiscogsToken` in `Core/Settings` (`SettingValue`, a struct over the string,
   encoded as a plain JSON string). Its `description` and `debugDescription` print
   `<Discogs token>`, so no log line, error or assertion message can carry it; `problem()`
   refuses an empty or whitespace-only value and any character outside printable ASCII (a
   header value must not carry a line break). `SettingKind.secret` is new. `AppSettings`:
   `discogsToken = Setting<DiscogsToken?>("discogs.token", title: "Discogs Token", default:
   nil, "A personal access token from discogs.com/settings/developers, for the API.")`. Hidden
   in `GeneralModel.isShown` (and `row` has no control for `.secret`), so it is edited in the
   file only, as the dumps folder is (ADR 0130). `fileValue(\.discogsToken)` is the only read.
2. **Mode 0600.** `ConfigStore.write` goes through a new `writeConfigFile(_:to:)`: a temp file
   in the same folder created with `open(O_CREAT|O_EXCL, 0o600)`, written, `fsync`ed, renamed
   over the resolved path (symlinks still resolve as now). Every config write is 0600, token or
   not: one rule, no branch on content. On read, if the file's token is set and its mode has
   any group or other bit, the token is not used and a non-blocking `ConfigProblem` says
   "config.json is readable by other users; run chmod 600 on it to use the Discogs token"
   (the file is not changed by the app: ADR 0025 row 21 says it is never written over on a
   problem). The token is also not copied anywhere else: not into `state.json`, the index,
   the log, the sync folder or the cache; step 3 builds the one header from it.
3. **AGENTS.md.** The "no secrets" bullet is replaced by: "**One secret: the Discogs token**
   (optional), kept only in `config.json` at mode 0600 ([ADR 0137](decisions/0137-the-discogs-token.md)). Never log, print,
   copy or commit it, and never put it in a test or fixture; `DiscogsToken` redacts itself.
   Any other secret: stop and ask first." The Boundaries bullet on music files gains nothing;
   a line is added: "No test or tool calls the Discogs API: tests use recorded responses
   through a stand-in transport."
4. **Tests** (`Tests/SettingsTests`): the key reads as `DiscogsToken`; `String(describing:)`,
   `"\(token)"`, `String(reflecting:)` and a thrown decode error never contain the value
   (the test uses a made-up value); a value with a newline, a space-only value and a number
   are problems naming the key but not the value; the settings window model has no row for it;
   a config write leaves mode 0600 (`stat`), including over an existing 0644 file and through
   a symlink; a 0644 file with a token reports the problem and `fileValue` is nil; a write
   that fails midway leaves the old file and no temp file. Existing config tests must still
   pass with the new temp-file write (`aBrokenFileAppliesNothingAndIsNeverWritten`).
5. **ADR 0137**: why in `config.json` and not the Keychain (the owner decided on 2026-11-07;
   the Keychain would also need the ad-hoc-signed app to be allowed access on each of three
   Macs, and the file is already synced by hand), redaction by type, mode, the fail-closed
   read of a loose file, and what no longer holds in AGENTS.md. Adds ADR 0025 rows 58 and 59
   (below) and marks 0025 "Amended by".

#### 52b. The client (52.2), ADR 0138

1. **Transport primitive.** `Sources/Primitives/HTTPSClient` (new module, `Foundation` only;
   tier map in `scripts/arch.swift` and map.md's search recipes need no change, the
   `Sources/Primitives/*` path pattern already covers it). `HTTPSClient.get(_ url:, headers:,
   cap:, timeoutSeconds:)` returns status, a header dictionary and the body bytes, or throws a
   typed `HTTPSError`. It refuses a URL that is not `https`, has a user, a port other than 443
   or a host not in the client's `allowedHosts`; uses an ephemeral `URLSession` (no cache, no
   cookies, no credential store, no HTTP/2 push use) built from a `URLSessionConfiguration`
   the caller can replace; refuses every redirect (a `URLSessionTaskDelegate` returns nil), so
   a 3xx is just a status; reads `bytes(for:)` and stops past `cap`, throwing `.tooLarge`
   before buffering more (macOS 12 has `bytes(for:delegate:)`); fails on the timeout. Proxy
   settings are the system's, which an internet client should honor (unlike
   `LocalHTTPClient`, whose reason for bypassing them was the LAN). Tests use a `URLProtocol`
   stub on the replaced configuration: no sockets.
2. **API client.** In `Core/Discogs` (adds `HTTPSClient` to its dependencies):
   `DiscogsAPI`, an actor over an `HTTPSTransport` closure type (production: `HTTPSClient`;
   tests: fixtures). One constant for `https://api.discogs.com`, one for the user agent
   `MusicPlayer/<CFBundleShortVersionString>` (Discogs rejects clients without one), both
   defined once. The `Authorization: Discogs token=<token>` header is built in one function,
   only for `api.discogs.com`. Calls: `release(id:)` (`/releases/{id}`), `master(id:)`
   (`/masters/{id}`), `search(artist:title:)`, `search(barcode:)`, `search(catalogNumber:label:)`
   (`/database/search?type=release&…`, parameters percent-encoded by `URLComponents`, per_page
   25, first page only). Search needs a token: without one it throws `.tokenRequired` without
   a request (Discogs's database search is authenticated; `/releases` and `/masters` work
   without). Verify this in the Discogs API docs when starting; if it differs, only
   `tokenRequired` changes.
3. **Pacing.** `RateLimiter` (a small struct held by the actor, with an injected `now` and
   `sleep` so tests don't wait): requests go one at a time. Gap between starts is
   60 / limit seconds, with the limit from `X-Discogs-Ratelimit` (60 with a token, 25
   without; those are the starting values until a response says otherwise). When
   `X-Discogs-Ratelimit-Remaining` is 0 it waits for the window (60 s) before the next one. A
   429 waits `Retry-After` (else 60 s) and retries, at most twice; a third is
   `.rateLimited`. Waiting is cancellable, and reports its length through a progress callback
   so the window can say "Waiting 40 s for Discogs's rate limit".
4. **Typed errors.** `DiscogsAPIError`: `.tokenRequired`, `.unauthorized` (401, "the Discogs
   token was refused"), `.notFound` (404), `.rateLimited`, `.status(Int)`, `.offline`,
   `.timedOut`, `.tooLarge`, `.malformed(String)`, `.refusedAddress`. Each has one sentence of
   text, kept once; none holds the token, a header or a URL's query. A 404 for one release is
   "no such release" for that album; 401, offline and timed out stop the run and are reported
   once (fail loudly: no album silently becomes "No candidate" because the network was down).
5. **Decoding.** `ApiRelease` (`Decodable`, strict about types, lenient about extra keys,
   since Discogs adds fields) → `CatalogRelease`: `artists` (name, anv → `nameVariation`, join,
   id), `labels` (name, catno, id), `formats` (name, qty, text, descriptions), `country`,
   `released`, `genres`, `styles`, `identifiers` of type Barcode → `barcodes`, `extraartists`
   → `credits` (role, tracks), `tracklist` → `CatalogTrack` (type_ track, heading, index;
   `duration` through `CatalogTrack.seconds`; `sub_tracks`), `master_id`. Also kept beside it:
   `primaryImage: URL?` (the `images` entry of type `primary`, else the first; present only
   with a token). Limits as hostile input: body 4 MiB, tracklist 2,000 rows, sub-tracks 3 deep
   (the catalog's `CatalogTrack` allows one; deeper is dropped with a `.malformed`), every
   string capped at 2,000 characters, `id` must equal the requested id, `primaryImage` must be
   `https` on an allowed host (`i.discogs.com`). `isMainRelease` isn't in a release response:
   step 4 of 52c fills it from `/masters/{id}`'s `main_release`, only when two or more fetched
   candidates share a master.
6. **Cache.** New `SchemaPart.discogsCache` (comment: a cache; rebuilding discards nothing a
   fetch can't get again), table `discogs_cache (kind TEXT, id INTEGER, fetched_at REAL,
   json TEXT, PRIMARY KEY (kind, id)) WITHOUT ROWID`, kinds `release` and `master`.
   `LibraryIndex.discogsCached(kind:id:)` and `storeDiscogs(kind:id:json:)`, surfaced on
   `LibraryReader` like `discogsReviews`. The Library module stays ignorant of
   `CatalogRelease`: it stores the JSON text; `Discogs` encodes the converted release (the
   catalog's one-letter keys, plus `primaryImage`) so a hit needs no second conversion. An
   entry older than 30 days (`DiscogsAPI.cacheDays`, once) is fetched again; searches aren't
   cached (their answer changes; the tagger already remembers reviewed albums). The cache is
   passed to `DiscogsAPI` as two closures, so `Discogs` tests use a dictionary.
7. **Fixtures and tests.** `Tests/DiscogsTests/Fixtures/api/` (loaded like
   `Tests/ReceiverTests/Fixtures`): `release-simple.json`, `release-multi-disc.json`,
   `release-vinyl-sides.json` (headings, A1/B2 positions), `release-index-tracks.json`
   (sub-tracks), `release-anv-variations.json`, `release-no-images.json` (no token),
   `search-barcode.json`, `search-title.json`, `search-empty.json`, `master.json`, plus
   header sets (`X-Discogs-Ratelimit*`, `Retry-After`). Nothing here is a real recording of a
   call this plan made; they are written to the shapes in Discogs's API documentation, and the
   owner check has three `curl` lines to replace them with real ones (see Open questions).
   Tests (`DiscogsAPITests`): each fixture decodes to the `CatalogRelease` the same release
   would be in the catalog (compared field by field against a catalog built from the matching
   dump XML in `DumpFolder`, which proves the matcher sees no difference); the token goes only
   to `api.discogs.com`, only in the `Authorization` header, never in a URL; no token header
   without a token and search throws `.tokenRequired` with zero requests; the user agent is
   sent; spacing at 60 and 25 per minute with a fake clock; `Remaining: 0` waits; a 429 with
   `Retry-After` waits that long, retries, and a third gives `.rateLimited`; cancelling during
   a wait stops it; 401/404/500/offline/timed out map to their errors; a body past the cap, a
   redirect, an `http` or foreign-host image URL, a mismatched id, a 5,000-row tracklist and
   9-deep sub-tracks are each refused; no error's text contains the token or the query; a
   cache hit makes no request, a stale entry makes one and stores it; a damaged cache JSON is
   fetched again and replaced, not trusted.
8. **ADR 0138**: the transport and why not `LocalHTTPClient` or `NWConnection` (TLS, proxies,
   HTTP/2 via URLSession; ADR 0039's reasons for bypassing them are LAN-specific), the host
   allowlist, caps, no redirects, pacing from the headers, the errors, the cache and its age,
   what is hostile input. It adds ADR 0025 rows 60 to 63 (below) with their test names.

ADR 0025 rows added (each with its test in this phase; the table's "every phase that adds an
entry point adds its row" rule):

| # | Asset | Attacker | Entry point | Mitigation |
|---|---|---|---|---|
| 58 | the Discogs token | another user on the Mac; a backup or sync of `~/.config` | `config.json` | mode 0600 on every write; read fails closed on a looser mode; `DiscogsToken` redacts itself; never in logs, state, index, cache or errors |
| 59 | the Discogs token | a server that isn't Discogs; a log reader | the `Authorization` header | built in one place, sent only to `api.discogs.com` over https, never in a URL, error or log |
| 60 | the app's memory, time and connections | the network; a compromised response | the first outbound internet connection | https only, hosts `api.discogs.com` and `i.discogs.com`, port 443, no redirects, ephemeral session, 4 MiB cap on JSON and 10 MiB on an image, 20 s timeout, one request at a time, only on the user's action |
| 61 | the tagger's matches; the cache | the network; a compromised response | release JSON | strict types, id must match the request, row, depth and string limits, decoded into `CatalogRelease` and nothing else; a cache entry that doesn't decode is refetched |
| 62 | Discogs's account for the token | the app itself | request rate | pacing from `X-Discogs-Ratelimit*`, `Retry-After` on 429, a third 429 stops the run |
| 63 | the UI | the network | text from a response (titles, names) | shown as any tag text is (rows 7, 9, 39): escaped in the terminal, kept as text in the window |

#### 52c. Sources (52.3), ADR 0139

1. **Matcher without a catalog.** `AlbumMatcher.catalog` becomes `Catalog?`.
   `candidateIDs(for:in:)` is split: the tagged-ids step stays, the catalog steps run only
   when there is a catalog. `match(_:choosing:fetched:)` gains `fetched: [Int: CatalogRelease]`
   (releases the API returned for this album): their ids are appended to the candidate ids
   (order kept, each once), and the lookup is `fetched[id] ?? catalog?.release(id:)`. Scoring,
   `TieBreak`, tiers and thresholds are untouched, so the API and the catalog tier an album the
   same way. `AlbumMatch` gains `origin: Origin` (`.catalog`, `.api`) for the window (51.35's
   reason) and for Apply's count.
2. **Candidates from the API.** `ApiCandidates.releases(for album:, api:)`, in the order
   `candidateIDs` uses: the album's tagged release ids (fetched by id; this alone is the only
   thing that works without a token), then a barcode search, label plus catalog number
   (`labelNames`), then artist and title (`artistNames` x `[title] + CatalogKey.titleVariants`),
   reusing those functions and not copying their rules. Searches stop at the first that gives
   candidates for barcode and catalog number; the title search always runs when those found
   nothing. At most 8 releases are fetched per album (`ApiCandidates.maximumReleases`, once),
   best search rank first. Masters aren't expanded to all their releases (hundreds of
   requests); when two or more fetched releases share a `master_id`, `/masters/{id}` is
   fetched once and `isMainRelease` set from `main_release`.
3. **The API surface.** `matchAlbums` gains `source: MatchSource` (`.catalog`, `.api`, `.both`;
   the tagger's `Source` maps onto it) and `api: DiscogsAPI?`. Flow:
   - `.catalog`: as now.
   - `.api`: no catalog opened. Per album: `ApiCandidates`, then `match(fetched:)`.
   - `.both`: the catalog pass runs for every album first (fast, local). Then the API runs
     only for albums that are `noCandidate`, or `matched` with no release in the catalog (a
     tagged id newer than the dump), or whose chosen release (a saved review) isn't in the
     catalog. That is the owner's "releases newer than the dump", decided as "not found in
     the catalog", because the dump has no per-release date to compare. Those albums are
     matched again with the catalog's candidates and the fetched ones together.
   Progress gains `waitingSeconds: Int?` (the limiter's wait) and counts API albums as its own
   total in `.both` ("Catalog 412 of 412, then Discogs 3 of 17"). Cancelling stops between
   albums and during a wait. A review's chosen release not in the catalog is fetched by id.
4. **Releases for the Other Releases and View Release sheets.** `releaseSummaries(_:catalogAt:)`
   takes the API-found ids too, reading them from the cache (they were stored when fetched),
   so the sheets work for API releases with no new request.
5. **The window (TaggerModel/TaggerWindow).** `Source.isAvailable` becomes real: `.api` and
   `.both` are enabled always. With no token, the pop-up item's tooltip says "No Discogs token
   in config.json: only releases already tagged with an id are looked up". With no catalog,
   Source = Discogs API is allowed and 51.13's "no catalog" state blocks only `.catalog` and
   `.both` (which then runs as API alone and says so in the status line, since `.both`
   without a catalog is the 2015 MacBook Pro's case). The chosen source is `AppState`
   (this Mac's), default Local catalog when a catalog exists, else Discogs API. `DiscogsTagger`
   gets `api: () -> DiscogsAPI?` from the app (built from `fileValue(\.discogsToken)` and the
   reader's cache), so the feature module never reads settings (map.md rule). The app builds
   the real `HTTPSClient` transport in `DiscogsCommands.swift` only; tests pass a fake.
6. **Errors in the window.** A `DiscogsAPIError` that stops a run is one alert via the
   existing `failed(_:_:)` ("The Discogs token was refused", "No connection to Discogs"); the
   albums matched so far stay shown as the last run's, as a stopped Analyze already does.
7. **Tests.** `DiscogsTests`: `.api` on the fixture library matches the catalog's tiers for
   the same releases (same albums, same fixture releases served both ways: Exact, Likely,
   Incomplete, No candidate, each the same tier); `.both` calls the API only for the no-candidate
   and not-in-catalog albums (counted through the fake transport) and never for an Exact one;
   with no token only tagged-id albums are fetched and nothing searches; the 8-release cap; a
   shared master fetches the master once and the tie-break picks its main release; a chosen
   release outside the catalog is fetched; `.api` with no catalog file works and `.catalog`
   still says "missing"; cancellation during a rate-limit wait; progress and `waitingSeconds`.
   `DiscogsTaggerTests`: the pop-up items' enabled state in each of token/catalog presence, the
   source saved and restored, `.both` without a catalog reports it ran as API, the alert for
   401 and offline, 51.34's auto-analyze does not start for API.
8. **ADR 0139**: one matcher for both sources, what `.both` sends to the API and why "not in
   the catalog", the per-album request budget and cap, what works without a token, no master
   expansion.

#### 52d. Artwork (52.4), ADR 0140

1. **Setting.** `DiscogsArtworkMode` (`SettingChoice`: `off`, `fillEmpty`, `replace`) in
   `Core/Settings`, setting `discogs.artwork`, default `off`. Separate from `DiscogsMapping`
   (see "What I found"); presets don't carry it. Shown as a row in the Field Mapping sheet
   (`MappingSheet`), "Artwork", with the mode pop-up and a note "Needs a Discogs token", and
   disabled with that note when there is none. `TaggerChoices` carries it like
   `skipVideo`; `DiscogsCommands` saves it with `settings.set`.
2. **Fetching.** When the user starts Apply (before the confirmation, with the files
   being read in `plan(_:)`), for each album with an `.api`-origin or cached release whose
   `primaryImage` is set: `DiscogsAPI.image(at:)` fetches it (`i.discogs.com` only, 10 MiB cap,
   20 s, paced like other requests, one image per album, memoized per release for the plan).
   A catalog-origin release has no image in the catalog, so its album's release is fetched by
   id through the cache first (one request), which makes a catalog match with artwork on cost
   one API call per album, and that is said in the confirmation. Without a token no image is
   asked for and the mode shows "needs a token". Fetch problems are per-album entries in
   `plan.problems` ("no cover: …"), not a stop; tags still apply.
3. **Checking.** The bytes must start with the JPEG or PNG signature, pass
   `thumbnail(of:maxPixelSize:)` (so a huge declared image is refused by the one decode, row
   4) and be at most 64 MiB (`maximumArtBytes`), else a problem and no cover. `Discogs`
   gains the `Artwork` dependency for this. The type is read from the signature, not from the
   server's `Content-Type`.
4. **Writing.** `AlbumChangeSet` gains `cover: Cover?` (bytes, mime type, pixel size, URL) and
   each `FileChanges` a `coverState` (`.none`, `.adds`, `.replaces(existing pixel size)`),
   from `TrackMetadata.art` read with the files. `edits(including:)` sets
   `edit.art = .replace(data, mimeType:)` for a file when the mode allows (`fillEmpty` skips a
   file that has art) and the user left the cover ticked. Nothing else writes the image: it
   goes into `TagWriter` in the same batch and the same undo as the tags, and `TagWriter`'s
   art limits and 64 MiB check apply unchanged. One more tick-box row in View Changes:
   "Cover: 600 x 600 JPEG from Discogs (replaces 300 x 300)". The confirmation sheet counts
   covers beside tags, files and albums. All files of an album get the same image.
5. **Tests.** `DiscogsTests`: a JPEG and a PNG fixture (generated by the `Fixtures` module, not
   downloaded) become `.replace` edits that `TagWriter` writes into FLAC, MP3 and M4A clones
   of the generated fixtures and read back identical; `fillEmpty` leaves a file with art
   alone; a non-image, a truncated JPEG, a 400-megapixel PNG header, an image over the cap, a
   `Content-Type: image/jpeg` over PNG bytes (signature wins) and a foreign-host URL are each
   a per-album problem with the tags still applied; an unticked cover is not written; the
   whole-batch undo restores the original art and tags. `DiscogsTaggerTests`: the sheet's
   row disabled without a token; the confirmation counts covers.
6. **ADR 0140**: why a separate setting and not a mapping field, the extra request per
   catalog-matched album, what "fill empty" means for art, that the cover write is part of
   the one confirmation from ADR 0133 (it is a tag edit by `TagWriter`; the boundary in
   AGENTS.md needs no new exception), image checks. Adds ADR 0025 row 64: the downloaded
   image (same limits and decode as rows 3 and 4; written only after the confirmation).

#### Commit order

Each commit is one logical change with its tests, and `./scripts/test --changed` before it.

1. `feat(settings): add the Discogs token, hidden and redacted` (52a steps 1, 4 partly)
2. `fix(settings): write the config file at mode 0600` (52a step 2; its own commit because it
   changes every config write)
3. `docs: rewrite the no-secrets boundary for the Discogs token` (AGENTS.md, ADR 0137, ADR 0025
   rows 58, 59)
4. `feat(httpsclient): add a capped, https-only client` (52b step 1)
5. `feat(discogs): add the API client with pacing and typed errors` (52b steps 2, 3, 4, 5, 7)
6. `feat(library): cache Discogs API releases in the index` (52b step 6; a schema part, so
   this commit changes the index and is flagged for the owner's rebuild check), then
   `docs: record the Discogs API client` (ADR 0138, ADR 0025 rows 60 to 63)
7. `refactor(discogs): let the matcher run without a catalog` (52c step 1, no behavior change,
   existing tests pass untouched)
8. `feat(discogs): match albums against the API` (52c steps 2, 3, 4, 7)
9. `feat(discogstagger): enable the API and Both sources` (52c steps 5, 6, its tests), then
   `docs: record the API source in matching` (ADR 0139)
10. `feat(settings): add the Discogs artwork mode` (52d step 1)
11. `feat(discogs): fetch and write a release's primary image` (52d steps 2 to 5), then
    `docs: record Discogs cover art` (ADR 0140, ADR 0025 row 64)

Check run: `./scripts/check` once at the end. Steps that read this diff: build and tests, the
format check, `scripts/arch.swift` (a new primitive), `scripts/surface.swift` (public only
where another module calls it), `scripts/dupes.swift` (the API's base URL, user agent and
header names are single string constants), the ADR 0025 test-name check if one exists in
`scripts/check`, and `scripts/check-signature` (no new entitlements; outbound connections
need none under the hardened runtime without the sandbox). Info.plist needs nothing:
`NSAppTransportSecurity` defaults allow https.

#### Owner check

With the token, on this Mac and then the 2015 MacBook Pro (no catalog, Source = Discogs API):

1. Confirm no "unknown setting" banner and that `ls -l ~/.config/music-player/config.json` is
   `-rw-------` after changing any setting in the app.
2. Analyze a handful of Likely or No-candidate albums with Both; the status line shows the
   API count and any rate-limit wait; Stop works mid-wait.
3. Open Other Releases on an API-found album; Apply with Artwork on Replace for two albums;
   check the cover in Finder/YATE; Undo Tag Edit restores it.
4. Remove the token from the file: Source API says what still works.
5. Optional, to replace the hand-written fixtures with recordings (the agent never calls the
   API): `curl -sD headers.txt -H 'User-Agent: MusicPlayer/1' -H "Authorization: Discogs
   token=$TOKEN" https://api.discogs.com/releases/<id> -o release-<id>.json`, the same for a
   `/masters/<id>` and a `/database/search?type=release&barcode=<code>`; drop the files in
   `Tests/DiscogsTests/Fixtures/api/` after removing nothing but trailing whitespace (the
   responses contain no token).

#### Open questions (owner decisions, with my default)

1. **Search needs a token.** I believe `/database/search` rejects unauthenticated calls, so
   "unauthenticated within the lower limit" (52.1) only covers lookups by release id. Default:
   as written above (no token: tagged ids only, no search). If the docs say otherwise, only
   `tokenRequired` goes.
2. **Fixtures.** Hand-written to the documented shape unless the owner records real ones
   (curl lines above). Default: hand-written now.
3. **Image URLs may need the token.** If `i.discogs.com` refuses an unauthenticated GET,
   either the token is also sent to `i.discogs.com` (a second host for the secret) or covers
   can't be fetched. Default: token to `api.discogs.com` only; decide after the owner check
   shows what the images need.
4. **Cache age.** 30 days. Default kept.
5. **Both's rule** is "not found in the catalog", not "newer than the dump" (the dump has no
   per-release date to compare). Default kept.

Result, phase 52: shipped 52.1 to 52.4 (ADRs 0137 to 0140, ADR 0025 rows 58 to 64), with these
changes from the plan. A token in a config file others can read is withheld with a warning, not
offered as an obsolete setting, which would delete it. The window and the matcher share one
`DiscogsSource`, from Settings. The app makes its `DiscogsAPI` in `DiscogsCommands` and makes
it again only when the token changes, so pacing carries from one Analyze to the next; the
tagger reads no setting. Cover art is a setting of its own (off, fill empty, replace), not a
mapping field, so saved mappings still load. A cover must also end with its format's end
marker (up to 16 bytes of padding after a JPEG's) and be at most 8,000 pixels a side. Both, when
the API stops (offline, a refused token, rate limits), keeps the catalog's matches and says
which albums have only those. No test or tool called the real API; the fixtures are written to
the documented shapes.

Gate, phase 52: four Sonnet reviews (correctness and security, simplify, architecture,
performance). The security review found no way for the token to leak and no way around the
https, host and redirect rules. 11 findings fixed in their own commits: a passing cover
failure no longer cached for the session, a missing token said in the confirmation, a failed
secure connection named apart from offline, a Retry-After that isn't a number, pacing on the
uptime clock, a queued request that can be cancelled, a cover checked off the API's actor, the
wait reporter given back after a run, one rule for a tracklist row's kind, and the HTTPS
client's surface. A second review found nothing above low; one low, a cached release dated
ahead of the clock read as missing at any age, fixed. `./scripts/check` passes except
`theGlassHeadersAreFrosted`, the known agent-session failure. `./scripts/bench`, 69 rows
without the window rows: no budget missed, nothing over 10% this branch could cause; open
tagger window 28.7 ms, Discogs analyze 2000 0.34 s, tag write rows within 4% of 51h's. Cost:
plan 130k tokens, 29 tool calls, 5 min; implementation 1.12M tokens, 437 calls, 83 min;
reviews 368k tokens, 77 calls, 18 min.

Owner steps: with the token, Analyze with API and with Both on this Mac and on the 2015 MacBook
Pro (no catalog); a cover fetched with Cover Art on, which settles whether `i.discogs.com` needs
the token (ADR 0140; a refusal shows as "the Discogs token was refused"); and the first launch
of this build, which adds the API cache and should ask no rescan.

### 53. Library, browser and settings

From the owner's testing on 2026-11-07. ADRs numbered when it starts, after 52's.

- [x] **53.1 Show in All Music.** In any list but All Music, a command in the track menu and
      the View menu, ⌥⇧⌘A, switches to All Music with the selected tracks selected and
      centered, the keys in the track table.
- [x] **53.2 Drag files out.** Track table and timeline rows also carry the files' URLs, so a
      drag to the Desktop, a Finder window or another app hands it the files. Outside the app
      the drag offers copy only, so Finder never moves a library file (an ADR beside the music
      files boundary). Drags within the app are unchanged.
- [x] **53.3 Every picture in the art viewer.** When a file holds more than one picture, the
      art viewer steps through them, by arrow keys and buttons, showing "2 of 3" and the
      picture's type (front, back, other).
- [x] **53.4 A Config group.** General's config file rows move into a sunken group titled
      Config, as Library's are.
- [x] **53.5 The database in Library.** The Library group shows the index's path, its size
      (the database and its `-wal`), and a Reveal in Finder button.
- [x] **53.6 Snapshots.** Once a day, on the scan queue when it's idle (never during a scan or
      sync), `VACUUM INTO` a temporary file, compressed with gzip (the zlib already linked)
      to `library-YYYY-MM-DD.sqlite.gz`. It keeps the last 7 daily snapshots and one for each of
      the 4 weeks before them, and deletes older ones. The folder is a setting, defaulting to
      `Backups` beside the index in `~/Library/Application Support/MusicPlayer`. A folder inside a watched folder or the sync
      folder is refused (AGENTS.md). Only the library index is kept; the Discogs catalog is
      imported again instead. Settings shows the last snapshot's time, and a Back Up Now button.
      An ADR.
- [x] **53.7 Restore.** Settings lists the snapshots, with date and size. Restore… confirms,
      snapshots the current index first, and relaunches with the chosen one in its place.
- [x] **53.8 The Extras tab.** The tag editor gains an Extras tab: every key the reader found
      that has no field of its own (custom keys, `TXXX`, MP4 freeform), key and value, in one
      scrolling list, read only, selectable and copyable. With several files selected, a key
      that differs shows as mixed.
- [x] **53.9 Tests.** The command's enabled rule and what it selects; a drag's pasteboard
      holds the URLs and a copy-only mask outside the app; the viewer over a fixture with three
      pictures; snapshot naming, rotation over a simulated 60 days, a gzip that opens as the
      same database, and a refused folder; a restore round trip; Extras over FLAC, MP4 and ID3
      fixtures.
- [x] **53.10 Open on Discogs.** A command, Open Discogs Release, in the track menu, the
      palette and the View menu, with a shortcut free in the registry. It's enabled when the
      selected track has a Discogs release id, and opens its page in the browser, the URL
      from `ReleaseFields`'s one builder.
- [x] **53.11 A Discogs tab in Get Info**, shown when the files have a Discogs release id: the
      release as the local catalog has it (label and catalog number, country, date, format,
      genres, styles, credits, tracklist), read only and copyable, with Open on Discogs. A
      release the catalog doesn't have, or no catalog, says so. Files from several releases
      show the first and say how many.
- [x] **53.12 Shorter headers.** Track of Total's header reads "Track No.", and Disc of Total's
      "Disc No."; the header menu and the smart playlist fields keep the full titles. Both
      titles defined once, beside the others in `TrackColumnTitle`.
- [x] **53.13 Re-releases as albums of their own.** An album is its title and artist
      (`albums_identity`), so a 2025 remaster titled as the original merges with it, two
      track 1s interleaved. A setting, Separate Releases, adds the Discogs release id to an
      album's identity when its tracks have one, so the two are two albums, each sorted by its
      own year. Changing it rebuilds the albums part, with 51.32's dialog. An ADR.
- [x] **53.14 The palette keeps its query.** ⌘K opens with the last query, selected, so typing
      replaces it and Return runs the same command again; ⌘K while open clears it. As Sublime
      Text's.
- [x] **53.15 Tests.** 53.10's enabled rule and URL; the Discogs tab over a fixture catalog and
      a missing release; the two headers; Separate Releases on and off over an original and a
      remaster; the palette's query kept, replaced and cleared.
- [ ] **Owner check:** each in the running app, with a snapshot restored, a remaster beside its
      original, and the palette's kept query.

Implementation plan, phase 53 (ADRs 0141, 0142, 0143):

Depends on 51h and 52 being merged. 51h supplies 51.32's rescan dialog (53.13 adds a part to
it), 51.33 to 51.38's tagger windows (the Discogs tab in 53.11 reuses the View Release
formatting of 51.37) and `AppState`'s per-sheet frames (untouched here). 52 supplies the API
source; 53 reads the local catalog only. Where a type below comes from 51h (the dialog's
wording table), the plan names it by role, since it isn't in the tree yet; the first commit of
53c reads what 51h built and fits to it.

What exists, found by search (map.md recipes):

- Commands: `CommandID` and the `AppCommands` registry (`Sources/Core/Commands/AppCommands.swift`,
  `Command(.id, "Title", [chords])`), menus in `AppMenus.swift` (`trackMenu`, `sections`),
  handlers in `Sources/App/MusicPlayer/*Commands.swift` via `dispatcher.handle(id, enabled:)`
  (Show Album is in `PlaylistCommands.swift`). Shortcut clashes are checked against the
  registry by its tests; `⌥⇧⌘A` is free (only `⌥⇧⌘P` Reverse Sort uses that modifier set).
- Show in Playlist's body, `LibraryBrowser.showSelection(inPlaylist:)` in `LibraryBrowser.swift`,
  is the template for 53.1: `model.setSource(...)`, `showSource()`, `showRow(row)`.
- Drag: `Sources/Features/LibraryBrowser/TrackDrag.swift` (`trackDragItem`, `trackIDsType`,
  whose comment says "never file URLs"), written by `TrackTableController` and
  `TimelineController` `pasteboardWriterForRow`.
- Art viewer: `ArtViewer.swift`, opened by `TrackTableController.openArt`. `TrackMetadata.art`
  is one `EmbeddedArt` (FLAC `pictures.first { type == 3 } ?? first`, ID3 `APIC`, MP4 `covr`);
  there is no list of a file's pictures, so 53.3 needs a reader.
- Extras: `TrackTags.custom: [String: String]` already holds every key no field maps (ADR 0129,
  FLAC/Vorbis, ID3 `TXXX`/`WXXX`/`TIPL`, MP4 freeform). The editor tabs are `TagEditorTab`
  (`TagEditorTab.swift`) laid out by `TagEditorWindow.swift`; `TagEditorModel` holds the files.
- Settings: `AppSettings.swift` (`syncFolder`, `conflicts(_:)` checks the sync folder and
  catalog path against watched folders: the model for the snapshot folder), `SettingKind`,
  `AppPaths` (`dataDirectory`, `libraryFileURL(in:)` in App), `AppState`. Settings' General
  pane is `GeneralPane.swift` / `GeneralModel.swift` (`Section` enum with `.library` and
  titles; `configHeader` is the config file's box).
- Titles: `TrackColumn.title` in `Sources/Core/Library/TrackColumnTitle.swift`, used by the
  header (`TrackTableController` 165, 879), the header menu and `SmartFieldTitle`.
- Discogs URL: `ReleaseFields.swift` has only `private func discogsURL(kind, id)`, used for
  the artist URL keys. 51.37 makes it the one builder for releases; 53.10 uses that one.
- Release id: `tracks.discogs_release_id TEXT`, read by `DiscogsMatch` and `DiscogsAlbum`.
- Album identity: `albums` table and `albums_identity` index in `LibrarySchema.swift` (the
  SQL is the part's identity, so a change rebuilds the part), filled by
  `LibraryIndex.albumID(_:artist:)` with the `AlbumKey` cache.
- gzip: the system zlib is linked only by the `Discogs` target (`Package.swift`, `GzipStream`
  reads). Nothing writes gzip yet.
- Palette: `PaletteModel.open(...)` resets `query = ""`; `PaletteController.show` sets
  `field.stringValue = ""`; ⌘K is `.showPalette` in the registry.

Sub-parts. 53a, 53b and 53c touch disjoint modules and can be separate worktrees; merge in the
order 53a, 53b, 53c (53c last since it changes the index schema and the dialog).

#### 53a. Browser and tag editor (53.1, 53.2, 53.3, 53.8, 53.12, 53.10, 53.11, 53.14)

Modules: Commands, Library (titles), Metadata, LibraryBrowser, TagEditor, Palette, App,
Discogs (read only). No schema change.

1. **Headers (53.12).** `TrackColumn.headerTitle` in `TrackColumnTitle.swift`: "Track No." and
   "Disc No." for `.trackOfTotal` and `.discOfTotal`, `title` otherwise, so both strings live
   beside the others. `TrackTableController` 165/166 (header cell and tooltip) use it; the
   header menu (879) and `SmartFieldTitle` keep `title`. Tests in `LibraryTests`: the two
   headers, and that `title` is unchanged.
2. **Open Discogs Release (53.10).** `AppCommands.openDiscogsRelease =
   CommandID("track.openDiscogsRelease")`, "Open Discogs Release", chord `⇧⌘D` unless the
   registry test finds it taken (`d` is unused in `AppCommands`); added to `trackMenu`, the
   File section of `sections` beside Show Album, and the palette comes free from the registry.
   The View menu is where the owner asked; this app's track commands sit in the File section
   (`sections`), so it goes there and the plan keeps the owner's "View menu" wording for
   Show in All Music too: both in the section that lists Show Album, whatever its title.
   Handler in `Sources/App/MusicPlayer` enabled when the first selected track's
   `discogs_release_id` parses as an Int (a new `LibraryReader` query, `discogsReleaseID(ofTrack:)`,
   since `TrackRow` doesn't carry it; no per-row cost). The URL comes from 51.37's builder,
   `ReleaseFields`'s `discogsReleaseURL(_ id: Int) -> URL`, exposed `public` for the app;
   opened with `NSWorkspace.open`. Tests: enabled rule over a tagged and an untagged track,
   the URL string.
3. **Discogs tab (53.11).** `TagEditorTab.discogs`, appended after `.file`, shown only when the
   files in `TagEditorModel` have a release id (`tags.discogsReleaseID`). `TagEditor` does
   not import Discogs, and sideways imports are barred; the window gets the release through a
   closure `releaseText: (Int) async -> ReleasePage?` that the app wires to the catalog
   (`Catalog` release, label, credits, tracklist; formatting shared with 51.37's View Release
   as a Core `Discogs` function `ReleasePage` so there is one wording). The tab shows a
   read-only selectable text view and an Open on Discogs button (the 53.10 URL). Missing
   release or no catalog: "This release isn't in the local catalog." / "No Discogs catalog is
   imported." Several releases: first one plus "and N other releases". Tests: a
   `TagEditorTests` model test over a fixture catalog (`Tests/DiscogsTests` fixtures), a missing
   release, no catalog, two releases.
4. **Extras tab (53.8).** `TagEditorTab.extras`, after `.details`. `TagEditorModel` already
   reads tags per file; add `extras: [ExtraRow]` (key, value or `.mixed`) built from each
   file's `TrackTags.custom`: union of keys, value shown when every file that has the key
   agrees and all files have it, otherwise mixed (a key missing from some files is mixed
   too). A scrolling `NSTableView` with two selectable text columns, copy as `KEY\tvalue`
   lines. Decision: custom keys that the Discogs tab or another tab already edits (the
   `DiscogsKey` ones) still appear; Extras is what the reader found, not what is unshown.
   Tests over FLAC, MP4 and ID3 fixtures from the generator (`Sources/Tools/GenerateFixtures`
   already makes custom keys for ADR 0129), and a two-file mixed case.
5. **Every picture (53.3).** `Metadata`: `public struct EmbeddedPicture { art: EmbeddedArt;
   type: PictureType }` and `readPictures(at:) -> [EmbeddedPicture]`, reusing the FLAC
   `PICTURE`, ID3 `APIC` (type byte) and MP4 `covr` parsing that find `art` today (those parsers
   already see every picture; the single `art` stays what the scanner records, derived from
   the list's front or first, so the index doesn't change). `PictureType` names the ID3/FLAC
   types: front (3), back (4), other for the rest, with the type's own name where it has one
   (leaflet, media...). `ArtViewer` takes the list: `←`/`→` and on-screen buttons step,
   "2 of 3 · Back" label in the dimmed backdrop, each decoded with the existing `ArtworkLoader`
   per `session`. One picture shows no buttons or count. Opened from the track table, reads
   the list once on open off the main actor. Tests: `MetadataTests` a three-picture fixture
   for each format; `LibraryBrowserTests` stepping, wraparound off (stops at ends), label.
6. **Show in All Music (53.1).** `AppCommands.showInAllMusic = CommandID("track.showInAllMusic")`,
   "Show in All Music", `⌥⇧⌘A`, in `trackMenu` and the same section as Show Album. In
   `LibraryBrowser`: `showSelectionInAllMusic()` following `showSelection(inPlaylist:)`:
   remember the selected track ids, `model.setSource(.library)` (the All Music source; check
   its case name), select every id present with `model.rows(holding:)`, scroll the first to
   center (`showRow` centers), `focusTracks()`. Enabled when `hasSelectedTracks` and the
   shown source isn't All Music. Tests: the enabled rule per source, the selection after
   the switch, and that keys go to the table.
7. **Dragging files out (53.2) and ADR 0141.** `trackDragItem(_ id:, url:)` writes both
   `trackIDsType` and the file URL (`NSPasteboardItem.setString(url.absoluteString,
   forType: .fileURL)`); the row's path is in the model (`trackRow(row)?.path`), no stat
   (the arch check bars `fileURLWithPath:` without `isDirectory: false`). Both controllers
   implement `tableView(_:draggingSession:sourceOperationMaskFor:)`: `.copy` when
   `context == .outsideApplication`, `.move`-free, and unchanged `.generic`/`.move` within the
   app. Queue and playlist reorders keep reading `trackIDsType`. The comment on
   `trackIDsType` is rewritten to match. ADR 0141: a file URL on the pasteboard lets another
   app read or copy library files; it forbids a move, so Finder never moves or trashes one
   (a drag to a folder copies), and the music-files boundary in AGENTS.md gains one clause
   saying so: a drag out copies, the app writes nothing. Playlist-file export is untouched.
   Tests: the pasteboard holds the id type and a file URL for the same row; the mask is
   `.copy` for `.outsideApplication` and unchanged `.within`; a unit over a helper
   `dragOperationMask(for context:)`.
8. **Palette keeps its query (53.14).** `PaletteModel.open` keeps `query` instead of clearing it
   (kept in the model for the app's session, not saved to disk; decision: not persisted
   across launches, since Sublime Text keeps it per window session). `PaletteController.show`
   fills the field with it, selects all, and `rankNow()` ranks it. ⌘K while open clears it
   (`close` then the next show is empty, or clearing the field in place: it clears the field
   and ranks the empty query). Go to Item mode keeps its own last query. Return runs the top
   result as before. Tests in `PaletteTests`: query kept across close and open, replaced by
   typing, cleared by the second ⌘K, the empty-query path unchanged when none was typed.

Commits: 1 headers; 2 Open Discogs Release + its builder use; 3 Show in All Music; 4 palette
query; 5 Extras; 6 Discogs tab; 7 pictures in Metadata; 8 viewer stepping; 9 drag out +
ADR 0141 + AGENTS.md clause. Docs: `plan.md` ticks.

#### 53b. Settings and snapshots (53.4, 53.5, 53.6, 53.7) (ADR 0142)

Modules: Settings, a new Core module `Snapshot`, SettingsWindow, App. The new module is
justified: it needs zlib writing (only `Discogs` links `z` and it reads), it is neither
Library's queries nor a Discogs thing, and Library gains nothing from linking `z`. Package.swift:
`Snapshot` depends on `Library`, `Log`, `Settings`, `SQLite`, links `z`; `Settings` stays free
of it. Search found no existing gzip writer, so there is no duplicate to share; the reader in
`GzipStream` stays where it is (principle 3: the reader and the writer are two different
sides, and the dumps are never written).

1. **Config group (53.4).** `GeneralPane`: the General section's config rows (`configHeader`
   and the `copyDefault` row) go into the same sunken titled box as Library's, title "Config".
   Reuse the function that builds Library's box (the `section(title:...)` helper that makes
   `panel`), so no second box. Test: a `SettingsWindowTests` model/layout test that General
   has a "Config" section with the three buttons.
2. **Database in Library (53.5).** `GeneralPane` Library box: a row with the index path
   (tilde-abbreviated, monospaced, truncating middle as `configHeader`), size (the file plus
   `Database.walSuffix`, read on the pane's open off the main actor through `LibraryReader`
   or a `Snapshot`-free `FileManager` stat in `Settings` as `IndexFiles.size(of:)`), and Reveal
   in Finder via `SettingsActions.revealIndex` (new closure, like `revealConfigFile`). A
   `ByteCountFormatter` string. Test: size sums both files; path shown.
3. **Snapshot writer.** `Snapshot/IndexSnapshot.swift`: `func writeSnapshot(of index: LibraryIndex,
   into folder: URL, on day: Date) throws -> URL`: `VACUUM INTO` a temp file in the snapshot
   folder (`.library-YYYY-MM-DD.sqlite.partial`), gzip it with zlib `deflate` (gzip header,
   level 6, 1 MB chunks, CRC from zlib) to `library-YYYY-MM-DD.sqlite.gz.partial`, then
   `rename` to the final name, and delete the temp. A day's second snapshot (Back Up Now)
   replaces that day's file. `VACUUM INTO` is SQLite 3.27; macOS 12 ships 3.37, fine. It is a
   read on the index's own connection (reader), never writes the index. A name with the day in
   local time via a fixed-format `DateFormatter` (POSIX locale), defined once as `SnapshotName`.
4. **Rotation.** `Snapshot/SnapshotRotation.swift`: `kept(_ names: [SnapshotName], today:)`
   keeps the newest 7 distinct days, then for each of the 4 ISO weeks before them the newest
   one in that week, and returns what to delete. Pure, tested over a simulated 60 days.
   Deletes only files whose names parse as `SnapshotName` in the folder (nothing else there
   is touched).
5. **Folder setting and the refusal.** `AppSettings.snapshotFolder: Setting<String?>`
   `library.snapshotFolder`, default nil meaning `Backups` beside the index
   (`AppPaths.snapshotDirectory`, `dataDirectory/Backups`). `AppSettings.conflicts(_:)` adds the
   refusal for a path inside a watched folder or the sync folder (reusing `standardized`,
   `isPath`, `SyncFolder.isInside`'s pattern), reason text in the conflict as the existing two.
   A network-share folder is not supported: a path only (decision, stated in the setting's
   summary), so it can't resolve through `ShareLookup`. The key sits under `library.` so
   `GeneralModel.Section.library` picks it up by prefix. Tests: refused inside a watched folder
   and inside the sync folder; accepted outside; default.
6. **Scheduling.** `Snapshot/SnapshotScheduler.swift` (an actor): once a day, on the scan
   queue's idle (the app already knows when `ScanControl`/the scan queue is idle: it posts to
   the status bar; check `LibraryScanner`'s idle callback in `WatcherStart.swift`), never
   during a scan or sync. It runs at launch after the first idle, and again on the next idle
   once the day changes. The last snapshot's time is the newest file name's day plus its
   modification time, read from the folder (no state to drift; nothing new in `AppState`).
   Failures log and show in Problems? Decision: log at error and show in Settings next to the
   time ("Last snapshot failed: reason"), not a dialog (fail loudly, but not modal on idle).
   The index isn't written; only the snapshot folder is, which is the app's own, so the
   AGENTS.md music-files boundary needs no change; its "app state lives in the SQLite index"
   sentence gets "and its dated snapshots in the snapshot folder (ADR 0142)".
7. **Settings UI (53.6/53.7).** Library box rows: Snapshot Folder (the setting), Last snapshot
   time, Back Up Now (calls the scheduler, disabled while a scan runs, with a spinner), and a
   Snapshots list (`NSTableView`: date, size; gzip'd size on disk) with Restore…. Restore:
   confirm sheet ("Replace the library index with the one from 2026-11-01? Plays, ratings and
   playlists in it replace the current ones. The current index is snapshotted first."), then
   (a) `writeSnapshot` of the current index, (b) gunzip the chosen file to `library.sqlite.restoring`
   in the data directory, (c) `PRAGMA integrity_check` on it, (d) write a small marker file
   `restore.pending` naming the file, and relaunch. At launch, before `LibraryIndex(at:)` opens
   (AppDelegate 236), a `Snapshot.applyPendingRestore(dataDirectory)` swaps the file in and
   moves the old `library.sqlite`, `-wal` and `-shm` aside to the existing `.unreadable-`
   scheme's neighbor (`.replaced-<stamp>`, pruned the same way). Doing the swap at launch
   avoids replacing a database that is open. The relaunch is `NSWorkspace.openApplication` then
   terminate, as the app already quits for the rescan dialog. A restored index of an older
   shape is rebuilt by the usual stale-part path (and 51.32's dialog asks first).
   Unzipping needs an inflate: a small `GzipFile.inflate(to:)` in `Snapshot` (zlib `inflate`
   with window 31, streaming 1 MB chunks, caps nothing since the file is the app's own, and
   checks CRC/size from zlib). Tests: naming; rotation over a simulated 60 days (7 daily + 4
   weekly kept, rest deleted, other files untouched); the gzip opens as a database with the
   same rows (`LibraryIndex` fixture, compare track count and a play count); a refused folder
   (a settings conflict test); restore round trip in a temp data directory (snapshot,
   change index, restore, reopen, rows from the snapshot; the pre-restore snapshot exists);
   a corrupt gzip is refused before anything is replaced; the scheduler skips while a scan
   runs and runs once on idle.
8. **ADR 0142:** snapshots, the format and name, rotation, where the folder may be, why VACUUM
   INTO a copy not a file copy of a live WAL database, why the swap happens at launch, and
   that the Discogs catalog is not kept.

Commits: 1 Config group; 2 database row; 3 `Snapshot` module with writer and rotation; 4
setting and refusal; 5 scheduler; 6 restore; 7 Settings UI; 8 ADR 0142 and AGENTS.md sentence.

#### 53c. Separate Releases (53.13) (ADR 0143)

Modules: Library (`LibrarySchema.swift`, `LibraryIndex.swift`, `RescanNotice.swift`,
`BrowserGroupingSQL.swift`, `LibraryQueries.swift`), Settings (`AppSettings.swift`), Commands
(`AppMenus.swift`), App (`AppDelegate.swift`, `SettingsChanges.swift`), LibraryBrowser
(`RescanAlert.swift`). Merges after 53a and 53b (see "Files shared with 53a and 53b").

What 51h built (read from main, 548d4115):

- `SchemaPart.rescanWhy: String?` (LibrarySchema.swift): one fixed sentence per part, nil for a
  part a rescan doesn't refill. Today only `.index` has one ("This build stores the index ... in a
  new shape ..."). It cannot know a direction, so it can't carry "on" or "off".
- `RescanNotice` (Library/RescanNotice.swift): `init?(parts: [SchemaPart])`, `title` ("Rescan the
  Library?"), `text` = the parts' `rescanWhy` joined, plus "Every file is read again. Plays,
  ratings and playlists stay."
- `LibraryIndex.init(at:movingAsideIfUnreadable:confirmRescan:)`, where `confirmRescan:
  ((RescanNotice) -> Bool)?` is asked from `prepareSchema` via the private `rescanNotice()`
  (reads `storedParts()` and `partsToRebuild(stored:)`, writes nothing) before `rebuildStaleParts()`.
  False throws `LibraryError.rescanDeclined`, file untouched. `public private(set) var
  rebuiltIndex` is set inside `rebuildStaleParts` (index in `rebuilt` and previously stored);
  `LibraryBrowser` copies it to `status.rebuildingIndex` (LibraryStatus shows the rebuild).
- `askToRescan(_:) -> Bool` (Features/LibraryBrowser/RescanAlert.swift): a modal NSAlert, buttons
  "Rescan Now" / "Quit". Only `AppDelegate.openWindow` passes it (the one launch open, with
  `movingAsideIfUnreadable: true`); `catch LibraryError.rescanDeclined` there calls
  `NSApp.terminate`.

What the old 53c got wrong:

1. "Every `LibraryIndex(at:)` caller is updated" is the dangerous part. Besides AppDelegate and
   ScanCommand there are ~15 in Core/Library alone (`LibraryReader`, `LibraryScanner`,
   `LibraryWatcher`, `MeasuresCache`, `StatsReader`), plus Tools and 37 test files, and 53b's
   `SnapshotScheduler` and `SnapshotRestore` add two more. All open the same file. If the option
   were a plain `Bool` defaulting to off, any of them opening a library built with it on would
   see a stale index part and drop and rebuild it, and the scanner would insert albums without
   release ids. So the option cannot be a parameter every open must repeat.
   Fix: the stored index SQL is the single source of truth. `init` takes `separateReleases: Bool?
   = nil`. Nil adopts whatever the stored first line says (on a new file: off); only the launch
   open in `AppDelegate.openWindow` passes the setting's value. `LibraryIndex` keeps the
   resolved value in a `private(set) var separateReleases: Bool`, read by `albumID`. No other
   caller changes, and the tests default to nil.
2. "`SchemaPart.sql` becomes `sql(separateReleases:)`": only `.index` takes it. Keep `var sql`
   for the others (and `sql` for `.index` = off) and add `func sql(separateReleases: Bool) ->
   String`; `indexSchema` becomes a function returning the `-- separate releases: on|off\n`
   line plus the text. `partsToRebuild(stored:)`, `rebuildStaleParts` (`database.execute(part.sql)`
   and `identity.run(part.rawValue, part.sql)`) and `rescanNotice()` all compare and write
   `$0.sql`, so they all take the resolved option (a parameter or the stored property, set in
   `prepareSchema` before `rescanNotice()`, which runs first). Read the stored option from
   `storedParts()[index]`'s first line.
3. "A change is applied at the next launch ... 'Cancel' reverts the toggle". The modal at launch
   has "Rescan Now" / "Quit", not Cancel, and Quit leaves the file untouched so the next launch
   asks again: a user who flips the setting and quits is asked on every launch until they edit
   the config by hand. And `rescanWhy` is fixed text. Decision:
   - `RescanNotice` gains `separateReleases: Bool?` (nil unless this open's change is the
     option's; `init?(parts:separateReleases:)`). `text` puts the direction sentence first, in
     words kept once beside the part: on, "Albums are made of each Discogs release, so a
     reissue tagged with the original's title is an album of its own."; off, "Albums are made of
     title and artist again, so releases that share them merge." In both, the stock tail ("Every
     file is read again. Plays, ratings and playlists stay.") is unchanged. The index part's
     "new shape" sentence is not shown when the only reason is the option: `partsToRebuild` can't
     tell, so `rescanNotice()` compares the stored SQL with the same part built with the stored
     option; equal means the option is the only difference.
   - Runtime toggle: `AppDelegate.settingsChanged` (SettingsChanges.swift), on
     `schema.separateReleases.key`, compares with `index.separateReleases` and, if different,
     shows a sheet on the Settings window with `notice.title` / `notice.text`, "Rescan Now" /
     "Cancel". Cancel calls `settings.set(\.separateReleases, to: old)` (ConfigStore.set exists).
     Rescan Now relaunches; there is no relaunch code in the tree today, so write the minimal one
     in App (`NSWorkspace.openApplication(at: Bundle.main.bundleURL, ...)` then terminate) and
     say so in the ADR. A hand-edit of the config file takes the same path, since it also goes
     through `settingsChanged`.
   - Launch with a differing setting (relaunched, or edited while closed): `askToRescan` as is,
     but a decline there is "Quit" (51h's behavior). Accept that; the owner can revert the
     setting in the file. If that is not acceptable, the alternative is a third button "Keep"
     that reopens with the stored option; not in 53c.
   - `rebuiltIndex` and `LibraryStatus.rebuildingIndex` already say "rebuilding" for any index
     rebuild. No change.
4. "The reason sentence is chosen by the direction": see 3; the per-part table is `rescanWhy`, a
   single string, so the direction text lives on `RescanNotice`, not in `SchemaPart`.
5. "Album ordering interleaves by album id": the track query's `ORDER BY` already adds
   `t.album_id` when grouping by album artist and sorting by Artist or Album
   (LibraryQueries.swift ~l.119), so those orders keep releases together; the other branch's
   tie-break (`ar/ga.sort_name, al.sort_title, t.disc_number, ...`) has no album id and would
   interleave two releases. Add `t.album_id` after `al.sort_title` there. The Album pane
   (`BrowserGroupingSQL`, `.albums`, order `sort_title`) needs `sort_title, <year>` with the
   same correlated `min(TrackColumn.year.expression)` subquery `.albumsByYear` already uses
   (extract it once, not copy it; two uses so no third occurrence rule issue, but they must share
   the text). The track table does not get a year subquery per row (cost on 100k rows; measure
   with the Bench if wanted); two releases then sort adjacent in insertion order, each whole.
   `TrackColumnSort` (`.album: "al.sort_title"`) is unchanged.
6. Release id source: `insertTrack` binds `tags.custom[DiscogsKey.releaseID]` (a String?) into
   `tracks.discogs_release_id`; there is no `tags.discogsReleaseID`. Pass the same trimmed value
   to `albumID(_:artist:releaseID:)`.

Steps:

1. **Schema and plumbing.** `albums.release_id TEXT NOT NULL DEFAULT ''`; index
   `albums_identity ON albums (title, ifnull(artist_id, 0), release_id)`; `AlbumKey` gains
   `releaseID: String`; the cache query selects `release_id`; the `INSERT INTO albums` binds it.
   `indexSchema` -> `func indexSchema(separateReleases:)` with the first line; `SchemaPart`
   `sql(separateReleases:)`; `LibraryIndex.init(... separateReleases: Bool? = nil ...)` with the
   resolution in point 1/2.
2. **Insert.** `albumID` uses `separateReleases ? trimmedReleaseID ?? "" : ""`. A track with no
   id still merges with every other idless one (intended).
3. **Setting.** `AppSettings.separateReleases = Setting("library.separateReleases", title:
   "Separate Releases", default: false, "Make an album of each Discogs release ...")`, placed
   after `groupByAlbumArtist`; `GeneralModel` groups by the `"library."` prefix, so it shows in
   the Library group with no model change (check after 53b's pane rework). File menu: add
   `.setting(settings.separateReleases.key)` after `groupByAlbumArtist` in `AppMenus` (~l.119).
4. **Applying it.** `RescanNotice` direction, `askToRescan` unchanged, `settingsChanged` sheet
   and relaunch (point 3). `AppDelegate.openWindow` passes `separateReleases: settings[\.separateReleases]`.
5. **Sort.** Point 5.
6. **Tests** (new file `Tests/LibraryTests/SeparateReleasesTests.swift`, not edits to
   `LibraryIndexTests`, which 53b edits; the dialog text in `RescanNoticeTests.swift`): original
   and 2025 remaster, same title and artist, different ids: one album off, two on, tracks stay
   with their own; idless track joins off, stays alone on; reopening with nil keeps the stored
   option and does not rebuild (this is the guard for the snapshot and scanner opens); reopening
   with the other value asks `confirmRescan` once with a notice carrying the direction, rebuilds
   only the index and scans parts, keeps ratings (as `quitAtTheRescanQuestionLeavesTheFileAsItWas`
   does); declined leaves the file byte-equal; Album pane and table order for two releases; the
   notice text per direction. The Settings-sheet path in `SettingsWindowTests` or a
   `MusicPlayerTests` fixture only if the sheet is testable without a relaunch; otherwise inject
   the relaunch.
7. **ADR 0143** (0141 is 53a's, 0142 is 53b's): identity with the option, setting not rule,
   release id not master, stored-SQL option with open-by-nil adoption and why (many connections),
   the toggle's sheet and the relaunch, Quit at launch.

Commits: 1 schema, option and the nil-adopting open; 2 insert and sort; 3 setting, menu, notice
and sheet; 4 tests with each; 5 ADR.

Files shared with 53a and 53b (`git diff --stat main...HEAD` of each worktree):

- `Sources/App/MusicPlayer/AppDelegate.swift`: 53a (import, `editing.release` ~l.629) and 53b
  (`applyRestoreAtLaunch`, `SnapshotScheduler(...)` right after the `LibraryIndex(at:
  movingAsideIfUnreadable:confirmRescan:)` call, ~l.244-260, watcher start ~l.848). 53c edits that
  same `LibraryIndex(...)` call: expect a textual conflict with 53b; resolve by adding the
  argument to 53b's version of the call.
- `Sources/App/MusicPlayer/SettingsChanges.swift`: 53b (`libraryDatabase`/`backUpNow` closures ~l.252).
  53c adds a block after the `groupByAlbumArtist` one (~l.117): different hunk.
- `Sources/Core/Library/LibraryIndex.swift`: 53b rewrites `moveAside` and adds `move`,
  `pruneMovedAside`, `copy(to:)` (l.34-160) immediately above `prepareSchema`; 53c edits `init`
  doc/signature, `prepareSchema`, `partsToRebuild`, `rebuildStaleParts`, `albumID`, `AlbumKey`.
  Adjacent, likely a clean merge, but rebase and check `prepareSchema`'s context.
- `Sources/Core/Settings/AppSettings.swift`: 53b adds `snapshotFolder` after `libraryFolder` and
  rewrites the conflicts section at the bottom; 53c adds one setting at ~l.83. Clean.
- `Sources/Core/Commands/AppMenus.swift`: 53a edits the track menu (~l.63) and View (~l.172);
  53c one line at ~l.119. Clean.
- `Sources/Core/Library/LibraryQueries.swift`: 53a adds `discogsReleaseID(ofTrack:)` at ~l.213;
  53c edits the sort tie-break at ~l.119-135. Clean.
- 53b's `Snapshot/SnapshotScheduler.swift` and `SnapshotRestore.swift` call `LibraryIndex(at:)`;
  safe only with the nil-adopting open (point 1). Also 53b's restore can put back an index with
  the other option; the next launch then asks via `askToRescan`, which is correct.
- `GeneralModel.swift` / `GeneralPane.swift` (53b): 53c has no edit, but confirm the
  `"library."` prefix grouping survived 53b.
- Tests: 53b edits `LibraryIndexTests.swift`; 53c adds new files only.
- Not touched by either: `LibrarySchema.swift`, `RescanNotice.swift`, `RescanAlert.swift`,
  `BrowserGroupingSQL.swift`, `RescanNoticeTests.swift`.

#### 53.9 and 53.15 tests

Spread across the sub-parts as above; each commit carries its tests. 53.15's last item
(palette) is in 53a, the rest as listed. `./scripts/test --changed` per commit; one
`./scripts/check` at the end of each sub-part. The check steps that read the diff: format,
build, tests, `arch` (new `Snapshot` module and the tier map), `surface` (`public` only where
another module calls), `dupes` (the three new strings: file-name format, "Reveal in Finder"
which exists once in `GeneralPane` today and moves with the Config group, and the 53.8/53.11
messages), and a docs check if ADR files are linted.

#### Owner check

As the plan says: each in the running app, a snapshot restored, a remaster beside its
original, the palette's kept query; plus a drag of a track out to the Desktop (a copy) and to a
Finder window on the NAS share (still a copy).

#### Decisions made here

- Palette query lives for the app session, not on disk.
- Snapshot folder is a plain path, no network share.
- Restore swaps the file at the next launch, not live.
- Separate Releases is applied at the next launch with the dialog, default off.
- Extras lists every key the reader holds in `custom`, including ones other tabs show.
- Open Discogs Release goes where Show Album is (the File section), with `⇧⌘D` if free.

#### Needs the owner

1. **Open Discogs Release's shortcut and the View menu.** The app has no View-menu section
   holding track commands; the track commands are in File. Confirm File, or say which menu.
2. **Separate Releases for tracks with no release id** stay merged with each other. If the
   owner wants them kept apart from a tagged release of the same title (they are today only
   by the id differing), that is already so; confirm no third behavior is wanted.
3. **Restore also restores plays and ratings** (they live in the index file). That is what a
   restore is, but say so in the dialog; confirm the owner wants the whole file and not the
   index part only.

Result, phase 53: shipped 53.1 to 53.15 in three parts, merged a, b, c (ADRs 0141 to 0143).
53a, browser and tag editor: Show in All Music (⌥⇧⌘A) and Open Discogs Release (⇧⌘D) in the
View menu, the track menu and the palette; rows dragged out of the app carry their files, copy
only (ADR 0141), and the sidebar takes file URLs only from a drag another app started, so the
app's own rows still drop on a playlist as tracks; the art viewer steps through every picture;
Extras and Discogs tabs in Get Info; "Track No." and "Disc No." headers; the palette opens with
its last query. Changes from the plan: the headers' tooltips keep the full titles; the viewer
names four picture types (front and back cover, leaflet page, disc label) and calls the rest
Other; every picture is listed in `TrackMetadata.pictures` beside `art`, only when the art
viewer asks; TagEditor imports Core/Discogs, where the tagger's field titles and the page URL
moved; Extras and Discogs are read-only text views, not tables; the viewer reads the file's
tags once more when it opens. 53b, settings and snapshots: the Config group, the index's path,
size and Reveal in Finder, a daily gzipped `VACUUM INTO` snapshot between scans (7 daily, 4
weekly, 3 from before restores), Back Up Now, and Restore…, which snapshots the current index
under a name of its own and swaps the chosen one in at the next launch (ADR 0142). The swap
waits while another copy of the app holds the new `library.sqlite.in-use` lock, puts the index
back if it fails, and stops the launch if it can't. A snapshot folder on a network volume is
refused, so a restore needs a local one. 53c, Separate Releases (ADR 0143): off by default;
the index's stored SQL holds the option, so only the app's own open changes it; a change asks,
in Settings with Rescan Now or Cancel, and relaunches with `--rescan-confirmed on|off`, which
waives only that question. With it on, Listening Stats, Library Health and the tagger list
same-titled releases as separate rows.

Gate, phase 53: per part, a correctness review and a quality and architecture review, then a
second review of the fixes; 53b's restore had a data-safety review. 53a: 10 findings fixed
(Open Discogs Release's menu check no longer reads every selected row from the database, the
Discogs tab follows a save, an MP4 cover of an unknown type is skipped). 53b: 14 fixed (a
same-day restore overwrote the snapshot it restored from; overlapping writes could publish a
garbled file; no check for another copy of the app; a failed swap could open an empty index),
then 2 lows. 53c: 7 fixed (the flag waived every question at its launch). `./scripts/check`
passes except `theGlassHeadersAreFrosted`, the known agent-session failure. `./scripts/bench`,
78 rows without the window rows: metadata parse was 5.29 s of 5 on the full run, 4.87 to 4.93 s
alone with and without listing every picture, so the full run's load, not the change; the
second keystroke during Analyze Library was 23.4 ms of 20 once and 15.6 and 16.1 ms on reruns.
Sort all columns 26.3 ms, browser pane query 0.81 ms, scan 1.25 s, index 47.4 MB. Cost:
plans 188k tokens, 37 tool calls, 5 min; implementation, 53a 417 calls and 98 min, 53b 259
calls and 97 min, 53c 142 calls and 54 min; reviews 656k tokens, 100 calls, 25 min.

Owner steps: each part in the running app: Show in All Music, a drag to the Desktop (a copy,
the original stays), the art viewer on a file with several pictures, Extras and Discogs tabs,
the palette's kept query; Back Up Now, then Restore… of that snapshot and the relaunch; Separate
Releases on with a remaster beside its original, Rescan Now, and Cancel.
