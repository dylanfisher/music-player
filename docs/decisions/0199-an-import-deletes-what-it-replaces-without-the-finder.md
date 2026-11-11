# 0199. An approved import removes the files it replaces without the Finder

- **Date:** 2026-11-10
- **Status:** accepted
- **Amends:** [0147](0147-moving-downloads-into-the-library.md) (the old files go to
  `moveToTrash`, which on a share with no Trash deletes them)
- **See also:** [0125](0125-trash-always-removes.md) (a file gone from its path counts as
  moved), [0193](0193-approving-safe-matches-unasked.md) (approving unasked),
  [0050](0050-remove-from-library.md) (Remove and Move to Trash)

## Context

With Approve Safe Matches Automatically on, an upgrade approved unasked still stopped on a
dialog saying its old files would be deleted. The owner: that defeats approving unasked.

Nothing in the app asks. The import gave the old files to `moveToTrash`, the call Remove and
Move to Trash makes, which passes them to `NSWorkspace.recycle`. That hands them to the Finder,
and on a volume with no Trash, such as the owner's NAS share, the Finder asks whether to delete
them at once before it does. The sheet's Approve met the same dialog after a sheet that already
says the old files are deleted permanently on a share with no Trash, so the owner was asked
twice.

## Decision

- **The import removes its old files itself,** through `trashOrDelete` (`Core/Library`), which
  the app gives `Downloads.Setup` in place of `moveToTrash`. Off the main actor, each file in
  turn goes to `FileManager.trashItem`, which moves it to its volume's Trash and shows nothing.
  On a volume with no Trash that call throws `CocoaError.featureUnsupported` and leaves the
  file; the file is then deleted with `FileManager.removeItem`.
- **Only that error makes it a delete.** Any other error from the Trash, a permission one say,
  leaves the file where it is and is reported.
- **A file that isn't removed fails the job's delete step, as before.** The import still counts
  a file as gone when it's no longer at its path (ADR 0125), says which weren't removed and why,
  and a later run resumes from the delete.
- **The sheet's Approve and the unasked one both change,** since both run `ImportRun`.
- **Remove and Move to Trash keeps `moveToTrash` and the Finder's dialog.** Nothing before it
  says the files are deleted for good, so the Finder's question is the only warning.

## Alternatives considered

- **Asking the Finder not to ask.** `NSWorkspace.recycle` has no option for it, and the
  Finder's own setting would change every deletion on the Mac.
- **Deleting at once whenever the volume isn't local.** Rejected: a network volume can have a
  Trash, and the old files should go to it where there is one. The Trash itself says when there
  isn't one.
- **Checking for the volume's Trash folder first**, with `url(for: .trashDirectory,
  appropriateFor:)`. Not needed: `trashItem` already answers that, and on a local volume a Trash
  folder not made yet would read as no Trash.

## Consequences

- An upgrade on the NAS lands with no dialog, whether approved in the sheet or unasked, and its
  old files are gone for good.
- If the NAS's share answers `trashItem` with an error other than `featureUnsupported`, the job
  fails at its delete step saying so, and the old files stay. The owner check on the NAS
  confirms the error it gives.
- `moveToTrash` is called only by Remove and Move to Trash, so it's internal to the library
  browser.

## AGENTS.md

The music files bullet in Boundaries says, in its Approve sentence, that an upgrade moves the
files it replaces to the Trash, or deletes them on a share with no Trash, and links here.
