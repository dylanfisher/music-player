# Build plan

The work still ahead: phases not yet built, owner checkpoints still pending, and ideas for later.
Agents work through it phase by phase, mostly unattended, and stop only at **hardware
checkpoints**, where the owner has to try something on the DAC Mac, the Denon, a phone, or the
2015 MacBook Pro.

Finished phases, 1 to 84 apart from 10 and 13, are in
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

Set by the owner on 2026-11-19, amended on 2026-11-20. Earlier run orders are in the archive.

1. Phases 91 and 92, asked for on 2026-11-19, built side by side on their own branches.
2. Phase 85, what phase 84 left, waits until the owner starts it.
3. Phase 10, drafted with the owner and started on 2026-11-20, runs now on its own branch. Its
   pairing-token storage is decided (see the phase).
4. Once phase 10 is on main, the owner said (2026-11-20) to start these unasked:
   - phase 93 and music-recommender's phase 12, side by side in their own worktrees;
   - then phase 94, once the service's phase 12 has landed.
5. Phase 13 waits.

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

- **90** ([phase](plan-archive.md#90-filtering-threads)): with music-recommender's phase 11
  running, follow threads from a few albums of an artist with many records, with and without
  Other Artists Only, and judge whether the filters find records worth playing.
- **89** ([phase](plan-archive.md#89-threads)): on this Mac and the 2015 MacBook Pro, against
  the real service, seed Threads from a few albums, walk three albums deep and back, and judge
  what the threads find and miss.
- **88** ([phase](plan-archive.md#88-where-a-download-came-from)): download an album from
  Recommendations and approve it; a smart playlist with Download Source is Recommendation
  holds it on this Mac, and on the 2015 MacBook Pro after its next sync.
- **87** ([phase](plan-archive.md#87-rediscover)): Rediscover on this Mac and the 2015 MacBook
  Pro over two days, against the real service: the panel, Not Now's undo, a resend from the
  other Mac, and whether the albums, reasons and threads hold up.
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
- **77** ([phase](plan-archive.md#77-faster-whole-file-tag-rewrites)): the owner check under
  its Result line, files a minute on the NAS for a large art or tag change.
- **79** ([phase](plan-archive.md#79-rating-the-menus-mark-get-infos-stars-shortcuts-and-a-message)):
  the owner check under its Result line, rating the playing track with ⌘⌥⇧4 and from Get Info.
- **83** ([phase](plan-archive.md#83-automatic-lossless-upgrades)): the owner check under its
  Result line, three upgrades in flight, the best first, and a fourth as one lands.
- **80** ([phase](plan-archive.md#80-the-rating-in-the-status-bar-and-the-toolbar)): the owner
  checks under its Result line, Rating in the status bar and Custom Status 1, rated by shortcut.
- **86** ([phase](plan-archive.md#86-recommendations-in-the-player)): the owner check on the
  real service on mbp2021, its steps in the phase's last box.
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
      on main too (the screen reads back as 0), so it alone doesn't fail the gate. A test
      target that fails on timing while other phases run (`RendererOutputTests`, a search
      during a refresh) is rerun with `./scripts/check test`, which runs only the targets that
      failed, before the failure is called the branch's.
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
| A 2 MB cover, too large for the padding, saved to the same 20 FLACs in one batch on the slow simulated NAS, every file rewritten (phase 77: 81.4 s and 3,482 MB over the link before, 47.5 s and 2,682 MB after); the old Mac figure is an estimate until its checkpoint | < 60 s | < 90 s |
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
| The web remote's whole Artists list, read and encoded on the server, over every fixture track (p95; 10b); the old Mac figure is the plan's, to be measured at its checkpoint | < 30 ms | < 150 ms |
| A web remote search, its artists, albums and tracks, per keystroke (p95; 10b); the old Mac figure is the plan's | < 25 ms | < 100 ms |
| An album's tracks, the web remote's first range of them (p95; 10b); the old Mac figure is the plan's | < 10 ms | < 50 ms |
| The real catalog of that dump (51.13: 35.89 GB) | < 40 GB | none |
| Analyze on the real catalog, per album and for the owner's 1,741 albums with a release id, ids hidden (51.13: 4.1 ms, 7.2 s) | < 10 ms, < 15 s | none |
| One album's candidates on the real catalog, matched and listed, warm (51.13: 15.7 ms for the median of five albums; 167 ms, 437 ms cold, for The Dark Side of the Moon's 1,555 releases) | < 50 ms; < 1 s for the most releases | none |
| Open the Discogs tagger on the real catalog (51.13: 33 ms, 79 ms the first time) | < 100 ms | none |

## Phases

Phases 91 and 92 are the owner's requests of 2026-11-19. Phase 85 is what phase 84 left on 2026-11-11; phases 10 and 13 are from the original plan and haven't been built.

### 91. Filtering and finding downloads and recommendations

The owner (2026-11-19) asked for three things. First, a search bar in the Downloads and Recommendations
windows, "not a full fledged search, just filter results that have been loaded in those
screens". Second, opening a row "in all music window (if it's been downloaded)". Third, in
Downloads, "a count of how many items are eligible for auto upgrade to flac when that setting
is enabled".

- [ ] **91.1 The filter.** A search field in each window filters the rows already loaded,
      matching every word against the row's visible text (artist, title, year, format, user,
      state in Downloads; artists, title, year, label, styles in Recommendations), case and
      diacritic insensitive. It doesn't change the service query or the stored settings. The
      empty state says when the filter hides every row. The rule lives in each model, without
      AppKit, as `ShortcutsModel.filtered(_:)` does. This is the third contains-style filter
      after that one and `ReleasesSheet`, so extracting the shared rule is its own commit first
      (AGENTS.md principle 3). Tests: a word in any column, two words in different columns,
      accents, an emptied list, and a refresh keeping the filter.
- [ ] **91.2 Show in All Music.** A context menu item, and the same command where each window
      already has row actions. It applies to a row whose release is in the library, found by
      Discogs release id in the index off the main thread. In Downloads that's an imported job,
      or an upgrade's old album. In Recommendations it's a row whose download was imported.
      The app wires it to the browser's existing album reveal (`showFirstTrack(of: .album,
      id:)` or its neighbor) and brings the main window forward. A release that isn't found
      says so in the window's status line rather than doing nothing. Tests: enabled and
      disabled by state, the release id the closure gets, and the not-found message.
- [ ] **91.3 The upgrade count.** While Upgrade to FLAC Automatically is on, a label beside
      its box says how many albums the pass could still queue. That's `AutoUpgrades.next`'s
      rule over the cached candidates with no room limit, so Never Upgrade, misses not yet due
      and live jobs aren't counted. It updates after each pass and when the box is ticked, and
      is hidden while the box is off. Tests in `AutoUpgradesTests` and `DownloadsWindowTests`.

### 92. Outputs that go away and outputs still being found

The owner (2026-11-19): "audio output device should fall back to using default if the other
one you were listening to goes offline", and "when i first start music-player, i don't see the
denon input in the list of output devices. can we show a searching indicator". The owner chose
to fall back to System Default and stay paused, and to keep searching only when a list opens
(ADR 0045), with a Searching row while it runs.

- [ ] **92.1 The ADR.** It supersedes ADR 0011's "It never moves to another device" and the
      matching line of ADR 0023 for this case. When the chosen device or renderer is lost, the
      output moves to System Default, paused, so nothing plays on the speakers until the user
      presses Play. The saved choice doesn't change, so ADR 0037's return and ADR 0041's
      renderer probe still move playback back when it returns. It records what Now Playing
      says, and what happens when System Default is itself the lost device (stay lost, as now).
- [ ] **92.2 The fallback.** On `.deviceLost` for a chosen HAL device or renderer, the engine
      stays paused at its position on System Default. The picker shows System Default in use
      and the chosen one "(not connected)" or "(not found)". When the chosen output returns,
      playback moves back to it, still paused. Tests with `NullDevice`'s `unplug` and `plugIn`
      and with the renderer stand-in: lost while playing, lost while paused, returned, and
      System Default itself lost.
- [ ] **92.3 The Searching row.** While `outputSearch` runs, the Output menus (Controls and
      the toolbar), the ⌘K output rows and the Settings popup show a disabled "Searching for
      network players…" row after the renderers. An open menu updates when the search starts
      and ends. The string is in `DisplayText`. Tests in `MainMenuTests`, `PaletteCommandsTests`
      and `GeneralModelTests`.
- [ ] **Hardware checkpoint (owner):** unplug the DAC while playing, then press Play on the
      speakers and plug it back in. Turn the Denon off while playing to it. On a fresh launch,
      open Controls ▸ Output and watch the Searching row give way to the Denon.

### 93. Removing Focus Mode

The owner (2026-11-20): "remove focus mode and all related code". Phase 82 added it
([ADR 0204](decisions/0204-focus-mode.md)). Distraction-Free Mode
([ADR 0072](decisions/0072-window-chrome-and-status-bar.md)) is a different feature and stays. So do the `focus.*` commands (Focus Sidebar, Focus Next
Pane, Focus Next Area), which move keyboard focus.

- [ ] **93.1 The code.**
      - **Command:** `AppCommands.focusMode` (`view.focusMode`, ⌥⌘F), its View menu item in
        `AppMenus`, and its title switch and enabling in `CommandHandlers`.
      - **Main window:** the Focus Mode section in `MainWindow` (what it saves and puts back,
        leaving it when full screen ends, the frame it won't save) and the toolbar check that
        mentions it.
      - **Library browser:** its section in `LibraryBrowser`, including the timeline's leaving
        hook.
      - **Track table:** in `TrackTableController`, the focus columns, the saved columns, the
        text and rows, and the branches in column reporting.
      - **Rows:** `TableAppearance`'s focus font size and row type.
      - **Setting:** `appearance.focusFontSize`, from `AppSettings`, the Settings window and
        `config.json`'s schema. A config that still holds the key is handled the way the
        Pre-release rule says: data that doesn't match is discarded, with no shim. If the
        config check refuses unknown keys, the stale key gets a message saying it's gone.
      - **Search afterwards:** `rg -i 'focus ?mode|focusFontSize|focusColumns'` over
        `Sources`, `Tests`, `Support` and `scripts` comes back empty, apart from the `focus.*`
        keyboard commands. `./scripts/dupes`, `surface` and `size` allowlist entries that
        only Focus Mode needed are removed.
- [ ] **93.2 What stays.** A reload of every row keeps the selection. ADR 0204 made that fix
      for every reload, not only Focus Mode's, so it stays with its test, renamed if the name
      mentions Focus Mode. Any other shared change from phase 82 is kept in the same way.
      Check each before deleting it.
- [ ] **93.3 Tests.** Delete the tests that exercise only Focus Mode (`MainWindowTests`,
      `TrackTableControllerTests`, `TimelineModelTests`) and keep the rest. One test checks
      that ⌥⌘F is unbound and that no command or setting named for Focus Mode is left, so it
      can't come back by halves.
- [ ] **93.4 Docs.**
      - ADR 0204's status becomes "superseded by" a short new ADR, 0216, that records the
        removal and what stayed.
      - Remove mentions of Focus Mode from `README.md`, `docs/map.md` and the other ADRs,
        except history in the archive and the retrospectives.
      - Delete phase 82's pending owner checkpoint from Waiting on the owner. The archived
        Result line notes that the feature was removed.
- Version: a minor bump, since removing a feature is a breaking change, pre-1.0.

### 94. An artist's discography in Recommendations

The owner (2026-11-20) asked to "view all albums by an artist (according to our local discogs
database), sort by community user rating, etc.", in the Recommendations window, with "a way
to filter/sort to a mode that finds just that artist's albums". The service builds the list
in its phase 12 (`list: "discography"`), which lands first. Its answers apply here too:

- the artist's albums are those it's a main artist on;
- every format is listed;
- everything shows, owned and marked albums included;
- the values are the master's main release's;
- a discography's values are fetched first.

Opening one needs a Discogs artist the player already knows, never a name typed in. That
means a track in the player, a row with an artist id, or a Discogs id or link the owner
pastes. ADR 0217 records the decisions.

- [ ] **94.1 The query.** `RecommendationQuery.Seed` gains `discography(artistID:)`, with its
      encoding and strict decoding of 12.2's rows: `score` null and `reasons` empty for this
      list, `formats`, `inLibrary`, `mark` and the reply's `pending`. The sorts gain `year`
      and `title`, offered only for a discography, where `year` is the default and `score`
      isn't offered. The `unknown_artist` 404 says "Discogs has no artist <id> in this Mac's
      catalog" in the status line. Tests on written replies through the stand-in transport.
- [ ] **94.2 Opening a discography.** Show Discography opens it in the Recommendations window,
      chosen in the list pop-up as "Discography: <artist>", like a seed list. The artists
      come from:
      - a track anywhere in the player (the track table, the queue, Now Playing, and other
        windows' track rows), through its `discogs_release_id`'s main artists in this Mac's
        catalog;
      - a Recommendations, Downloads or Threads row, through the artist ids it carries.

      With one main artist the command opens it. With several it's a submenu, one item for
      each. A track without a Discogs release id, or one the catalog doesn't hold, gets the
      item disabled, with the reason as its tooltip.

      From anywhere else, Show Discography… in the palette and the Recommendations window
      asks for a Discogs release id or a discogs.com link to a release, master or artist.
      `pastedReleaseID` grows into one parser for the three kinds. A release or master opens
      its main artists, chosen as above when there are several. There's no search by name.
      Tests for each source, for several artists, for a track without an id, and for the
      parser's kinds, slugs, locale prefixes (`/fr/artist/…`) and refusals.
- [ ] **94.3 The window in discography mode.**
      - **Columns:** Format and In Library are new, and Mark shows the verdict. Score, Why and
        Rank are hidden while a discography shows, and come back as they were.
      - **Controls:** the Missing checkbox hides owned albums, as a filter of the loaded rows,
        since the service lists everything. The Styles, Labels and year filters and phase
        91's text filter work as they do for other lists.
      - **Values coming in:** while `pending` is over 0, the status line says "Fetching
        ratings, <n> left", and the list is asked for again every 15 s while the window is
        open and showing it. The selection and scroll are kept as rows reorder, and asking
        stops when `pending` is 0 or the list changes.
      - **Row actions:** Open on Discogs, Download…, Not Interested and Already Have work as
        on other rows. In Library albums offer Show in All Music (91.2).

      Tests in `RecommendationsModelTests` for the columns, Missing, the refresh's timing with
      an injected clock, and the kept selection.
- [ ] **94.4 Docs.** ADR 0217, the README's Recommendations section, and a palette and menu
      entry in the command docs.
- [ ] **Hardware checkpoint (owner):** open the discography of an artist from the library,
      one from a recommendation, and one from a pasted link. Sort by rating while the values
      come in, and download a missing album.

### 85. The file splits and the performance rerun

Left from phase 84 when the owner landed it early on 2026-11-11. Its triage (in the archive,
under [phase 84](plan-archive.md#84-a-codebase-agents-can-keep-changing-safely)) has the
detail of each item.

- [ ] **The splits** (84.29, 84.30): `AppCommands` and `AppMenus` per area in `Core/Commands`,
      then `LibraryBrowser.swift`, `AppDelegate.swift`, `TrackTableController.swift` and
      `BrowserModel.swift` along the seams the auditor drew, code moves only, with
      `size-allow.txt`'s ceilings and map.md brought down to match.
- [ ] **`DeviceOutput`'s mutation entries** (84.8), by ranges of about 150 mutants, with tests
      for the survivors that matter.
- [ ] **Performance rerun** (84.31): on a quiet machine, alternating with main's binary, Analyze
      1741 first, then Approve local, Apply to All, the over-budget and tight rows and the
      playback rows.
- [ ] **Code review** of phase 84's 52 commits, which landed without one: `/code-review high`
      on `5fb2cabe..` the landing commit, its confirmed findings fixed.

### 10. Web remote

The owner (2026-11-20): control "the macbook that is connected to the denon receiver from my
phone", with "full efficient browsing of the library", and no iOS app and no Shortcuts. The
2015 MacBook Pro is usually the Mac on the Denon, but any of the three Macs may be playing, so
the remote "determine[s] if multiple music players are launched, which one is currently
playing, and control[s] that one", and shows every one of them.

A web page can't discover anything on the LAN by itself, so each running app does that for the
page. Every app advertises itself over Bonjour and lists the others it finds. The page, served
by whichever app the phone opened, asks that app for the list, then talks to each app on it
directly.

- [ ] **10.1 The remote server.** A second listener in `LocalNetwork`. The phase 9
      `HTTPServer` serves files to one renderer by token, and this one answers any paired
      device on a local subnet, so it's a type of its own, sharing the head parser and the
      subnet check. `remote.enabled` is off by default; nothing listens or advertises until the
      owner turns it on, and turning it off closes every connection. `remote.port` defaults to
      a fixed port (47800) rather than one the system picks, so a saved home-screen link keeps
      working. It listens on each LAN interface (not loopback, not point-to-point) and accepts
      connections only from that interface's subnet. `Host` must be one of the Mac's own
      addresses or its `<name>.local` with the port, which stops DNS rebinding. `GET` for the
      page and reads, `POST` for commands and pairing, JSON bodies of 16 KiB at most, 8 KiB
      heads within 10 s, and keep-alive allowed. At most 32 connections, since each phone holds
      one event stream per Mac (10.4). Responses are gzip-compressed with `Compression`
      (system zlib, no dependency) when the client asks. Threat model rows in ADR 0025, and a
      fuzz target, `scripts/fuzz remote-request`.
- [ ] **10.2 Pairing.** Settings → Remote shows a 6-digit code, live for 2 minutes, and a QR
      code holding `http://<name>.local:<port>/#pair=<code>`, with the LAN IP beside it as
      plain text for when `.local` doesn't resolve. The page trades the code and a device name
      it makes up ("iPhone, Safari") for a 128-bit token. Five wrong codes kill the code, and
      a new one has to be shown. Every request except the static page and the trade carries the
      token in `Authorization: Bearer`; anything else gets 401 and nothing more. The Mac keeps
      only the token's SHA-256, with the device name, when it paired and when it was last seen,
      so the Mac holds no secret, just a way to check one (owner question below). Settings
      lists paired devices with Forget for each.
- [ ] **10.3 Finding the other Macs.** Each app keeps a random instance ID in its state file and
      advertises `_music-player._tcp` with its port, its computer name and that ID in the TXT
      record. It doesn't advertise whether it's playing: anyone on the LAN can read a TXT
      record. An `NWBrowser` collects the other instances, and `GET /api/instances` returns
      them (ID, name, addresses, port) to a paired device. A Mac that sleeps or quits drops off
      the list. `NSBonjourServices` in `Info.plist` names the one service, amending ADR 0039.
      The page talks to the other Macs directly, so each one sends CORS headers, echoing
      `Origin` only when it's another instance's origin from its own Bonjour list, and answers
      the `OPTIONS` preflight that the `Authorization` header triggers.
- [ ] **10.4 State and push.** `GET /api/state` returns now playing (track, album and
      artwork IDs), whether it's playing, position with the time it was read so the page can
      advance the bar itself without an update every second, the queue's change stamp, volume,
      the output, and the receiver's power, volume and input when receiver control is on.
      `GET /api/events` is a Server-Sent Events stream of the same state, sent whenever any of
      it changes, at most 4 times a second. SSE rather than WebSocket: it's plain HTTP on the
      same hand-written server, Safari reconnects it on its own, and commands go up as `POST`
      anyway. The stream also carries a `lastPlayedAt` time, which the page uses to choose a
      Mac (10.6).
- [ ] **10.5 Commands.** `POST /api/command {name, argument}` goes through `ScriptRouter`
      with a new `Origin.remote`. It runs only commands marked `runsFromRemote`: playback,
      seek, queue edits, the app's volume, the output, and the receiver (volume, mute, input,
      power). It runs nothing that writes tags, moves or deletes files, changes a setting, or
      approves a download, since AGENTS.md lets those happen only after a confirmation in the
      Mac's own UI. `playTracks` and `queueTracks` take track IDs, or an album ID with a track
      to start from, for browsing (10.7).
- [ ] **10.6 Which Mac.** The page keeps one token per instance ID, all in the storage of the
      origin it was saved from. A header strip lists every Mac it can see, with a dot for
      playing, paused or unpaired. Tapping an unpaired Mac asks for the code that Mac's
      Settings shows. Unless the owner picks one, the page controls the Mac that is playing. If
      more than one is playing, it picks the one with the newest `lastPlayedAt`. If none is, it
      picks the one controlled last, and failing that, the Mac whose page was opened. Each Mac
      sends its own event stream, so the strip and the choice stay current as playback moves.
      Browsing (10.7) uses the chosen Mac's library.
- [ ] **10.7 Browsing the library, quickly.** Reads come from the index through the
      `LibraryQueries` the browser already uses (`artists`, `albums`, `genres`,
      `columnEntries`, `trackNames`, `TrackFilter.search`), never a second set of queries.
      - Lists come as compact arrays (`[id, name, artist]`), not objects. Genres, artists and
        albums load whole, since even 10k artists is about 60 KB gzipped, with first-letter
        offsets for a jump bar.
      - Tracks load by position: the total, then any range of 200 (`offset`, `limit`), sorted
        on the server by the browser's `TrackColumnSort`. Ranges are fetched by position rather
        than by keyset cursor, because a full-height list has to jump straight to any point
        when its scrollbar is dragged. SQLite's `OFFSET` on 100k rows takes milliseconds.
      - The page's list is a hand-written virtual list, not TanStack or another dependency:
        fixed-height rows, a spacer as tall as all of them, and about 40 reused row elements
        for what's on screen. It fetches the range in view and one either side, drops ranges it
        no longer needs once they arrive, keeps the 20 used last, and shows placeholder rows
        until a range arrives.
      - Every read carries the index's `changeStamp` as its `ETag`. The page caches lists in
        IndexedDB under that stamp and asks again with `If-None-Match`, so a library that
        hasn't changed costs a 304.
      - Search runs `TrackFilter.search` over artists, albums and tracks at once, 20 of each,
        at most one request in flight per keystroke, and the stale one is dropped.
      - Artwork comes from `ThumbnailStore` at two sizes (list and now playing), at URLs keyed
        by the artwork's hash with `Cache-Control: immutable`, so each cover crosses the
        network once.
      - Budgets, measured on the 2015 MacBook Pro over the owner's library: the first page of
        artists in under 150 ms on the server, a search in under 100 ms, and an album's tracks
        in under 50 ms. `Bench` gets a remote case for each.
- [ ] **10.8 The web app.** Static HTML, CSS and JS in `Support/Remote/`, which `scripts/bundle`
      copies into the app; no framework, no build step. It's sized for phones and has
      `apple-mobile-web-app-capable`, so Add to Home Screen opens it full screen. Four views:
      - **Now Playing:** artwork, transport, a seek bar, and the app's and the receiver's volume.
      - **Queue:** reorder and remove.
      - **Browse:** Artists → Albums → Tracks, and an album grid, as virtualized lists.
      - **Search.**

      It reconnects its event streams on `visibilitychange`, since iOS suspends the page while
      the phone is locked. Light and dark follow the phone. It needs nothing newer than iOS 15
      Safari.
- [ ] **10.9 Tests.** Swift Testing tests for the server's caps, the Host and CORS checks,
      pairing (expiry, five misses, Forget), a 401 for every route without a token, an
      unremotable command refused, ranges by position and ETags against a fixture index, and
      discovery with an injected browser. JS stays thin enough that its logic, such as picking a
      Mac and which ranges the virtual list fetches, is a pure module that a Swift test runs in
      `JavaScriptCore` (a system framework). No test opens a port past loopback or advertises
      on the LAN: Bonjour's advertiser and browser are injected.
- [ ] **Hardware checkpoint (owner):**
      - Pair a phone with the 2015 MacBook Pro.
      - Add it to the home screen and control playback through the Denon.
      - Start playing on a second Mac and watch the remote switch to it.
      - Browse and search the full library.
      - Control one Mac from a phone and a computer at once.
      - Forget a device.

**What a web page can't do here.** It's plain `http`, so there's no service worker or offline
page, and the token travels unencrypted on the LAN, as the recommender's does (ADR 0025 row
65). There are no lock-screen controls: Safari offers them only for audio the page itself
plays. The phone's home-screen link points at one Mac, the 2015 MacBook Pro, and works only
while that Mac is awake. The others show up on its strip.

**Decided by the owner (2026-11-20).** The Mac stores only a SHA-256 of each device token, in
the state file, so no Mac holds the secret, and AGENTS.md's secrets line gets a note saying so
rather than a third secret. The virtual list is written by hand, with no TanStack or any other
dependency.

**Built in two parts on one branch, `phase/10-web-remote`.** 10a is the server side: 10.1 to
10.5, 10.3's discovery and the Settings → Remote pane, with their tests. 10b is browsing and the
page: 10.6 to 10.8, with their tests. Each part gets its own review. ADR 0214 is 10a's and ADR
0215 is 10b's.

**10a, the server side (sub-plan).**
1. Settings: `remote.enabled` (off) and `remote.port` (47800, 1024 to 65535) in the config;
   `remote.instanceID` and `remote.devices` (each device's name, token SHA-256, paired and last
   seen, at most 32) in the state file, decoded strictly.
2. `LocalNetwork`: `RemoteServer`, one `NWListener` per LAN interface on the one port, with the
   request rules as a pure function (`RemoteRequestRules`) that the fuzz target
   `remote-request` drives; keep-alive, caps on heads, bodies, connections and event streams;
   the `Host` check against the bound addresses and `<name>.local`; CORS for the origins a
   closure allows and the `OPTIONS` preflight; gzip through zlib; SSE streams. Bonjour behind
   `BonjourAdvertising` and `BonjourBrowsing`, with dns_sd and `NWBrowser` as the real ones.
3. Core module `Remote`: pairing (code, misses, expiry, constant-time compares, token hashes),
   the routes (`/`, `/api/pair`, `/api/state`, `/api/events`, `/api/command`,
   `/api/instances`), the state and its change check, the event hub (at most 4 a second), the
   instance list from the browser, and `RemoteService`, which starts and stops it all.
4. `ScriptRouter.Origin.remote` and `Command.runsFromRemote`; new argument commands Seek To,
   Set Volume and Choose Output for the page's seek bar, slider and output menu.
   `playTracks`, `queueTracks` and the queue's reorder and remove come with browsing in 10b,
   since they take IDs only browsing gives the page, as do the artwork IDs in the state.
5. Settings → Remote: the two settings, the code with its QR code and LAN address, paired
   devices with Forget. App wiring starts the service, restarts it when the interfaces change
   and feeds it the state.
6. `NSBonjourServices`, a placeholder `Support/Remote/index.html`, ADR 0214 (amending 0039,
   rows in 0025) and AGENTS.md's note on device tokens.

**10b, browsing and the page (sub-plan).**
1. Static files: a fixed list (`index.html`, `style.css`, `app.js`, `logic.js`, `icon.png`)
   read from `Remote/` in the bundle once at start into a map keyed by exact path, each with
   its type and an `ETag` of its bytes; nothing from the request path touches the file system.
   `scripts/bundle` makes `icon.png` from `AppIcon.svg`. The page gets a
   `Content-Security-Policy`.
2. `LocalNetwork`: 304 Not Modified, `If-None-Match` in the preflight's allowed headers, and
   `ETag` exposed to the other Macs' pages.
3. `Library`: `trackNames` takes a window (`LIMIT`/`OFFSET` on the same statement) and a
   filtered count gives the total; `searchEntries` reads the Artist and Album panes with the
   search applied, which the panes ignore; one new read, an art track for each of a set of
   albums, for the album grid. `ThumbnailStore` hands back a thumbnail's encoded bytes, made and kept on a
   miss, and names a picture by the hash its files are named by.
4. `Remote`: `RemoteLibrary` on a query-only connection of its own: `/api/genres`,
   `/api/artists`, `/api/albums` (compact arrays, whole; the phone works out the jump bar's
   letters from the names),
   `/api/tracks` (a total and a range by `offset` and `limit`, sorted by a `TrackColumn`),
   `/api/search` (artists, albums and tracks, 20 each), `/api/queue` (a range of the queue in
   play order, with its stamp), `/api/covers` (art IDs for albums) and `/api/art/<size>/<id>`
   (two sizes, `immutable`). Every library read carries `ETag` from `changeStamp`, a launch
   nonce and the grouping, and answers `If-None-Match` with a 304. The state gains the track's
   art ID, the app volume's floor and the receiver's inputs.
5. Commands, through `ScriptRouter` as `Origin.remote`: Play Tracks and Queue Tracks
   (`tracks:<ids>` or `album:<id>[:<track>]`), Move in Queue and Remove from Queue Item
   (`<stamp>:<position>[:<to>]`, refused when the queue changed). Arguments parse in Core.
6. The page: `logic.js`, a pure ES module (choosing a Mac, range planning with its 20-range
   cache, search request ordering, the SSE parser, letter offsets), and `app.js`, the DOM:
   the Mac strip, pairing, an event stream per Mac read with `fetch` and reconnected on
   `visibilitychange` and on error with backoff, tokens keyed by instance ID and origin, Now
   Playing, Queue, Browse (Genres, Artists, Albums, Songs, an album grid), Search, IndexedDB
   list cache, `textContent` only.
7. Tests: the routes, ranges, ETags and 304s against a fixture index, the art URLs, the static
   map, the new commands and their arguments, and `logic.js` in `JavaScriptCore`. `Bench`
   gets the three 10.7 budgets. ADR 0215.

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
