# Build plan

The work still ahead: phases not yet built, owner checkpoints still pending, and ideas for later.
Agents work through it phase by phase, mostly unattended, and stop only at **hardware
checkpoints**, where the owner has to try something on the DAC Mac, the Denon, a phone, or the
2015 MacBook Pro.

Finished phases, 1 to 53 apart from 10 and 13, are in [plan-archive.md](plan-archive.md), with
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

1. Phases 51, 52 and 53, set by the owner on 2026-11-07, are done.
2. Phase 54 runs on its own branch (set on 2026-11-08), and waits there for the owner's review.
3. Phases 55 to 61, the owner's feedback of 2026-11-09, run next: 55 and 58 (done) first, then 56,
   57 and 59, then 60 and 61. All seven are done. Each merges to `main` when its gate passes.
4. Phases 62 to 66, the owner's feedback of 2026-11-09 (second list): 62, 63, 64 and 65 in
   parallel, each on its own branch and worktree, then 66. All five are done.
5. Phase 67, the owner's matcher feedback of 2026-11-09, is done.
6. Phases 68 to 72, the owner's feedback of 2026-11-09 (third list): 68, 69, 70 and 71 in
   parallel, each on its own branch and worktree, then 72, which builds on 69's tagger.
7. Phases 10 and 13 wait. Phase 10 adds pairing tokens, a secret, so the owner decides how
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

- **66** ([phase](plan-archive.md#66-artwork)): the Artwork tab on scratch MP3, FLAC and M4A
  copies, the viewer's strip, Get Artwork's Fill Missing and Replace.
- **64** ([phase](plan-archive.md#64-downloads-approve-upgrades-open-in-tagger-window)): a
  manual download replacing an album on the NAS (scratch album), the window's frame and
  columns on a second display, Open in Tagger on a discrepancy.
- **63** ([phase](plan-archive.md#63-a-library-pane-in-settings)): Snapshots opened and closed
  leaves no gap; the Library pane's rows and the palette opening it.
- **65** ([phase](plan-archive.md#65-tagger-confidence-and-the-safe-set)): the Match column,
  the Safe tab and Apply to All in it, a choice in API mode sending no search.
- **62** ([phase](plan-archive.md#62-small-fixes-palette-saving-status-quit-guard)): the quit
  guard's three answers, the saving total with a second batch queued, `a:` and `t:`.
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
- **53** ([phase](plan-archive.md#53-library-browser-and-settings)): each part in the running
  app, a snapshot restored, Separate Releases with a remaster beside its original.
- **Window benchmarks** ([51h's Result](plan-archive.md#51h-the-tagger-second-pass)): the 11
  window rows of `./scripts/bench` hang in an agent session; run them on this Mac.
- **55** ([phase](plan-archive.md#55-windows-and-settings)): the owner steps under its Result
  line, on the two-display Mac.
- **58** ([phase](plan-archive.md#58-tagger)): the owner steps under its Result line.
- **56** ([phase](plan-archive.md#56-browsing-and-the-keyboard)): the owner steps under its Result line.
- **57** ([phase](plan-archive.md#57-get-info)): the owner steps under its Result line; delete
  `"tagEditor.place"` from `state.json` first.
- **61** ([phase](plan-archive.md#61-tagging-preferences-in-settings)): the owner steps under its
  Result line.
- **59** ([phase](plan-archive.md#59-downloads)): the owner steps under its Result line.
- **60** ([phase](plan-archive.md#60-keep-files-organized)): the owner steps under its Result
  line, on a scratch copy first.

### Answers

- **38.11 Tag-write error** ([phase](plan-archive.md#38b-table-navigation-and-palette-adr-0088)):
  the error text.
- **39** ([phase](plan-archive.md#39-owner-feedback-2026-11-03-evening)): whether selected rows
  show their row line, and whether "the first column on the right" counts from the center, as
  now, or from the window's edge.

## Phase gate

Run after every phase, before ticking it off.

- [ ] **Gate:** `./scripts/check` passes. In an agent session `theGlassHeadersAreFrosted` fails
      on main too (the screen reads back as 0), so it alone doesn't fail the gate.
- [ ] **Code review:** `/code-review high` on the phase branch. Fix confirmed findings in
      their own commits, then rerun the review until it finds nothing new above low severity.
- [ ] **Simplify:** `/simplify` on the same branch. Look especially for duplication across modules
      and for abstractions with one caller.
- [ ] **Performance audit:** `./scripts/bench` against the budgets in
      [Performance budgets](#performance-budgets). A budget miss blocks the phase. A regression
      over 10% against the last recorded result needs a fix or a written reason in the Result
      line. In an agent session the window rows that quit the app (launch, scrolling, page
      down, resize, row height) hang in `terminate:`, each for its 300 s timeout: leave them out
      by name and list them for the owner's Mac. Rerun a row that misses alone before calling
      it a miss; a full run's load can push a row past its budget.
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

### 54. Soulseek imports

Albums found and downloaded on Soulseek, tagged from a known Discogs release, and imported only
after the owner reviews them. The owner asked: "if the album is new from soulseek we can
automatically write the tags", and "nothing should be imported into the real full music
tracklist until manually reviewed and approved". The service (`~/projects/music-recommender`
on mbp2021) searches and downloads with slskd, which only it talks to, and copies each finished
album into a staging folder on the NAS; its design is
`~/projects/music-recommender/docs/downloads.md` and its contract `docs/api.md` there (both on
its branch `phase/5-soulseek` until the owner merges it). The player tags staged albums, lists
them in a Downloads window, and moves them into the library on Approve.

Runs on the branch `phase/54-soulseek-imports`, which `main` doesn't take until the owner has
reviewed it. 54.1 is docs only and came first, so the owner read the boundary changes before
code depended on them; then P0.1, P0.2 and 54.2 onward in order. P0.2 and everything after it
need the service's `docs/api.md`. ADR numbers: 0144 to P0.1 (the service token, the app's
second secret, kept as ADR 0137 keeps the Discogs token), 0145 to P0.2 (the client), 0146 and
0147 to 54.1, 0148 to 54.4 (the player's copy of the matching rules). The owner approved ADRs
0144 to 0147 on 2026-11-08, and AGENTS.md carries their wording.

The branch was merged with `main` on 2026-11-08, and its ADRs renumbered to 0144 to 0148 to
follow main's 0143. The merge made the service token follow main's secret rule (ADR 0137):
`config.json` only, every write mode 0600, a token in a file others can read not used. A staged
job's tagger writes no cover art and is fixed to the local catalog, and the staging folder is
refused when it overlaps the snapshot folder (ADR 0142).

Settled on 2026-11-08. The owner asked for the feature in the words above and chose who talks to
slskd, staging on the NAS with a move on Approve, and the upgrade's trash; the orchestrator
settled the rest while the owner was away, for the owner's review with the branch:

| Question | Answer |
|---|---|
| Who talks to slskd | The service only, holding its API key; the player talks to the service by an IP address and a port set in Settings and a bearer token set in `config.json` only, with no field in Settings. No Bonjour yet |
| Staged tag writes | Automatic after a clean match (tier Exact, no unmapped file, the player's mapping agrees with the service's); a discrepancy writes nothing until resolved in the tagger (ADR 0146) |
| Approve | The confirmation for the move into the library: staged files are renamed into the library folder (ADR 0147) |
| Upgrade | The old files go through `moveToTrash`, which on the NAS deletes them, and their stats move to the new files (ADR 0147) |
| Reject | The service deletes the staged folder |
| Staging folder | `/Volumes/music/staging` on the player Macs, beside `library` on the same share: a setting, and the service reports each job's folder relative to it |
| Queueing | Manual only: library albums with a release id, or a pasted Discogs release id or URL found in the local catalog. Recommendations are later |
| Formats | `flac` (the default), `lossless`, `mp3_320` (CBR 320 or V0), `any`. Never 24-bit over 16-bit; no hi-res upgrades. An upgrade always asks for a lossless format |
| Several Macs | A tagging lease of 10 minutes and a review claim of 24 hours. Rows are gray through `downloading`, opaque from `downloaded` |
| Undo | Staged writes have a journal of their own, for crash recovery, and stay out of Edit > Undo |

The job's lifecycle, the claims and the API are the service's (its `docs/api.md`); the player
holds a strict Swift copy of the state table and what it did to the library. Nothing here
touches real Soulseek, slskd, the library or the NAS: the service is a loopback stub with
recorded replies, and staging and the library are temporary folders and `SimulatedNAS`.

#### 54a. The service client

- [x] **P0.1 Settings.** `recommender.address` (an IP literal; a host name is refused),
      `recommender.port`, `recommender.token` and `import.stagingFolder` (a share and a path,
      the shape of `library.watchedFolders`, ADR 0028). The token is kept as the Discogs token
      is (ADR 0137): only in `config.json`, every write mode 0600, never logged, shown in a
      problem's text or copied elsewhere. The staging folder is refused inside a watched folder,
      the library folder, the sync folder or the snapshot folder, and checked again whenever any
      of them changes. ADR 0144. Tests: each refusal, a folder change that would hold the
      staging folder, the token in no printed form or problem, a loose file's token not used.
      Result: address, port and staging folder are in the Downloads box of the General pane; the
      token is file-only by the owner's decision, with no field in Settings (`SettingKind.secret`),
      and the Downloads window's not-set message says where it goes. `ServiceToken` prints as
      `<service token>`. ADR 0144 accepted on 2026-11-08.
- [x] **P0.2 Client.** A new `Core/Recommender`: `post` with the bearer header on
      `LocalHTTPClient` (no change to the client beyond what `post(… fields:)` allows), strict
      models for `ping` and the config route, typed errors (unreachable, 401, 400, `ok:false`,
      oversize, unknown state) naming the address tried. A fuzz target. ADR 0145. Tests on the
      loopback stub with recorded replies.
      Result: `RecommenderClient` posts with the bearer and JSON fields, `keepingRefusals`, to
      another device's address on a local subnet (`ping` and `downloadsConfig` were removed
      once nothing but tests called them); errors name the
      URL, never the token. `LocalURL(host:port:path:on:)` is the one `LocalNetwork` change.
      Replies decode with every field present and none unknown. ADR 0145 accepted, its threat
      model row is row 65 of ADR 0025. The `recommender-reply` fuzz target came with 54.2, to run
      every reply shape: 60 s, 108k inputs, no crash.

#### 54b. Tagging staged albums

- [x] **54.1 ADRs.** ADR 0146, staged tag writes: `TagWriter` writes staged files once, after a
      clean match, with no confirmation of its own; a fixed overwrite mapping, a second journal,
      a guard that refuses any path outside the staging folder. ADR 0147, the move into the
      library and the upgrade's order, with the trash-on-SMB rule (the NAS has no Trash, so the
      upgrade's delete is permanent). Each gives its AGENTS.md wording. Docs only.
      Result: ADRs 0146 and 0147 accepted on 2026-11-08, and AGENTS.md's music files bullet has
      their clause and sentence.
- [x] **54.2 Job calls and the snapshot.** The downloads routes in `Core/Recommender` (create,
      list with epoch, reset and paging by revision with `more`, retry, cancel, handoff);
      `Core/Discogs/ReleaseSnapshot.swift`, built from `CatalogRelease` with both
      `ReleaseTracklist.flattenings`; a release not in the local catalog refused at queue time.
      Tests on the loopback stub and a temporary catalog.
      Result: typed `create`, `retry`, `cancel`, `handoff` and `refreshed`; an upgrade's order
      takes only `flac` or `lossless`. `DownloadJobs.take` pages by the last job's revision,
      drops every row on a reset wherever it comes, and refuses a page that doesn't advance.
      Positions the service can't take are refused at queue time: an index track without one
      takes its parts' joined with "+", a list with none is numbered, anything else is refused.
      Fixtures from the service's `api.md` examples.
- [x] **54.3 Library.** `import_jobs` as a schema part of its own (an outbox of reports, a ledger
      of steps, cached edits), `LibraryIndex.upgradeCandidates()` (albums whose every track has a
      release id and is lossy), an album's library-share-relative paths and quality. The scanner
      skips the staging folder, with a test. Tests on a temporary index.
      Result: `import_jobs` (`import_outbox` and `import_steps`, keyed by job id, release id and
      folder-relative paths, kept by an index rebuild); every scan passes over the found staging
      folder, a watched folder inside it isn't scanned, and a sync folder found in or around it
      is refused (`stagingOverlap`, the found-path check ADR 0144 deferred; the library folder's
      turn is 54.6's move). `upgradeCandidates(onShare:)` lists the albums whose every file is
      AAC or MP3, carries one numeric release id and lies in a watched folder on the share, each
      with its paths relative to the share (from `share_roots`) and its quality ("MP3 320
      kbps", the average bit rate less the art). No cached edits: AutoTag works the edits out
      from the files on every run, and a takeover reruns from the read (design step 7), so
      there is nothing to cache; see 54.4.
- [x] **54.4 StagedAlbum and AutoTag.** `Core/Discogs/{StagedAlbum,AutoTag}.swift`, without
      writing: `readAlbumFiles` on the staged paths with synthetic negative ids; a missing or junk
      title filled from the file name; `matchAlbums(choosing:)` on the job's release; clean or a
      discrepancy with reasons from `comparison(of:)`; the edits from a fixed overwrite mapping.
      ADR 0148 records the player's copy of the matching rules and the SHA-256 of
      `rank-golden.json`, which a test asserts. Tests: exact and clean, wrong title, a missing
      track, 40 s off, an extra file, an unreadable file, DSD, untagged titles.
      Result: `autoTag` runs design steps 1–5 and 7 without writing: `StagedAlbum` reads the
      job's files with ids from -1, refusing a missing file, one over 2048 MB or one whose size
      isn't the service's; fills a missing or junk title from the file name as the service reads
      it; drops any uploader's release id; and orders by tags, else the names' leading numbers,
      else the names. `matchAlbums(choosing:)` on the release; clean is Exact, every file mapped
      to the position the service reported (`ReleaseSnapshot.positions`), each file's codec the
      candidate's format (an AAC `.m4a` taken for ALAC is a discrepancy) and every file
      writable, else a discrepancy with reasons from `comparison(of:)`. The edits come from
      `DiscogsMapping.overwriting()`. Edits aren't cached (54.3): every run works them out
      from the files. ADR 0148: the matcher's titles now fold with the service's Latin table
      (`CatalogKey.matchKey`), which agrees on all 56 fold, 16 similarity and 7 score cases;
      the Foundation fold missed 7 and 2. Catalog keys stay on Foundation. 11 AutoTag tests,
      each check also caught by a mutation.
- [x] **54.5 StagedWriter.** `Core/Discogs/StagedWriter.swift`: `TagWriter.write` with a second
      `TagUndoJournal` in its own folder and a write closure that doesn't call the watcher, the
      staging folder guard, a read-back that must find no changes. Tests: a path outside staging
      refused, the main journal untouched (undo after a staged write reverts the library edit
      before it), a staged file never in the index.
      Result: `StagedWriter` writes a clean run's edits through `TagWriter` with a journal in
      `staged-tags/tag-undo` under the data folder and tells no watcher; every path is resolved
      with `realpath`, links included, and the whole run is refused (`StagedPathRefused`)
      before any write if one is outside the staging folder or missing. The files are then
      read back and the overwrite change set must be empty. Its `write(_:)` is the closure the
      staged tagger (54.11) will use. Nothing calls it yet, so no staged file is written until
      54.10 wires it, ADR 0146 being accepted. 5 tests; the guard and the journal's folder
      each caught by a mutation.

#### 54c. Approve

- [x] **54.6 Move into the library.** `Core/Library/LibraryFolderMove.swift`: every destination
      checked before any moves, `renamex_np(RENAME_EXCL)` with an `lstat` and `rename`
      fallback on `ENOTSUP` or `EINVAL`, the same volume required, sources only inside the
      staging folder and destinations only inside `library.folder`, a ledger entry per file.
      Tests on temporary folders and `SimulatedNAS`: a collision refuses the album, another
      volume refused, the fallback, each guard.
      Result: `LibraryFolderMove.moveIn` works out every destination from the staged files'
      tags (`libraryFolderPath`) and refuses the whole album, moving nothing, when one is taken
      or two files share one, or a file isn't the staged size or doesn't read. It records every
      file's destination and size in the ledger, relative to the share, before the first
      rename, so a resumed run takes them from there once the staged files are gone and the
      file system says which are done. `renamex_np(RENAME_EXCL)`; on `ENOTSUP` or `EINVAL` an
      `lstat` and `rename(2)`, logged. Staging and the library folder resolved with links
      followed, on one volume (`st_dev`, and `EXDEV`) and apart (`stagingOverlap`, the check
      54.3 left here); sources inside staging and destinations inside the library folder,
      checked again on every rename. The file system calls are a `MoveCalls` value tests
      replace; `SimulatedNAS` stands in for a scan's reads, not renames, so the tests use
      temporary folders. 13 tests; each guard, the fallback's `lstat` and both size checks
      caught by a mutation. Nothing calls it until ADR 0147 is approved.
- [x] **54.7 Upgrade mapping and stats.** `Core/Library/UpgradeMapping.swift` (old tracks to new
      through the release's track index; the ones with no counterpart listed);
      `LibraryWatcher.importMoves(lines:)` and a `MoveList` from lines. Tests with a temporary
      index and stats, including `forgetTrashed` then `importMoves`.
      Result: `UpgradeMapping` pairs old and new files by release position; the old files with
      no counterpart are listed with whether they have stats. `upgradeOldFiles` finds the job's
      share paths in the index and refuses one not there or no longer tagged with the release.
      The old album's positions come from `upgradePositions` in `Core/Discogs`
      (`matchAlbums` with the release chosen, named as the snapshot names them; a release the
      catalog lacks is refused, since the matcher would pick another). `importMoves(lines:)`
      builds `MoveList(moves:)` through the same parser and runs on the scan queue; plays, a
      rating, a love and a playlist entry move, and the move is in the sync log, with and
      without `forgetTrashed` first. `moveToTrash` and `TrashOutcome` are public;
      `scripts/surface` flags `moveToTrash` until 54.14 calls it from `App`. 10 tests.
- [x] **54.8 Approve flow.** The import steps as an idempotent state machine over the ledger and
      the outbox, for a new album and an upgrade. The lossy-origin check calls `analyzeFile(at:)`
      and `verdicts()` on the staged files when the Approve sheet is built, never `FileAnalyzer`
      or `MeasuresCache`, so no staged path enters the index; after the move the upgrade only
      re-reads tags, sizes and the file count before it deletes the old files. `moveToTrash`
      and `TrashOutcome` become public in `Features/LibraryBrowser` and reach the coordinator
      as a closure. Resume, and Resume Here for a job another Mac left. May split into 54.8a
      (new album) and 54.8b (upgrade). Tests: a failure injected at each step and resumed, the
      outbox replayed, a truncated moved file refused before the delete, an old track with no
      counterpart blocking, stats on the new tracks and the moves in the sync log.
      Result: one `ImportRun` for both kinds, in `Core/Library`, which now depends on
      `Recommender` for `JobState` and `HandoffEvent` (both `package`) rather than repeat the
      stage names. It queues `approved` (from `staged`) and `importing`, moves the files in,
      and for an upgrade reads each moved file again (tags, size, count), records the old files
      and their pairs in the ledger, gives the ones still there and still of the release to
      the trash closure, judged by the files being gone, carries the stats through the
      `importMoves(lines:)` closure, then rescans and queues `imported`; a failure queues
      `failed` with its stage. Reports are deduplicated against the outbox, a run drops a
      `failed` its predecessor queued and never sent, and a run after `imported` only answers.
      The ledger stays until the outbox's sender forgets it (54.10). The lossy-origin check is
      `stagedOrigins` in `Core/Analysis`: the first and last staged files through
      `analyzeFile(at:)` and `verdicts()`; `lossyOrigin`, `upsampled` or a file that can't be
      analyzed blocks, for 54.13's sheet. The ledger is in each Mac's own index, so Resume Here
      on another Mac finishes a job whose move hadn't begun; one moved in part is refused,
      saying to resume on the Mac that started it, since the moved files took the tags their
      destinations came from. Tests: a
      new album, an upgrade end to end, the unticked block, a truncated file stopped before the
      delete, a failure at the move, the delete and the carry each resumed, a repeat after
      `imported`, reports cut short before the move, a retagged old file kept; 13 tests, and 4
      for the check; each report rule and guard caught by a mutation.

#### 54d. The window

- [x] **54.9 Model.** `Features/Downloads`: `DownloadsModel` with rows, polling (2 s with the
      window open and a job active, 60 s otherwise) on an injected clock, row styling and
      Approve's enabled rule as pure functions, the service-down state; `Core/Commands`
      entries. Tests against a fake client, styling and gating as tables.
      Result: `DownloadsModel` keeps the service's jobs by epoch and revision (`DownloadJobs`,
      so a reset drops every row) and polls on an injected sleep: 2 s while the window is open
      and a job is moving, else 60 s. Opening the window polls at once; closing it cancels the
      request. "Moving" counts a staged job not yet tagged, so a tag run shows, and leaves out
      `not_found`, whose next search is hours away. A failed poll keeps the rows, dimmed, with
      the error naming the address and the last good poll's time. `DownloadRow`'s rules are
      static functions: dimmed through `downloading` and for a failed search or download (both
      go back to the queue); the tagging label (Pending, Tagging, Clean, Discrepancy, Error,
      with reasons) from `staged` on; "Being reviewed on <Mac>"; Approve only for a staged,
      clean job this Mac has claimed; sections needs review, downloading, waiting, failed,
      newest first; terminal jobs not listed. `downloads.show` (File > Downloads…) is in
      `Core/Commands`, disabled until 54.14 gives it a handler, so `scripts/surface` flags it
      until then. The job's fields the window reads are `package` in `Recommender`. 14 tests,
      8 of them tables, against `FakeService` (the list's paging and `handoff`'s leases and
      claims) and `FakeClock`; each rule caught by a mutation.
- [x] **54.10 Coordinator.** `DownloadsCoordinator`: claims and leases, the tag loop, the outbox
      flush, a stale lease released at launch, the idle poll; clock and effects injected. Tests:
      a claim race, lease expiry, resume, a crash between tagging steps.
      Result: an actor fed each poll's jobs by the model (`took`), so there is one poller, and
      the idle poll is the model's 60 s. At launch it gives up any lease the service lists for
      this Mac, then sends the outbox, then tags one job at a time: staged, no live lease, and
      `none` or `running` (a run that crashed or slept past its lease, rerun from the read). It
      takes the lease (`claimed` leaves the job alone), queues `running`, renews every 3
      minutes, and a renewal refused stops the run before it writes or reports. A clean run goes
      through the injected writer (`StagedWriter`), a discrepancy writes nothing, and the verdict
      is queued and sent while the lease is held, then the lease given up. The outbox goes in
      order: a report refused or a 400 is dropped and listed in `problems`; one unanswered stops
      the send for the next poll to retry; `forgetImportJob` runs only once `imported` is
      answered. `approve` and `resumeHere` (`take_over`) take the review claim, then run the
      import, injected as a closure (App builds `ImportRun` with the trash and the watcher;
      `ImportRun`'s own tests cover the moves), one at a time. `claimReview`, `releaseReview`,
      `reject` and `resolved` (54.11's report) round it out. The coordinator opens its own index
      from the database URL. `HandoffEvent` decodes from the outbox's JSON, refusing any text
      that isn't exactly an event's encoding. 14 tests, no real sleeps: a clean run, a
      discrepancy, no catalog, another Mac's lease taken first, a crash mid-lease at the next
      launch, an expired lease, renewal and a lost lease, a send failing then succeeding and the
      ledger forgotten, refusals dropped, Resume Here, the review claim, reject, a resolved
      discrepancy; 9 mutations each caught.
      Also fixed: AutoTag took the matcher's pick for the job's release, and when the catalog
      lacks the release the matcher picks the best other one; it now requires the job's release.
- [x] **54.11 Tagger entry.** `TaggerModel(stagedJob:)` with staged effects; the tagger opens
      with the release chosen, and an Apply that leaves no changes makes the job clean. Tests
      against fake effects.
      Result: `TaggerModel(stagedJob:effects:mapping:savedMappings:choices:resolved:)`, a
      separate initializer, with `StagedEffects` (read the staged files, match with a release,
      summaries, the catalog's state, and `StagedWriter.write(_:)`). It opens on its one album's
      tier with the job's release chosen; choosing another is refused. Apply writes through the
      staged effects only, never `write`, so the main undo journal and the watcher never see
      it; then the files are read back, and `resolved` hears clean when the mapping would change
      nothing but what the owner unticked, else a discrepancy (`StagedWriter.verdict`, one copy
      with the auto-tag write). A failed write reports nothing and can be applied again. The
      confirmation and status say Edit > Undo doesn't put staged writes back. 5 tests; 7
      mutations each caught. The live `StagedEffects` and a `DiscogsTagger` entry for App come
      with 54.14.
- [x] **54.12 Window.** `DownloadsWindow`: the table (Source, Album, Format, State, Tagging,
      Added), toolbar, context menu, status messages; built on first show. A construction
      test.
      Result: one table of Source (an icon, an upgrade's old quality in its tooltip), Album
      (the release id in its tooltip), Format, State (a progress bar while downloading, "·
      Being reviewed on <Mac>"), Tagging (the reasons in its tooltip), Candidate (the peer and
      size) and Added. Rows through `downloading` are secondary at half alpha, the rest
      opaque; a failed state is red and a warning tagging orange. A bar of Approve…, Reject…,
      Retry, Cancel Download, Open in Tagger and Resume Here, the same items in each row's
      context menu, and Add's menu. `DownloadAction.applies` gates each from the job, this
      Mac, whether the service answers and whether the Mac has a catalog: nothing while it
      doesn't answer, only Resume Here on a job another Mac reviews. The status line says why
      the service didn't answer and when the rows are from, that a Mac with no catalog can't
      queue or tag, and the coordinator's `problems`; with no address or token it says how to
      set the service up. `Downloads` is the entry App starts, stops and shows. Tests: the
      actions as tables, the window's columns, styling, buttons and menu, the status line,
      the window without a service; 11 mutations each caught.
- [x] **54.13 Sheets.** Upgrades, From Library Selection, Paste a Discogs Release, Approve (with
      the lossy-origin and lost-stats acknowledgments, and "permanently deleted if the share has
      no Trash"), Reject. Tests of each sheet's model.
      Result: `QueueSheet` lists `upgradeCandidates(onShare:)` (the staging folder's share;
      none without one) or the selection's albums, those without one numeric release id as
      "Tag first", each with a box, and a format: flac, lossless, MP3 320 or any, an upgrade
      only the first two. Paste takes an id or a discogs.com `/release/<id>` URL. Each
      choice's snapshot comes from `ReleaseSnapshot.queueable`, so a release the catalog
      lacks is refused before anything is sent. Approve… takes the review claim, then
      `ApprovalPlan` lists each move (`LibraryFolderMove.destinations`, the first run's
      checks with nothing moved), an upgrade's old files placed by `upgradePositions`, with
      "deleted permanently" on a share with no Trash, the unmatched ones to tick, and
      `stagedOrigins`' verdicts to acknowledge when they block; it builds `ApprovedImport`.
      Cancel gives the claim back. Reject and Cancel confirm; Retry asks for a format when
      it searches again. The service gains create, retry and cancel. Tests: the plan's
      blockers and import, the sheet's ticks, the pasted id, the selection, the orders, the
      model's calls against `FakeService`.
- [x] **54.14 Wiring.** `App/MusicPlayer/DownloadsCommands.swift`: File > Downloads…, the trash,
      rescan, tagger and write closures; the coordinator starts at launch. Tests: the commands'
      enabled rules.
      Result: File > Downloads… shows the window whenever the main window is up. The downloads
      start after the first rows draw when the address and token are set, restart on a change
      to the service, staging, library folder, catalog or mapping settings, stop when either
      is cleared, and stop at quit. The client is made on each call from the interfaces up
      then. The import gets `moveToTrash(...).failure`, `watcher.importMoves(lines:)` and
      `watcher.rescan`; its places are the staging folder where it's found, its share's mount
      point (else the library folder's volume) and `library.folder`. Open in Tagger opens a
      `DiscogsTagger(stagedJob:…)` with the live `StagedEffects`. This Mac's name is its
      computer name. `--snapshot-of downloads` draws the window. `scripts/surface` passes.
      No test of the command's enabled rule: it is the Discogs tagger's, untested there too.
      Launched on a scratch home with the service at 192.0.2.7, the window said the address
      isn't on a local subnet and that the Mac has no catalog.
- [ ] **Owner checks:** on each reviewing Mac, the service's IP, port and staging folder in
      Settings and the token in `config.json`, the DAC Mac first. On a scratch folder on the share, from the DAC Mac,
      a same-share `RENAME_EXCL` (or the fallback, which the log line names) and a refused
      collision. A new album end to end: queued, staged and clean, approved, in the library. An
      upgrade of an MP3 album copied first: stats, rating and playlists on the new tracks, the
      old files gone. A discrepancy (an album with a bonus track) resolved in the tagger, then
      approved. On mbp2015 the window lists the rows and says it can't queue or tag; with the
      service stopped, its message.
- [ ] **Follow-up:** `Tests/DiscogsTests/Fixtures/rank-golden.json` still says "music-player ADR
      0140", the number before the renumbering. It can change only together with
      music-recommender's byte-identical copy and the SHA-256 in ADR 0148, so fix both Macs'
      repos in one step.

### 68. Organize's progress and the Library Problems window

Asked by the owner on 2026-11-09 (ADR 0164 is Keep Files Organized).

- [ ] **Organize Selected Files opens at once.** The confirmation opens as soon as the command
      runs, counting the tracks and files to rename with live progress, and Cancel works while it
      counts. Its buttons and summary appear when the count is done. A test with a slow counting
      stand-in.
- [ ] **Progress after Organize.** Once confirmed, the status area at the bottom left shows how
      many files are left, progress, and the current file or folder, until the run ends, then a
      one-line result ("Organized 2,340 files; 3 problems"). Library Problems opens only when
      there were problems, as now.
- [ ] **Library Problems is a normal window.** It no longer floats above other apps' windows or
      the app's own; it can go behind them like any document window.
- [ ] **Library Problems as a table.** A standard table like the tagger's album list: a column
      for each piece (the problem's kind, the track or album, the file's path, the folder, the
      detail), sortable by any column, with resizable columns that are remembered, and the
      window's frame remembered (ADR 0158). The problem text is plain enough to act on.

### 69. Tagger columns and the releases window

Asked by the owner on 2026-11-09.

- [ ] **Sort the album list by any column:** a click on Album, Files, Match or Review sorts by
      it, a second click reverses it, and the sort is remembered.
- [ ] **Column widths are remembered** between launches. The owner reports they aren't: find
      why with a test that relaunches the window, then fix it.
- [ ] **The releases window remembers itself.** The sheet or window for choosing a release
      (Other Releases, Look Up) keeps its size, its position where it has one, and its column
      widths and order, like every other window (ADR 0158). This includes the tagger opened from
      Downloads (Open in Tagger).

### 70. Artwork, Settings and Get Info

Asked by the owner on 2026-11-09.

- [ ] **The art viewer opens without layout shift.** It opens at its final size: no frame drawn
      stretched across the screen and then shrunk, and the thumbnail strip's space is reserved
      before the thumbnails load, from a cheap count of the album's pictures. Thumbnails fill
      in place.
- [ ] **⌘⌥⇧A shows the artwork viewer,** unless that chord is already taken (check
      `KeyChord` and the menus first; if it is, say which command has it and pick none).
- [ ] **Watched Folders is its own Settings tab again,** next to Library, so Library is shorter
      (ADR 0168 moved it).
- [ ] **Snapshots always show** in Settings' short table; the collapse toggle is removed.
- [ ] **Get Info's previous and next track:** left and right arrow buttons in the bottom button
      row move to the previous and next track of the list Get Info was opened from, with
      unsaved edits handled as closing the window handles them (ADR 0160).
- [ ] **Get Info warns about one title for several tracks:** a save that gives several tracks
      the same title asks first, naming the title change, since it's usually a mistake made by
      editing a multiple selection. Other fields shared by every track, such as the album, don't
      ask.

### 72. Combine Albums for Tagging

Asked by the owner on 2026-11-09, as proposed: "Combine Albums for Tagging", a command-palette
command (and a track menu item) on the albums selected in the library.

- [ ] **Joined for tagging:** it opens the Discogs Tagger with the selected albums joined into
      one album, their files in disc and track order, and analyzes it, so the matcher compares
      every file with the catalog, and a release of the whole count ranks first.
- [ ] **Albums with different titles or artists** are allowed, and the tagger names every
      source album on the joined one, so combining "1983" with "1983 [Expanded Reissue]" by
      mistake is easy to see before writing.
- [ ] **Review and write** as any tagger write: nothing writes until the owner confirms; two
      files that would be the same track show as a conflict in the review, as now; Other
      Releases… and Look Up… work; undo works. After the write every file carries one release
      id, so Separate Releases shows them as one album.
- [ ] Works with the Discogs API alone, only slower.

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
  ([ADR 0124](decisions/0124-drop-files-and-the-library-folder.md)), and phase 60 keeps it
  organized when tags change ([ADR 0164](decisions/0164-keep-files-organized.md)). Move and
  Consolidate Library move and rename music files from outside it, which AGENTS.md doesn't
  allow, so they need an ADR and the owner's go-ahead first.
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
