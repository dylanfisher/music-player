# 0091. Show Current Track goes where the play started; Undo Selection

- **Date:** 2026-11-04
- **Status:** accepted
- **Amended by:** [0123](0123-undo-selection-settles.md): a selection becomes a step once it has
  stayed put for 5 seconds, replacing the coalescing below.

## Context

The owner's feedback of 2026-11-04 night (phase 41c) asked for two navigation changes.

Show Current Track (⌘L) selected the playing track in whatever the window listed, and showed
the whole library only when the source, a pane or the search hid it. A track started in the
library was shown in a playlist that happened to list it too. He wants ⌘L to go back to the
view the track was started from: the library, a playlist, the timeline. The browser already
takes a step for each play (ADR 0090), but a step's window is overwritten as the step is left,
so where a play started wasn't kept.

He also asked for Sublime Text's soft undo: ⌘U steps back over selection changes and ⌘⇧U
forward, never touching playback. His example: play a track, click another, ⌘L, then ⌘U selects
the clicked track again. He chose "selection + view": each step is a selection with the view it
was in, so undoing to a step from another source shows that source again. Coalescing, the cap,
and what a new selection after undo does were left open.

## Decision

### Show Current Track

- **A play keeps what the browser showed when it started**: the filter (source, search, column
  selections), apart from the step's window. The playing track's source is that of the latest
  play at or before the history's place, so after Back over a play ⌘L follows the play before.
  Track ends, Next and queue jumps keep the play's source, as they fold into its step.
- **⌘L tries, in order:** the track's row where the window already shows that source and lists
  it, keeping the window's own search and panes; the source with the play's search and column
  selections; the source alone; and the whole library, as before. A playlist since deleted, a
  track taken out of the playlist, and a session with no recorded play end at the library.
  Changing source is a step Back can undo, as the reveal into the library already was.
- **From the timeline**, ⌘L shows the timeline with the newest loaded play of the track
  selected, after its first page loads. Its rows are plays, and the play just started may not
  be logged yet, so the newest one is the nearest to what was double-clicked. A track with no
  loaded play there goes to the library.
- With nothing playing, ⌘L centers the selection, as before.

### Undo Selection

- **Two commands**, `go.undoSelection` "Undo Selection" ⌘U and `go.redoSelection` "Redo
  Selection" ⌘⇧U, after Back and Forward in the View menu. Neither chord was bound (⌥⌘U is Show
  Queue). They're rebindable in Settings ▸ Shortcuts and the config file like every command,
  and don't run from links, since they need the window. Sublime's name for ⌘U is Undo Selection.
- **A step is a `WindowPlace`**, the capture Back and Forward use: filter, selected track IDs,
  first visible track. Showing a step goes through `LibraryBrowser.show(_:)`, which Back uses
  too, so there is one restore. It changes source as a visited step for Back.
- **A step is recorded when the track table's selection changes** to a non-empty selection
  other than the current step's in the same source. The same tracks still selected under a new
  search or pane keep their step as it was made. An empty selection is no place to go back to,
  so it isn't a step. The timeline's rows are plays, which a place doesn't hold, so its
  selections aren't steps.
- **Coalescing, as in Sublime:** consecutive moves by the selection commands' keys (↑ ↓, ⇧↑
  ⇧↓, ten rows, page, first and last, and ↑ ↓ from the search field) in one source are one
  step, holding where the run ended. A click, ⌘L, a reveal, Show Album or any other jump is a
  step of its own and ends a run. A selection a reload made (rows kept or dropped as a source,
  search or pane changed) is replaced by the next change, so ⌘L into another source makes one
  step, not one for the reload and one for the track. Each Shift-click and each type-to-select
  match is a step: each lands on a row the user chose.
- **Undo first returns to the current step when the window has moved off it**, to another
  source or to no selection, and otherwise to the step before. The step left keeps the window
  as it was left, scroll included, so redo comes back to it.
- **A new selection after undo drops the redo steps.** At most 100 steps; the oldest go first.
  Steps in a deleted playlist go, as Back's do.
- **In memory only**, never saved, and never touches playback.
- Undo, redo, Back and Forward run one after another, so a quick second ⌘U reads the window
  the first one left.

## Alternatives considered

- **⌘L to the play's step window:** rejected. That window changes as the step is left (ADR
  0090), so it would show where the user browsed to afterwards, not where the play started.
- **⌘L always to the play's source with its search and panes**, even when the window shows the
  source and lists the track: rejected. It would undo a search the user typed since, only to
  select a row the window already showed.
- **Time-based coalescing** (changes within a second as one step): rejected. The owner's own
  example, a click then ⌘L, can come within a second.
- **Recording every selection, empty ones and reload ones included:** rejected. Undo would land
  on blank tables and on selections nobody made.
- **Undo over the timeline's selections too:** left out. A place holds track IDs, and the
  timeline's rows are plays that load a page at a time.
- **Saving the steps:** rejected for the reasons ADR 0090 gives for Back's.

## Consequences

The restore Back and undo share now centers the first selected row when the step's first
visible track is gone from the list, where it left the scroll alone before. Part 41f, which
saves the play state across quits, can call `show(_:)` with a saved `WindowPlace`.
