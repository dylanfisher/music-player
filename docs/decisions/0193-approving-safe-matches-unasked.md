# 0193. Approving safe staged matches unasked

- **Date:** 2026-11-10
- **Status:** accepted
- **Amends:** [0147](0147-moving-downloads-into-the-library.md) (Approve is the owner's
  confirmation for each job)
- **See also:** [0146](0146-staged-tag-writes.md) (a clean run),
  [0169](0169-approve-at-once-and-manual-upgrades.md) (the sheet's plan, Keep Both),
  [0156](0156-replacing-an-album-at-its-own-paths.md) (an upgrade at its own paths)

## Context

The owner asked for a box at the top of the Downloads window that approves a staged download
whose tags check out, upgrades included, so a download goes into the library with good Discogs
tags and nothing to click.

AGENTS.md lets Approve move staged files into the library, and an upgrade's replaced files to
the Trash, only for a job the owner approved in its sheet. This ADR adds a second way to give
that confirmation.

## Decision

**The box is the confirmation.** `import.autoApproveSafeMatches` (`AppSettings`), off by
default, titled Approve Safe Matches Automatically, is a box above the window's toolbar, and
is also in Settings > General's Downloads section, as `import.` keys are. Ticking it is the
owner's standing confirmation for every job it finds safe, on this Mac, until it's unticked.
Each Mac has its own `config.json`, so each Mac's box is its own.

**What is safe.** Only a job that would leave the owner nothing to judge in the sheet:

- `staged`, tagged `clean` (ADR 0146's clean run: Exact, every file mapped, the mapping the
  service reported), with no other Mac's review claim (`Downloads.mayApproveUnasked`), and not
  tagged as another release in the tagger here (ADR 0178);
- its plan, built and checked as the sheet's is, with no blockers when nothing is ticked or
  acknowledged: no moves problem, no upgrade problem, no old file without a new one, and no
  lossy-origin finding, or a file the check couldn't read;
- no library album it replaces without being queued as an upgrade (`replaced`), since the
  sheet then offers Keep Both and the download may be a lesser copy, and no note that the
  library holds albums of its release it can't replace (`notReplaced`)
  (`ApprovalPlan.unasked`).

**The same path.** The job then goes through the coordinator's `approve`, the call the sheet's
Approve makes, with the `ApprovedImport` the sheet would make: its claim, its stale check, and
`ImportRun`'s moves, Trash call and stats carried, so an upgrade replaces its old files as
Approve does, at their own paths under ADR 0156. Nothing else moves a file.

**One at a time, after each poll.** After each poll, and when the box is turned on, the first
such job by id is taken under the 24-hour review claim; none starts during an Approve… on this
Mac, and its row's actions are off while it runs. Anything not clearly safe, or any refusal,
gives the claim back and leaves the job staged, with the reason in the State column's tooltip
("Not approved automatically: …"). A job left is not looked at again until the box is turned
off and on, so a job left for a lossy-origin finding isn't checked every minute. An import that
fails stops at its stage, as Approve's does, and Retry goes on.

## Alternatives considered

- **Approving every clean job.** Rejected: the sheet's blockers are there because the owner's
  judgement is needed; an unticked old file without a new one would be lost, and a lossy-origin
  finding is the one sign the files aren't what they claim.
- **Approving a new album that replaces one in the library by its release id.** Rejected for
  now: a job queued by hand may ask for any format, so it can replace FLAC with MP3, and the
  sheet offers Keep Both. Queued as an upgrade, a job only asks for a lossless format.
- **A confirmation per job, in a notification.** Rejected by the request: the owner wants no
  step between the download and the library.

## Consequences

- A clean download goes into the library within a poll of its tag run, about a minute, with no
  one at the Mac.
- A bug in what counts as safe moves a download into the library, or deletes an upgrade's old
  files, without the owner looking. The tests hold each blocker to leaving the job staged.
- A Mac with the box on and its NAS unmounted leaves each clean job with the reason, until the
  box is turned off and on.

## AGENTS.md

The music files bullet in Boundaries says, in its Approve sentence, that the box approves such a
job as the owner's standing confirmation, and links here.
