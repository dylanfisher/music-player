

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

### 66. Artwork

Asked by the owner on 2026-11-09. Bulk art is the front cover only, by the owner's choice.

- [x] **Art viewer:** never scales an image past its own pixel size. An album with several
      images shows a strip of thumbnails along the bottom; the selected image's height shrinks
      to make room, and a click on a thumbnail shows it.
- [x] **Get Info Artwork tab:** lists every embedded image with its type, and adds (open panel,
      drag, paste) and removes any number. `TagEdit.art` becomes a list of pictures with types,
      written by `TagWriter` for ID3, FLAC and MP4 (MP4 `covr` has no types); the round trip is
      tested on generated fixtures. Mixed art across the selected tracks shows as mixed and is
      left alone unless changed.
- [x] **Get Info File tab:** stays aligned left when tabs are switched. The tab's container gets
      its frame before its content is pinned, and the File grid's value column takes the spare
      width.
- [x] **Bulk Discogs cover:** "Get Artwork for N Albums…" in the tagger window, over every
      album with a Discogs release id, and "Get Discogs Artwork" in the library's track menu
      for the selection. Both confirm with the count, fetch the front cover through
      `DiscogsAPI.cover(release:)` (one image request per release, rate-limited), fill albums
      with no art or smaller art, or replace with the Replace choice, and write through
      `TagWriter` with progress in the status bar. Needs the token.

Implementation plan, phase 66 (ADR 0172):

What exists, found by search (map.md recipes): the reader lists every picture in
`TrackMetadata.pictures` (`EmbeddedPicture`, its type internal) when asked; `TrackMetadata.art`
is the front cover or the first. `TagEdit.art` (`ArtChange`) replaces the picture the reader
shows, as a front cover, or removes them all; the writer checks the shown art after each
write. The viewer's `ArtViewer.frame(of:in:)` fits with no cap. Get Info's Artwork tab shows
`TagEditorModel.shownArt`, one image. The tagger fetches covers through
`DiscogsAPI.cover(release:)`, paced by `RateLimiter` in `DiscogsAPI.get`, and writes through
`TagEditing.write(_:over:progress:completion:)`, which the status bar counts (ADR 0167).

- 66.1 Picture types (`Core/Metadata`): `PictureType`, ID3's and FLAC's numbers with the five
  the editor offers by name; `EmbeddedPicture.type` takes it.
- 66.2 Several pictures written (`Core/TagWriter`): `ArtChange.pictures([ArtPicture])` puts
  the list in place of every picture: ID3 `APIC` frames, each with a description of its own,
  where the first old one was; FLAC `PICTURE` blocks; MP4 `covr` data atoms, front covers
  first, no types. `.replace` stays the front cover alone, for Discogs. The write is checked
  by reading every picture back. Round trip and undo on every generated sample.
- 66.3 Editor model: `EditableTrack.pictures`, read whole; `TagEditorModel` lists the shared
  pictures, mixed when the tracks differ, and adds, removes and retypes them into
  `.pictures`; Replace and Remove keep their edits.
- 66.4 Artwork tab: a table of every picture (thumbnail, type pop-up, size), + (open panel),
  − for the selection, drops of image files and Paste.
- 66.5 File tab: the cause found in a test, then fixed (container frame, value column width).
- 66.6 Art viewer: no scale past the image's pixels; with several pictures, a strip of
  thumbnails along the bottom, the image's height less the strip, a click shows one.
- 66.7 Bulk cover (`Core/Discogs/BulkCover.swift`): albums by tagged release id, one
  cover per release through `cover(release:)`, Fill Missing (no art, or fewer pixels than the
  cover) or Replace, giving the edits and the problems. Stand-in transport only.
- 66.8 Tagger: "Get Artwork for N Albums…" over the albums listed with a tagged release id,
  confirming with the count and Fill Missing, Replace or Cancel, then `write`.
- 66.9 Library: "Get Discogs Artwork" (`track.getDiscogsArtwork`) in the track menu, the same
  flow for the selection, through the tagger's public entry, which needs the token.
- 66.10 ADR 0172, see-also lines in 0020 and 0140, and AGENTS.md's clause if it needs one.

Result, phase 66: shipped all four items (ADR 0172; 0020 and 0140 see-also lines, a clause in
the AGENTS.md boundary). `ArtChange.pictures` writes every picture with its type, one APIC
frame each with a unique description, one FLAC PICTURE block each, MP4 `covr` with front covers
first and each picture's own data type code, and reads every one back; `.replace` still changes
only the front cover. The Artwork tab lists the pictures the tracks share, with type pop-ups,
add by panel, drag or paste, and remove; mixed art is left alone unless the list changes. A
kept picture of any type is written back as it was (a gate fix: a GIF in the file blocked the
save, and MP4 relabelled it as a JPEG). The File tab's labels went right because no grid column
took the spare width; the values now do. The art viewer draws at most a point per pixel and
shows a strip of thumbnails for several pictures. Get Artwork for N Albums… (tagger) and Get
Discogs Artwork… (track menu) fill or replace front covers of albums tagged with a release id,
after one question. The gate also replaced every `performClick` in Tests with
`Fixtures.click` (ADR 0127's early exit 0). Deferred: a list edit drops pictures the reader
can't list (compressed, encrypted or linked APIC frames, unknown `covr` types); a library Get
Artwork's progress shares the save slot. Bench, Apple Silicon, all within budget: tag journal
1000 files 7.99 s, NAS read 200 files 0.57 s, temp-file write on the NAS 72.2 s, JPEG decode
14.6 ms, PNG 74.8 ms; window rows left for the owner's Mac. Full `./scripts/check` passed before
landing. Cost: implementer (Opus) 429k tokens, 316 tool calls, 53 min; gate (Sonnet) 159k
tokens, 71 tool calls, 23 min.

**Owner checks:** in Get Info's Artwork tab on a scratch copy, add, retype and remove pictures
in an MP3, a FLAC and an M4A, then check them in another player; the art viewer on an album with
several pictures, on Retina and the 2015 MacBook Pro; Get Artwork on a few tagged albums, Fill
Missing then Replace.

### 67. Safer matches and messy album titles

Asked by the owner on 2026-11-09: more albums safe to apply from a whole-library run, a tab for
"every title the same, some lengths off" that isn't fooled by "Untitled 1, 2, 3", and albums
found whose title carries label information, such as `Ghost [WIGCD 32]`.

- [x] **The tuning per tab:** `discogsTuning` reports each Apply to All tab as the tagged release
      or a twin, another release of its master, or wrong, runs on the untagged albums too, and
      writes `albums.tsv`, a line per album and run, to compare two tunings by.
- [x] **Title spellings:** trailing and leading catalog-number brackets, format and disc words,
      and the artist's name before a dash, each step a spelling looked up beside the title.
- [x] **The title's catalog number:** for the label lookup and the tie-break, when the tags have
      none.
- [x] **The artist alone:** when nothing is found, the artist's releases, kept only when Likely,
      never Exact, with "found by artist only".
- [x] **Safe and Titles Fit** decided in the matcher (`AlbumMatch.safety`): distinctive titles,
      a tie only with the same album, Titles Fit's lengths. Tooltips on every tab.
- [x] **The confidence:** points off for titles that say little unless lengths agree, and for a
      tie with another album.

Plan:

- 67.1 `MatchSafety` in `Core/Discogs`, read by `TaggerTab`; the tuning's per-tab rows,
  untagged run and `albums.tsv`; a baseline.
- 67.2 `CatalogKey.titleVariants(_:artist:)` and `catalogNumbers(inTitle:)`; `catalogNumbers`
  in `candidateIDs`, `ApiCandidates` and `tieBreak`; tuned.
- 67.3 The artist-only search (`Catalog.mainReleases(byArtist:limit:)`,
  `artistOnlyReleases`), its reason, confidence and tier cap; tuned for recall against time.
- 67.4 `TitleDistinctness`, the tie with another album, `MatchSafety.of`, the confidence;
  the Titles Fit tab, tooltips, Apply to All; tuned.
- 67.5 ADR 0174, a see-also line in 0170.

Result, phase 67: shipped all six items (ADR 0174). On the 2026-11-07 survey, with tags: Exact
or Likely right 1564 → 1573 of 1632, Exact with a wrong release 29 → 29, Safe 48 → 43 albums
with no wrong album either way, Titles Fit 98 albums, none wrong. Titles only: right 1004 →
1038, Safe 376 → 364 (two counted wrong, each the same tracklist under another release), Titles
Fit 83, none wrong. Untagged: no candidate 2789 → 1761 of 4905, Safe 185 → 220, Titles Fit 64.
The artist-only search found about 450 of those, about 75% right where the answer is known, so
it stops at Likely. It first took 38 ms an album, nearly all random reads in the 37 GB catalog;
searching only albums with no candidate and reading at most 50 masters brought it to 3.3 ms, 450
found against 465 at 100. A tie only within one master took 26 good albums out of Safe; a tie
across both masters and titles took 5. `DownloadsCoordinatorTests`' lease test failed once
under the parallel run and passed three times alone, outside this phase's code. Implemented in
the orchestrating session (Opus), without a separate implementer. The gate's review (Sonnet,
101k tokens, 17 tool calls, 4 min) found Both no longer sending artist-only matches to the API
and the tie-break missing a title number's second spelling, both fixed. Full `./scripts/check`
passed before landing, after a rerun of `PlayerImportBrowserTests`, which failed once under
load and passed alone.

### 71. Choosing another release for a download

Asked by the owner on 2026-11-09. The service side (stall timers, offline peers, cleanup, and
recording a new release on a job) is a separate prompt for music-recommender.

- [x] **A staged download can take another release.** In the tagger opened from Downloads,
      Other Releases… and Look Up… choose another release, as for a library album, instead of
      refusing with `StagedReleaseFixed`. The write stays in the staging folder (ADR 0146) and is
      confirmed as any tagger write is. The Downloads row says the album is tagged as another
      release than the one queued, and Approve still works. When the service offers a call to
      record the job's new release, the player makes it; until then the player keeps the new
      release with the staged job and says so.

Implementation plan, phase 71 (ADR 0178):

What exists, found by search (map.md recipes): the staged tagger (`StagedTagging.swift`) fixes
its release to `StagedJob.releaseID`, refuses any other review with `StagedReleaseFixed`, and
has no Look Up (`canLookUp` is false for a staged job). Its Apply hands the verdict to
`resolved`, which Downloads passes to `DownloadsCoordinator.resolved`, which records the files'
sizes as `tagged` steps in the index's import ledger (`ImportJobs.swift`) and reports the
verdict. `coordinator.stagedJob(_:)` builds the `StagedJob` the tagger and AutoTag take. The
service has no call to change a job's release, so `DownloadJob.release` stays the queued one.

- 71.1 The ledger (`Core/Library`): an `ImportStep.Kind.retagged` step, the job's folder as its
  path and the release its files were tagged as in `destination`; `recordTaggedRelease`, which
  forgets the step when the release is the queued one, and `taggedReleases()`, giving
  `TaggedRelease` (folder, release) by job. `TaggedRelease.differs(for:)` is the release a
  row names: only while the job is staged in that folder and the service lists another.
  Forgotten with the job's other steps once it's imported. Tests in `ImportJobsTests`.
- 71.2 The staged tagger (`StagedTagging.swift`, the staged init in `DiscogsTagger.swift`,
  `canLookUp`): a staged review takes any chosen release, kept for the session; Analyze and
  Other Releases… match it; Look Up… searches the local catalog only, as every staged match
  is. Reject still points to Downloads. `resolved` hears the release written with the
  verdict. Tests in `StagedTaggerTests`: choose and Look Up take another release, and Apply
  reports it.
- 71.3 Downloads: `coordinator.resolved` records the release before its report, and
  `stagedJob(_:)` tags with the recorded one, so a reopened tagger or a rerun keeps it. The
  model holds the recorded releases for its rows; the row's Tagging cell adds "another
  release" to the verdict's word, and its tooltip and the album's say which release was
  queued, which the files are tagged as, and that the service doesn't know yet. The Approve
  sheet's subtitle names both. Approve itself is unchanged: the old files of an upgrade or a
  replaced album are still the queued release's. Tests in `DownloadsCoordinatorTests`, the
  row's and model's tests, and the window's.
- 71.4 ADR 0178, an amended-by line in 0146 and a see-also in 0147 and 0145. AGENTS.md
  unchanged: the tagger's write is a confirmed one in the staging folder.

Result, phase 71: shipped the item (ADR 0178; an amended-by line in 0146, see-also lines in
0145 and 0147; AGENTS.md unchanged, since the tagger's write is a confirmed `TagWriter` write
inside the staging folder). The staged tagger's Other Releases… and Look Up… choose any release
in the local catalog; Look Up asks no API, as no staged match does. Apply reports the release it
wrote with the verdict (the plan's release, taken before the write; a partial write passes
it on with no verdict, so it's kept all the same), and the coordinator keeps it in this Mac's
import ledger as a `retagged` step, which the tagger and a rerun of the tag run then match. The Downloads row's
Tagging cell says "Clean, another release" (or the verdict's own word), its tooltip and the
album's name both releases, and the Approve sheet's subtitle says "Tagged as Discogs release N,
queued as M". Approve is unchanged; the album it replaces is still the queued release's.
Open: music-recommender has no call to record a job's new release, so only the Mac that tagged
the files knows it; another Mac's row and tagger show the queued one. When the service adds
the call (likely `POST /v1/downloads/release` with `id` and `release_id`), it goes in
`RecommenderClient` beside `retry`, in `DownloadsService`, and in
`DownloadsCoordinator.resolved` before the tagging report; the row stops naming the release once
the service lists it. Tests: the ledger's record, replace and forget (`ImportJobsTests`), the
coordinator keeping and forgetting it (`DownloadsCoordinatorTests`), the row, model, window and
sheet's words, and the staged tagger choosing, looking up and reporting the release, after a
partial write too, and the plan's release when another is chosen during the write
(`StagedTaggerTests`). Flakes seen in the parallel runs and passing alone: SettingsWindowTests,
`aPollThatOverlapsTheRecoveryWaitsForItBeforeTagging`, `ImportCheckpointTests`,
`PlayCountTests.saveStoresTheCountWithoutAWrite`. Implemented by an Opus implementer (253k
tokens, 120 tool calls, 32 min, with its review fixes). The gate's review (Sonnet, 67k tokens,
12 tool calls, 1 min) found the release read after the write and a partial write left
unrecorded, both fixed, and `taggedAs()` noting a failed read on every poll, now once. Full
`./scripts/check` passed before landing.
