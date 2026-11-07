# Build plan

The work still ahead: phases not yet built, owner checkpoints still pending, and ideas for later.
Agents work through it phase by phase, mostly unattended, and stop only at **hardware
checkpoints**, where the owner has to try something on the DAC Mac, the Denon, a phone, or the
2015 MacBook Pro.

Finished phases, 1 to 50 apart from 10 and 13, are in [plan-archive.md](plan-archive.md), with
their implementation plans, Result lines and the full text of each checkpoint.

Each phase ends with the [phase gate](#phase-gate): review, performance audit, and architecture
check. A phase isn't done until its gate passes.

## How to run it

Start a session with "run the next phase of docs/plan.md". For several phases unattended, say "use
a workflow to run phases N–M of docs/plan.md". For each phase, the orchestrating agent:

1. **Plans.** It reads the phase, the code it touches, and `docs/map.md`, then writes a short
   implementation plan under the phase heading: files, modules, tests, and order. It does a
   search first (map.md recipes), so it extends existing code instead of writing a second copy.
   Earlier phases' plans in the archive are the pattern to follow.
2. **Implements** on a branch `phase/<n>-<slug>` with an Opus subagent (per the owner's
   CLAUDE.md), in small commits. Each commit passes the `./scripts/check` steps that read
   what it changed (AGENTS.md); the implementer iterates with `./scripts/test --changed`.
3. **Runs the phase gate.** The reviewers and auditors are Sonnet subagents running in parallel.
   It fixes every confirmed finding, then reruns only the checks those fixes can fail. A full
   `./scripts/check` runs once, before step 4, and its test step reruns only the test targets
   edited since its last pass.
4. **Records.** It ticks the phase's boxes, adds a "Result" line with measured numbers and what
   the phase cost (each subagent's tokens, tool calls and wall time), commits, and fast-forwards
   `main` to the branch. It never pushes.
5. **Archives.** It moves the finished phase, unchanged, to the end of the archive's phases. A
   checkpoint the phase leaves pending gets a line in [Waiting on the owner](#waiting-on-the-owner)
   pointing at the archived text.
6. **Looks back** every third phase archived since the last
   [retrospective](#retrospective), and runs one.
7. **Continues.** A hardware checkpoint doesn't stop the run. It's recorded as pending, and the
   run moves on to the next phase that doesn't depend on its result. When the run ends, it lists
   every pending checkpoint at once: what to push, what to run on which machine, and what to
   paste back.

If something blocks a phase that only the owner can resolve (a product decision, missing
hardware, an Apple API that can't do what the phase assumes), stop and ask. Don't work around it.

### Current run order

Set by the owner on 2026-11-06. Earlier run orders are in the archive.

1. Phase 51, then 52 (set by the owner on 2026-11-07).
2. Phases 10 and 13 wait. Phase 10 adds pairing tokens, a secret, so the owner decides how
   they're stored first (AGENTS.md).

## Waiting on the owner

Checkpoints and answers from finished phases. Each links to its phase in the archive, which has
the full steps. When the owner clears one, tick its box in the archive, add what was found to
that phase's Result line, and delete its line here.

### Hardware checkpoints

- **5 Main window** ([steps](plan-archive.md#5-main-window)): the release build on the 2015
  MacBook Pro with the real library; launch time, scrolling, searching, `./scripts/bench`.
- **8 System integration** ([steps](plan-archive.md#8-system-integration)): media keys, Now
  Playing and art on the DAC Mac with the ADI-2.
- **9a Network control** ([steps](plan-archive.md#9a-network-control)): receiver control,
  Pure Direct, volume and input on the Denon, both ways.
- **9b UPnP output** ([steps](plan-archive.md#9b-upnp-output)): 16/44.1, 24/96 and 24/192 FLAC
  to the Denon; display, gapless, seek, volume.
- **11 Tag editor** ([steps](plan-archive.md#11-tag-editor)): the edited corpus clones in
  Swinsian and Finder.
- **12 DSD over DoP** ([steps](plan-archive.md#12-dsd-over-dop)): DSD64, DSD128 and DSD256 on
  the ADI-2, its DSD indicator lit.
- **18 Import from other players** ([steps](plan-archive.md#18-import-from-other-players)): the
  Swinsian import on the DAC Mac.
- **20 Signal path panel** ([steps](plan-archive.md#20-signal-path-panel)): 16/44.1 and 24/192
  on the ADI-2, the rate changed in Audio MIDI Setup while playing.
- **22 Per-device profiles** ([steps](plan-archive.md#22-per-device-profiles)): volumes per
  device, the ADI-2 powered off and on.
- **23 Sync across machines** ([steps](plan-archive.md#23-sync-across-machines)): two Macs on the
  NAS, plays, ratings, a renamed folder, a remounted share.
- **31.4 Output for devices that can't play bit-perfect**
  ([steps](plan-archive.md#31-output-for-devices-that-cant-play-bit-perfect)): 44.1 and 96 kHz
  to AirPods on the 2015 MacBook Pro.
- **32f and 33, the old Mac** ([32f](plan-archive.md#32f-checkpoint-and-budgets),
  [33](plan-archive.md#33-old-mac-follow-ups)): rerun the 32f block on the 2015 MacBook Pro and
  send back the file, then the hands-on check.
- **43 Listening Stats** ([steps](plan-archive.md#43-listening-stats)): open Stats and change
  periods on the 2015 MacBook Pro with the real library.
- **44e Tags written in place** ([steps](plan-archive.md#44e-tags-written-in-place)): in-place
  tag edits on copies of NAS files, then a pulled network cable during a batch.
- **46 Doubled Swinsian play counts** ([steps](plan-archive.md#46-doubled-swinsian-play-counts)):
  the steps in its Result line on both Macs, then a few tracks' counts compared.
- **47 Faster tag writes** ([steps](plan-archive.md#47-faster-tag-writes)): a 20-track
  hi-res album saved on the NAS over Wi-Fi and Ethernet, art added and edited again; and 47.7's
  probe, `swift scripts/smb-copy-probe.swift /Volumes/<share>/<scratch folder>`, its output
  pasted back.
- **48e Receiver moving on** ([steps](plan-archive.md#48e-the-receiver-moves-on-to-the-next-track)):
  the end of three tracks in a row on the Denon, and the log lines back.
- **49 Click-free play, pause and seek** ([steps](plan-archive.md#49-click-free-play-pause-and-seek)):
  play, pause and seek quickly on the ADI-2 at 44.1 and 192 kHz and with DSD; pops gone, still
  immediate, bit-perfect in the signal path panel.
- **45 Spectrum and file quality** ([steps](plan-archive.md#45-spectrum-and-file-quality)):
  45a, Show Spectrum on the 2015 MacBook Pro while music plays and flagged files against Spek;
  45b, Analyze Library on the real library from the DAC Mac, its time and tile counts.

### Owner checks in the running app

- **35** ([phase](plan-archive.md#35-seek-progress-bar-and-buffering)): click and scrub the
  progress bar on the 2015 MacBook Pro, in the toolbar and the status bar, glass on and off.
- **36** ([phase](plan-archive.md#36-window-chrome-and-glass)): dark mode, the real blur, 36.8's
  lines, glass in full screen, the material bar on the 2015 MacBook Pro.
- **37** ([phase](plan-archive.md#37-toolbar-and-status-bar-builders)): the current header and a
  centered-status layout with each builder, on mbp2026 and the 2015 MacBook Pro.
- **38b** ([phase](plan-archive.md#38b-table-navigation-and-palette-adr-0088)): each item on
  mbp2026 and the 2015 MacBook Pro.
- **39** ([phase](plan-archive.md#39-owner-feedback-2026-11-03-evening)): row lines, the status
  bar border off glass, the art margin, the builder with a real mouse, the title line.
- **40** ([phase](plan-archive.md#40-owner-feedback-2026-11-04-evening)) and **41**
  ([phase](plan-archive.md#41-owner-feedback-2026-11-04-night)): each part in the running app.
- **48** ([phase](plan-archive.md#48-owner-feedback-2026-11-05-third-round)): 48c, DSD on the
  ADI-2 with hog mode off, turned on from the dialog; 48d, the window after a quit, and the launch
  row (`./scripts/bench`) with the display awake.
- **50** ([phase](plan-archive.md#50-owner-feedback-2026-11-06)): each part's Result line
  lists its steps: Stats' height after the timeline and a relaunch, the import table, the
  Top Genres row; Turn On after a DSD track mid-album; Analyze Library on the DAC Mac (measured
  files counted as done, a pause, quit and relaunch, Again), a paused NAS scan; the spectrum
  window's Differences on known remasters. When the stuck row line shows again: whether Hide
  Status Bar or a window resize clears it, and what was shown just before.

### Answers

- **38.11 Tag-write error** ([phase](plan-archive.md#38b-table-navigation-and-palette-adr-0088)):
  the error text.
- **39** ([phase](plan-archive.md#39-owner-feedback-2026-11-03-evening)): whether selected rows
  show their row line, and whether "the first column on the right" counts from the center, as
  now, or from the window's edge.

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
- [ ] **Result line** written: what shipped, the benchmark numbers, what the phase cost, and
      anything deferred.

## Retrospective

Every third phase, and before a long run ends, the orchestrator adds a dated entry at the top of
[retrospectives.md](retrospectives.md):

- Tokens and wall time per phase since the last entry, from the Result lines, and where they
  went: reading code, test iterations, gate runs, review rounds, waiting on probes.
- What changes because of it, in this plan, AGENTS.md, a script or a brief, with the reason.
  Make the change in the same commit as the entry.
- Cleanup: `git worktree list`, then remove every worktree no running agent is using and run
  `git worktree prune`. Each one holds a full `.build`, several gigabytes.

Then `./scripts/test --fresh` and `./scripts/check`. The full run catches what the gate's
incremental test step can miss ([ADR 0122](decisions/0122-incremental-test-step.md)): a race
that shows only with the whole suite running at once.

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
| Open Listening Stats on Past Month, 1M synthetic plays: a new connection, every album's first play and the past month's report (p95; phase 43); the old Mac figure is an estimate until its checkpoint | < 400 ms | < 1500 ms |
| Change the Listening Stats period, each of Past Week, Past Month, Past Year, last year and All Time in turn, 1M synthetic plays (p95; phase 43); the old Mac figure is an estimate until its checkpoint | < 250 ms | < 900 ms |
| Palette, Go to Item over every fixture track, the last of 8 keystrokes 50 ms apart to its results (median; phase 32d); the old Mac figure is an estimate until its checkpoint | < 15 ms | < 80 ms |
| Tag editor, read 200 fixture files with each file's opens on the slow simulated NAS (phase 32d); the old Mac figure is an estimate until its checkpoint | < 5 s | < 15 s |
| Get Info on one fixture track, to its window on screen (median of 5; phase 42e); the old Mac figure is an estimate until its checkpoint | < 50 ms | < 150 ms |
| Get Info on one fixture track, to its fields (median of 5; phase 42e); the old Mac figure is an estimate until its checkpoint | < 100 ms | < 300 ms |
| Get Info on 100 fixture tracks, to their fields (median of 5; phase 42e); the old Mac figure is an estimate until its checkpoint | < 500 ms | < 2000 ms |
| One fixture FLAC's title written and read back into the index (median of 5; phase 42e); the old Mac figure is an estimate until its checkpoint | < 100 ms | < 400 ms |
| A title saved to 20 fixture FLACs grown to 40 MB, in one batch, in place (phase 47); the old Mac figure is an estimate until its checkpoint | < 1 s | < 3 s |
| The same on the slow simulated NAS: 10 ms a file system call, 57 MB/s over one link (phase 47) | < 10 s | < 10 s |
| The same batch through the temp file (phase 47); the old Mac figure is an estimate until its checkpoint | < 5 s | < 30 s |
| The same through the temp file on the slow simulated NAS (phase 47) | < 100 s | < 120 s |
| Launch to the first scan's start with a 1M-event sync merge pending (phase 32d); the old Mac figure is an estimate until its checkpoint | < 1 s | < 3 s |
| Analyze a 5-minute 24/96 FLAC fixture, local, from the page cache (phase 45a); the old Mac figure is an estimate until its checkpoint | < 2 s | < 12 s |
| The same on the slow simulated NAS: 23 ms to open, 10 ms a 1 MB block (phase 45a); the old Mac figure is an estimate until its checkpoint | < 6 s | < 20 s |
| Memory that analysis adds at its peak (phase 45a) | < 10 MB | < 10 MB |
| The second of two search keystrokes 50 ms apart, as above, while Analyze Library runs over every fixture file and the browser refreshes every 2 s (p95; phase 45b); the old Mac figure is an estimate until its checkpoint | < 20 ms | < 80 ms |
| Analyze Library over 200 fixture files on the slow simulated NAS, two to four files at once at utility priority (phase 45b, 50c); the old Mac figure is an estimate until its checkpoint | < 15 s | < 40 s |
| Import a 20,000-release fixture Discogs dump into a new catalog (phase 51b); the old Mac figure is an estimate until 51.13 | < 5 s | < 20 s |
| The catalog of that fixture dump (phase 51b) | < 60 MB | < 60 MB |

## Phases

Phases 10 and 13 are from the original plan and haven't been built.

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
merge a, then b. 51c needs both, and 51d needs 51c; 51e needs 51d's import button. ADR
numbers: 0128 and 0129 to 51a (the survey's findings, custom fields), 0130 to 51b, 0131 to 51c,
0132 and 0133 to 51d (the mapping, one confirmation for a match set), 0134 to 51e (resuming an
import).

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

- [ ] **51.1 Survey (read only, the owner's ask).** A `TagCorpus` mode that reads every file in
      the watched folders and reports, per format: each `DISCOGS_*` and other non-standard key
      with how many files and albums carry it, sample values, and which keys are constant
      within an album. Also how many albums have `DISCOGS_RELEASE_ID` on every track, on some,
      or none, and the conventions around it (the genre, style and grouping layout,
      `Artist (2)` suffixes, ANVs). Written to a file under `.build/`, never to the
      library. Its findings become 51.10's "Like my library" preset and an ADR.
- [ ] **51.2 Custom fields read and written.** The tag reader exposes non-standard keys
      (Vorbis comments, ID3 `TXXX`, MP4 `----:com.apple.iTunes:<name>`) by name, and `TagEdit`
      can set or remove a custom key in each format, with tests on generated fixtures and the
      corpus clones. `DISCOGS_RELEASE_ID` and `DISCOGS_MASTER_ID` are stored in the index
      (columns on `tracks`), the rest is read from the file when needed.
- [ ] **51.3 Matched albums.** An album counts as matched when every track has the same
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

- [ ] **51.4 Import.** A streaming import of the releases, masters, artists and labels dumps,
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
- [ ] **51.5 What's kept.** Per release: id, master id and whether it's the main release, title,
      artists (id, name, ANV, join), labels with catalog numbers, formats with descriptions,
      country, release date, genres, styles, barcodes, and the credits the mapping can use.
      Per track: position, title, duration, track artists and credits; headings and sub-tracks
      kept with their type so the matcher can fold them. Per artist: name and name variations.
      Per label: name. Folded keys (lowercased, accents and a leading "The" dropped, `&` as "and",
      `Artist (2)` suffixes and edition words in brackets removed, punctuation and spaces
      removed; the folding the 2026-11-06 coverage count used) indexed for
      artist plus title, barcode, and label plus catalog number.
- [ ] **51.6 Tests.** Small fixtures in the dump's format: a release with every optional element
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

- [ ] **51.7 Candidates.** For each album, in order: its release id (refresh); barcode; label
      plus catalog number; folded album artist plus title against masters and against releases
      without a master. Titles are also tried with a leading `[catalog number]` or trailing edition
      words removed (music-recommender's prototype found 390 library titles with the first).
- [ ] **51.8 Scoring.** Each candidate scored on track count, the tracklist (folded titles
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
      their ids hidden, at least 95% of them should come back Exact or Likely with the same
      release, and none Exact with a different one.
- [ ] **51.9 Tests.** Albums from fixtures against a fixture catalog for each tier, the tie-break
      order, bonus and hidden tracks, multi-disc sets, vinyl positions, sub-tracks, and
      `Artist (2)` and ANV names.

#### 51d. The mapping and the window

- [ ] **51.10 Field mapping.** A list of Discogs fields, release-level and track-level, as
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
- [ ] **51.11 The window.** Toolbar: source (Local catalog; API and Both are shown disabled
      until 52), scope (whole library, the albums selected in the library window, or only
      unmatched albums), Analyze, Field Mapping…. A tab per tier with its count; each tab is an
      album list. The selected album shows the chosen release (artist, title, label, catalog
      number, country, year, format) and, side by side, the album's tracks against the release's
      with each row marked matched, different or missing. "Other Releases…" lists the
      candidates with filters by artist, title, country, label and format (YATE's release
      list), and choosing one rescores the album. For Likely and Incomplete albums, the rows
      can be dragged to change which file gets which track (YATE's mapping screen). Analysis
      runs off the main thread with progress and can be stopped.
- [ ] **51.12 Review and apply.** Each album has a "View Changes" sheet: per file and field, the
      current value against the value the mapping writes, with a checkbox each (YATE's import
      screen). "Apply to All in Exact" (and in Likely) opens one confirmation sheet with the
      counts of albums, files and fields changed, then writes through `TagWriter` as a batch with
      the existing progress and undo. Rejected albums and chosen releases are remembered in the
      index, so a second session doesn't redo the review. Nothing is written before the user
      confirms, and an ADR records that one confirmation for a reviewed match set is the
      confirmation AGENTS.md's music files boundary asks for.
- [ ] **51.13 Budgets.** Rows for the import's time and the catalog's size, Analyze over the
      whole library, one album's candidates, and opening the window, measured on fixtures and
      on the real catalog on this Mac. On a Mac without a catalog (the 2015 MacBook Pro) the
      window says so and offers the import; nothing falls back silently.
- [ ] **Owner check:** import the 2026-11-01 dump, analyze the whole library, review the Exact
      tab, apply it, and check a few albums' tags in YATE.

#### 51e. An import that resumes

Asked for by the owner on 2026-11-07, after the first real import trapped at 76% of the
releases (a duration too long for an `Int`, fixed in `72960469`) and had to start over.

- [ ] **51.14 Checkpoints.** A table in `<catalog>.importing` holds the dump date, the files
      finished, and for the current file the last record committed, its compressed and bit
      offsets, the last 32 KB inflated (zlib's `zran.c` access point) and the SHA-256 state
      (CommonCrypto's `CC_SHA256_CTX`, since CryptoKit's can't be saved). Written in the same
      transaction as its batch, every few minutes of input, so a checkpoint always matches the
      rows.
- [ ] **51.15 Resume.** An import that finds a `.importing` file of the same dump date carries
      on from its checkpoint: it seeks to the offset, restores the inflate state with
      `inflatePrime` and `inflateSetDictionary` and the hash, and goes on; one of another date,
      or without a checkpoint, is removed and the import starts over. The window shows
      "Resume Import" and "Start Over" after a stop, a quit or a crash. The hash still covers
      every byte, and the swap is unchanged.
- [ ] **51.16 Fuzzing the dump parser.** A `DumpParser` target in `Tools/Fuzz`, so a record that
      traps is found on fixtures, not 20 minutes into a real import: Swift can't catch a trap.
- [ ] **51.18 Name variations.** `title_keys` also holds each release's and master's artist
      ANVs, so an album tagged with one is found by title, not only by its barcode or catalog
      number (found in 51c's tuning; the owner chose 51e on 2026-11-07, as it reimports anyway).
- [ ] **51.17 Tests.** A stop and a crash (a killed child process) at each stage, resumed to a
      catalog identical to an import run straight through; a checkpoint from another dump date;
      a damaged checkpoint; the bench's fixture import stopped halfway and resumed.

### 52. Discogs API

- [ ] **52.1 The token.** An optional Discogs personal access token, the player's first secret:
      an ADR, the AGENTS.md "no secrets" line rewritten for it, kept only in `config.json` at
      mode 0600, never copied elsewhere.
      Without a token the API is used unauthenticated, within its lower rate limit.
- [ ] **52.2 The client.** Search and release requests, paced by the rate-limit headers, with a
      size cap, a timeout and typed errors, cached in the index by release id. ADR 0025 gains
      rows for the app's first outbound internet connection. Tests use recorded JSON, never the
      real API.
- [ ] **52.3 Sources.** The window's API and Both: Both searches the catalog first and the API
      for albums with no candidate or releases newer than the dump. The matcher and the mapping
      are the same for both.
- [ ] **52.4 Artwork.** The dumps have no images; with a token, the mapping's Artwork field
      fetches the release's primary image and writes it as the cover through `TagWriter`.
- [ ] **Owner check:** the same with the token, on this Mac and the 2015 MacBook Pro, which has
      no catalog.

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

## Later

Not phases yet. Each becomes one when the owner asks.

- **Mini player:** a small window with art, transport and seek.
- **Library folder:** files dropped on the window are copied into it
  ([ADR 0124](decisions/0124-drop-files-and-the-library-folder.md)). Keeping it organized by
  album artist when tags change, Move and Consolidate Library move and rename music files,
  which AGENTS.md doesn't allow, so they need an ADR and the owner's go-ahead first.
- **LLM review of incomplete matches:** after phase 51, a model reads an Incomplete album's
  files and its candidates and proposes a release and a mapping, which lands in Likely for the
  user to review. Needs the model, its key and what is sent decided first.
- **Live visualizer (TBD):** a spectrum of what's playing, asked for on 2026-11-05 with phase 45
  and put off. The decoder thread would copy what it decodes into a second ring buffer
  (`Sources/Primitives/RingBuffer`) before the device's ring, so the IO proc and the
  bit-perfect path don't change, and do nothing while no view shows it. The view draws bars
  or a line on a log frequency axis, or a scrolling spectrogram, at the display's rate at most,
  from the track's own samples before any conversion for the device; DoP isn't shown. Bench
  rows for CPU while 24/192 FLAC plays with the view shown and hidden, and an old Mac
  checkpoint.
- **Waveform seek bar:** the analysis pass of phase 45 could also store a waveform per track
  for the seek bar.
- **Compressed sync logs:** asked in phase 44 and answered, not built. The sync design
  (ADR 0038) depends on each log being plain appended lines: a push appends the outbox's tail
  and checks that the file is a byte prefix of the outbox, a push that died mid-line continues
  from the file's size, and a reader resumes at a byte offset after the last whole line.
  Compressed, each push would append a gzip member (concatenated members are a valid gzip
  file); the writer would keep the member boundaries to check its prefix, readers would keep
  compressed offsets at member boundaries and drop a torn last member, and both would need a
  decompressor with caps against a compression bomb. About the size of phase 23's log code
  again, in the code that decides what counts twice. JSON lines compress about 8 to 10 times; a
  million plays are about 110 MB plain, so about 12 MB. Worth it when a log passes a few
  hundred MB; not before.
