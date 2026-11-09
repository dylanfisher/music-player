

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
