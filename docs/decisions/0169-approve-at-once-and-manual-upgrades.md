# 0169. Approve opens at once, and a download queued by hand replaces the library's copy

- **Date:** 2026-11-09
- **Status:** accepted
- **Amends:** [0147](0147-moving-downloads-into-the-library.md) (which old files the Trash
  takes), [0156](0156-replacing-an-album-at-its-own-paths.md) (a new album that replaces one)
- **See also:** [0158](0158-every-window-keeps-its-frame.md) (window frames),
  [0163](0163-download-progress-and-the-status-item.md) (the Approve sheet's layout)

## Context

Phase 64 is the owner's feedback of 2026-11-09 on the Downloads window. Approve showed nothing
until it had claimed the job from the service, planned the moves and decoded the first and
last staged files over the share for the lossy-origin check, which takes seconds; it looked
like the click did nothing. A job queued from Library Selection or by pasting a release had no
`upgrade`, so the plan replaced the library's copy of its release only when the new files'
paths were the old ones' (ADR 0156); otherwise Approve imported a second copy. Open in Tagger
opened an empty tagger, or did nothing at all, and the window opened at the bottom left of the
primary display and forgot its size.

## Decision

**The sheet first.** Approve presents its sheet straight away, saying what it's doing:
claiming the album, finding the folders, planning the moves. The plan fills the tables as soon
as it's worked out; the lossy-origin check then runs, with a spinner in the row of each file
it reads, and Approve stays off until it ends. Cancel at any point stops the work, and a claim
taken, or still being asked for, is given back once the service answers. A failure before the
plan closes the sheet and says why, as before. No sheet, no claim: with the window not up, or
another sheet on it, Approve asks the service for nothing.

**Finding the album to replace.** For a job with no `upgrade`, the plan looks for the library
album of the job's release: the one album whose every track carries the release id, else the
one whose album artist and title fold, by the key the matcher compares titles by
(`CatalogKey.matchKey`), to the release's artist and title. Two or more matches choose none,
and the sheet says so; so does an album with a file off the staging folder's share, whose
files can't be named relative to it. The one album found is planned as an upgrade, as ADR 0156
did for an album found by its paths, which this replaces: that album is found this way too.

**What the sheet says.** "Replaces N files in the library", which album it found and how, and
a Keep Both box that imports the job as a new album beside the old one, with its own moves;
where the new album's paths are taken, Keep Both is refused with them, as any new album is.
The replaced files go to the Trash after the new ones are checked, exactly as an upgrade's do
(ADR 0147), with the delete warning above them.

**Which files the Trash takes.** ADR 0147 passed only files still carrying the job's release
id. An album found by name may carry another release id, or none. Each old file is now held to
the release id it carried when the sheet found it: the import checks each against it before
the set-aside and before the delete. For a file whose id isn't the job's, the ledger keeps the
id as a `held` step, written with the other steps before the first rename, so a run after a
failure, on this Mac, holds it to the same one. A file re-tagged since the approval is refused
at the delete, with the new files already in the library and the old ones where they were. An
upgrade queued from Add > Upgrades still requires the job's release on every old file.

**The window.** `Downloads.show` made the window through `makeWindow`, which set the
controller, then checked the controller to see if this was the first show, so
`keepsFrame(as:)` never ran: the window opened at its content rect's origin and its frame was
never saved. It runs now. `placedFrame` centers a saved frame the screens together show less
than half of on the main window's screen, at its saved size, as it does a frame on none. The
column widths are kept in `state.json` as `downloads.columns`, by column, applied once the
window has its frame.

**Open in Tagger** says why it can't open a job (no staged folder, no format, no catalog on
this Mac, the release not in it) before it opens the tagger, and the staged tagger analyzes its
album when it first opens, so it shows on the album's tier tab.

## Alternatives considered

- **Requiring the job's release id on the old files of an album found by name.** Rejected: the
  owner's case is an album the tagger never matched, which carries none, and refusing it is
  the duplicate this phase removes.
- **Keeping the held release only in the approval, not the ledger.** Rejected: a resume after
  a failure rebuilds no upgrade from the sheet, so it would hold every file to the job's
  release and refuse the album's own files, or, with no check, delete a file re-tagged since.
- **Matching by name first.** Rejected: a release id is the owner's own match; a name can be
  shared by a reissue the library also has.
- **Asking which album to replace when several match.** Not now: Keep Both is the import in
  that case, and the owner can tag the album to replace first.
- **Showing the sheet only after the claim.** Rejected: the claim is a round trip to the
  service on another Mac, and the delay it hides is what the owner reported.

## Consequences

- Approve can be cancelled while it's still working, and the claim is given back either way.
- A download queued by hand never silently doubles an album; the owner chooses Keep Both.
- An album found by name loses its files to the Trash on Approve, as an upgrade does; the sheet
  lists them, and they are checked against what they carried when the sheet found them.
- The Downloads window keeps its place and its columns; one left mostly off-screen comes back
  to the main window's screen.

## AGENTS.md

No change: Approve still renames the staged files into the library folder and passes the files
it replaces to the Trash call, which the boundary's ADR 0147 sentence says.
