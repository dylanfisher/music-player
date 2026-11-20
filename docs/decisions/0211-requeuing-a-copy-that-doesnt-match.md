# 0211. Requeuing a copy that doesn't match

- **Date:** 2026-11-20
- **Status:** accepted
- **Amends:** [0210](0210-requeuing-a-damaged-download.md) (only a damaged copy is requeued
  unasked)
- **See also:** [0200](0200-upgrading-to-flac-automatically.md) (the upgrader requeues its own
  discrepancies), music-recommender's ADR 0023 (requeue and tried peers)

## Context

The owner (2026-11-20), looking at a Downloads window with nine staged jobs tagged
Discrepancy: "are those already set to auto-retry? if not, make it so they retry with a
different user/files to try to self fix". They weren't. Only Upgrade to FLAC Automatically
requeued a discrepancy, and only for jobs it had queued. These were new albums added by hand.

A discrepancy has two kinds of reasons. Some are about the peer's files: too many or too few,
a file that fits no track, a track with no file, a title or a length that differs, the wrong
codec. Another peer's copy may not have them. Others come back with every copy: a file the
writer can't tag, such as a DSD file, or a format AutoTag can't check. A match that is only
below exact, or a file the service put at another position, doesn't show that the copy is
wrong either.

## Decision

**AutoTag says whether another copy might fix it.** A run's `anotherCopyMightFix` is true
when at least one reason is about the files and none would come back with every copy. The run
knows which check failed, so nothing matches the reasons' text (0210's reason too).

**The tag run requeues it, up to three peers.** The coordinator reports the discrepancy, gives
up its lease, and then asks the service for the job's tried peers. While there are fewer than
three, it sends `requeue`. The service deletes the staged copy and searches again without
those peers, as for a damaged copy (0210). From that point the two work the same way: the
import ledger is forgotten, and a requeue the service doesn't answer is sent again at each
poll. The third copy that doesn't match stays for the owner, and so does a job whose tried
peers the service doesn't give. A job the upgrader owns may be requeued by either. The second
requeue is refused because the job is no longer staged, which the window's problems show once.

**Retry requeues a staged copy by hand.** Retry now applies to a staged job tagged Discrepancy
or Error, after a confirmation. It covers the jobs tagged before this change, which no tag run
looks at again, and a copy the cap left. The coordinator first gives up this Mac's review
claim, which the service would otherwise refuse the requeue for, then forgets the ledger.

## Alternatives considered

- **No cap, as the upgrader has.** Rejected. A release whose catalog listing differs from
  every rip, such as one with a bonus track every peer has, would throw away every peer's copy
  and end `not_found`, with nothing left for the tagger.
- **A checkbox in the window, like Upgrade to FLAC Automatically.** Rejected. The owner asked
  for it outright, and 0210 needed none. The cap and Retry leave the owner a copy and a way back.
- **Requeuing the backlog unasked at launch.** Rejected. The verdicts already reported carry
  only their reasons' text, so their kind would have to be guessed from the words.

## Consequences

- Most discrepancies end in a clean copy from another peer, which Approve Safe Matches
  Automatically can then approve, without the owner looking.
- A release few peers share can go `not_found` after a requeue. The copy that had a
  discrepancy is gone by then, and only a new job searches again from scratch.
- Each requeue counts toward the service's searches per hour.

## AGENTS.md

The music files bullet in Boundaries says that the tag run requeues a staged download whose
copy doesn't match its release, up to three peers, and that Retry requeues a staged copy the
owner confirms. The service deletes the staged copy in both cases. The bullet links here.
