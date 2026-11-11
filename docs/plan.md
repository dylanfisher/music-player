# Build plan

The work still ahead: phases not yet built, owner checkpoints still pending, and ideas for later.
Agents work through it phase by phase, mostly unattended, and stop only at **hardware
checkpoints**, where the owner has to try something on the DAC Mac, the Denon, a phone, or the
2015 MacBook Pro.

Finished phases, 1 to 76 apart from 10 and 13, 78, 81 and 82, are in
[plan-archive.md](plan-archive.md), with their implementation plans, Result lines and the full
text of each checkpoint.

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
   CLAUDE.md), in small commits. Each commit passes `./scripts/check --changed main`
   (AGENTS.md), which the implementer also iterates with.
3. **Runs the phase gate.** The reviewers and auditors are Sonnet subagents running in parallel.
   It fixes every confirmed finding, checking each fix with `./scripts/check --changed main`.
   No subagent runs the full gate: the orchestrator runs `./scripts/check` once, in the branch's
   worktree just before step 4, and its test step reruns only the test targets edited since
   their last pass. Fast-forwarding main to the branch then carries that pass's test stamp into
   main's checkout (`scripts/post-merge`).
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

Set by the owner on 2026-11-10. Earlier run orders are in the archive.

1. Phases 79 to 83, the owner's feedback of 2026-11-10 (second list), run after 78: 79, 81 and
   82 in parallel, each on its own branch and worktree, then 80, which builds on 79, then 83,
   after its music-recommender change lands.
2. Phase 84, the codebase review for agents, runs after 83, so it reviews their code too.
3. Phase 77 waits until the owner starts it.
4. Phases 10 and 13 wait. Phase 10 adds pairing tokens, a secret, so the owner decides how
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
- **45 Spectrum and file quality** ([steps](plan-archive.md#45-spectrum-and-file-quality)):
  45a, Show Spectrum on the 2015 MacBook Pro while music plays and flagged files against Spek;
  45b, Analyze Library on the real library from the DAC Mac, its time and tile counts.
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
- **53** ([phase](plan-archive.md#53-library-browser-and-settings)): each part in the running
  app, a snapshot restored, Separate Releases with a remaster beside its original.
- **54** ([phase](plan-archive.md#54-soulseek-imports)): the owner checks under 54.14, the
  DAC Mac first, then mbp2015. And its follow-up: `rank-golden.json` still names "music-player
  ADR 0140", fixed together with music-recommender's copy and ADR 0148's SHA-256 on both Macs.
- **55** ([phase](plan-archive.md#55-windows-and-settings)): the owner steps under its Result
  line, on the two-display Mac.
- **56** ([phase](plan-archive.md#56-browsing-and-the-keyboard)): the owner steps under its
  Result line.
- **57** ([phase](plan-archive.md#57-get-info)): the owner steps under its Result line; delete
  `"tagEditor.place"` from `state.json` first.
- **58** ([phase](plan-archive.md#58-tagger)): the owner steps under its Result line.
- **59** ([phase](plan-archive.md#59-downloads)): the owner steps under its Result line.
- **60** ([phase](plan-archive.md#60-keep-files-organized)): the owner steps under its Result
  line, on a scratch copy first.
- **61** ([phase](plan-archive.md#61-tagging-preferences-in-settings)): the owner steps under its
  Result line.
- **62** ([phase](plan-archive.md#62-small-fixes-palette-saving-status-quit-guard)): the quit
  guard's three answers, the saving total with a second batch queued, `a:` and `t:`.
- **63** ([phase](plan-archive.md#63-a-library-pane-in-settings)): Snapshots opened and closed
  leaves no gap; the Library pane's rows and the palette opening it.
- **64** ([phase](plan-archive.md#64-downloads-approve-upgrades-open-in-tagger-window)): a
  manual download replacing an album on the NAS (scratch album), the window's frame and
  columns on a second display, Open in Tagger on a discrepancy.
- **65** ([phase](plan-archive.md#65-tagger-confidence-and-the-safe-set)): the Match column,
  the Safe tab and Apply to All in it, a choice in API mode sending no search.
- **66** ([phase](plan-archive.md#66-artwork)): the Artwork tab on scratch MP3, FLAC and M4A
  copies, the viewer's strip, Get Artwork's Fill Missing and Replace.
- **73** ([phase](plan-archive.md#73-performance-audit)): the owner checks under its Result
  line, and the flagged fixes in its "For the owner" paragraph, each a yes or no.
- **74** ([phase](plan-archive.md#74-tagger-scrolling-keeping-your-place-and-the-writes-last-steps)):
  the owner checks and two questions under its Result line.
- **75** ([phase](plan-archive.md#75-closing-the-reset-layout-banner)): the owner checks under
  its Result line, and whether its wording will do.
- **76** ([phase](plan-archive.md#76-a-layout-editor-for-the-status-bars-totals)): the owner
  checks and two questions under its Result line.
- **78** ([phase](plan-archive.md#78-staying-awake-while-playing-to-a-renderer)): the owner
  checks under its Result line, on the 2015 MacBook Pro on battery with the Denon.
- **81** ([phase](plan-archive.md#81-downloads-approving-unasked-without-a-dialog-and-no-offer-for-one-track)):
  the owner checks under its Result line, an unasked upgrade on the NAS.
- **82** ([phase](plan-archive.md#82-focus-mode)): the owner checks under its Result line,
  focus mode while playing.
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

- [ ] **Gate:** the full `./scripts/check` passes, run once by the orchestrator just before
      landing (step 3). In an agent session `theGlassHeadersAreFrosted` fails
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
      it a miss; a full run's load can push a row past its budget. A row that errors with
      SQLite's "disk I/O error" (6922) while other phases run is rerun alone the same way, and
      the bench's app is built first for the rows that need it. A row still slower alone is
      run against main's binary, alternately, under the bench lock, before it's called a
      regression: in phase 73 four such rows read the same on main.
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
  `git worktree prune`. Each one holds a full `.build`, several gigabytes. Removing one deletes
  its `.build`, so anything a Result line points at goes in the scratchpad first.

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
| History table plus its indexes, 1M synthetic plays (phase 73 added `history_path_played`, about 16 MB, which cut opening Stats from 299 to 84 ms) | < 50 MB | < 50 MB |
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
| Analyze 1,741 fixture albums against a shaped fixture dump: a master of 20 to 100 releases each, 1 in 14 found only by its artist (73.1: 4.6 to 4.9 s, 290 to 330 MB more footprint at the peak, most of it still held with the matches); the old Mac figure is an estimate until its checkpoint | < 10 s | < 40 s |
| The tagger window with those 1,741 albums analyzed, a refresh of its Exact tab (median of 20; 73.1); the old Mac figure is an estimate until its checkpoint | < 10 ms | < 40 ms |
| The same window, Apply to All in Exact: the main thread's time for the write's progress, two reports a file, as the tag writer sends them (73.1: 192 to 286 s for about 18,400 files before 73.9, 5 to 8 ms a report; the budget is 73.9's aim); the old Mac figure is an estimate until its checkpoint | < 5 s | < 20 s |
| Approve a staged 12-file fixture album, local: the sheet's moves, the lossy-origin check of its two five-minute 24/96 files, and the import (73.1); the old Mac figure is an estimate until its checkpoint | < 5 s | < 30 s |
| The same with the lossy-origin check and the library folder's listings on the slow simulated NAS: 23 ms to open, 10 ms a 1 MB block, 45 ms a listing (73.1); the old Mac figure is an estimate until its checkpoint | < 10 s | < 40 s |
| Organize Selected Files over 2,000 fixture files in a library folder of every fixture artist, local: the plan and the moves (73.1); the old Mac figure is an estimate until its checkpoint | < 15 s | < 60 s |
| The same over about 200 fixture files, the library folder's listings on the slow simulated NAS: 45 ms a listing, 10 ms any other question (73.1); the old Mac figure is an estimate until its checkpoint | < 15 s | < 30 s |
| Type-to-select a key over every fixture title, sorted by title (p95; 73.1); the old Mac figure is an estimate until its checkpoint | < 20 ms | < 80 ms |
| A 3 MB body read through `HTTPSClient` from a stand-in server, asked from the main actor (73.1); the old Mac figure is an estimate until its checkpoint | < 50 ms | < 200 ms |
| The real catalog of that dump (51.13: 35.89 GB) | < 40 GB | none |
| Analyze on the real catalog, per album and for the owner's 1,741 albums with a release id, ids hidden (51.13: 4.1 ms, 7.2 s) | < 10 ms, < 15 s | none |
| One album's candidates on the real catalog, matched and listed, warm (51.13: 15.7 ms for the median of five albums; 167 ms, 437 ms cold, for The Dark Side of the Moon's 1,555 releases) | < 50 ms; < 1 s for the most releases | none |
| Open the Discogs tagger on the real catalog (51.13: 33 ms, 79 ms the first time) | < 100 ms | none |

## Phases

Phases 77 to 84 are the owner's asks of 2026-11-10; phases 10 and 13 are from the original plan
and haven't been built.

### 77. Faster whole-file tag rewrites

Asked by the owner on 2026-11-10, during a Discogs tagger Apply with covers over 15,435 files
on the NAS. Its undo journal showed 8,104 of the first 14,376 files (56%) rewritten through the
temp file, since the new cover didn't fit the tag's padding: 169 GB of originals, at about 75
files a minute over the whole batch, or about 15 MB/s of audio. A rewrite runs inside
`prepare` (`Core/TagWriter/TagWriter.swift`), one file at a time, and reads the original about
three times, in `fileHashes`, in `writeTemp`'s copy and in `checkEdited`'s read-back, and
writes it once. Only a chunk's writes in place run `writesAtOnce` (4) at a time (ADR 0108).
Don't start until the owner asks.

- [ ] **Several rewrites at once.** Files that go through the temp file are written a few at a
      time, as a chunk's writes in place are, each touching only its own file and its own temp
      file. Each file's journal steps keep today's order (the temp file written and read back,
      then its record and old bytes, then the rename), and journal appends stay one at a time.
      How many at once scales with the Mac, with the 2015 MacBook Pro as the floor, as
      `filesReadAtOnce` does (ADR 0074); memory stays bounded, since each copy moves 4 MB at a
      time. Results stay in the batch's order. A failure that stops the batch, such as a full
      disk or a journal that can't be written, starts no new file, and the ones in flight finish
      or are put back as today.
- [ ] **Hash while copying.** `writeTemp` computes the original's whole-file and payload hashes
      from the bytes it copies, on the descriptor whose identity it checks, instead of
      `fileHashes` reading the file in a pass of its own first. The temp file's read-back still
      has to give the payload's hash, and the record still carries `originalSHA256` for undo.
      A file changed during the copy is caught as it is today, by the identity checks before
      the rename.
- [ ] **Bench.** A `tagBatchBenchmarks` row for an art change too large for the padding, so
      every file is rewritten: the batch's time before and after, on the slow simulated NAS if
      `SimulatedNAS` can stand in for writes, else on a local folder with a latency the plan
      says. A budget row beside it in [Performance budgets](#performance-budgets).
- [ ] **Tests.** A batch mixing writes in place and rewrites gives each file its result, in
      order; a crash injected at each step (`WriteFaults`) with several rewrites in flight
      recovers every file as today; a batch that stops leaves no temp file and no record
      without its file; the recorded `originalSHA256` equals a separate hash of the original.
- [ ] **ADR 0196**, amending ADRs 0107 and 0108: the rewrites' concurrency and where the hashes
      come from.
- [ ] **Owner check:** the next large art or tag change on the NAS, or one on a scratch copy of
      a few albums of large FLACs whose tags have no padding: files a minute, compared with this
      batch's 75.

### 79. Rating: the menu's mark, Get Info's stars, shortcuts and a message

Asked by the owner on 2026-11-10. The Rating submenu (`AppMenus`, `CommandID.rate`) shows no
rating as chosen, Get Info shows none, and its commands have no default chords.

- [ ] **The menu's mark.** The Rating submenu, in the menu bar and the track table's context
      menu, ticks the item for the rating of the tracks the commands act on; Clear Rating for
      none. Tracks rated differently show the mixed mark on each rating they have.
- [ ] **Get Info's stars.** The Info tab shows five empty stars at the right end of the title's
      row, the pattern of the track table's Rating column (`TrackColumnText.stars`,
      `RatingClick`). Hovering fills them up to the star under the pointer; a click sets that
      rating, and a click on the current rating clears it, as in the table. It sets the rating at
      once, as the table does, not on Save, since a rating is the index's, not the file's: no tag
      is written. For several tracks rated differently it shows the mixed state until clicked.
- [ ] **Shortcuts.** ⌘⌥⇧1 to ⌘⌥⇧5 rate one to five stars and ⌘⌥⇧0 clears, as default chords of
      `CommandID.rate`, shown in the menus and changeable as other chords are. Check they clash
      with no default chord first.
- [ ] **The message.** Rating by a shortcut or the menu shows "Rated “Title” ★★★★" (or "Rated 3
      tracks ★★★★", or "Cleared the rating of “Title”") at the status bar's bottom left, and it
      fades after about 3 seconds; another rating replaces it. It doesn't cover the scan's
      progress; the plan says where it goes while a scan runs.
- [ ] **Tests.** The submenu's marks for one track, several alike and several mixed; the
      default chords; Get Info's click and hover mapping, through `RatingClick`; the message's
      text and that a second one replaces the first.
- [ ] **Owner check:** rate the playing track with ⌘⌥⇧4, see the message, the menu's tick and
      Get Info's four stars; set it to two from Get Info.

### 80. The rating in the status bar and the toolbar

Asked by the owner on 2026-11-10, with phase 79, which it follows.

- [ ] **A Rating part.** `StatusPart` and `HeaderPart` gain `rating`: the playing track's stars
      in the status bar's layout editor (phase 76) and the toolbar's Now Playing and Custom
      Status builders. Empty stars for an unrated track, nothing while nothing plays. It updates
      when the rating changes from anywhere, a sync from another Mac included. Clickable to
      rate, as Get Info's stars are, if the plan finds it fits the bar's hit areas; else shown
      only, and the plan says which.
- [ ] **Tests.** Each layout decodes and encodes the part; its text for 0 to 5 stars; it changes
      on a rating set while playing.
- [ ] **Owner check:** add Rating to the status bar and to Custom Status 1, and rate the
      playing track with a shortcut: both follow.

### 83. Automatic lossless upgrades

Asked by the owner on 2026-11-10. Builds on Upgrades… (`upgradeCandidates`, phase 64) and
Approve Safe Matches Automatically (ADRs 0193 and 0195). While it's on and the app is open, it
keeps a few FLAC upgrades in flight on music-recommender, most-played and lowest quality first,
and lands the clean ones.

The owner's answers, 2026-11-10: the candidates are Upgrades…'s; the priority is plays times
quality gap, with a boost for a loved or highly rated album; FLAC only, 24-bit and 16/44.1 both
fine, no lossy-to-better-lossy; 3 in flight, no daily cap; a miss is retried after 1, 7 and 30
days, then set aside with a Not Found list to queue again from; it runs only while the app is
open; approving follows Approve Safe Matches Automatically, and a download that isn't clean is
rejected and searched again from another peer; albums can be marked Never Upgrade.

- [ ] **The setting.** Upgrade to FLAC Automatically, a checkbox in the Downloads window beside
      Approve Safe Matches Automatically, and `downloads.autoUpgradesInFlight` (default 3). It
      runs only while the app is open and can tag (staging on the library's share, as Upgrades…
      needs), and stops queuing the moment it's turned off; jobs already queued carry on.
- [ ] **Candidates.** The rule of `upgradeCandidates`: lossy albums whose every track carries one
      Discogs release id. Not an album marked Never Upgrade, one set aside as not found, or one
      with a job already on the service from either Mac, so two Macs never queue the same
      release; the service's job list is the source of truth for that.
- [ ] **Priority.** One score, written once in Core: the album's plays (summed over its tracks)
      times its quality gap, lower bit rates scoring higher (128 kbps well above 320), with a
      boost for a loved album or one rated 4 stars or more. The plan gives the formula and a
      table of worked examples in the ADR.
- [ ] **In flight.** At most N of its own jobs at once, counted from the service's jobs with
      source `upgrade` that it queued (the plan says how they're told apart from Upgrades…'s).
      When one lands, is rejected or set aside, the next candidate is queued. Format policy
      `flac` only; 24-bit and 16/44.1 are both accepted.
- [ ] **Not found.** A job the service finds nothing for is retried after 1 day, then 7, then
      30; after the third miss the album is set aside. A Not Found list, from the Downloads
      window, shows those albums with their misses, and Queue Again clears the count.
- [ ] **Not clean.** Approving follows Approve Safe Matches Automatically as today. A job of its
      own that lands left for review because it isn't clean (the tagger's verdict or the
      plan's lossy-origin check, not a failure of the share or the service) is rejected, its
      staged folder deleted by the service, and searched again from a different peer. That needs
      the service to skip peers a job already tried: a change in music-recommender, planned
      there first (a job's tried peers kept and left out of `rank`), then used here. A release
      with no clean copy from any peer counts as a miss.
- [ ] **Never Upgrade.** A mark per album, from the track table's context menu and the Upgrades
      sheet, kept in the index by release id. The plan says whether it goes in the sync log, as
      ratings do; it should, so both Macs honor it.
- [ ] **Tests.** The score's order for the worked examples; candidates leave out marked, set
      aside and already-queued albums; never more than N in flight; the 1, 7, 30 day backoff
      and setting aside; an unclean job is rejected and searched again excluding its peer;
      turning it off queues nothing more. Through the stand-in transport, never the real
      service.
- [ ] **ADR 0200**, amending ADRs 0193 and 0195: what the app queues unasked, its priority, the
      in-flight limit, and rejecting an unclean download unasked.
- [ ] **Owner check:** turn it on with a handful of candidates; three jobs queue, the
      most-played lowest-quality first, clean ones land, and a fourth queues as one finishes.

### 84. A codebase agents can keep changing safely

Asked by the owner on 2026-11-10: a review of the tree, fixing what it finds, aimed at what makes
the next phases cheaper and safer for agents. Agents write all of this code. What costs them is
reading a large file to make a small change, editing a file another phase's branch is editing
too, a test suite that passes a wrong edit, a rule that lives only in prose, and a map or a
duplicate that points the wrong way. A function's branch count, on its own, isn't a target.
Nothing the user sees changes.

The survey of 2026-11-10 counted, for each file, the commits since the start that touched it
and how many of them were `fix`:

| File | Lines | Commits | Fixes |
|---|---|---|---|
| `Features/LibraryBrowser/LibraryBrowser.swift` | 2,619 | 159 | 41 |
| `App/MusicPlayer/AppDelegate.swift` | 1,229 | 146 | 32 |
| `Features/LibraryBrowser/TrackTableController.swift` | 973 | 66 | 24 |
| `Features/LibraryBrowser/BrowserModel.swift` | 1,118 | 65 | 15 |
| `Core/HALOutput/DeviceOutput.swift` | 1,657 | 50 | 27 |

It also found that `scripts/mutate-files.txt` covers only Playback, `ConfigStore`,
`LibraryScanner` and `TagWriter`; that `scripts/dupes-allow.txt` has 167 entries; that
`Sources/` has 56 `try?` and 86 `@unchecked Sendable` or `nonisolated(unsafe)`; that the `map`
step of `./scripts/check` only checks that the tier folders exist; and that the threat model,
ADR 0025, was last amended by ADR 0145.

- [ ] **The files agents edit most.** Split `LibraryBrowser.swift`, `AppDelegate.swift`,
      `TrackTableController.swift` and `BrowserModel.swift` along the seams they already have,
      one concern a file, so a typical change reads one small file and two phases adding
      features rarely edit the same one. The plan first sorts the last 60 commits to each file
      by the part of it they changed, and splits along those parts. Code moves only; nothing
      is rewritten, renamed or changed in behavior, and the tests pass unchanged. Where every
      feature adds a line to one shared list (a command's registration, a menu item, a setting
      change), the plan says whether each feature can own its piece in its own file, and does
      it only if the list stays defined once (principle 1).
- [ ] **Why `DeviceOutput.swift` keeps breaking.** Read its 27 fix commits and group them by
      cause: a state the tests can't reach, a device callback's order, a missing stand-in, or
      something else. Fix the cause the largest group shares, for example a test seam or one
      state machine where there are several flags, with a test for each past bug that group
      holds. Report the rest. Splitting the file follows from that, not the other way round.
- [ ] **Tests that catch a wrong edit.** Add `scripts/mutate-files.txt` entries for the logic
      agents change most and that has none: `DeviceOutput`, `LibrarySyncMerge`, `TieBreak`
      and `AlbumMatcher`, `BrowserModel`'s selection and sort, and `Downloads`' job states. Run
      `./scripts/mutate` on each and add a test that kills each surviving mutant that matters.
      The Result line gives each file's score before and after. Parsers are left to
      `scripts/fuzz`, which already covers them.
- [ ] **Checks, so it doesn't slide back.** New steps in `./scripts/check`, each failing on a new
      case and listing today's in an allowlist that only shrinks:
      - a file in `Sources/` over 1,000 lines;
      - a `try?` with no comment on its line or the line above saying why the failure doesn't
        matter (principle 5);
      - an `@unchecked Sendable` or `nonisolated(unsafe)` with no comment naming the lock or
        queue that guards it.

      Clear what the audit can on the way: each `try?` and unchecked sendable it reads is
      either explained or fixed. ADR 0201 records the limits and why.
- [ ] **A map that stays true.** The `map` step also fails when a path or file that
      `docs/map.md` names in backticks doesn't exist, or when a module folder under
      `Sources/<Tier>/` isn't in the map. Bring map.md up to date for the splits above.
- [ ] **Duplication.** Reread each entry in `dupes-allow.txt`. An entry whose reason no longer
      holds is removed and its duplicate fixed. The 5-file strict-decode block (`b013e447`, in
      `SmartRules`, `SourceSort`, `TaggerSheetLayouts`, `TrackTableLayout` and others) and its
      4-file siblings are the first candidates for one helper. `/simplify` runs across the
      modules phases 54 to 83 touched, looking for a second or third copy in a neighboring
      module, which a phase's own gate can't see.
- [ ] **Security.** Bring ADR 0025's table up to date for what was built since ADR 0145: staged
      downloads and the folder names the service sends (ADR 0146), Approve moving files into
      the library and approving unasked (0147, 0156, 0193), Keep Files Organized, whose paths
      come from tags (0164), snapshots and their restore (0142, 0181), and the profile export
      (0198). Each row gets an attacker, a mitigation and a test or check, like the table's
      other rows. The questions: can a tag value or a service reply name a path outside the
      library or staging folder, through `..`, an absolute path or a link? Can a restored
      snapshot carry a secret or write outside the app's folders? Does the export send only
      what ADR 0198 lists? A gap is fixed, with its test.
- [ ] **Performance since phase 73.** Run every bench row an agent session can against phase
      73's Result numbers and the budgets. A row more than 10% slower is profiled and fixed, or
      given a written reason. The items in [Later](#later) stay there.
- [ ] **How it runs.** One Sonnet auditor per item above, in parallel, writes its findings into
      one triaged list under this heading: fix, defer with a reason, or drop. The fixes run in
      lanes that touch separate files, each on its own branch from `phase/84-agent-health`,
      with Opus implementers, one commit a fix, each passing `./scripts/check --changed main`.
      The file splits land last, after the other lanes, so they don't conflict with them, and
      only once phases 79 to 83 have landed. `TagWriter.prepare` and `FileReplace.writeTemp`
      are left to phase 77 while it's unbuilt, since it rewrites both.
- [ ] **ADR 0201**, amending ADR 0025: the threat model's new rows, the new check steps and
      their limits, and what `DeviceOutput`'s fixes had in common.
- [ ] **Result line:** before and after for each count above (lines and commits of the five
      files, mutation scores, allowlist entries, unexplained `try?` and unchecked sendables),
      the findings deferred and why, and what the phase cost.
- [ ] **Owner check:** none beyond a normal session's use, since nothing the user sees changes.
      The window rows go to the owner's Mac if any window code moved.

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

- **The matcher's memory** (phase 73, E3 and E4): after Analyze of 1,741 albums whose masters
  have 20 to 100 releases, 290 to 330 MB stays held, because each candidate keeps its whole
  scored tracklist, artists and credits, and each is decoded whole when scoring needs only
  the tracks. Keep only what the review reads; the matcher row measures it.
- **A control thread that sleeps until it's due** (phase 73, A1): while playing it wakes every
  10 ms, about 0.28% of a core; waking for the next segment boundary, half-empty ring or drain
  deadline instead needs an ADR beside 0029.

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
