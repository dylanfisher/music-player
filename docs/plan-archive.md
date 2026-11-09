

### 60. Keep Files Organized

Asked by the owner on 2026-11-09, with the boundary change: "record the new move in an ADR and
in the AGENTS.md boundary".

- [x] **Setting:** Keep Files Organized, limited to the library folder. After each tag write
      the user confirms, the edited files are renamed to their `libraryFolderPath` layout with
      `renamex_np(RENAME_EXCL)`, as Approve does, and stats and playlists carry over through
      the move list (`importMoves`/`TrackMove`). A taken target name skips the file and lists
      it in Problems.
- [x] **Organize Selected Files:** the same for selected tracks already in the library folder.
- [x] **ADR and AGENTS.md boundary** for the new move.

Implementation plan, phase 60 (ADR 0164):

What exists, found by search (map.md recipes): the layout is `libraryFolderPath` in
`Core/Library/LibraryFolderLayout.swift`; Approve's renames are `LibraryFolderMove`, over
`MoveCalls`; the move list is `LibraryIndex.importMoves(_:)`, reached through
`LibraryWatcher.importMoves(lines:)`. Tag writes and undos run one at a time on `TagEditing`'s
write queue and report through `written`; the undo journal (`TagUndoJournal`) keys each file's
record by its path, with the edited file's size, mtime and inode. Problems rows come from
`LibraryStatus`'s reports, filled by `LibraryBrowser.finish`.

- 60.1 Shared rename (refactor): `LibraryFolderMove`'s exclusive rename (`renameNeverOver`),
  its case-preserving path (`listedPath`) and its library check (`isFolder`) become
  file-level functions, which Approve and the organizer both call; `layoutDestination` reads
  the tags and gives the destination for the copy, Approve and the organizer.
- 60.2 The organizer (`Core/Library/LibraryFolderOrganize.swift`): `layoutMoves` plans,
  `moveToLayout` renames a plan. A file outside the library folder (links followed) is
  skipped; one already in place is left; one whose path is taken, or on another volume
  (`EXDEV`), is skipped and listed, never copied. Folders a move leaves empty are removed with
  `rmdir`, up to but never the library folder itself; a folder still holding other files
  (cover art) stays, and is listed when no audio is left in it.
- 60.3 The journal follows (`TagWriter.follow(_:)`, `TagUndoJournal`): every record of a
  moved path takes the new path, and the one whose edited size and mtime match the file takes
  its identity there, since an SMB rename may renumber the inode. Undo Tag Edit then finds it.
- 60.4 Setting `library.keepFilesOrganized` (`AppSettings`), in the Library Folder box; the
  box's folder row is on while either checkbox is (`switchKeys`).
- 60.5 `TagEditing` hook: with a folder from `organizingFolder`, each write or undo the user
  asked for is followed on the write queue by the organizer and the journal's follow, so no
  later write or undo comes between; `written` gets the report at the new paths and what was
  organized. Recovery at launch isn't organized.
- 60.6 Organize Selected Files… (`track.organize`, in File > Moved and Removed Files):
  `LibraryBrowser.organizeSelection` plans off the main thread, asks "Organize N Files?" with
  the count that will move and the skipped, then hands the plan to `TagEditing.organize`.
  `finishOrganizing` says what moved in the status bar and lists the rest in Problems.
- 60.7 App wiring: the moves are recorded in the index before the renames
  (`LayoutMoveLedger.swift`) and `carryLayoutMoves` gives them to `importMoves(lines:)`, so
  stats, ratings and playlists follow, after each organize and each watcher start; the new
  paths are rescanned.
- 60.8 ADR 0164, the AGENTS.md clause, ADR 0124's and 0147's amended-by lines, and the
  "Later" item's organize part reworded as done.

Tests: a taken name skipped, a move to another album folder, a file outside the library
folder, `ENOTSUP` and `EXDEV` through `MoveCalls`, another client taking a name during the
fallback, empty-folder cleanup and a folder with art kept, one spelling per folder on a volume
that ignores case, stats and a playlist entry carried through `importMoves` and after a failed
carry, undo after a move, and the hook's ordering in `TagEditorTests`. All in temporary
folders.

- [x] **Owner check, on a scratch folder on the share:** with two Macs, organize on one and
      Approve or organize on the other into the same names: neither file is replaced, and the
      second is listed as taken. Look in the log for "reserving the name" to see the share
      took the fallback, and that no empty file is left after a refused rename.

Result, phase 60: shipped all three items (ADR 0164; 0020, 0124 and 0147 amended; the AGENTS.md
boundary). With Keep Files Organized on, a confirmed tag write or undo renames its files inside
the library folder to their layout, and Organize Selected Files does it after a confirmation that
names the count, running exactly the plan it confirmed. A taken name, a file outside the folder,
or a move across volumes is skipped and listed; only folders a move empties are removed. Where a
share refuses `RENAME_EXCL`, the name is reserved with `open(O_CREAT|O_EXCL)` before the rename,
which holds across Macs; Approve shares that helper. Moves are written to a `layout_moves`
ledger before the first rename and carried on the write queue, at each organize and at every
watcher start. The undo journal follows a batch of renames in one pass. Gate: one file-safety
and one simplify review, then a re-review of the fixes; 8 correctness findings, all real, fixed
with tests, 4 simplifications, then 2 more from the re-review (the ledger carry raced an
organize; a placeholder whose fstat failed stays, as recorded). No data-loss path found.
`theGlassHeadersAreFrosted` fails as in every agent session. Cost: implementer about 440k tokens
plus the last fixes, 449 tool calls, 92 min; reviewers 206k tokens, 25 calls, 4 min.

Owner steps, on a scratch copy first: set the library folder to a scratch copy with one album
folder holding cover.jpg, turn on Keep Files Organized, change a track's album in Get Info, and
check the move, its plays, rating and playlists, and the old folder gone or listed; Undo Tag
Edit puts it back; a taken name overwrites nothing and is listed; Organize Selected Files… over
tracks in and outside the folder, its count, and Cancel; then on a scratch folder on the share,
the same, the log's `RENAME_EXCL` fallback line, and undo after a moved file; two Macs organizing
into the same scratch folder at once; on a second Mac, the moves and stats through sync.

### 62. Small fixes: palette, saving status, quit guard

Asked by the owner on 2026-11-09.

- [x] **Palette kinds:** short prefixes beside the full names: `a:` album, `ar:` artist,
      `t:` track, `p:` playlist, `g:` genre. `song:` goes; the word is "track" everywhere,
      placeholder included (ADR 0161 amended).
- [x] **Saving status:** the status bar's "Saving tags: N of M" counts every queued and running
      batch, as the tagger window does (`TagWriteProgress.combined`), so a second batch queued
      mid-run raises M at once instead of after the first ends. One count, read by both.
- [x] **Quit guard:** `applicationShouldTerminate` while tag writes are running or queued asks
      "N tag writes haven't finished." with Wait and Quit (default), Quit Anyway and Cancel.
      Wait and Quit terminates when the queue drains; the play state save still runs.
- [x] **Status bar:** the downloads item moves from the right end to the left side, after the
      scan and saving labels.

Implementation plan, phase 62 (ADR 0161 amended, ADR 0167):

What exists, found by search (map.md recipes): the kind words are `PaletteItem.Kind`'s case
names, read by `PaletteQuery` through `queryNames`, with `songName` the one alias; the Go to
Item placeholder is in `PaletteController.show`. `TagEditing.enqueue` reports each batch's own
`TagWriteProgress` to `saving`, and `pendingWrites` counts what is queued; the tagger sums its
writes with `TagWriteProgress.combined` (`TaggerModel.writeProgress`).
`AppDelegate.applicationShouldTerminate` saves the play state with a 1 s bound. The downloads
item goes in through `LibraryBrowser.setStatusAccessory`, into `statusTrailing`.

- 62.1 Palette kinds: `PaletteItem.Kind.shortName` (`a`, `ar`, `t`, `p`, `g`; none for
  command, setting and output) joins the name in `queryNames`; `songName` goes. The
  placeholder names `album:`, `a:`, `track:` and `t:`. ADR 0161's typed-search bullet amended.
- 62.2 Saving status: `enqueue` takes the batch's file count; the write batches queued and
  running are kept by number with their last report, and `saving` gets `combined` over all of
  them, at each report and when a batch is queued while one shows, so M rises at once. Undos
  and organizes have no count and report nothing, as now.
- 62.3 Quit guard: `TagEditing.holdQuit(_:)` returns false with nothing queued; otherwise it
  asks through a new effect, "N tag writes haven't finished." (Wait and Quit, Quit Anyway,
  Cancel), and calls back: Cancel at once with false, Quit Anyway with true, Wait and Quit with
  true when `pendingWrites` reaches 0. The app returns `.terminateLater` while it holds, then
  runs the play state save as now. ADR 0167.
- 62.4 Status bar: `setStatusAccessory` inserts the view into `statusLeading` after the
  analysis label, before the leading columns, whichever is laid out first; ADR 0163's bullet
  amended.

Tests: `PaletteTests` (each short prefix, `song:` now plain text), `TagEditingTests` (a second
batch queued mid-run raises M at once; each quit answer, nothing asked with nothing queued),
`StatusBarLayoutTests` (the item after the labels and before a leading column, set before or
after the layout).

Result, phase 62: shipped all four items (ADR 0167; 0161 and 0163 amended). The palette takes
`a:`, `ar:`, `t:`, `p:` and `g:`, and `song:` is plain text. The status bar's saving count
covers every batch queued since the queue was last empty, so it never goes backwards (the
owner's call at the gate, which reverses the first cut's drop of a finished batch). Quitting
with tag writes queued asks first; N counts batches, and a staged download's write
(`StagedWriter`) isn't held. The gate found no other bug. `./scripts/check links format
typecheck arch dupes surface test` passed; no bench, as nothing touched a budgeted path. Cost:
implementer (Opus) 145k tokens, 95 tool calls, 21 min; gate (Sonnet) 61k tokens, 14 tool
calls, 3 min.

**Owner check:** queue a large tag write and quit: each of the three answers; queue a second
batch mid-run and watch the status bar's total rise at once; `a:` and `t:` in Go to Item.

### 65. Tagger: confidence and the safe set

Asked by the owner on 2026-11-09.

- [x] **Confidence:** each album's match carries a confidence, 0 to 100%, from the chosen
      release's `ReleaseScore` (title fit, durations, count, how it was found, ties), shown as
      a column between Files and Review. Every title the same (above `sameTitle`) scores high
      even when found by title only; one title differing slightly lowers it a little. The
      formula and its thresholds are in an ADR.
- [x] **Safe to apply:** a filter, or a tab after Likely, listing the albums whose every title
      matches, with the counts and durations fitting, whose only reason is "found by title
      only". Select All and Apply work on it as on the other tabs.
- [x] **No extra API requests:** choosing a release in Other Releases loads that release
      (`release(id:)`, cached) and scores it, instead of rerunning the album's searches. Other
      Releases and View Changes already send none beyond the cover the apply would fetch; a
      test with a counting stand-in transport holds both to that.

Implementation plan, phase 65 (ADR 0170):

What exists, found by search (map.md recipes): the matcher (`AlbumMatcher.match`) scores every
candidate (`ReleaseScore`), picks and tiers one, and keeps of the chosen score only the reasons
(`NotExactReason.reasons`) and the mapping. How a release was found is `CandidateKey`, dropped
after the reasons. The window's tabs are `MatchTier.allCases`, with `model.tab` a tier, and
Apply to All writes `applicable(tab)`. Choose goes through `rematch`, which runs
`effects.match`, so in API or Both mode it repeats `ApiCandidates.found`'s searches.

- 65.1 Confidence (`Core/Discogs/MatchConfidence.swift`): the percent from the shown score, the
  album's title similarities, the tie and how the release was found, with its weights in that
  file, not `MatchThreshold`, which the golden file pins. `AlbumMatch` gains `confidence`
  (nil with no release scored) and keeps `foundBy`; `MatchCandidate` keeps its `foundBy` too,
  so choosing it later can say how it was found. Ranking, tiers and reasons don't change.
- 65.2 Choosing without searching (`Core/Discogs/AlbumMatcher.swift`): `chooseRelease` loads
  the one release, from the catalog when the source has one and it holds it, else
  `api.release(id:)` (cached), and scores it alone with the choice branch's tiering, which
  becomes one function both paths call. The other candidates are the previous match's, with the
  previously chosen release rescored among them. `TaggerModel.Effects.choose` wraps it;
  `TaggerModel.choose` calls it in place of `effects.match`. A staged tagger keeps its own
  match (default effect unused there: its release is fixed).
- 65.3 Confidence column headed "Match", between Files and Review: "92%", blank with none.
- 65.4 Safe tab (`TaggerTab`, after Likely): the Likely albums whose every title is the same,
  in order, with the counts the same and every known length agreeing; by the matcher's rules
  their reasons are at most "other releases fit as well" and "found by title only". It is a view
  of Likely, which keeps them; Apply to All in Safe writes them as the other tabs do.
- 65.5 ADR 0170: the formula, its weights, why a tab, the safe rule and the choose path;
  0131 and 0136 get see-also lines.

Tests: confidence of an exact, a title-only, a tied, a one-title-off and a bonus-track album
(`AlbumMatcherTests`); choosing scores the release alone, keeps the candidates and sends no
search, with `FakeDiscogs` counting (`ApiMatchingTests`), and Other Releases' summaries and View
Changes' cover send none beyond the cover; the model's choose doesn't call `match`
(`TaggerRematchTests`); the column and the Safe tab, its count and Apply to All
(`TaggerWindowTests`).

Result, phase 65: shipped all three items (ADR 0170; 0131 and 0136 see-also lines). Each album
match carries a confidence from its chosen release's score, shown as a column headed Match: an
exact match found by barcode is 100%, by title only 95%, a tied Likely found by title 90%. The
Safe tab, after Likely, lists the Likely albums whose only reasons are the tie and "found by
title only" (the plan's "only reason" would leave it always empty, since every title fitting
with agreeing lengths and counts is Exact unless tied); they stay in Likely too. Choosing in
Other Releases loads that release alone, from the catalog or the API cache, with no search, held
by a counting stand-in transport. Deferred: leaving a file out and a full Analyze still run the
album's searches; the confidence isn't recomputed when a file is dragged to another track.
`rank-golden.json` unchanged. The gate found no bug. `./scripts/check format typecheck arch
dupes surface links test` passed, and format, typecheck and test again after the rebase onto
phase 62; no bench row covers the matcher. Cost: implementer (Opus) 255k tokens, 125 tool calls,
26 min; gate (Sonnet) 73k tokens, 16 tool calls, 3 min.

**Owner check:** the Match column and the Safe tab on the real library, with Apply to All in
Safe; choose another release in API mode and see no search in the log.

### 63. A Library pane in Settings

Asked by the owner on 2026-11-09; the owner chose one merged pane.

- [x] **Library pane:** a new toolbar pane, Library, holds the watched folders list, Folder
      Changes, Network Folders, Library Folder, the `library.*` settings (health, database)
      and Snapshots, with the Snapshot Folder row. The Watched Folders pane goes; General keeps
      the rest. ADR 0042's pane list amended.
- [x] **Snapshots gap:** opening then closing the Snapshots disclosure leaves no empty space at
      the top. The pane's scroll origin returns to the top when `fit()` shrinks the window, and
      a test opens and closes it and checks the document's top is at the clip's top.

Implementation plan, phase 63 (ADR 0168):

What exists, found by search (map.md recipes): the panes are `SettingsWindowController.Pane`,
each naming the `GeneralModel.Section`s it shows, and General shows the rest. The Watched
Folders pane is `FoldersPane`, the folders table over a `GeneralPane` of its sections. The
Library section's extra rows (Show Library Health, Database, Last Snapshot, the Snapshots
disclosure) are added by any `GeneralPane` that shows `.library`; Snapshot Folder is a
`library.` row of that section. `PaneScroller.fit()` sizes the window to the pane.

- 63.1 Gap (fix): reproduced in a test before any change. `fit()` runs from the pane's
  frame-change notice, which the window's layout pass posts; resizing the window inside that
  pass leaves the scroll view at its old height plus the change again, so after a close it's
  shorter than the window and the strip above it is empty. `fit()` runs after the pass
  instead. The test opens and closes Snapshots and checks the pane's top is at the window's
  content top.
- 63.2 Rename (refactor): `FoldersPane` becomes `LibraryPane`, the file with it.
- 63.3 The pane (feat): `Pane.folders` becomes `.library`, titled Library, symbol
  `books.vertical`, in the same toolbar place, with the sections Folder Changes, Network
  Folders, Library Folder, Browsing and Database, in that order (`Section` cases reordered to
  match; the owner split the Library box in two, ADR 0168).
  The palette's watched folders and Watched Folders… open it. `--snapshot-of folders` becomes
  `library` (`SnapshotTarget`, `AppDelegate`, README, main.swift's comment).
- 63.4 Docs: ADR 0168, the amended-by lines of 0042 and 0017, README's two pane names.

Tests: the gap test above; the Library pane holds the watched folders table, every section
above with the health, database and snapshot rows and Snapshot Folder, and General none of
them; the palette opens Library for a folder, network or `library.` setting; the command line
test's list of targets.

Result, phase 63: shipped both items (ADR 0168; 0042 and 0017 amended). The Library pane
replaces Watched Folders: the folders list, Folder Changes, Network Folders, Library Folder,
then two boxes the owner asked for at the gate, Browsing (Group by Album Artist, Separate
Releases, File Viewer, Show Library Health) and Database (the database row, Snapshot Folder,
Last Snapshot, the Snapshots list). `--snapshot-of folders` is now `--snapshot-of library`. The
gap wasn't the scroll position: `PaneScroller.fit()` resized the window from inside the layout
pass, which then sized the scroll view again from its old height, 235 pt off; `fit()` now runs
on the next main-queue turn. The gate found no bug. `./scripts/check links format typecheck arch
dupes surface test` passed, and format, typecheck and test again after the rebase onto phases
62 and 65; no bench row covers it. Cost: implementer (Opus) 167k tokens, 95 tool calls, 27 min;
gate (Sonnet) 118k tokens, 32 tool calls, 8 min.

**Owner check:** open and close Snapshots several times, with the window near the screen's
height too; every setting in the Library pane, and the palette's folder settings opening it.

### 64. Downloads: approve, upgrades, Open in Tagger, window

Asked by the owner on 2026-11-09.

- [x] **Approve opens at once:** pressing Approve presents the sheet straight away, saying what
      it's preparing (claiming, planning the moves). The track list shows as soon as the plan
      has it; the lossy-origin check runs after, with a spinner in each checked row, and
      Approve stays disabled until it finishes.
- [x] **Manual downloads as upgrades:** a job queued without `upgrade` (Library Selection, Paste
      a Discogs Release) that matches an album in the index, by its Discogs release id, falling
      back to the same album artist and album title, is planned as an upgrade of that album.
      The sheet says "Replaces N files in the library" and has a Keep Both choice that imports
      it as a new album. The replaced files go to the Trash as Add > Upgrades' do (ADR 0147).
- [x] **Open in Tagger:** opens the staged tagger with the job's album analyzed and its tab
      selected, so a discrepancy can be fixed there. A job it can't open (no staged folder, no
      format, release not in the catalog) says why instead of doing nothing.
- [x] **Window:** the Downloads window's column widths are saved and restored (`ColumnLayout`
      or the table's own autosave, whichever the track table pattern fits), and a saved frame
      on no current screen, or mostly off one, is placed back on the main window's screen.

Implementation plan, phase 64 (ADR 0169):

What exists, found by search (map.md recipes): Approve is `Downloads.review`, which claims the
job, finds the places, builds `ApprovalPlan` (index, moves, the old album, then
`stagedOrigins`, a decode of two files over the share) and only then presents `ApproveSheet`.
A job queued by hand has `upgrade` nil, and the plan replaces an album only when its paths
collide (`albumToReplace`, ADR 0156). Open in Tagger returns silently when
`coordinator.stagedJob` is nil, and the staged tagger never analyzes, since `show` analyzes
only a library selection. The Downloads window's `makeWindow` sets `controller`, so `show`'s
`keepsFrame(as:)` behind `if self.controller == nil` never runs: the window opens at its
content rect's origin, the primary screen's bottom left, and keeps no frame. Its columns have
fixed widths.

- 64.1 Window: `show` calls `keepsFrame(as:)` for the window it made. `placedFrame` treats a
  saved frame the screens together show less than half of as on none, so it's centered on the
  main window's screen. Column widths in `state.json` as `downloads.columns`, a new
  `ColumnWidths` value (by column identifier, as the tagger's sheets keep theirs), applied
  when the window is made and saved through the layout saver as a column resizes.
- 64.2 Open in Tagger: `Downloads.taggerRefusal` says why a job can't open (no staged folder,
  no format, no catalog on this Mac, the release not in it), checked before the tagger
  opens, as an alert. `DiscogsTagger.show` analyzes a staged tagger when it first opens, so
  it opens on the album's tier tab, and says why when the catalog can't be read.
- 64.3 Approve at once: `review` presents `ApproveSheet` first, in a preparing state that
  names the step (claiming, planning the moves); the plan without the lossy-origin check
  fills its tables; the check then runs with a spinner in each checked row, and Approve is
  off until it ends. Cancel while preparing stops the work and gives the claim back; a
  failure closes the sheet and alerts as before.
- 64.4 Manual downloads as upgrades: `ApprovalPlan.build` finds the library album to replace,
  for a job with no `upgrade`, by its Discogs release id, else by its folded album artist and
  title (`CatalogKey.matchKey`), when exactly one album matches with all files on the share.
  It plans the upgrade and, for Keep Both, the moves as a new album. The sheet says
  "Replaces N files in the library" and has a Keep Both box. Each old file is held to the
  release id it carried when approved, recorded in the ledger (a `held` step) for those not
  carrying the job's, so a resume checks it too; `albumToReplace` goes.
- 64.5 ADR 0169, amending 0147 and 0156.

Tests: the window placed and its frame kept on a second show, a mostly-off frame centered,
column widths restored and saved; each refusal of Open in Tagger, and a staged tagger
analyzing on show; the sheet up before the claim answers, the plan's tables before the check,
Approve off until the check, Cancel while preparing giving the claim back; a manual job matched
by release id and by name, two matches left new, Keep Both's plan, and an import whose old
files carry another release or none trashing them, and refusing one re-tagged since. All in
temporary folders, against the fake service.

Result, phase 64: shipped all four items (ADR 0169; 0147 and 0156 amended, 0158 amended-by
line). Approve shows its sheet at once, names the step it's on, fills the track table from the
plan, then runs the lossy-origin check with a spinner per checked row, Approve disabled until
it ends; Cancel at any point gives the claim back. A job queued by hand replaces the one library
album whose every track carries its release id, else the one whose album artist and title fold
alike, edition words kept (the owner's call at the gate: "Album (Deluxe Edition)" is not
"Album"); the sheet says "Replaces N files in the library", which album and how, with Keep Both.
Each old file is held to the release id it carried when found (a `held` ledger step), and one
re-tagged since is refused at the delete. Open in Tagger analyzes the staged album on open, or
says what's missing. The Downloads window never kept its frame: `show()` tested
`controller == nil` after `makeWindow()` had set it, so `keepsFrame` never ran; a frame the
screens show less than half of is now centered on the main window's screen, and column widths
are kept in `state.json`. Deferred: with several albums matching, nothing asks which to
replace. The gate found one bug, the edition words. Full `./scripts/check` passed before
landing; no bench row covers Downloads. Cost: implementer (Opus) 371k tokens, 205 tool calls,
48 min; gate (Sonnet) 79k tokens, 17 tool calls, 6 min.

**Owner checks:** on the NAS with a scratch album, Approve a manual download whose library copy
has no release id: the sheet appears at once, says "Replaces N files", and the old files go only
after the new ones are in place. On a second display, the Downloads window reopens where it was
left, at its size and column widths. Open in Tagger on a discrepancy.
