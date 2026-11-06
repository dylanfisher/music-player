# Build plan

The work still ahead: phases not yet built, owner checkpoints still pending, and ideas for later.
Agents work through it phase by phase, mostly unattended, and stop only at **hardware
checkpoints**, where the owner has to try something on the DAC Mac, the Denon, a phone, or the
2015 MacBook Pro.

Finished phases, 1 to 44 apart from 10 and 13, and 45 to 49, are in [plan-archive.md](plan-archive.md), with
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
   CLAUDE.md), in small commits that each pass `./scripts/check`.
3. **Runs the phase gate.** The reviewers and auditors are Sonnet subagents running in parallel.
   It fixes every confirmed finding, then reruns the gate.
4. **Records.** It ticks the phase's boxes, adds a "Result" line with measured numbers, commits,
   and fast-forwards `main` to the branch. It never pushes.
5. **Archives.** It moves the finished phase, unchanged, to the end of the archive's phases. A
   checkpoint the phase leaves pending gets a line in [Waiting on the owner](#waiting-on-the-owner)
   pointing at the archived text.
6. **Continues.** A hardware checkpoint doesn't stop the run. It's recorded as pending, and the
   run moves on to the next phase that doesn't depend on its result. When the run ends, it lists
   every pending checkpoint at once: what to push, what to run on which machine, and what to
   paste back.

If something blocks a phase that only the owner can resolve (a product decision, missing
hardware, an Apple API that can't do what the phase assumes), stop and ask. Don't work around it.

### Current run order

Set by the owner on 2026-11-06. Earlier run orders are in the archive.

1. Phase 50 next: its four parts in parallel worktrees, merged in order a, b, c, d.
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
| Analyze Library over 200 fixture files on the slow simulated NAS, at background priority (phase 45b); the old Mac figure is an estimate until its checkpoint | < 15 s | < 40 s |

## Phases

Phases 10 and 13 are from the original plan and haven't been built.

### 50. Owner feedback, 2026-11-06

Listening Stats, the import sheet, the hog mode fix, Analyze Library and Scan Library, the
spectrum window and the log. The four parts touch mostly different modules, so they run in
parallel worktrees and merge in order a, b, c, d; a later part rebases on the earlier ones.
ADR numbers: 0117 to 50a if it needs one, 0118 to 50b, 0119 to 50c, 0120 to 50d.

#### 50a. Library window

- [ ] **50a.1 Stats never opens hidden.** Clicking Stats with Show Browser off showed the
      panel at zero height; the owner had to drag it open. Probe: the panel slot is hidden
      for sources without a panel, so the split collapses it, and `fillPanelSlot`
      (`LibraryBrowser.swift`) calls `setPosition` straight after unhiding, with no layout
      between, then records `placedHeight` whether or not it took. `statsHeight`'s range is
      `0...2000`, so a 0 can be saved, and the split has no minimum. Give the stats height a
      range with a real minimum (the header and one row of cards), place the divider after a
      layout pass as `MainSplit.restore` does, set a minimum coordinate while a panel shows,
      and record a height only from the user's drag, not from layout passes.
- [ ] **50a.2 Stats keeps its height.** Moving to another source and back, or relaunching,
      opens Stats at the height the user last dragged it to. Test: Show Browser off, Stats
      shown at its saved height, a playlist, Stats again at the same height; and the same
      with Show Browser on.
- [ ] **50a.3 A lighter selected row in the Stats lists.** The marked row in Top Genres and the
      other list cards is the selection color at 0.4 alpha (`StatsListView.swift`), too
      dark. Lighter, still clearly above hover's 0.18.
- [ ] **50a.4 No "discarded" text in the status bar.** "earlier play counts and playlists
      discarded" leaves the status bar's totals (`LibraryStatus.summary`). The notices stay in
      the Problems list and the problems button, where they already show.
- [ ] **50a.5 The import sheet says what will change.** The top of the Import from Swinsian
      sheet becomes a two-column table (`NSGridView`, as in Get Info's File tab): what
      changes on the left, the count on the right, a heading line for how many tracks matched,
      rows with nothing to change grouped in one dimmed line ("No change: last played, date
      added, ratings, loved") instead of "later on 0 tracks", and the notes (playlists
      skipped, rows merged) as a short line under the table. Same width, so it still fits
      1440×900. Tests: the rows for a plan, and the sheet's fit test and its snapshot.
- [ ] **50a.6 The stuck row line.** After hours of use a 1-point horizontal line stays at a fixed
      height on screen, across the art column and the rows, while the rows scroll under it.
      Not reproduced yet. Candidates, from reading the code: the split's divider over a panel
      slot shown at 0 height (fixed by 50a.1); an album line set on an art cell drawn into its
      row's layer (`canDrawSubviewsIntoLayer`) without redrawing the row, so a recycled row
      keeps it; the status bar's border. Fix the first two, and try to reproduce with long
      scrolls, source changes and Stats shown and hidden. Owner check: when it shows again,
      whether View > Hide Status Bar or resizing the window clears it.

#### 50b. Playback: the hog mode fix plays the track you chose; the log

- [ ] **50b.1 Turn On plays the chosen track.** With hog mode off, double-clicking a DSD
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
- [ ] **50b.2 Log values in Copy Details.** The owner asked whether playback log lines should be
      public so Copy Details shows their values instead of `<private>`. Decision (the owner can
      overrule it): the log's values that are the app's own or the device's are public: errors,
      OSStatus codes, formats, device and renderer names. Track paths stay private, logged
      with `privacy: .private(mask: .hash)` so the lines about one file can be matched; Copy
      Details already prints the failed track's path and error in plain text. Make
      `renderer.name`'s privacy consistent in `RendererSession`. Update ADR 0025's row 35 and
      its `rg` check.

#### 50c. Analyze Library and Scan Library

- [ ] **50c.1 Two to four files at once.** The pass analyzes `min(4, max(2,
      activeProcessorCount / 2))` files at once, 2 on the 2015 MacBook Pro, as a sliding task
      group (Spectrum's `filesAtOnce` loop is the pattern); only the pass's actor counts and
      reports. Pause cancels every file under way, and each is read again next run; each file
      is still read once per run. Files are still started in path order.
- [ ] **50c.2 Utility priority.** Each file is decoded at `.utility`, not `.background`. Bench
      rows rename "at background priority"; the 200-file row is measured again (the owner's
      guess: 2 to 3 times faster on the NAS).
- [ ] **50c.3 Progress in Library Health.** While the pass runs, Library Health shows a
      progress bar with "Analyzing library: 1,240 of 43,368" and the file under way (the
      newest started, its name only), and a Pause button beside it; paused, it shows Analyze
      Library to carry on. The status bar shows the same Pause button beside its bar. Detail
      comes from what the pass already knows, reported at most a few times a second; no new
      reads.
- [ ] **50c.4 Carry on after a quit.** A run already skips measured files; what's missing is
      the count. The count is over the whole pass, not what's left: "1,240 of 43,368" after a
      relaunch, the measured files counted as done. After a relaunch with a pass unfinished,
      Library Health says "Library analysis paused: 1,240 of 43,368" and its Analyze Library
      button carries on.
- [ ] **50c.5 Start over once done.** Once every file is measured, Analyze Library reads
      "Analyze Library Again" in the menu and Library Health, and asks first, since it reads
      every file again. A run again keeps the measures it replaces until each file's new ones
      are stored, and resumes after a quit the same way: the index records the time the run
      started and each measure the time it was made, and a run lists files measured before
      its start. Stored data has one shape: if the measures table changes, how the owner's
      existing measures are kept, or why they can't be, goes in the ADR; prefer a side table
      over a change that discards them.
- [ ] **50c.6 Pause Scan Library.** A Pause button beside the scan's bar in the status bar,
      and wherever scan progress shows (Settings > Folders), pauses the running scan with
      `ScanControl.pause()`, which already exists; Resume carries on where it was. A
      user's pause is held in `WatchState` so the watcher's own `resume()` calls don't undo
      it, and the status bar says "Scan paused: …". While a scan is paused by the user, other
      scans wait behind it as now, and Analyze Library doesn't wait for it (a paused scan
      reads nothing). A pause doesn't outlast a quit; the next launch scans as usual. Tests in
      `WatchState` and the watcher.
- [ ] Amend ADR 0116 with ADR 0119.

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
Questions" (the WAV first, as it's the one compared against), Show Spectrum, and read the
Differences box; say whether each sentence matches what you hear, and whether the thresholds
(1 dB level and bands, DR 2, 1 kHz cutoff) say too much or too little. Then try a remaster
against its original.

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
- **Library folder:** Swinsian's copy of newly added tracks into one folder, kept organized by
  album artist when tags change, with Move and Consolidate Library. It moves and renames music
  files, which AGENTS.md allows only `TagWriter` and Move to Trash to touch, so it needs an ADR
  and the owner's go-ahead first. Watched folders cover adding music meanwhile.
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
