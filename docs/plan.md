# Build plan

The work still ahead: phases not yet built, owner checkpoints still pending, and ideas for later.
Agents work through it phase by phase, mostly unattended, and stop only at **hardware
checkpoints**, where the owner has to try something on the DAC Mac, the Denon, a phone, or the
2015 MacBook Pro.

Finished phases, 1 to 51 apart from 10 and 13, are in [plan-archive.md](plan-archive.md), with
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

1. Phase 51, then 52, then 53 (set by the owner on 2026-11-07).
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

- **51** ([phase](plan-archive.md#51-discogs-tagger)): 51d, import the dump, analyze, apply
  the Exact tab and check tags in YATE; 51f, a smart playlist of one style and the Mood column;
  51g, the help, Save As, a mapping exported and imported, the editor's buttons; 51h, the next
  build that changes the index, the tagger on a selection, a sheet reopened, Undo Tag Edit
  after a tagger write on the NAS, and 51.39's `xattr` output.
- **Window benchmarks** ([51h's Result](plan-archive.md#51h-the-tagger-second-pass)): the 11
  window rows of `./scripts/bench` hang in an agent session; run them on this Mac.

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
| List a smart playlist of four "has" and "doesn't have" rules, one on each list field, over every fixture track (p95; phase 51f); the old Mac figure is an estimate until its checkpoint | < 50 ms | < 150 ms |
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
| The same import stopped past halfway, then resumed: to the stop plus the resume (51.17); the old Mac figure is an estimate until its checkpoint | < 6 s | < 24 s |
| The catalog of that fixture dump (phase 51b) | < 60 MB | < 60 MB |
| Analyze 2,000 albums of that fixture dump, found by artist and title or by label and catalog number, ids hidden (51.13); the old Mac figure is an estimate until its checkpoint | < 2 s | < 8 s |
| One fixture album's candidates, matched and listed as Other Releases lists them (median of 20; 51.13); the old Mac figure is an estimate until its checkpoint | < 5 ms | < 20 ms |
| Open the Discogs tagger, to its window on screen with its catalog checked (median of 5; 51.13); the old Mac figure is an estimate until its checkpoint | < 100 ms | < 400 ms |
| The real import, the 2026-11-01 dump read from the NAS on this Mac (51.13: 1,530 s, 635 MB peak footprint, 1.9 GB most resident); the old Mac has no catalog, and its window offers the import | < 30 min | none |
| The real catalog of that dump (51.13: 35.89 GB) | < 40 GB | none |
| Analyze on the real catalog, per album and for the owner's 1,741 albums with a release id, ids hidden (51.13: 4.1 ms, 7.2 s) | < 10 ms, < 15 s | none |
| One album's candidates on the real catalog, matched and listed, warm (51.13: 15.7 ms for the median of five albums; 167 ms, 437 ms cold, for The Dark Side of the Moon's 1,555 releases) | < 50 ms; < 1 s for the most releases | none |
| Open the Discogs tagger on the real catalog (51.13: 33 ms, 79 ms the first time) | < 100 ms | none |

## Phases

Phases 10 and 13 are from the original plan and haven't been built.

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

### 53. Library, browser and settings

From the owner's testing on 2026-11-07. ADRs numbered when it starts, after 52's.

- [ ] **53.1 Show in All Music.** In any list but All Music, a command in the track menu and
      the View menu, ⌥⇧⌘A, switches to All Music with the selected tracks selected and
      centered, the keys in the track table.
- [ ] **53.2 Drag files out.** Track table and timeline rows also carry the files' URLs, so a
      drag to the Desktop, a Finder window or another app hands it the files. Outside the app
      the drag offers copy only, so Finder never moves a library file (an ADR beside the music
      files boundary). Drags within the app are unchanged.
- [ ] **53.3 Every picture in the art viewer.** When a file holds more than one picture, the
      art viewer steps through them, by arrow keys and buttons, showing "2 of 3" and the
      picture's type (front, back, other).
- [ ] **53.4 A Config group.** General's config file rows move into a sunken group titled
      Config, as Library's are.
- [ ] **53.5 The database in Library.** The Library group shows the index's path, its size
      (the database and its `-wal`), and a Reveal in Finder button.
- [ ] **53.6 Snapshots.** Once a day, on the scan queue when it's idle (never during a scan or
      sync), `VACUUM INTO` a temporary file, compressed with gzip (the zlib already linked)
      to `library-YYYY-MM-DD.sqlite.gz`. It keeps the last 7 daily snapshots and one for each of
      the 4 weeks before them, and deletes older ones. The folder is a setting, defaulting to
      `Backups` beside the index in `~/Library/Application Support/MusicPlayer`. A folder inside a watched folder or the sync
      folder is refused (AGENTS.md). Only the library index is kept; the Discogs catalog is
      imported again instead. Settings shows the last snapshot's time, and a Back Up Now button.
      An ADR.
- [ ] **53.7 Restore.** Settings lists the snapshots, with date and size. Restore… confirms,
      snapshots the current index first, and relaunches with the chosen one in its place.
- [ ] **53.8 The Extras tab.** The tag editor gains an Extras tab: every key the reader found
      that has no field of its own (custom keys, `TXXX`, MP4 freeform), key and value, in one
      scrolling list, read only, selectable and copyable. With several files selected, a key
      that differs shows as mixed.
- [ ] **53.9 Tests.** The command's enabled rule and what it selects; a drag's pasteboard
      holds the URLs and a copy-only mask outside the app; the viewer over a fixture with three
      pictures; snapshot naming, rotation over a simulated 60 days, a gzip that opens as the
      same database, and a refused folder; a restore round trip; Extras over FLAC, MP4 and ID3
      fixtures.
- [ ] **53.10 Open on Discogs.** A command, Open Discogs Release, in the track menu, the
      palette and the View menu, with a shortcut free in the registry. It's enabled when the
      selected track has a Discogs release id, and opens its page in the browser, the URL
      from `ReleaseFields`'s one builder.
- [ ] **53.11 A Discogs tab in Get Info**, shown when the files have a Discogs release id: the
      release as the local catalog has it (label and catalog number, country, date, format,
      genres, styles, credits, tracklist), read only and copyable, with Open on Discogs. A
      release the catalog doesn't have, or no catalog, says so. Files from several releases
      show the first and say how many.
- [ ] **53.12 Shorter headers.** Track of Total's header reads "Track No.", and Disc of Total's
      "Disc No."; the header menu and the smart playlist fields keep the full titles. Both
      titles defined once, beside the others in `TrackColumnTitle`.
- [ ] **53.13 Re-releases as albums of their own.** An album is its title and artist
      (`albums_identity`), so a 2025 remaster titled as the original merges with it, two
      track 1s interleaved. A setting, Separate Releases, adds the Discogs release id to an
      album's identity when its tracks have one, so the two are two albums, each sorted by its
      own year. Changing it rebuilds the albums part, with 51.32's dialog. An ADR.
- [ ] **53.14 The palette keeps its query.** ⌘K opens with the last query, selected, so typing
      replaces it and Return runs the same command again; ⌘K while open clears it. As Sublime
      Text's.
- [ ] **53.15 Tests.** 53.10's enabled rule and URL; the Discogs tab over a fixture catalog and
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

## 53a. Browser and tag editor (53.1, 53.2, 53.3, 53.8, 53.12, 53.10, 53.11, 53.14)

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

## 53b. Settings and snapshots (53.4, 53.5, 53.6, 53.7) (ADR 0142)

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

## 53c. Separate Releases (53.13) (ADR 0143)

Modules: Library (schema, `LibraryIndex`), Settings, SettingsWindow, App. Depends on 51h's
rescan dialog. Runs after 53a and 53b are merged because it changes `LibrarySchema.swift` and
the dialog's table.

1. **Schema.** `albums` gains `release_id TEXT NOT NULL DEFAULT ''`; the index becomes
   `albums_identity ON albums (title, ifnull(artist_id, 0), release_id)`. `AlbumKey` and the
   `albumIDs` cache include it. The setting does not change the SQL text, so the stale-part
   check can't see it. Decision: `indexSchema` takes the option: `SchemaPart.sql` becomes
   `sql(separateReleases:)`, and the index part's stored SQL carries a first line
   `-- separate releases: on|off`, so a change is a stale `index` part and takes the existing
   rebuild path (drop, recreate, rescan refills; stats, `scans` and the rest kept as for any
   index change). `LibraryIndex.init(at:separateReleases:)` passes it; `prepareSchema` and
   `rebuildStaleParts` use it. Every `LibraryIndex(at:)` caller (AppDelegate, ScanCommand,
   tests, tools) is updated; tests default to off.
2. **Insert.** `insertTrack` passes `tags.discogsReleaseID` (the string, trimmed) as the
   album's release id when the option is on and the track has one, else `''`. Tracks with no
   release id still merge with each other and with nothing else, which is intended: an
   untagged copy of an album stays one album.
3. **Setting.** `AppSettings.separateReleases: Setting<Bool>` `library.separateReleases`,
   "Separate Releases", default false (existing libraries unchanged), summary: "Make an album
   of each Discogs release, so a remaster tagged with the original's title is its own album,
   sorted by its own year." Shown in the Library box by prefix; also a File-menu setting
   toggle beside `groupByAlbumArtist`.
4. **Applying it.** The index is opened once at launch with the option, so a change is applied
   at the next launch: the toggle in Settings shows the 51.32 dialog's wording at once
   ("Rescan Now" quits and relaunches into the rebuild; "Cancel" reverts the toggle). Rebuild
   through the same path as a build's schema change, so the status bar says it's a rebuild.
   The dialog's per-part wording table (51.32, in words kept once with the part) gets an entry:
   the albums are grouped differently, every file is read again, plays, ratings and playlists
   stay. The reason sentence is chosen by whether the option went on or off.
5. **Sorting by year.** Album ordering is `sort_title` then track fields; two albums with one
   title now interleave by album id unless ordered. The album sort in `BrowserGroupingSQL` and
   `TrackColumnSort` adds the album's earliest track year as the tie-break after title, so
   each release stays together and the older sorts first. Test for this order.
6. **Tests.** `LibraryTests`: an original and a 2025 remaster with the same title and artist,
   different release ids: one album off, two on; tracks of each stay with their own; sorted
   by year; a track without an id joins the album off and stays alone on; flipping the
   option changes the stored SQL and rebuilds only the index part (stats kept); the dialog
   text for each direction (`SettingsWindowTests`).
7. **ADR 0143:** an album's identity with the option, why a setting not a rule, why the
   release id and not the master, the rebuild.

Commits: 1 schema and option plumbing; 2 insert and sort; 3 setting and dialog; 4 tests; 5 ADR.

## 53.9 and 53.15 tests

Spread across the sub-parts as above; each commit carries its tests. 53.15's last item
(palette) is in 53a, the rest as listed. `./scripts/test --changed` per commit; one
`./scripts/check` at the end of each sub-part. The check steps that read the diff: format,
build, tests, `arch` (new `Snapshot` module and the tier map), `surface` (`public` only where
another module calls), `dupes` (the three new strings: file-name format, "Reveal in Finder"
which exists once in `GeneralPane` today and moves with the Config group, and the 53.8/53.11
messages), and a docs check if ADR files are linted.

## Owner check

As the plan says: each in the running app, a snapshot restored, a remaster beside its
original, the palette's kept query; plus a drag of a track out to the Desktop (a copy) and to a
Finder window on the NAS share (still a copy).

## Decisions made here

- Palette query lives for the app session, not on disk.
- Snapshot folder is a plain path, no network share.
- Restore swaps the file at the next launch, not live.
- Separate Releases is applied at the next launch with the dialog, default off.
- Extras lists every key the reader holds in `custom`, including ones other tabs show.
- Open Discogs Release goes where Show Album is (the File section), with `⇧⌘D` if free.

## Needs the owner

1. **Open Discogs Release's shortcut and the View menu.** The app has no View-menu section
   holding track commands; the track commands are in File. Confirm File, or say which menu.
2. **Separate Releases for tracks with no release id** stay merged with each other. If the
   owner wants them kept apart from a tagged release of the same title (they are today only
   by the id differing), that is already so; confirm no third behavior is wanted.
3. **Restore also restores plays and ratings** (they live in the index file). That is what a
   restore is, but say so in the dialog; confirm the owner wants the whole file and not the
   index part only.

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
