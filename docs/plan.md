# Build plan

The work still ahead: phases not yet built, owner checkpoints still pending, and ideas for later.
Agents work through it phase by phase, mostly unattended, and stop only at **hardware
checkpoints**, where the owner has to try something on the DAC Mac, the Denon, a phone, or the
2015 MacBook Pro.

Finished phases, 1 to 52 apart from 10 and 13, are in [plan-archive.md](plan-archive.md), with
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
- **52** ([phase](plan-archive.md#52-discogs-api)): API and Both with the token on this Mac and
  the 2015 MacBook Pro, a cover with Cover Art on, and the first launch asking no rescan.
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
