# 0200. Upgrading to FLAC automatically

- **Date:** 2026-11-10
- **Status:** accepted
- **Amends:** [0193](0193-approving-safe-matches-unasked.md) (a job left for a lossy-origin
  finding), [0195](0195-approving-a-clearly-better-replacement-unasked.md) (what is queued
  to be approved)
- **See also:** music-recommender's ADR 0023 (its main at `2d448e6`: requeue and tried peers),
  [0147](0147-moving-downloads-into-the-library.md) (Approve)

## Context

Upgrades… (phase 64) lists the lossy albums whose every track carries one Discogs release id,
and the owner queues the ones to replace with a lossless copy. Approve Safe Matches
Automatically (ADRs 0193 and 0195) then lands the clean ones. The owner asked for the queuing
to happen by itself too: a few FLAC upgrades always on their way, most-played and lowest
quality first, and a copy that isn't clean thrown away and searched for again from another
Soulseek user.

music-recommender now keeps each job's tried peers and leaves them out of every search, and
`POST /v1/downloads/requeue` sends a staged job back to its search, deleting the staged copy.
Its job has no field saying who queued it, and a new one would break the player's strict
decoder, so the player has to tell its own jobs apart.

## Decision

**The box.** `downloads.autoUpgrade`, Upgrade to FLAC Automatically, off by default, beside
Approve Safe Matches Automatically in the Downloads window and in Settings > General's
Downloads section. `downloads.autoUpgradesInFlight`, 3 by default, 1 to 10. It runs only
while the app is open, the service answers, this Mac can tag (it has the Discogs catalog) and
the staging folder is on the library's share, as Upgrades… needs. Each Mac has its own box.
Turning it off stops a pass before its next call; the jobs already queued carry on as any
upgrade does.

**What it queues unasked.** After each poll, while fewer than N jobs of its own are in flight,
it queues the next candidates of `upgradeCandidates` as upgrades with the `flac` policy (24-bit
and 16/44.1 are both FLAC), leaving out a release marked Never Upgrade, one set aside or
waiting after a miss, one whose snapshot this Mac's catalog can't build, and one with any job
on the service that isn't imported, rejected or cancelled, from either Mac by any route: the
service's job list is the truth for that, and `create` refuses a second one anyway.

**Its own jobs** are the ones the index records it queued, by the service's epoch, job id and
release (`auto_upgrade_jobs`). In flight is every one of them listed in the current epoch that
is still on its way without the owner: searching, downloading, being tagged, staged clean for
Approve Safe Matches Automatically to look at, or importing. One left for the owner, failed
past its download, tagged with an error, or staged clean for review, is kept but holds no
slot. A new epoch, a job gone from the list, or an imported one is forgotten.

**The priority**, `UpgradeCandidate.priority`: (plays + 1) × 320 / kbps, doubled for a boosted
album, and a tie to the lower album id. Plays are its tracks' play counts summed; kbps its
average bit rate, as Upgrades… shows it, held to at least 32. An album is boosted when half or
more of its tracks are liked, or its rated tracks average 4 stars or more. The + 1 keeps an
album never played in order of its quality. Worked examples, in the order they're queued:

| Album | Plays | kbps | Boosted | Score |
|---|---|---|---|---|
| A | 200 | 256 | no | 251.25 |
| B | 50 | 128 | no | 127.5 |
| C | 50 | 320 | liked | 102 |
| D | 50 | 320 | no | 51 |
| E | 10 | 192 | rated 4.5 | 36.67 |
| F | 0 | 128 | no | 2.5 |
| G | 0 | 320 | no | 1 |

**A miss** is a job of its own that ends `not_found`, or `failed` at its search or download,
or is rejected or cancelled by anyone. One that hasn't ended is cancelled first, so it holds
no slot and doesn't search again on the service's own schedule (6 h, 1 d, 3 d, weekly). The
release then waits 1 day after its first miss, 7 after its second and 30 after its third; the
fourth sets it aside (`upgrade_misses`). Add > Not Found Upgrades… lists the albums set aside,
with their misses, and Queue Again clears the count.

**Rejecting an unclean download unasked.** A staged job of its own that the tagger found a
discrepancy in, once no Mac holds its tagging lease, or that Approve Safe Matches
Automatically left for a lossy-origin finding (`ApprovalPlan.Unasked.notClean`), is requeued:
the upgrader gives up this Mac's review claim, sends `requeue`, and forgets the job's import
ledger, since the new copy is staged in the same `job-<id>` folder. The service deletes the
staged copy and searches again without the job's tried peers; finding no untried peer, it
goes `not_found`, which is a miss. A tagging error, a file the origin check couldn't read, a
refusal, and a failed import stay for the owner. With Approve Safe Matches Automatically off,
the origin check doesn't run unasked, so a clean-tagged copy waits for the owner's review.

**Never Upgrade** is a mark per release, from the track menu (for the selection's releases,
or clearing them when every one is marked) and the Upgrades sheet (for the ticked albums). It
is kept in the index by release id and synced as a latest-wins event, as ratings are, so both
Macs leave the album out. Upgrades… still lists a marked album, saying so, for the owner to
queue by hand. The misses and the own jobs aren't synced: each Mac counts its own.

## Alternatives considered

- **Telling its jobs apart by a field on the job.** Rejected: the shipped player decodes the
  job strictly, so any new key breaks it (music-recommender's ADR 0023 says the same).
- **Leaving an unfound job to the service's schedule.** Rejected: the owner set 1, 7 and 30
  days, and a job waiting a week would hold one of the three slots.
- **Retrying an unfound job with `retry` instead of a new job.** Rejected: the service
  searches a `not_found` job again on its own schedule, which only cancelling stops. The new
  job after a wait starts with no tried peers, so it may choose a peer an earlier job of the
  release tried; `create` takes no peers to leave out.
- **A daily cap.** Rejected by the owner: three in flight is the limit.

## Consequences

- With both boxes on, a lossy album becomes FLAC with no one at the Mac: queued, downloaded,
  tagged, approved and its old files replaced, as Approve does.
- A bug in the queuing spends the service's searches, not the library: nothing reaches the
  library unless Approve Safe Matches Automatically finds it safe.
- A release few peers share runs through its peers and is set aside; Queue Again starts it
  over.

## AGENTS.md

The music files bullet in Boundaries says, after the Approve Safe Matches Automatically
sentence, that Upgrade to FLAC Automatically queues upgrades and requeues an unclean one,
whose staged copy the service deletes, and links here.
