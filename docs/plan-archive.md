

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

### 68. Organize's progress and the Library Problems window

Asked by the owner on 2026-11-09 (ADR 0164 is Keep Files Organized).

- [x] **Organize Selected Files opens at once.** The confirmation opens as soon as the command
      runs, counting the tracks and files to rename with live progress, and Cancel works while it
      counts. Its buttons and summary appear when the count is done. A test with a slow counting
      stand-in.
- [x] **Progress after Organize.** Once confirmed, the status area at the bottom left shows how
      many files are left, progress, and the current file or folder, until the run ends, then a
      one-line result ("Organized 2,340 files; 3 problems"). Library Problems opens only when
      there were problems, as now.
- [x] **Library Problems is a normal window.** It no longer floats above other apps' windows or
      the app's own; it can go behind them like any document window.
- [x] **Library Problems as a table.** A standard table like the tagger's album list: a column
      for each piece (the problem's kind, the track or album, the file's path, the folder, the
      detail), sortable by any column, with resizable columns that are remembered, and the
      window's frame remembered (ADR 0158). The problem text is plain enough to act on.

Implementation plan, phase 68 (ADR 0175):

What exists, found by search (map.md recipes): `LibraryBrowser.organizeFiles` reads every
selected file's tags with `layoutMoves` before `askToOrganize`'s `NSAlert` opens, so a large
selection on the NAS shows nothing for minutes. `TagEditing.enqueue` runs `moveToLayout` on the
tag writes' queue with no progress; the status bar has slots for a save, a copy and Analyze
(`LibraryStatus.savingText` and the rest). `ProblemsWindow` is a utility `NSPanel` with one
headerless column of lines; `Problem` is a line and a fix. The Downloads window keeps its column
widths as `downloads.columns`, a `ColumnWidths` in `AppState` (ADR 0169), the pattern to follow.

- 68.1 Counting (`Core/Library`): `layoutMoves` takes a progress closure, told the files checked
  and the moves found so far, and a stop check read before each file. Tests: the counts as it
  goes, and a stop leaves the rest unread.
- 68.2 The sheet (`Features/LibraryBrowser/OrganizeSheet.swift`): a sheet of its own, opened
  as the command runs, before the selection's paths are read: "Checking N of M tracks", a bar
  and Cancel, which stops the count; once counted, the question's text and Organize, or OK
  when nothing moves. `confirmOrganizing` goes; the counting is an injected closure. Tests,
  through the sheet's buttons with `Fixtures.click`: a counting stand-in held on a gate shows
  the sheet and its progress first, Cancel stops it and organizes nothing, Organize hands on
  the plan.
- 68.3 Progress (`Core/Library`, `TagEditor`, `LibraryBrowser`, App): `moveToLayout` tells a
  progress closure each file it reaches (`OrganizeProgress`: done, total, current path);
  `TagEditing.organizing` passes it to the main thread; `LibraryStatus.organizingText` shows
  "Organizing files: 2,328 left · Artist/Album/01 Song.flac" with its bar until
  `finishOrganizing`, whose line becomes "Organized 2,340 files; 3 problems". Tests: the
  progress from a rename run, the status text and fraction, the summary.
- 68.4 A normal window: `ProblemsWindow`'s window becomes a titled `NSWindow`, not a floating
  panel. Test: its level is normal and it isn't a panel.
- 68.5 The table: `Problem` gains a kind, the path it's about and its detail, filled where the
  rows are made (file issues, scan issues, the folder failures, health, organize and drops),
  and parsed from "<path>: <detail>" lines for the rest; the window gets Kind, Track, File,
  Folder and Detail columns, sortable, their widths kept as `problems.columns` in `AppState`
  and wired by App. The Track column is looked up from the index by path. Tests: the columns'
  text for each kind of row, sorting by a column, the widths reported and applied.
- 68.6 ADR 0175, cross-linked from 0164 and 0059.

Result, phase 68: shipped all four items (ADR 0175; amended-by lines in 0164 and 0059). Organize
Selected Files opens `OrganizeSheet` as the command runs, before the selection's paths are
read, with "Checked N of M tracks · K files to rename so far" and a bar fed by `layoutMoves`'
new `counted` closure; Cancel sets the stop that `layoutMoves` asks before each file, so the
count ends unread and nothing is renamed. Once counted the sheet shows the old question and
Organize; a count with nothing to move closes it and reports as before. `moveToLayout` tells
an `OrganizeProgress` before each file and after the last; `TagEditing.organizing` brings it to
the main thread and the status bar shows "Organizing files: N left · Album/01 Song.flac", then
"finishing" while the folders are tidied and the stats carried, until `finishOrganizing` says
"Organized 2,340 files; 3 problems" (Keep Files Organized's renames show the same way).
`FilesOrganized.summary` went; `problemCount` is the one "N problems". Library Problems is a
titled `NSWindow`, no longer a utility panel. Its table has Kind, Track, File, Folder and Detail
columns, each sortable, rows the column holds equal keeping their order; widths are kept as
`problems.columns` in `state.json`, wired by App as the Downloads window's are. File issues,
scan issues, failed scans, health lines and an import's misses fill the columns from their own
fields, a file issue's failure and warning said in words; the other reports' lines split at
the first ": " after a leading path and take their report's kind. The Track column is looked up
by path through `trackIDs(atPaths:)` and `rows(ids:)`. `line` is unchanged, so earlier
dismissals still match. Tests: the count's progress and stop, the renames' progress, the
progress reaching the main thread through `TagEditing`, the sheet up before a held count with
Cancel stopping it, Organize and Cancel through the sheet's buttons, the status text and the
result line, the normal window, each kind of row's columns, the statuses' kinds, sorting with
the selection kept across a refresh, the widths applied and reported, and the browser's track
lookup and kept widths. Check steps `format typecheck arch dupes surface links` passed and
`./scripts/test --changed main` passed. Not measured: no bench row covers these paths. Deferred:
the sort isn't kept across launches (only the widths were asked for), and the organizer's and
move list's lines are still strings made in Core, split for the columns rather than built
structured, since the tag editor and Core are being changed by phases 69 to 71 in parallel. Implemented by an Opus
implementer (249k tokens, 123 tool calls, 34 min, with its review fixes). The gate's review
(Sonnet, 70k tokens, 12 tool calls, 1 min) found a main-thread post for every file counted
or renamed, now one per percent, and a failed track lookup adding a fresh undismissable line
on each refresh, now one stable line; both fixed with tests. Full `./scripts/check` passed
before landing.

**Owner checks:** Organize Selected Files on a few thousand tracks on the NAS: the sheet at
once, the count moving, Cancel mid-count, then a real run with the status bar's count and
file, and the result line; Library Problems behind Finder, a sort by Folder, a column
resized and the window moved, both kept after a relaunch.

### 69. Tagger columns and the releases window

Asked by the owner on 2026-11-09.

- [x] **Sort the album list by any column:** a click on Album, Files, Match or Review sorts by
      it, a second click reverses it, and the sort is remembered.
- [x] **Column widths are remembered** between launches. The owner reports they aren't: find
      why with a test that relaunches the window, then fix it.
- [x] **The releases window remembers itself.** The sheet or window for choosing a release
      (Other Releases, Look Up) keeps its size, its position where it has one, and its column
      widths and order, like every other window (ADR 0158). This includes the tagger opened from
      Downloads (Open in Tagger).

Plan:

- 69.1 A test that shows the tagger, widens the album list's columns, and opens a second tagger
  with what the first saved: it fails because nothing records the album list. The fix:
  `TableLayout` in `Core/Settings` (widths, order, sort), which `TaggerSheetLayouts` holds for
  each sheet and, with the album pane's width, for the album list; one `NSTableView` apply and
  record in `DiscogsTagger` for both; the window records on a column's resize or move and the
  divider's drag, and applies once its frame is placed, as Downloads does. `StateStoreTests`
  for the new shape.
- 69.2 The album list's sort: `TaggerModel.AlbumSort` by Album, Files, Match or Review, ties in
  artist and title order; header clicks set it, the layout keeps it. Model and window tests.
- 69.3 The sheets keep their column order through the same `TableLayout`; Open in Tagger's
  tagger gets the layouts and saves them, and the two taggers share one copy. A window test of
  the order.
- 69.4 ADR 0176, cross-linked from 0136 and 0158.

Result, phase 69: shipped all three items (ADR 0176). Why the widths went: nothing recorded the
album list. The sheets kept their layouts (ADR 0136), the window's own table had none, and its
divider always started at 340 points. A test that shows the tagger, drags the divider to 460
and widens Files, then opens a second tagger with what the first saved, failed with every
column back at its default; it passes now. The album list keeps its pane's width and its
columns' widths, order and sort in `discogsTagger.sheets`, saved as each changes and applied
once the frame is placed. A header click sorts by Album, Files, Match or Review and a second
reverses it, ties and no sort in artist-then-title order. The sheets now keep their column order
too, through the same `TableLayout`. Open in Tagger's tagger gets and saves the layouts, and the
two taggers share one copy so neither saves over the other's. A sheet has no position of its
own; it opens over the tagger's window, which keeps its frame. The setting's shape changed, so
a saved one is discarded once. Tests: the relaunch, the sort in the model and through the
header, the sheets' order, layouts reaching an open window, the setting's round trip and
discards. Not run in the app: an owner check that the widths, the divider and a sort survive a
relaunch, and that a sheet from Open in Tagger (View Changes now; Other Releases once phase 71
lets a staged album choose) keeps its size. Implemented by an Opus implementer (200k tokens, 100
tool calls, 39 min, with its review fixes). The gate's review (Sonnet, 62k tokens, 6 tool
calls, 1 min) found a saved order naming a column twice crashing `apply`, now discarded, and
window resizes saving over the owner's widths, now saved only on a column drag or a divider
drag (a `DividerSplitView` whose `mouseDown` reports the drag's end, untested since a test
can't drag); both fixed. Full `./scripts/check` passed but for `WindowGlassTests
.theGlassHeadersAreFrosted`, whose screen capture came back empty while the Mac's screen was
locked; it failed the same way on `main`, so it's the locked screen, not this phase.

### 70. Artwork, Settings and Get Info

Asked by the owner on 2026-11-09.

- [x] **The art viewer opens without layout shift.** It opens at its final size: no frame drawn
      stretched across the screen and then shrunk, and the thumbnail strip's space is reserved
      before the thumbnails load, from a cheap count of the album's pictures. Thumbnails fill
      in place.
- [x] **⌘⌥⇧A shows the artwork viewer,** unless that chord is already taken (check
      `KeyChord` and the menus first; if it is, say which command has it and pick none).
- [x] **Watched Folders is its own Settings tab again,** next to Library, so Library is shorter
      (ADR 0168 moved it).
- [x] **Snapshots always show** in Settings' short table; the collapse toggle is removed.
- [x] **Get Info's previous and next track:** left and right arrow buttons in the bottom button
      row move to the previous and next track of the list Get Info was opened from, with
      unsaved edits handled as closing the window handles them (ADR 0160).
- [x] **Get Info warns about one title for several tracks:** a save that gives several tracks
      the same title asks first, naming the title change, since it's usually a mistake made by
      editing a multiple selection. Other fields shared by every track, such as the album, don't
      ask.

Implementation plan, phase 70 (ADR 0177):

What exists, found by search (map.md recipes): `TrackTableController.openArt` makes an
`ArtViewer`, shows it at once with the hover's small image drawn enlarged to the screen, then
starts the decode at the screen's pixels and the pictures read; the decode, never enlarged,
shrinks the art, and the read adds the strip, which shrinks it again. `readMetadata(pictures:)`
lists a file's pictures without reading their bytes. ⌘⌥⇧A is `track.showInAllMusic`'s
(`AppCommands`, Show in All Music, in the track and View menus). Settings' Library pane is
`LibraryPane`, the folders table over a `GeneralPane` of the `Pane.library` sections; the
Snapshots list is a fallback row under a disclosure in `GeneralPane.addSnapshotRows`. Get Info
is a `TagEditorWindow` on fixed `paths`, opened by `TagEditing.open(_:over:)` from the
browser's `selectedPaths()`; closing it, by Cancel or its close button, drops what was typed.
A save of several files asks `Confirmation.writing`.

- 70.1 Art viewer (fix, `Features/LibraryBrowser`): `ArtViewer.open(_:path:failed:)` reads
  the pictures and decodes the art together, off the main thread, then lays out the strip with
  a button for each picture and the decoded art, and only then orders the window front;
  thumbnails fill their buttons as they decode. `openArt` calls it; a close before it's ready
  drops it. A decode that fails still opens, on the opening image.
- 70.2 ⌘⌥⇧A: taken by Show in All Music, so nothing changes; reported.
- 70.3 Rename (refactor): `LibraryPane` becomes `FoldersPane`, the file with it, as before
  phase 63.
- 70.4 Watched Folders pane (feat): `Pane.folders`, titled Watched Folders, symbol `folder`,
  after Library: the folders table, Folder Changes and Network Folders. Library is a
  `GeneralPane` of Library Folder, Browsing and Database. The palette's folder settings and
  Watched Folders… open the new pane; `--snapshot-of folders` draws it. README's pane names.
- 70.5 Snapshots (feat): the list's row always shows, with no disclosure.
- 70.6 Previous and next track (feat, `Features/TagEditor`, `Features/LibraryBrowser`, app):
  the browser hands Get Info the list it was opened from, as `TrackList` (the track table's
  ids then, the selected row, and a path read for a row); `TagEditorWindow` gets ‹ and ›
  buttons at the left of its button row, on for a one-track window with a row before or after,
  and a step shows that track in the same window, as `TagEditing` reads it, dropping what was
  typed, as a close does.
- 70.7 One title for several tracks (feat): a save whose edit sets a non-empty title on more
  than one file asks `Confirmation.sameTitle` in place of `.writing`, naming the title.
- 70.8 ADR 0177; 0168, 0042 and 0160 amended-by lines.

Tests: the viewer is visible only once laid out, with every thumbnail button and the decoded
art's frame at once, the art's frame unchanged once the thumbnails load; the existing viewer
tests wait for the open. The Watched Folders pane holds the table and the folders' boxes and
Library the rest; the palette opens each. The Snapshots list shows with no disclosure; the
gap test uses another disclosure. Get Info's › and ‹ show the next and previous track in the
same window, off at the ends, off for several tracks, and drop what was typed. A title saved
over two tracks asks, naming it; an album doesn't.

Result, phase 70: shipped five of the six items (ADR 0177; 0168, 0042, 0172, 0160 and 0021
amended-by lines). The sixth, ⌘⌥⇧A, already belongs to Show in All Music
(`track.showInAllMusic`, in the track and View menus), so no chord was assigned, as the item
says; the owner can pick another. The art viewer now reads the file's pictures (a tag read,
no picture bytes) and decodes the art together before it shows, with a strip button for
each picture, so it opens at its final size and the thumbnails fill in place; a close while
it opens keeps it hidden. Settings ▸ Watched Folders is its own pane again, after Library,
with the folders list, Folder Changes and Network Folders; Library keeps Library Folder,
Browsing and Database; `--snapshot-of folders` draws the new pane, and a snapshot from a
scratch home shows it. The Snapshots list always shows. Get Info has ‹ and › at the left of
its button row: for a window on one track they step through the track table as it was listed
when Get Info opened, in the same window, dropping what was typed, as closing does; off for
several tracks and for the timeline. A save that gives several tracks one non-empty title
asks "Give all N tracks the title “…”?" in place of the batch question. Tests added: the
viewer opening laid out and a viewer closed while opening; the two panes' contents and the
palette opening each; the always-shown Snapshots row; Get Info's steps, ends, multi-track
case and a row whose track left the library; the browser's list; the title question.
`./scripts/check format typecheck arch dupes surface` and `links` passed, and
`./scripts/test --changed main` passed (a Downloads test and some browser status-text tests
failed once under the parallel run and passed alone or on a rerun). Not done: a step doesn't
move the browser's selection, and nothing asks about unsaved edits on a step or a close. Implemented by an Opus implementer (277k tokens, 164 tool
calls, 47 min, with its review fixes). The gate's review (Sonnet, 62k tokens, 10 tool calls,
1 min) found the viewer dropping its decode when the row's art was no longer among the file's
pictures, so it opened on the stale art, now fixed with a test; a sign that the viewer is
opening was left out (AppKit has no public busy cursor, and the status line is a browser
action away), and the title question keeps counting the files written, as the window's
read-only line does, now pinned by a test. Full `./scripts/check` passed but for
`WindowGlassTests.theGlassHeadersAreFrosted`, whose screen capture is empty while the screen
is locked, as on `main`.

### 72. Combine Albums for Tagging

Asked by the owner on 2026-11-09, as proposed: "Combine Albums for Tagging", a command-palette
command (and a track menu item) on the albums selected in the library.

- [x] **Joined for tagging:** it opens the Discogs Tagger with the selected albums joined into
      one album, their files in disc and track order, and analyzes it, so the matcher compares
      every file with the catalog, and a release of the whole count ranks first.
- [x] **Albums with different titles or artists** are allowed, and the tagger names every
      source album on the joined one, so combining "1983" with "1983 [Expanded Reissue]" by
      mistake is easy to see before writing.
- [x] **Review and write** as any tagger write: nothing writes until the owner confirms; two
      files that would be the same track show as a conflict in the review, as now; Other
      Releases… and Look Up… work; undo works. After the write every file carries one release
      id, so Separate Releases shows them as one album.
- [x] Works with the Discogs API alone, only slower.

Implementation plan, phase 72 (ADR 0179):

What exists, found by search (map.md recipes): the tagger's Analyze scopes to the library's
selection (`TaggerModel.Scope.selection`) and matches each of its albums, a `DiscogsAlbum` from
the index (`discogsAlbums`, one per album id, tracks in disc and track order). The matcher
compares the files in that order with each candidate's tracklist and ranks a release of the
album's count first; a file two files would share is left on no track, which the review shows
as Missing and keeps the album out of Exact. Reviews are saved on the files and read back by
album id. `DiscogsTagger.show()` scopes to the selection and analyzes with the catalog only.
Separate Releases makes an album of title, artist and release id (ADR 0143), so the files
become one album only when those three agree; the Minimal mapping doesn't write the title.

- 72.1 The mapping (`Core/Settings`): `DiscogsMapping.combining(titles:artists:)`, the mapping
  with the album title, or the album artist, replacing its tag, whatever its mode and the
  Keep existing values choice say, and writing the tag the index groups by. Tests in
  `DiscogsMappingTests`.
- 72.2 The model (`Features/DiscogsTagger`): a `Scope.combined`, "Selected Albums as One";
  Analyze in it joins the selection's albums (`CombinedAlbum.swift`): albums by their first
  disc, then title, each in its own disc and track order; the first's title, artist and
  details for the search; an id of its own (the first source's, negated), so a session's
  left-out files and counts don't mix with a source's. `Album.sources` names them; it takes
  a review only when every source has the same one. Fewer than two albums is an alert. Its
  changes come from `combining`, for the title when the sources' titles differ and the
  album artist when their artists do. Tests in `TaggerCombineTests`: the join and its order,
  the match seeing one album, the review, the forced title, fewer than two.
- 72.3 Naming the sources: the album list's cell ("Persuader – 1983 + Persuader – 1983
  [Expanded Reissue]"), a line over the tracklists ("Combined from 2 albums: … (10 files) ·
  … (14 files)"), the album list's tooltip, and Apply's confirmation. Window and
  confirmation tests.
- 72.4 The command (`Core/Commands`, App): `track.combineForTagging`, "Combine Albums for
  Tagging…", in the track menu after Get Discogs Artwork… and in the File menu beside it,
  enabled with tracks selected; it calls `DiscogsTagger.combineSelection()`, which shows the
  window in the combined scope and analyzes at once from whichever source is chosen, the
  API too, since the command is the click. Busy, it says so. Tests: the menus, and the
  tagger opened by it with each source.
- 72.5 ADR 0179, see-also lines in 0133, 0139 and 0143.

Result, phase 72: shipped all four items (ADR 0179; see-also lines in 0133, 0139 and 0143;
AGENTS.md unchanged, since the write is a confirmed `TagWriter` edit through the tag editor's
queue). Combine Albums for Tagging… is in the palette, the track menu after Get Discogs
Artwork… and the File menu beside it. It opens the tagger in a new scope, Selected Albums as
One, and analyzes at once from the chosen source, the API too; a busy tagger, no selection, a
missing catalog or a single album is an alert. The albums go by first disc, then title, each in
its own order, so an album and its reissue aren't interleaved; the search takes the first's
title and artist; the combination's id is the first's negated, so left-out files and counts
don't mix with a source's. It takes a review only when every source has the same one. Where
the sources' titles differ, the files get the release's album title, and where their artists
differ, its album artist, whatever the mapping or Keep existing values say
(`DiscogsMapping.combining`), since Separate Releases makes an album of title, artist and
release id together and the Minimal mapping writes no title. The album list names every source
("Persuader – 1983 + Persuader – 1983 [Expanded Reissue]"), a line over the tracklists and the
row's tooltip list each with its file count, and Apply's question says which albums the files
come from. Two files on one track, Other Releases…, Look Up…, the write and Undo Tag Edit are
the existing paths, on the combined album as on any. Tests: the mapping's override
(`DiscogsMappingTests`), the order, id, details and names (`TaggerCombineTests`), the match
seeing one album, the review rule, one album refused, the forced title and the question, the
window's names, the command's tagger with each source and its three alerts, the track menu,
and a real-catalog match of a split set ranking the six-track release over the three-track
one (`AlbumMatcherTests`). Check steps `format typecheck arch dupes surface links` passed and
`./scripts/test --changed main` passed but for `WindowGlassTests.theGlassHeadersAreFrosted`,
which fails on `main` too while the screen is locked. Not measured: no bench row covers
these paths, and the matcher's work for one combined album is that of one album of its count.
Deferred: nothing. Not run in the app: an owner check on a real split album. The gate's
review found the scope reusable from the pop-up on a later selection, the search artist taken
from the first album only, and left-out files carried into another combination with the same
first album; all fixed with tests, and a real combined write and its undo tested too.

Implemented by an Opus implementer (231k tokens, 122 tool calls, 31 min, with its review
fixes). The gate's review (Sonnet, 70k tokens, 13 tool calls, 1 min) found no serious bug;
its smaller points (the combined scope left set, the artist only from the first album, left-out
files shared by combinations starting alike) are fixed above. Full `./scripts/check` passed
but for `aPeerOfAnotherUserIsRefusedBeforeItsRequestIsRead` and
`aRunAgainReadsEveryFileAndCarriesOnAfterARelaunch`, which failed once under the parallel run
and passed alone.

**Owner checks:** select "1983" and "1983 [Expanded Reissue]" and run Combine Albums for
Tagging…: the joined album in the list, the line naming both, a conflict for the repeated
tracks, then a write and Undo Tag Edit; and a two-CD set split by disc, written with Separate
Releases on, showing as one album after the rescan.

### 73. Performance audit

Asked by the owner on 2026-11-10: "a full performance audit and make any easy fixes or big
improvements we can." The phase measures where the app spends CPU, main-thread time, memory,
I/O and wakeups, fixes what is cheap and what moves a number the owner feels, adds bench rows
for the paths built since phase 54 without one, and writes down the rest with a reason. Nothing
the user sees changes apart from speed.

- [x] **Baseline:** every bench row an agent session can run, on the phase branch before any
      fix, saved and copied into the Result line.
- [x] **Audit:** every module under `Sources/App`, `Features`, `Core` and `Primitives` read by
      an auditor, and the main scenarios profiled in the release app; one triaged list of
      findings.
- [x] **Bench gaps closed:** a row and budget for each user-visible path at the owner's scale
      that has none (at least the matcher over many albums, the tagger window with many
      albums, Downloads' approve, Organize Selected Files).
- [x] **Fixes landed:** every finding triaged as a fix, each with its before and after number;
      no budget missed, no row more than 10% slower than the baseline without a written reason.
- [x] **The rest recorded:** findings deferred or dropped, each with its reason, in the Result
      line; the ones worth a later phase in [Later](#later).
- [ ] **Owner checks:** the window rows on the owner's Mac, and the old Mac.

Result, phase 73: 16 commits; one new ADR, 0185. Wave 0 ran every bench row an agent session
can, without the `window:` rows, on the branch before any fix (`.build/perf-audit/baseline.txt`
in the phase's worktree): every row in budget but the metadata parse, 5.07 s against 5 s under
the auditors' load and 1.54 s alone. Seven Sonnet auditors read every module of their area,
and one profiled the release app and the rows over 70%. The real-time audit passed: the IO proc
is C, lock and allocation free, 157 ns a 1024-frame callback at 192 kHz. Twelve fixes shipped
in three lanes, and seven rows and an ADR in a bench lane, as the implementation plan above
lists. The numbers that moved, before and after, Apple Silicon, each row alone:

| Row | Before | After | Budget |
|---|---|---|---|
| stats: open Stats on Past Month (73.6) | 321 ms | 84 ms | 400 ms |
| analysis: a 5-minute 24/96 FLAC, local (73.3) | 1.03 s | 0.74 s | 2 s |
| settings: load and validate (73.5) | 1.80 ms | 1.10 ms | 2 ms |
| library: scan 43000 fixture files into a new index (73.8) | 1.35 s | 1.16 s | 5 s |
| discogs: tagger, Apply to All's write progress, 18,288 files (new; 73.9) | 192 to 286 s | 0.75 s | 5 s |
| discogs: tagger, a refresh of Exact with 1,741 albums (new; 73.9) | 4.3 ms | 3.1 ms | 10 ms |
| downloads: Approve a 12-file album, local (new; 73.11, 73.3) | 2.2 s | 0.81 s | 5 s |
| downloads: the same on the slow simulated NAS (new) | not measured | 3.4 s | 10 s |
| library: Organize Selected Files, 2,000 files, local (new; 73.7) | 4.6 to 6.4 s | 1.21 s | 15 s |
| library: Organize Selected Files, 213 files, slow simulated NAS (new; 73.7) | 7.3 s | 0.90 s | 15 s |
| selection: type-to-select a key over every title (new; 73.10) | 8.4 ms | 3.4 ms | 20 ms |
| https: a 3 MB body through `HTTPSClient` (new; 73.2) | 7.1 to 9.1 ms | 2.3 ms | 50 ms |
| discogs: Analyze 1,741 albums, masters of 20 to 100 releases (new) | 4.6 to 4.9 s | 4.45 s | 10 s |
| history: history table plus its indexes | 28.6 MB | 46.6 MB | 50 MB, was 40 |

Slower by more than 10%: the sync merge of 1M plays, 6.45 to 7.8 s (39% of its budget), and a
play recorded, 0.09 to 0.21 ms, because each play now goes into two indexes on `history`, the
price of 73.6 (ADR 0185); the history size budget went from 40 to 50 MB for the same index.
Four other rows read 13 to 30% slower in the full run (the 3000-file NAS scan, a scan's peak
memory, the palette's last of 8 keystrokes, a seek during a refill); main's binary, run
alternately with the branch's under the bench lock, measured the same, so they moved with
the Mac, not the code. D1's 17 s for 3 MB was the auditor's harness reading on the main
actor; through the client it was 7 to 9 ms, and the chunked read still took 60% off. C1's
eager decode moved 0.04 to 0.2 ms a cover off the main thread, less than its estimate.

For the owner (each changes something flagged, so not done): E2, the tag writer reading and
planning a batch's files concurrently (its planning estimated 4 to 8 times faster); T1, the
temp-file write hashing the original while copying it (74 s to about 55 s on the slow NAS
row); D2, Downloads polling less often with its window closed (1,440 wakeups a day); L1, a
path stored once when already normalized (11 MB of the 47 MB index, a rescan); L2 and E5, the
catalog's key tables `WITHOUT ROWID` and an artist key with release ids (3.9 MB, and faster
artist-only searches; both a re-import of the dump); and a `memset` of the renderer's held
buffer when it's made, so a first fade can't page-fault on the IO thread. Deferred, in
[Later](plan.md#later): A1, the 10 ms control-thread tick while playing (0.28% of a core); E3, the
matcher keeping every candidate's whole score, which the new matcher row confirmed (290 to 330
MB held after Analyze of 1,741 albums with masters of 20 to 100 releases); E4, decoding only a
candidate's tracks. Deferred without a Later line: B3, more listers on a NAS rescan (needs the
owner's NAS, ADR 0151); F2, Approve reading every track to find its album (about 60 ms); P2,
All Time's period (99 ms in the sorter, no cheap fix). Dropped: D3 (network time), C3 and C4
(unmeasured or already off the main actor), F5 (no number), P3 (1.3% of a sort), Get
Artwork's and the status bar's per-file progress (outside 73.9). Not run: the `window:` rows
and the old Mac, whose host didn't resolve (`ssh mbp2015`).

The gate: the review found one defect, the chunked reader copying the whole body on each chunk
(fixed in place); its second round found nothing above low, and that low one is fixed too.
Simplify found `LibraryFolderListings` keeping two copies of each listing and a removal
rebuilding a folder's map, both fixed, and the type-to-select row timing a copy of the old
loop, fixed to call the real code; the architecture audit found nothing. Every commit passed
`./scripts/check --changed` but for `theGlassHeadersAreFrosted` (the screen is locked) and
one flaky `UPnPOutputTests` run under load, which passed alone. Full `./scripts/check` passed but
for `theGlassHeadersAreFrosted`.

Cost: auditors (Sonnet) A 156k tokens, 52 tool calls, 17 min; B 309k, 102, 30 min; C 170k, 58,
12 min; D 137k, 54, 9 min; E 185k, 66, 11 min; F 242k, 75, 12 min; P 175k, 93, 25 min. Lanes:
bench (Opus) 352k, 159, 51 min with two rounds of follow-ups; library (Opus) 206k, 126, 48 min
with its gate fixes; ui (Opus) 144k, 78, 25 min; small (Sonnet) 106k, 46, 25 min with its gate
fix. Gate (Sonnet): review 99k, 23, 3 min, and its second round 58k, 5, 1 min; simplify 71k,
10, 1 min; architecture 64k, 12, 1 min. About 2.4M subagent tokens, and about 5 hours of wall
time, most of it the audit and the lanes running side by side.

Out of scope: the test suite's and `./scripts/check`'s speed (landed in 0.20.1); `Sources/Tools`
apart from what a new bench row needs; any change of behavior, stored data the owner would lose,
or new dependency without the owner's answer (see Triage); the real-time path's design, which is
audited and changed only for a measured defect.

#### How to run phase 73

The orchestrator (Opus) runs five waves on the branch `phase/73-performance-audit`, in its own
worktree. Agents are Sonnet unless the wave says Opus, per the owner's CLAUDE.md: Opus only
for a fix lane that changes several files. Waves 1 and 4 fit the Workflow tool (parallel agents
with a findings schema); triage stays with the orchestrator.

**Before wave 0**, `git status` in main's checkout. It may hold the owner's uncommitted work (at
planning time `TaggerModel.swift`, `TaggerWindowTests.swift` and an untracked ADR 0184). Never
stash, reset, commit or edit it. A file with uncommitted changes there is off limits to fixes;
its findings are deferred to the owner. ADR numbers start after the highest one on disk,
tracked or not (0185 at planning time), and only the orchestrator assigns them.

**Shared brief.** Every agent's prompt starts with this, then its own part:

> Phase 73 of docs/plan.md, a performance audit. Read AGENTS.md, docs/map.md and the phase's
> text first. Boundaries: no real library, no NAS, no Discogs API, no real service, no secrets;
> measure with the fixture library, the simulated NAS and the null device only. The scale that
> matters is 43k tracks, 1M plays, the owner's 1,741 tagged albums and a 36 GB Discogs catalog,
> on Apple Silicon and on a 2015 MacBook Pro on macOS 12. A finding needs a number (bench row,
> `xctrace`, `sample`, `EXPLAIN QUERY PLAN`, a timed loop) or a cost argument with n at that
> scale; "could be faster" without either is dropped. Timed runs take the bench lock first:
> `until mkdir "$(git rev-parse --git-common-dir)/perf-bench.lock" 2>/dev/null; do sleep 5; done`,
> and `rmdir` it after, so two measurements never share the Mac. In an agent session the window
> rows that quit the app hang in `terminate:` (see the [phase gate](#phase-gate)); leave them
> out, and stop a launched app with `kill`.

**Wave 0: baseline** (orchestrator, alone on the Mac). Create the branch and worktree, build
release, and run `./scripts/bench` without the window rows, saving the output to
`.build/perf-audit/baseline.txt`. Rerun alone any row that misses. Mark every row above 70% of
its budget: those are wave 1's first profiling targets.

**Wave 1: audit** (7 Sonnet agents in parallel, strictly read only: no edits, no commits; they
write only under `.build/perf-audit/`). Six read code, by area; the seventh profiles. Each
reports findings in this shape, one per item:

| Field | What |
|---|---|
| `id` | area letter and number, `B7` |
| `where` | `file:line`, every one involved |
| `what` | what is slow or large, in one sentence |
| `scenario` | what the owner does when it costs, at the scale above |
| `evidence` | the number and how it was got, or the cost argument |
| `fix` | a sketch, and what it risks (a stale cache, an ordering change) |
| `size` | S: one file, under an hour; M: one module; L: several modules or a design change |
| `proof` | the bench row that would show it, or "new row: …" |
| `flags` | any of: real-time path, AGENTS.md boundary, stored data shape, user-visible change, new API needing `#available` on macOS 12 |

Each also lists its area's **bench gaps**: user-visible paths at the owner's scale with no row.

- **A, playback and output:** `Core/HALRender`, `HALOutput`, `Playback`, `UPnPOutput`,
  `Primitives/RingBuffer`. CPU per second while playing 24/192 FLAC and through conversion,
  decode burst sizes and the control thread's wakeups, allocation on the decode thread, vDSP
  use, and the [real-time audit](#phase-gate) in full.
- **B, index and scan:** `Core/Library`, `Primitives/SQLite`, `Core/Metadata`, `Core/Snapshot`.
  Every SQL statement run at launch, per keystroke, per refresh and per play, with
  `EXPLAIN QUERY PLAN` on the bench's fixture index for a scan or temp B-tree; statement reuse,
  transactions per write, pragmas, WAL checkpoints; a scan's and rescan's system calls per file,
  the watcher's coalescing, the sync merge, a snapshot's copy.
- **C, library window:** `Features/LibraryBrowser`, `Primitives/DisplayText`, `Core/Artwork`,
  `Core/BarView`, `Features/QueueView`, `Palette`, `PlaylistEditor`. Main-thread work per
  keystroke, refresh and scroll frame; full reloads where a row reload would do; text layout and
  drawing caches; the thumbnail cache's size, eviction and decode threads; resident memory.
- **D, launch, idle and background:** `App/MusicPlayer`, `Core/Settings`, `Log`, `Commands`,
  `Scripting`, `Receiver`, `UPnP`, `Recommender`, `Primitives/LocalNetwork`, `LocalSocket`,
  `HTTPSClient`. What runs before the first rows; timers and their tolerance; polling; listeners
  and SSDP while idle; log volume; behavior with the window hidden, on battery, under App Nap.
- **E, Discogs and tagging:** `Core/Discogs`, `Features/DiscogsTagger`, `Core/TagWriter`,
  `Features/TagEditor`. The matcher per album and over 1,741 albums, its queries against the
  real catalog's size (index use, not row counts in the fixture); the tagger model's work per
  change and its table reloads with thousands of albums; Combine; Apply of a large match set;
  tag writes on the simulated NAS.
- **F, Downloads, analysis and the other windows:** `Features/Downloads`, `Core/Analysis`,
  `Features/NowPlaying`, `SettingsWindow`, `Spectrum`. Staging folder watching, Approve's renames
  and copies, Organize's renames, Analyze Library's threads and peak memory, Now Playing's
  updates per second, window open times.
- **P, profiles:** the release app on the fixture library, with `xctrace` (Time Profiler,
  Allocations, Leaks), `sample`, `footprint`, `vmmap --summary` and `top -l` for wakeups.
  Scenarios: launch to idle; ten search keystrokes; a sort; scrolling with art; playing to the
  null device; opening the Discogs tagger on the fixture catalog and analyzing; and each row wave
  0 marked over 70%. Reports the ten heaviest symbols by self time per scenario, allocations per
  scenario, any leak, and memory after each, as findings where a symbol is the app's own.

**Wave 2: triage** (orchestrator). Merge and dedupe by `where`, then sort each finding into one
bucket:

- **Fix:** a size S finding with evidence, or any finding that improves a row or profiled
  scenario by 25% or more, brings a row from over 80% of its budget to under 50%, or removes
  CPU work that is small on Apple Silicon but measurable on the old Mac.
- **Ask:** a fix with any flag but `#available`. Put them to the owner in one question, each
  with its gain and what changes, and carry on with the rest; an answered one moves to Fix or
  Defer.
- **Row:** a bench gap. Its budget comes from its measured number with room, as phase 32f set
  its rows; the old Mac figure is an estimate until its checkpoint.
- **Defer:** worth doing but L and under the Fix line, or blocked by the owner's uncommitted
  files. **Drop:** under 5%, unmeasurable, or more code than it saves.

Then write "Implementation plan, phase 73" under this heading, as earlier phases did: numbered
items 73.1 onward, each with its finding ids, files, the number it should move and its lane;
and commit it (`docs:`).

**Wave 3: fixes**, in lanes. A lane is one agent on one worktree branched from the phase
branch, `phase/73-perf-<lane>`, and no two lanes running at once touch the same file. At most
four lanes run at once: each worktree's `.build` takes several gigabytes, and builds load the
Mac's measurements.

- **The bench lane** goes first, alongside any fix lane whose rows already exist: the new rows
  in `Sources/Tools/Bench` and their lines in [Performance budgets](#performance-budgets), so a
  fix on those paths has a before number. Sonnet, or Opus if a row needs a new fixture
  generator.
- **Fix lanes**, one per module group from triage. Opus for a lane holding an L or M fix or
  files in several modules; Sonnet for a lane of S fixes. Each fix is its own `perf` commit,
  measured under the bench lock right before and right after, with both numbers and how they
  were got in its body (see `647e65f1`). A fix that caches, batches or skips work gets a test
  that fails if the cached or skipped result goes stale: that is where these fixes break.
  Existing tests pass unchanged. A fix using an API newer than macOS 12 keeps an
  `#available` fallback that is measured too. Iterate with `./scripts/check --changed main`.
  A non-obvious choice goes in the lane's report as ADR text; the orchestrator numbers and
  commits it.
- Only the orchestrator edits `docs/plan.md`, apart from the bench lane's budget rows. It rebases
  each finished lane onto the phase branch, fast-forwards, and removes the lane's worktree and
  branch.

**Wave 4: gate and landing.** The [phase gate](#phase-gate) on the phase branch: code review,
simplify, the real-time audit if lane A changed anything, and the architecture audit, as
Sonnet agents in parallel, strictly read only. Each confirmed finding goes back to the lane
agent that wrote the code (`SendMessage`, so it keeps its context), or to a new Sonnet agent if
that one is gone. Then, alone on the Mac, the bench as in wave 0, saved to
`.build/perf-audit/after.txt`, and a table in the Result line of every row whose number moved
more than 5%: baseline, after, budget. Then the full `./scripts/check` once, a patch bump in
`Support/Info.plist` (perf only, as 0.21.1), Result and cost lines, the archive move and the
[retrospective](#retrospective) if one is due. If the fast-forward of `main` fails because of
the owner's uncommitted files, stop and ask.

**Old Mac, timeboxed.** If `ssh mbp2015 true` succeeds, try to run the non-window bench rows
there: an `x86_64` release build of `Bench`, `MusicPlayer` and `GenerateFixtures`, copied with
`scp` to `~/perf-audit-73/` on that Mac, fixtures generated there, the output copied back, and
the folder removed. Nothing outside that folder. Stop at the first step that fails twice, or
after 30 minutes, and leave it as an owner check; either way, say which in the Result line. Its
numbers replace an "estimate until its checkpoint" figure only with the owner's agreement.

Rough cost, from earlier phases: the audit about 1M tokens and 30 minutes, the fix lanes 1 to 3M
tokens and 1 to 3 hours, the gate and benches about 500k tokens and an hour.

**Owner checks:** the window rows the agent session left out, with `./scripts/bench window` on
the owner's Mac, compared with the last recorded numbers; the old Mac's rows if the timeboxed run didn't finish;
and one use of the app on the real library: launch, search, scroll with art, play, open the
tagger.

Implementation plan, phase 73:

Wave 0's baseline (`.build/perf-audit/baseline.txt`) missed one row, the metadata parse
(5.07 s against 5 s); alone it measured 1.54 s, so the miss was load. Rows over 70% alone:
settings 1.73 ms (87%), Stats' period change 247 ms (99%), Stats' open 292 ms (73%), the
reader during Analyze Library 15.5 ms (78%), and the database sizes (index 79%, catalog 80%,
history 72%). The seven auditors' findings are in `.build/perf-audit/{A,B,C,D,E,F,P}.md`;
the real-time audit passed (A).

- 73.1 Bench lane (`Sources/Tools/Bench`, the budget table): rows for the matcher over many
  albums with masters of many releases and an artist-only share (E gap 1), the tagger window
  with 1,741 albums, its refresh and Apply's progress (E, P), Downloads' Approve with its
  lossy-origin check (F), Organize Selected Files local and on the slow simulated NAS (B2,
  F1), type-to-select over every fixture title (C2), and a multi-MB body through
  `HTTPSClient` (D1). Each row's before number is measured on the lane's own branch, before
  the fix lanes land. Lane `bench`, Opus.
- 73.2 `HTTPSClient` reads the body in chunks, not a byte at a time (D1: 17 s against 2 ms for
  3 MB), keeping the size cap and the refusal of redirects. Lane `small`.
- 73.3 `SampleMeasures` checks a block for clipping with vDSP before the per-sample loop (F3:
  266 ms of the 1.03 s analysis row). Lane `small`.
- 73.4 `ThumbnailStore` decodes a thumbnail when it's made, off the main thread (C1: the first
  draw 0.31 against 0.17 ms at 256 px, 4.7 against 1.8 ms at 1024 px). Lane `small`.
- 73.5 `ConfigStore` parses the config's `Data` without copying it to `[UInt8]` (P4: 24% of
  the settings row, at 87% of its budget). Lane `small`.
- 73.6 A schema part of its own, derived like `recorded`, holding an index on `history
  (path_id, played_at)`, so Stats' first plays stop sorting 1M rows (B1, P1: 211 of 290 ms;
  26 ms indexed). The stats part keeps its SQL, so no play is discarded; a test opens an index
  of the old shape and finds its plays. A second index on `played_at` only if the history row
  stays under its budget. Lane `library`, Opus.
- 73.7 One listing of each folder per Organize, Approve or Copy Added Files run, not three per
  file (`LibraryFolderMove.listedPath`; B2, F1: 0.96 ms a file locally, at least 135 ms a file
  on the slow simulated NAS). A test that a folder changed during the run is listed again
  where the move needs it. Lane `library`.
- 73.8 The scanner's connection checkpoints the WAL less often (B4: 20% of the batch store's
  samples). Lane `library`.
- 73.9 Apply's write progress reaches the tagger about 200 times, not twice per file, and the
  artwork count is kept between refreshes (E1: 42k main-queue blocks for 21k files, 0.69 ms
  of artwork groups each). A test that the count follows a change. Lane `ui`, Opus.
- 73.10 Type-to-select folds the titles once per list, not per keystroke (C2: 11.6 to 14.3
  ms a keystroke over 43k titles). A test that a refreshed list is folded again. Lane `ui`.
- 73.11 Approve's lossy-origin check decodes its two files at once (F4: 7.2 s serial against
  about 3.6 s on the slow simulated NAS). Lane `ui`.

For the owner (flags, see Triage): E2, the tag writer reading and planning a batch's files
concurrently (estimated 4 to 8 times faster planning; the writer's boundary); T1, hashing the
original while it's copied to the temp file (74 s to about 55 s on the slow NAS row; the
same); D2, Downloads polling less often while its window is closed (1,440 wakeups a day;
user-visible); L1, storing a file's path once when it's already normalized (11 MB of the
47 MB index; stored shape, a rescan); L2 and E5, the catalog's key tables `WITHOUT ROWID` and
an artist key with release ids (3.9 MB, and artist-only searches; both a re-import of the
dump); A's `memset` of the held buffer when the renderer is made, so a first fade doesn't
page-fault on the IO thread (real-time path).

Deferred: A1, a deadline-driven control thread instead of the 10 ms tick (0.28% of a core
while playing; a real-time design change, ADR 0029); E3 and E4, the matcher's kept and decoded
tracklists (unmeasured until 73.1's matcher row); B3, more listers on a no-change NAS rescan
(needs the owner's NAS, ADR 0151); F2, Approve finding its album without reading every track
(M, about 60 ms); P2, All Time's period (no cheap fix, 99 ms in the sorter). Dropped: D3, the
Output menu's search (network time), C3 and C4 (unmeasured, or already off the main actor),
F5, Now Playing's unchanged labels (no number), P3 (1.3% of a sort).
