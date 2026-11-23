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
3. Phase 10, drafted with the owner and started on 2026-11-20, landed on 2026-11-20.
4. Once phase 10 is on main, the owner said (2026-11-20) to start these unasked:
   - phase 93 and music-recommender's phase 12 (both landed 2026-11-20), side by side in
     their own worktrees;
   - then phase 94, once the service's phase 12 has landed (it did, and phase 94 landed
     2026-11-20).
5. Phases 95, 96 and 97, the owner's list of 2026-11-22, each on its own branch in its own
   worktree, side by side; 96 in two parts, 96b after 96a on the same branch.
6. Phase 13 waits.

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
- **10 Web remote** ([steps](plan-archive.md#10-web-remote)): pair a phone with the 2015
  MacBook Pro, control the Denon from the home-screen page, switch Macs, browse the full library.
- **94 An artist's discography** ([steps](plan-archive.md#94-an-artists-discography-in-recommendations)):
  open discographies from the library, a recommendation and a pasted link, sort by rating while
  values come in, download a missing album; with the service's phase 12 checkpoint.

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

Phases 96 and 97 are the owner's list of 2026-11-22. Phases 91 and 92 are the owner's requests of 2026-11-19. Phase 85 is what phase 84 left on 2026-11-11; phases 10 and 13 are from the original plan and haven't been built.

### 96. The web remote, denser and searchable

The owner (2026-11-22), on the web remote: the A–Z selector on the left, and the right side
"should support fine tune scrubbing if possible (e.g. scroll up/down to quickly go through whole
library, move finger left to change scrubbing speed to get fine tunes). if scrubbing is hard,
keep the default scroll"; "lists should have less vertical space so there are more items on
screen at once. keep font size as is"; Now Playing "should show the songs from that album below
it in track view, with a playing indicator on current track"; search "should support same cmd+p
commands, `a:dream` means album matching `dream`"; "a slider for volume"; and "use phosphor
icons https://phosphoricons.com/ for all icons/emojis currently in it". The owner asked for
Phosphor by name, so vendoring its SVGs (MIT) is the owner's go-ahead for that one asset set.

#### 96a. The page: icons, density, the scrubber and volume

- [ ] **96a.1 The ADR (0219).** Phosphor's regular weight, the SVGs of only the icons the page
      uses, vendored into `Support/Remote` as one file served by `RemotePage.files` (inline
      SVG keeps the content policy as it is), with its MIT notice and the version they came
      from. It also records the scrubber's rule from 96a.3.
- [ ] **96a.2 Icons and density.** Every glyph and emoji in `index.html`, `app.js` and
      `style.css` (transport, repeat one, shuffle, back, the ± and arrows, play state) becomes
      its Phosphor icon, coloured by `currentColor`, each button keeping its `aria-label`.
      List rows lose vertical padding so about 40% more fit on a phone screen, with the font
      sizes unchanged and each row still at least 36 px tall to tap.
- [ ] **96a.3 A–Z on the left, the scrubber on the right.** The jump bar moves to the left
      edge. A strip on the right edge scrubs: a vertical drag moves through the whole list in
      proportion, and moving the finger left of the strip slows it (full speed on the strip,
      about a half, a quarter and an eighth at set distances to the left), the way iOS scrubs
      a seek bar, with a small label showing the row's letter or name under the finger. If it
      can't be made smooth on the owner's phone with long lists, the right side keeps the
      default scroll and the ADR says why. The speed rule is a pure function in `logic.js`
      with tests where `logic.js` is tested.
- [ ] **96a.4 Receiver volume slider.** The app's slider already shows while Digital Volume is
      on. The receiver row gets a slider too, sending `receiver.setVolume` on release over the
      receiver's range from the state, showing the value while dragged, and the ± buttons stay.
      Tests where the state's receiver fields are tested.

#### 96b. Now Playing's album and search prefixes

- [ ] **96b.1 The ADR (0220).** The query grammar of ADR 0161 (`album:`/`a:`, `artist:`/`ar:`,
      `track:`/`t:`, `genre:`/`g:`, `playlist:`/`p:`) moves to a tier `Core/Remote` and
      `Features/Palette` both import, and the server parses `q`, so the page holds no copy.
      A kind the remote doesn't list answers an empty result rather than a 400; an unknown
      word before a colon is plain text, as in the palette.
- [ ] **96b.2 Search prefixes.** `/api/search?q=a:dream` returns only albums matching `dream`,
      and the same for each kind the remote lists; the search field's placeholder names them.
      Tests in `RemoteLibraryTests` (each prefix, a short and a long name, case, an unknown
      word) and the palette's existing `PaletteQuery` tests still passing unchanged.
- [ ] **96b.3 Now Playing's album.** Below the controls, Now Playing lists the playing track's
      album in track view, read through the routes the album view already uses, with a
      playing indicator (a Phosphor icon) on the current track that moves when the track
      changes, and a tap that plays from that track as the album view's does. A track with no
      album, or nothing playing, shows no list. It reads the album once per album, not once
      per state event.
- [ ] **Hardware checkpoint (owner):** on the phone, with the library open: the icons, the
      denser lists, A–Z on the left, scrubbing on the right through Artists and Songs at each
      speed, the receiver slider against the Denon, `a:` and `ar:` searches, and Now Playing's
      album following a track change.

### 97. Rescanning the selected files

The owner (2026-11-22): "add ability to rescan only some files (the selected files)".

- [ ] **97.1 Rescan Selected Files.** A command in the Library menu, the track table's context
      menu and ⌘K, enabled while the browser has tracks selected, that reads those files again
      through `LibraryWatcher.rescan(files:)`, whatever their size and mtime say, as after a
      tag edit. The status line says how many were read again, and a file that's gone or
      unreadable is reported as a scan problem as a folder scan reports it, not dropped. It
      reads the files only (AGENTS.md boundary). Tests: the command's enabled state, the
      paths it passes (an album row's tracks, not the row), and a missing file reported.

Implementation plan:

1. **Commands:** `CommandID.rescanSelected` ("Rescan Selected Files"), in the File menu after
   Rescan All (the library's commands are there; there's no Library menu) and in the track
   menu after Reveal in Finder; the palette lists it as it lists every menu command.
2. **Library:** `LibraryWatcher.rescan(files:parsed:done:)` hands its caller the summary, or
   the error it now only logs, besides sending `edited`.
3. **LibraryBrowser:** `rescanSelection(through:)` reads the selected paths, hands them over,
   and says "Read 12 files again" in the status bar, listing the files it couldn't read as
   their own report in the Problems window, as a folder scan's issues show.
4. **App:** the handler, on while the browser has tracks selected and a watcher runs.
5. ADR 0221; tests in `LibraryBrowserTests` (enabled state, the paths of a timeline's rows,
   a gone file reported) and `LibraryWatcherTests` (the reply).

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
