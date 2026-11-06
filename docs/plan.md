# Build plan

The work still ahead: phases not yet built, owner checkpoints still pending, and ideas for later.
Agents work through it phase by phase, mostly unattended, and stop only at **hardware
checkpoints**, where the owner has to try something on the DAC Mac, the Denon, a phone, or the
2015 MacBook Pro.

Finished phases, 1 to 44 apart from 10 and 13, 46 and 47, are in [plan-archive.md](plan-archive.md), with
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

Set by the owner on 2026-11-05. Earlier run orders are in the archive.

1. Phase 46 next, then 47, 48 and 49, in that order.
2. Then phase 45: 45a, then 45b.
3. Phases 10 and 13 wait. Phase 10 adds pairing tokens, a secret, so the owner decides how
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
| Open Listening Stats on This Month, 1M synthetic plays: a new connection, every album's first play and the month's report (p95; phase 43); the old Mac figure is an estimate until its checkpoint | < 400 ms | < 1500 ms |
| Change the Listening Stats period, each of This Week, This Month, This Year, last year and All Time in turn, 1M synthetic plays (p95; phase 43); the old Mac figure is an estimate until its checkpoint | < 250 ms | < 900 ms |
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

## Phases

Phases 10 and 13 are from the original plan and haven't been built; 45, 48 and 49 are new.

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

- [ ] **48b.1 Rolling periods.** Past Week, Past Month, Past Year and All Time replace This
      Week, This Month and This Year: the last 7, 30 and 365 days up to today. The year menu
      stays as it is. The bench rows rename their periods.
- [ ] **48b.2 Totals box height.** When the totals box shares a row with Plays per Day, it fits
      the height of the Plays per Day cards, laid out in columns rather than one tall list.
- [ ] **48b.3 Smaller cards wider.** The smaller cards' maximum width goes up slightly.
- [ ] **48b.4 Save as Playlist asks first.** A sheet asks for the playlist's name, filled in with
      the name the current logic makes, and creates the playlist only on confirm.

#### 48c. Playback errors that explain themselves

When a track can't play, the status bar shows "Playback stopped: " and the error's
`description`, which is often a type name or a code, and nothing more. The owner hit it playing
a DSD file with hog mode off, where `DeviceOutput.swift:42` already has the clear reason. 48c
touches playback and the status bar, not the windows of 48a and 48b, so it can run in a third
worktree and merge after them. ADR 0111 records the error model if it needs one.

- [ ] **48c.1 Messages people can read.** Every error that can stop playback gives a short
      message for the user, defined once beside the error, such as "DoP needs exclusive access,
      and hog mode is off for this device". The status bar shows that message, not the error's
      `description`. A test walks every case of the playback, output and decoder errors and
      checks that each has a message and that none prints a type name.
- [ ] **48c.2 Details on click.** The playback stopped message in the status bar has a small
      question mark icon and is clickable. It opens a Playback Problem window with the message,
      the track and its format, the output device and its format, hog mode, the error's full
      text, and the app's recent log lines about playback. A Copy button copies all of it as
      text for a bug report.
- [ ] **48c.3 Fixes offered.** An error the app knows how to fix carries its fix, and the
      details window shows it as a button. The first is hog mode: playing DSD over DoP with hog
      mode off shows a dialog at once, saying that DSD needs exclusive access to the device, with
      a button that turns hog mode on for that device (the per-device setting, phase 22) and
      plays the track again, and a Cancel button. Hog mode held by another app is a different
      message, naming the app, with no button.
- [ ] **48c.4 Every track failing.** When tracks fail in a row until playback stops
      (`PlaybackError.failedInARow`), a dialog says why instead of the count alone: if every
      failure has the same cause, that cause and its fix as in 48c.3; if not, the causes with
      the number of tracks each, and a button that opens the details window.
- [ ] **48c.5 Tests.** DSD on a null device with hog mode off gives the hog mode message and
      fix, and the fix turns hog mode on and plays; tracks failing in a row with one cause give
      that cause; the details window's text includes the device and the log lines.
- [ ] **Owner check in the running app:** play a DSD file on the ADI-2 with hog mode off; turn
      it on from the dialog and hear it play. Click the stopped message and copy its details.

#### 48d. The window comes back as it was left

The owner quit and relaunched, and the track list had lost the column it was sorted by. The
goal: quitting and launching again shows the same state. The sort is saved with the column
layout (`TrackTableController.swift:845`), so start by finding where it's lost. 48d touches the
track table and the state file, not the windows of 48a to 48c, so it can run in its own
worktree and merge last. ADR 0113 records the list if it needs one.

- [ ] **48d.1 Sort order.** The sort column and direction come back after a quit, per source as
      they are kept now. A test sorts, saves, relaunches the model from the saved state and
      gets the same sort and the same first rows.
- [ ] **48d.2 Everything else the window shows.** List every piece of window state and whether
      it survives a quit: the source, the sort, the columns and their widths, the browser
      panes' selections, the search, the selection, the scroll, the split sizes, the queue
      panel, the window's frame. Fix each that doesn't. Per-Mac state goes in the state file;
      `playback.resume` stays as ADR 0095 has it, so the synced key stays small. The list goes
      in the Result line.
- [ ] **48d.3 Test.** One round trip that changes each item in 48d.2, saves, restores into a
      fresh window and checks each came back. It fails without the fixes.
- [ ] **Owner check in the running app:** sort by a column, change the window, quit, relaunch;
      everything is where it was.

#### 48e. The receiver moves on to the next track

Playing to the Denon, a track ends and the next never starts. The session waits for the
receiver to report the end (`RendererSession.swift`, `poll` and `stopped`), but the receiver's
reports lag: the last position it gave can be more than `endSlackSeconds` (3 s) short of the
end when it stops, so the stop doesn't count as the end, and `holdBack` keeps moving the app's
own deadline later while the receiver reports itself behind. The receiver also seems to ignore
`SetNextAVTransportURI`, so it never moves on by itself. 48e touches only `UPnPOutput`, so it
runs in its own worktree. ADR 0112 records the new timing and amends ADR 0041.

- [ ] **48e.1 Find out first.** Log, at notice level, each poll's transport state, position,
      duration and track URI in a track's last 15 s and the 15 s after, and whether a
      `SetNextAVTransportURI` was accepted. The owner's run on the Denon (checkpoint below)
      confirms the cause; the parts below don't wait for it.
- [ ] **48e.2 The app's clock decides.** When the next track goes out is worked out from the
      app's own clock: started when the receiver first reports playing, paused and resumed
      with it, and set again by a seek. It no longer waits on a report of the end. A poll may
      move the end later only for a stall the polls show (the position not moving while the
      receiver says it's playing), and by at most a cap defined once, for example 10 s a
      track, so a lagging receiver can't hold the next track back for good. A stop counts as
      the end when the app's clock is within the slack of it, whatever position was last
      polled.
- [ ] **48e.3 A receiver that ignores the next URI.** After a track whose next URI was
      accepted, if the receiver stops, or goes on playing the same URI past the end, instead
      of moving to the next one, the session marks that renderer as not honoring it
      (`RendererGapless.afterStop`, with the reason shown in the signal path) and from then
      on starts each track itself with `SetAVTransportURI` and Play at the clock's end. The
      choice is kept per renderer for the session, so the second track in a row doesn't stall
      too.
- [ ] **48e.4 Tests,** with the fake renderer the UPnP output tests already use: one whose
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
   next URI are logged too. Every line starts "track change:", so one predicate finds them.
2. **48e.2 clock.** A new value type, `RendererClock` (its own file), holds the app's clock for
   the loaded track: where it was, when, whether it runs, and how far stalls moved the end. It
   starts at the first poll that finds the renderer playing, pauses and resumes with the
   transport (not from the polled position), and a seek or start sets it. A poll moves the end
   later only by how much more the renderer is behind the clock than its least lag since its
   position first moved, two polls running, while the clock is short of the end, and by at
   most `RendererClock.stallCapSeconds` (10 s) a run of the clock. `leadMarginSeconds` and
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
   lagging renderer that accepts and ignores the next URI, three tracks in a row with one
   `SetNextAVTransportURI` sent; the mid-track stall test stalls 4 s once the position moved;
   the gapless test plays three tracks with one `SetAVTransportURI`. `RendererClockTests`: a
   steady lag moves nothing, a stall moves the end by its length, a long one by the cap, a
   renderer stuck past the end moves nothing, pause and resume, seeks.

Result (draft, before the gate): shipped 48e.1 to 48e.4 as planned, checked only against the
fake renderer (ADR 0112). A track's end is the app's clock's: started by the first poll that
finds the renderer playing, paused and resumed with it, set by a seek. A poll moves the end
later only when the renderer falls further behind than its usual lag, measured once its
position first moves, and by 10 s at most from a start or a seek. A stop counts as the end
when the clock or the last position is within 3 s of it. A renderer that took a next URI and
then stopped at the end, two polls running, or played on past the clock's end, is marked not
gapless with the reason, and from then on the app gives it each track with
`SetAVTransportURI` and Play. The two new network tests (a renderer lagging 5 s without a
next URI, and one lagging 5 s that takes and ignores it, three tracks in a row) fail on main
with the stop reported as one on the renderer; a stall now moves the end only after the
position has moved, so a stall in a track's first second isn't waited for (ADR 0112). No test
reads the log lines; they were read with `log show` after a fake-renderer run.

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

- [ ] **49.1 Short fades.** Pause fades out and play fades in over a few milliseconds (one
      length, defined once, about 5 ms), as do both sides of a seek and a click in the progress
      bar. The fade runs in the C render path (`HALRender`), with no allocation, locks or
      logging. Every sample outside a fade is passed through unchanged, so playback between
      fades stays bit-perfect; gapless track changes don't fade.
- [ ] **49.2 DoP.** A fade would corrupt the DoP markers, so DSD over DoP doesn't fade. Say in
      ADR 0110 how it goes quiet instead (for example DoP silence), or that it doesn't.
- [ ] **49.3 Tests.** A sine paused and played has no step larger than the fade allows; the
      samples outside the fades match the file bit for bit; a seek during a fade goes on from
      where the gain is. The seek rows in the budgets still pass, and the soak shows no
      underruns.
- [ ] **Hardware checkpoint (owner):** play, pause and seek quickly on the ADI-2 and say whether
      the pops are gone and it still feels immediate, and that the signal path panel still shows
      bit-perfect while playing.

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

- [ ] **45a.1 Analysis module.** A new Core module, `Analysis`. It decodes a file through
      `FileDecoder` (marked `package` for it), off the main thread at utility priority, and
      runs a short-time FFT with vDSP: 8192 points, Hann window, 50% overlap, per channel. A
      lossless file is read in its own integer format, so effective bits are exact; a lossy one
      as float. DSD files are skipped in this phase and say so. Analysis can be cancelled at
      any FFT frame.
- [ ] **45a.2 Results.** One pass gives: a spectrogram reduced to at most 1,000 time columns ×
      512 frequency rows in dB, keeping each cell's maximum so short events survive; the average
      spectrum; and the measures in the table above: cutoff frequency and steepness, effective
      bits, identical channels, peak, true peak (4× oversampled), clipped runs (3 or more
      samples at full scale), and a dynamic range score (per 3-second block, the peak against
      the loudest 20% RMS, as DR meters do).
- [ ] **45a.3 Verdicts.** Rules from the measures, with every threshold defined once:
      suspect lossy origin (a lossless codec, a steep cutoff at or under 20.5 kHz, Nyquist at
      22.05 kHz or more), suspect upsampled (a rate over 48 kHz and content stopping at or under
      24 kHz), padded bits (effective bits under the stored bits), fake stereo, clipped. Lossy
      files get measures, not a lossy-origin verdict. Each verdict has one line of text that
      names its numbers: "Cutoff at 16.0 kHz: suspect conversion from a lossy file".
- [ ] **45a.4 Spectrum window.** A command, Show Spectrum, on the selected tracks, from the
      track table's menu, the File menu and so the palette. For one track: the spectrogram
      (time across, frequency up, linear to Nyquist, a dB color scale with its legend), dotted
      reference lines at 16, 19, 20, 22.05 and 24 kHz, the average spectrum beside it, the
      format line (codec, rate, stored and effective bits), the measures and the verdicts.
      Hovering shows time, frequency and level. Drawn in AppKit, no Swift Charts, as 43.4.
- [ ] **45a.5 Comparing files.** With up to 8 tracks selected, the window stacks their
      spectrograms on one frequency axis scaled to the highest Nyquist, and draws every
      average spectrum on one chart, one color per file, with a legend of title and format. A
      file that's still being analyzed shows its progress; closing the window cancels the work.
- [ ] **45a.6 Cache.** Measures go in the index, in a table of their own keyed by path, with the
      file's size and modification time; a row whose file changed is ignored and the file
      analyzed again. The table is a schema part of its own (`SchemaPart`), so changing it drops
      nothing else. Spectrograms go in the Caches folder beside the thumbnails (ADR 0079), as
      8-bit dB, about 0.5 MB each, and are evicted oldest first past a size cap.
- [ ] **45a.7 Command line.** `music-player analyze [<path>…] [--json]`, from the same command
      registry entry: the selected tracks with no paths. It prints the format line, measures and
      verdicts, or the results as JSON.
- [ ] **45a.8 Fixtures and tests.** The fixture generator adds broadband test audio with known
      properties: full band at 16/44.1; the same through a steep low-pass at 16 and 19 kHz;
      the same encoded to AAC with AudioToolbox and decoded back into a FLAC; 16/44.1 upsampled
      to 24/96; 16-bit padded to 24; identical channels; clipped. Each verdict has a test that
      fails without its rule, and each clean fixture a test that it gets no verdict.
- [ ] **45a.9 Speed.** Bench rows with budgets set from the first measurement, with room for
      the old Mac: analyze a 5-minute 24/96 FLAC fixture locally, and the same on the slow
      simulated NAS; the analysis's peak memory. A soak run with analysis going shows no
      underruns.
- [ ] **Hardware checkpoint (owner):** on the 2015 MacBook Pro, show the spectrum of a 24/192
      track and of 8 tracks at once while music plays; report the times and any dropout. Open a
      few flagged and unflagged files in Spek and say whether the verdicts agree.

#### 45b. The library pass

- [ ] **45b.1 Analyze Library.** A command that analyzes every file not yet analyzed, or
      changed, one at a time at background priority, pausing while a scan runs. It runs only
      when the user starts it, from the menu, the palette or the command line: never at launch,
      after a scan, or on a schedule, and files a scan adds aren't analyzed until the next run. It shows
      progress in the status area, can be paused, and resumes after a relaunch from what the
      index already holds. On the NAS the reading is the cost, so it reads each file once.
- [ ] **45b.2 Library Health.** Tiles for suspect lossy origin, suspect upsampled, padded
      bits, fake stereo and clipped, over the files analyzed so far; each tile says how many
      that is.
- [ ] **45b.3 Columns and smart playlists.** Cutoff, Effective Bits, Dynamic Range and True
      Peak as track table columns and smart playlist fields, read from the index.
- [ ] **45b.4 Speed.** A bench row for analyzing 200 fixture files on the slow simulated NAS,
      and the soak run with Analyze Library going: 0 underruns, and search still within its
      budget.
- [ ] **Hardware checkpoint (owner):** run Analyze Library on the real library from the DAC
      Mac; report the time, the counts per tile, and a handful of flagged files checked by eye.

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
