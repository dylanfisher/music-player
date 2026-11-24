# 0224. Using the release the files fit

- **Date:** 2026-11-23
- **Status:** accepted
- **Amends:** [0178](0178-another-release-for-a-staged-download.md) (only the tagger
  tagged a staged job as another release), [0211](0211-requeuing-a-copy-that-doesnt-match.md)
  (every discrepancy about the files was requeued)
- **See also:** [0146](0146-staged-tag-writes.md) (the tag run),
  [0193](0193-approving-safe-matches-unasked.md) (approving unasked)

## Context

A job was queued for MLO's Oumuamua, release 20774077, the 12-track vinyl LP. The staged copy
had 14 FLAC files, and the tag run reported a discrepancy: "14 files, release has 12", "track
A3 is 36 s off", and two files that fit no track. In the Discogs Tagger's Other Releases…,
the 2022 CD, MFM056, and others fit every file. The owner could fix it only through Open in
Tagger, Other Releases…, Use Release and Apply (ADR 0178), and the tag run would have
requeued the copy first (ADR 0211), so the service deleted files that were right for another
release. The owner (2026-11-23): "If a download finishes with a discrepancy like too many
files, but we have the information that another release has the correct number of files, we
should allow switching to that correct version." Asked how, the owner chose one click in
Downloads.

## Decision

**AutoTag looks for a release the files fit.** When the queued release's run is a discrepancy
with a reason about the tracklist (the count, a file that fits no track, a track with no file,
a title or a length), and none about the codec or any that every copy would have (a file the
writer can't tag, a format AutoTag can't check), it tries the other releases the matcher
already found, best first. Only those whose score fits the tracklist and the lengths can be
exact, so only those are read again, with `chooseRelease`, from the catalog. The first that
the same checks find no reason for is the run's `fits`, and a reason names it: "release
5151 (CD (Album), Music From Memory MFM056, 2022) fits every file". The reasons go to the
service, so every Mac's Tagging tooltip shows the line.

**The service's positions are checked only for the release queued.** They are positions on
its tracklist, so a file at "A3" on the LP is at "3" on the CD whether or not it's the right
file. This applies to every run whose release isn't the queued one, so a tag run that takes
over a job tagged as another release in the tagger (ADR 0178) is no longer a discrepancy for
that reason alone.

**A copy that fits another release isn't requeued.** `anotherCopyMightFix` is false when
`fits` is set: the files aren't wrong, and a requeue would delete them.

**This Mac keeps the release they fit.** The coordinator records it in the import ledger as
a `fits` step beside `retagged`, the job's folder as its path and the release as its
destination. Each tag report replaces it, with none for a run that found none; a write in the
tagger forgets it, and it goes with the job's other steps. Nothing reads it back from the
reasons' text. Another Mac, which didn't run the tag, sees only the reason line and uses Open
in Tagger.

**Use Release That Fits writes it, once confirmed.** The action applies to a staged job tagged
Discrepancy, on a Mac with a catalog that knows a release the files fit, reviewed on no other
Mac, and acts on one row. It's in the context menu only: a toolbar button would widen the
window's smallest width by 160 points. Its confirmation names the release queued and the one
the files fit, artist, title, format, label, catalog number, year and id, with a Tag as Release
button. On confirm the coordinator runs the tag run's own steps for that release under a
lease: AutoTag, the decode check, the write through `StagedWriter` when the run is clean, the
sizes, and the report. It records the release as `retagged`, as the tagger's Apply does, so
the row names it and a later tag run matches with it. A run that isn't clean writes nothing,
reports its verdict, and the window says why. It never requeues: the owner asked to tag the
copy, not to replace it.

## Alternatives considered

- **Switching to the release that fits unasked.** Rejected by the owner, who wants a confirmed
  click: the release queued may be the one the library needs, as for an upgrade.
- **Opening the tagger with the release that fits chosen.** The other option offered; it
  still takes Analyze and Apply, and the owner chose one click.
- **Recovering the release from the reason line on any Mac.** Rejected: it would parse text
  meant for people, and the service's reasons aren't a contract for ids.
- **Trying every release of the album's master.** Rejected: the matcher's candidates already
  hold the releases its searches found, and reading more would slow every discrepancy's run.

## Consequences

- A copy with a bonus track or another edition's tracklist is kept and tagged in two clicks,
  where before it was requeued and deleted.
- A discrepancy that names a release that fits stays for the owner; Approve Safe Matches
  Automatically still leaves a job tagged as another release for review (ADR 0193).
- Approve still replaces the queued release's album in the library (ADR 0178).
- A discrepancy's run reads a few more releases from the catalog when the files miss the
  queued tracklist.
- The music files rule is unchanged: the write is one the owner confirmed in the UI, through
  `TagWriter`, inside the staging folder (ADR 0146).
