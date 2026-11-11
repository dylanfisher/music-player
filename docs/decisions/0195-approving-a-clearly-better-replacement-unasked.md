# 0195. Approving a clearly better replacement unasked

- **Date:** 2026-11-10
- **Status:** accepted
- **Amends:** [0193](0193-approving-safe-matches-unasked.md) (what is safe)
- **Amended by:** [0200](0200-upgrading-to-flac-automatically.md): Upgrade to FLAC
  Automatically queues upgrades for it to approve.
- **See also:** [0169](0169-approve-at-once-and-manual-upgrades.md) (a new album that replaces
  one, Keep Both), [0147](0147-moving-downloads-into-the-library.md) (Approve)

## Context

The owner often queues a download as a new album, not through Upgrades, for an album the
library already has. ADR 0169 then plans it as a replacement of that album (`replaced`), and
ADR 0193 left every such job for the owner, since a job queued by hand may ask for any format
and could replace FLAC with MP3. The owner asked for a download of higher quality to be taken
as the upgrade it is, and a lower one left to approve by hand.

## Decision

**A clearly better replacement is safe.** Approve Safe Matches Automatically approves a job
that replaces a library album it wasn't queued to upgrade when that album was found by its
tracks' release id and the staged files are clearly higher quality than it
(`ApprovalPlan.unasked`). It makes the `ApprovedImport` the sheet's Approve makes with Keep
Both off: an upgrade of the album's files, through the coordinator's `approve`. Every other
condition of ADR 0193 still holds, an old file with no new one among them. Anything else is
left with the reason, naming both qualities: "it isn't higher quality than the library's MP3
320 kbps (MP3 256 kbps isn't better)".

**Clearly higher** (`AudioQuality.isClearlyHigher`):

- lossless (FLAC, ALAC, WAV, APE, WavPack, PCM) over lossy (MP3, AAC, Ogg, Opus);
- of two lossless, a bit depth and a sample rate each at least as high, and one higher; a
  mixed pair, such as 24/44.1 against 16/96, or an equal one, isn't higher;
- of two lossy, an average bit rate at least 10% higher (`lossyMarginPercent`);
- lossy over lossless never, and a quality not known on either side never.

The 10% margin is there because the two bit rates aren't measured alike: the library's is the
album's audio bytes over its length, the download's is the peer's report, and VBR files of one
setting land a few percent apart. 10% clears that, and still takes the steps people choose
between: 256 over 224 (14%), 320 over 256 (25%), V0 at about 245 over 192.

**The download's quality** is the service's candidate, held to what the lossy-origin check
read of the staged files: the lowest bit depth and sample rate of the files it decoded, over
the peer's report, which Soulseek peers often leave out. The check already decodes the first
and last files, so this reads nothing more. A lossy download's bit rate is the peer's, since
the check doesn't measure one. Files the check found to be another kind of codec than the
peer reported leave the quality unknown.

**The library album's quality** is read from the index in the plan's `find`, off the main
thread, with what it already reads (`LibraryIndex.albumQuality`): for an album with any
lossless track, its highest bit depth and highest sample rate, so a download must be higher
than every track; else its average bit rate, worked out as `upgradeCandidates` does. A DSD
track, or a lossless one with no bit depth, leaves it unknown.

**Found by artist and title only, it's left.** A `byName` match is an album not tagged with the
release, so it may be another edition the owner wants to keep beside the new one. The plan's
old-to-new matching has the Discogs matcher place the old files on the release it's told is
theirs (`upgradePositions`), which another edition of the same tracks passes, so it doesn't
settle that. The owner decides in
the sheet, where Keep Both is.

**The sheet says it too.** Where both qualities are known, the sheet's replace note adds
"Replaces MP3 320 kbps with FLAC 16/44.1."

## Alternatives considered

- **Any lossless download over a lossy album, without reading either's details.** Rejected:
  of two lossless copies, it would replace a 24/96 album with a 16/44.1 download.
- **Comparing against the album's average for lossless too.** Rejected: an album of mixed
  tracks would be replaced by a download no better than its best one.
- **Reading each staged file's headers for its quality.** Rejected for now: an MP3's length
  takes a read of every frame, over the share, and the check's two decoded files already give
  a lossless download's bit depth and sample rate.

## Consequences

- A download queued by hand at a higher quality than the library's copy goes into the library
  within a poll of its tag run, replacing the old files, with no one at the Mac.
- A lossy download over a lossy album needs the peer to report its bit rate; without one it's
  left for the owner.
- A bug in the comparison deletes a library album's files for a download no better. The tests
  hold each side of the rule, and the reason names both qualities, so a wrong one is visible.
