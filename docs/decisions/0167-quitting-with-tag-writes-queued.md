# 0167. Quitting with tag writes queued, and the saving count

- **Date:** 2026-11-09
- **Status:** accepted
- **See also:** [0107](0107-tags-written-in-place-within-the-padding.md) (a write cut short is
  put right at the next launch), [0108](0108-faster-tag-writes.md) (the status bar's "Saving
  tags"), [0095](0095-play-state-across-quits.md) (the play state saved at quit)

## Context

Tag writes and undos run one at a time on `TagEditing`'s queue, and a Discogs match set or a
batch edit on the NAS can take minutes. ⌘Q quit at once: the batch running was cut short, and
the batches queued behind it were never written, with nothing said. The owner asked, on
2026-11-09 (phase 62), for a question at quit, and for the status bar's "Saving tags: N of M"
to count the whole queue, and never to go backwards. It counted each batch alone, so a second
batch queued during the first raised M only once the first ended.

## Decision

- **The quit guard.** `applicationShouldTerminate`, while a write or undo is queued or
  running, returns `.terminateLater` and asks, app-modal since a quit can come with no window
  open: "N tag writes haven't finished." with Wait and Quit (the default), Quit Anyway and
  Cancel. N is the writes and undos not finished, a batch counting once. Wait and Quit quits
  once the queue is empty, writes queued while it waits included; Quit Anyway quits at once;
  Cancel stays. Either way out, the play state is saved as before, with its 1 s bound starting
  then.
- **Where the logic lives.** `TagEditing.holdQuit(_:)` decides and calls back; the app only
  wires the reply. It answers after it returns, never inside the delegate call, so the app has
  returned `.terminateLater` before it replies. A quit while one is already waiting joins it
  rather than asking again. The app asks only a tag editor already made, so a quit never makes
  one, which would start the launch's recovery of an interrupted write.
- **The saving count.** `TagEditing` keeps each write batch queued since the queue was last
  empty, running or finished, with its file count and its last report, and the status bar
  shows their `TagWriteProgress.combined`: M is every file queued in that span and N every
  file written. A batch queued while a save shows sends the new total at once. A finished
  batch stays counted until the whole queue drains, then the count clears. Undos and Organize Selected Files have no count to give
  and add none, as before.

## Alternatives considered

- **No question, finishing the queue before quitting.** Rejected: a long batch on a slow share
  would hold the quit with no way out.
- **A sheet on the main window.** Rejected: the main window may be closed or hidden at quit.
- **Counting files rather than batches in the question.** The undo has no count until it runs;
  a batch is what the user queued.
- **Dropping a finished batch from the count,** as the tagger's window does. Rejected: N fell
  back when a batch ended, which the owner didn't want.

## Consequences

A failure alert from a write that finishes during Wait and Quit is shown for a moment before
the app quits; the failed files keep their old tags and the journal is as the write left it.
A staged download's write ([0146](0146-staged-tag-writes.md)) runs outside `TagEditing`'s
queue and isn't held; it writes only inside the staging folder.
