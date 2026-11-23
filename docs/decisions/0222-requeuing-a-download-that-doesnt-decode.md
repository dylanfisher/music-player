# 0222. Requeuing a download that doesn't decode

- **Date:** 2026-11-23
- **Status:** accepted
- **Amends:** [0210](0210-requeuing-a-damaged-download.md) (what damaged means)
- **See also:** [0146](0146-staged-tag-writes.md) (the tag run),
  [0193](0193-approving-safe-matches-unasked.md) (a plan that asks nothing)

## Context

Job 1535 sat in staging, tagged clean, and Approve Safe Matches Automatically left it: the
lossy-origin check couldn't analyze its first and last files, and a file it can't analyze
asks the owner. `flac -t` found three of its six files fail partway through their audio
(lost sync, invalid residual). Their headers, tags and covers were intact, so the tag read
that ADR 0210 judges damage by found nothing, and the job wasn't requeued.

The owner had also approved the three albums before it by hand, Rediscovers The Rings Of
Saturn, Black City and Writer's Block, and every file of each fails the same way. AudioToolbox
fails on them too, with `'bada'` or `-50` from `ExtAudioFileRead`, so the Approve sheet would
have shown "Couldn't be analyzed" for at least one file of each. The tag write didn't do it:
a write in place leaves the audio alone, and a rewrite reads the temp file's audio back
against the original's hash (ADR 0196). The owner (2026-11-23): "yes, count it as damage".

## Decision

**Damaged also means a staged file that opens but fails partway through decoding.** After
AutoTag reads and matches a job, the tag run decodes every staged file to its end through
`FileDecoder` (`damagedAudio`). A decode error on a file that's still there at the size it had
when the check started is damage: the run reports `error` with a line per file, saying how far
in it stopped, writes no tags, and requeues the job as ADR 0210 does. These aren't damage, and
are only logged: a file that doesn't open (the tag read already judged it), a DSD file, which
AudioToolbox doesn't decode, and a file that's gone or resized when the decode fails, as on a
share that dropped. A run that's already an error isn't decoded; its reasons stand.

**Retry also requeues a staged copy tagged clean.** ADR 0211 let it requeue only a
discrepancy or an error, so a clean copy the owner found broken, tagged before this check or
cut short in a way no check sees, could only be rejected and queued again by hand. The owner
(2026-11-23): "some files that are supposedly clean actually have discrepancies (cutoff
etc)". Retry still asks first, and still waits for the tag run to finish.

## Alternatives considered

- **Counting the lossy-origin check's failure as damage, at Approve.** Rejected: it runs only
  when a job is approved, by hand or unasked, so a job reached the owner's sheet first, and it
  decodes only the first and last files: job 1535's fourth file would have passed.
- **Decoding only the first and last files in the tag run, as the origin check does.**
  Rejected: the album gets read once more over the share either way, and an upgrade's Approve
  throws the old album away, so one bad track in the middle costs the owner a track.
- **Also calling a file that decodes fewer frames than it declares damaged.** Left out: an MP3's
  length is an estimate, and a file cut short is already caught by its size against the
  service's.

## Consequences

- A broken copy goes back to its search before the owner sees it, from another peer.
- Each tag run reads the whole album over the share, a few seconds to a minute on the NAS,
  before it writes tags. A write in place used to read only the tags.
- A job tagged clean before this, such as job 1535, isn't tagged again; Retry requeues it.
- Retry can throw away a copy that was fine; its confirmation is the only guard.
- If AudioToolbox wrongly fails a good file, each peer's copy is thrown away until none is
  left, as ADR 0210 says of the reader. The reasons stay in the log and the service's history.
