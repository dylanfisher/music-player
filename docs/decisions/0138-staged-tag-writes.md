# 0138. Tags written to a staged download once, after a clean match, without asking

- **Date:** 2026-11-08
- **Status:** Proposed — awaiting owner approval
- **Amends:** [0020](0020-tag-writing.md) (who writes music files, and when),
  [0133](0133-one-confirmation-for-a-match-set.md) (what counts as the confirmation)
- **See also:** [0131](0131-discogs-matching.md) (the tiers),
  [0132](0132-discogs-field-mapping.md) (the mapping), [0136](0136-the-service-token.md) (the
  staging folder setting), [0139](0139-moving-downloads-into-the-library.md) (Approve)

## Context

Phase 54 downloads albums from Soulseek. The service, music-recommender on mbp2021, finds and
downloads each one for a Discogs release the owner picked, and copies its files into a staging
folder on the NAS, `/Volumes/music/staging` on the player Macs, beside the library and outside
every watched folder. The player then tags them and shows them in a Downloads window for review.

AGENTS.md lets `TagWriter` write music files only for a tag edit the user confirmed in the UI.
The owner asked for staged downloads to be tagged without that step: "if the album is new from
soulseek we can automatically write the tags". The owner also asked that "nothing should be
imported into the real full music tracklist until manually reviewed and approved", so the
confirmation that matters for the library is Approve (ADR 0139), not the tag write. That request
is the basis for this exception: it covers files that aren't in the library yet and can't reach
it without Approve.

## Decision

**What is written, and when.** The Mac holding a job's tagging lease reads the staged files
(`readAlbumFiles`, with synthetic negative ids, so nothing enters the index) and matches them
against the job's release only (`matchAlbums(choosing:)`). A run is **clean** when the tier is
Exact, no file is left unmapped, and the player's file-to-track mapping agrees with the one the
service reported. Only a clean run writes, once, with no confirmation. Anything else is a
discrepancy, with reasons from `comparison(of:)`, and writes nothing until it's resolved in the
tagger, whose Apply is the one confirmation ADR 0133 describes.

**A fixed overwrite mapping.** The edits come from the saved field mapping (`discogs.mapping`),
with every field it names replaced, never filled only where empty, whatever Keep Existing Values
says. A Soulseek file's tags are the uploader's, not the owner's, so none of them is worth
keeping over the release's. Tags the mapping doesn't name stay as they are; the Approve sheet
says so.

**`StagedWriter`.** The write goes through `TagWriter.write(_:progress:)`, as every tag write
does, from `Core/Discogs/StagedWriter.swift`:

- **The path guard.** Each path is resolved, symbolic links included, and refused unless it is
  inside the staging folder (`import.stagingFolder`). A refused path fails the whole run before
  anything is written. Nothing under a watched folder or the library folder can pass, since
  Settings refuses a staging folder inside either (ADR 0136).
- **A journal of its own.** A second `TagUndoJournal`, in a folder of its own beside the main
  one, holds the in-place writes' recovery entries, so a crash mid-write is put back at the next
  launch on that Mac. Its write closure doesn't call the library watcher and doesn't push to the
  app's journal, so Edit > Undo never sees a staged write and still undoes the library edit
  before it.
- **A read-back.** After the write the files are read again and the change set worked out
  again; it must be empty. A failure, or a change set that isn't empty, makes the run a
  discrepancy with the reason, or an error.

**File sizes.** The service's file sizes are fixed when it stages a job, and a tag write grows a
file when its padding runs out. The player holds a file to the service's size only before its own
write. After the write, a clean run, or an Apply in the tagger, records what each file measures,
in the index's import ledger (kind `tagged`, by job and file), and every later check (the read in
a rerun, the tagger's read-back, the move's preflight, the upgrade's verify) holds the file to
that size. A read accepts either size, so a job the service stages again is read afresh. The
record is in the index of the Mac that wrote, so a job tagged on another Mac, whose files grew,
is refused at Approve here with the file's size in the reason. Approve on the Mac that tagged it.

**Several Macs.** Only the lease holder writes. A Mac that takes over a job another left
half-tagged reads the files again and reruns the whole test from the start; it never trusts the
reported status, and the read-back is what tells it a write finished, since the recovery journal
is on the other Mac.

## Alternatives considered

- **Asking before each staged write.** Rejected by the owner's request. Approve still stands
  between every staged file and the library, and its sheet shows what was written.
- **Writing the tags at Approve, after the move.** Rejected: the owner would approve tags not
  yet written, and a failed write would leave a half-tagged album in the library.
- **The service writing the tags.** Rejected: the service never parses or decodes audio, and
  `TagWriter` stays the only code that writes a music file.
- **Writing Likely matches too.** Rejected: a Likely match is a guess about which file is which
  track (ADR 0131), and a wrong one would write every tag of the album wrong.
- **Using the mapping's fill-empty fields as they are.** Rejected: an uploader's wrong title or
  year would survive under the release's.

## Consequences

A bug in the mapping or the matcher writes wrong tags to staged files, never to the library: the
files stay staged until Approve, and the sheet shows the tags. A clean album needs no action
until the owner reviews it. Tags the mapping doesn't name, such as an uploader's comment, ride
along into the library. Recovery of a torn staged write needs the Mac that started it, or a
rerun of the tag run on another.

## Proposed AGENTS.md change

The music files bullet in Boundaries gains one clause in its first sentence, for this ADR, and
one sentence after the ADR 0124 sentence, for ADR 0139. The line count stays the same, and the
detail stays in the two ADRs. The whole bullet, as proposed; its links are written here relative to this folder, and in
AGENTS.md each takes the `docs/decisions/` prefix, as the bullet's links do now:

> - **Music files are written only by `Sources/Core/TagWriter`, for a tag edit the user confirmed in the UI** (one confirmation covers a reviewed Discogs match set, [ADR 0133](0133-one-confirmation-for-a-match-set.md); a download staged for review is written once, unasked, after a clean match, and only inside the staging folder, [ADR 0138](0138-staged-tag-writes.md)). Besides it, only Remove and Move to Trash moves them: it passes the files the user confirmed to `NSWorkspace.recycle` ([ADR 0050](0050-remove-from-library.md)). A drop of files with Copy Added Files on creates new copies in the library folder, reading the originals only, and removes only a copy of its own that failed ([ADR 0124](0124-drop-files-and-the-library-folder.md)). Approve in the Downloads window renames the staged files into the library folder, never over a file, and for an upgrade then passes the files it replaces to the same Trash call, which on a share with no Trash deletes them ([ADR 0139](0139-moving-downloads-into-the-library.md)). Nothing else writes, renames, moves or deletes them, and no test or tool touches a real library or the NAS, except `scripts/smb-copy-probe.swift`, which only the owner runs, on a scratch folder, making and removing a subfolder of its own ([ADR 0108](0108-faster-tag-writes.md)), and the Discogs tagger's agent runs that read the watched folders and the dumps folder, read only, reporting under `.build/` ([ADR 0128](0128-discogs-survey.md)): tag tests write to generated fixtures or to clones of the reference corpus ([ADR 0020](0020-tag-writing.md)). App state lives in the SQLite index. The one exception: the app appends its own `<machine id>.log`, and writes nothing else, in the sync folder the user chose, which must be outside every watched folder; tests use a temporary folder ([ADR 0038](0038-sync-logs.md)).

Until the owner approves, AGENTS.md stays as it is and no code from 54.4 on writes a staged file.
