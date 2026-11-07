# 0123. A selection becomes an Undo Selection step once it has stayed put for 2 seconds

- **Date:** 2026-11-06
- **Status:** accepted
- **Amends:** [0091](0091-show-playing-and-undo-selection.md) (when a selection is recorded as a
  step, replacing its coalescing)

## Context

ADR 0091 made each click or jump a step and joined runs of selection keys. The owner found the
steps hard to travel: "every time you move items, there's a debounced cooldown, like 5 seconds
or so, where it saves your selection state at that point. So if you click a different item
once, after 5 seconds it saves that soft undo point." Using it, they shortened the wait to 2
seconds the same day.

## Decision

- **The latest selection is pending, and becomes a step when it hasn't changed for 2 seconds**
  (`SelectionHistory.settleDelay`). A selection that replaces it first, by click, key, jump or
  reload, takes its place, so a burst of changes is one step: the one it settled on.
- **Undo and Redo settle the pending selection first**, so Redo comes back to it. A pending
  selection that equals the current step adds nothing, and an empty selection leaves nothing
  pending, as before.
- **The cause of a change no longer matters.** The key-run joining and the reload replacement
  of 0091 are gone: both are cases of a newer selection replacing a pending one.
- **The struct holds no clock.** `note(_:)` sets the pending selection and `settle()` makes it
  a step; `BrowserModel` restarts a 2 second wait on each change and calls `settle()` when it
  ends, so tests settle by calling it.
- The cap, the redo drop, deleted playlists and the in-memory history are as in 0091.

## Alternatives considered

- **Timestamps passed to `record`:** rejected. A wait that restarts on each change needs a
  timer anyway, and `settle()` keeps the struct free of time.
- **Keeping the key joining beside the debounce:** rejected. A run of keys is a burst of
  changes, which the debounce already collapses.

## Consequences

A click followed within 2 seconds by Show Current Track is one step, not two, so 0091's example
(play, click, ⌘L, ⌘U selects the clicked track) now needs the click to have stayed put for 2
seconds.
