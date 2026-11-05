# 0089. One history for plays and places

- **Date:** 2026-11-04
- **Status:** accepted

## Context

⌘[ and ⌘] (Back and Forward) stepped through the sidebar sources shown, and nothing else. The
owner's feedback of 2026-11-04 evening (phase 40d) asked for them to undo and redo plays too,
so an accidental double-click is undone with ⌘[: the track before comes back at the place it
had reached, playing if it was, with the window as it was. He chose one history for both,
each step a source visited or a track played, each with the window's state (source, browse
and search, selection and scroll).

A play can be started several ways. From the browser: a double-click or Return in the track
table or the timeline, Play in the menus, and `music-player play`, which all reach the app
through `LibraryBrowser.play` and `playStart`. Within the queue the engine already has: a
track's end, Next and Previous (menu, toolbar, media keys, Dock), and a double-click in the
queue panel. ⌘K shows things and starts nothing. The plan left open which of these are steps.

## Decision

- **A step is a source shown or a play from the browser** that replaces the queue. Track ends,
  Next, Previous, the media keys and queue panel jumps are no steps of their own. They fold
  into the play that started the queue: what a play replaced is whatever was playing when it
  started, at the place it had reached. So Back after an album has played on goes to the
  track it had reached, not the one double-clicked, and one ⌘[ undoes an accidental play
  however many tracks it had advanced through.
- **Each step keeps the window as it was when last left**: the source, the search, the column
  selections, the selected tracks and the first visible track with its offset. Back over a
  step shows the window as it was just before it, and Forward shows it as Back left it. A
  source shown again returns to where the user got to in it. The timeline keeps its source
  only; its rows are plays, and it loads afresh each time it shows.
- **A play keeps the playback on both sides of it** as a `PlaybackSpot` (queue, entry,
  seconds, stopped, playing or paused). Back puts back what it replaced, and saves where it
  had got to; Forward plays that again, and saves what it replaces this time. Back over the
  first play of a session stops, since nothing played before it. Back over a source leaves
  playback alone.
- **`PlaybackEngine.restore`** replaces the queue and loads the entry at its seconds, without
  stopping the output first, so the device stays open (ADR 0078). With shuffle on, the rest
  of the queue is shuffled again after the restored track.
- **A play from Back or Forward isn't recorded again**, and a new step after Back drops the
  steps ahead, as in a web browser. Showing the source already shown adds nothing.
- **Back, Forward and recording a play run one after another**, each reading the engine's
  playback before it changes the history, so a quick second ⌘[ reads what the first put back.
- **In memory only.** The history starts at launch from the saved source, as before; no stored
  data changes.
- **The menu titles stay Back and Forward.** Their enabling reads the merged history.

## Alternatives considered

- **Every track change a step**, track ends and Next included: rejected. Undoing an accidental
  play that had advanced through an album would take a press per track, and an evening of
  albums would sit between a source and the one before it, so Back would rarely reach a place.
  Back over an advance would also be Previous, which has its own key.
- **Queue panel double-clicks as steps**: rejected for now. They jump within the queue Back
  would restore, they don't start from the browser's window, and Previous undoes them.
- **A play keeping the window it was started from**, rather than the window as left: rejected.
  Back from a source to a play's step would then lose the browsing done after the play, and
  Back over a play is an undo, which puts back the state just before it.
- **Two histories, one for places and one for plays**, with two pairs of keys: rejected by the
  owner, who wanted one.
- **Saving the history**: rejected. It would add a stored shape for a convenience that matters
  within a session, and its queues would name files that may have moved since.

## Consequences

Restoring a play loads a track at a position, which counts toward frecency as a track start,
as any play does. The queue's Play Next and Add to Queue marks are not kept, so a restored
queue's added tracks become ordinary entries. A play that replaced a paused track brings it
back paused. If queue jumps turn out to be accidental too, they can become steps: the app
would pass the queue panel's plays to the browser's history, since features don't call each
other.
