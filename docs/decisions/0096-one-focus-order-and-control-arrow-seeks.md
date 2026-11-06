# 0096. One focus order for Tab and ⇧Tab; Control-arrow seeks

- **Date:** 2026-11-05
- **Status:** accepted
- **Amended by:** [0103](0103-option-arrow-seeks-get-info-place-health-toggle.md): the seeks
  take ⌥→, ⌥←, ⌥⇧→ and ⌥⇧←, and the longer one moves at least 30 s

## Context

The owner's feedback of 2026-11-05 (phase 42a). Tab was Focus Next Area, a command the lists
take from their key presses: the sidebar, the browser's three columns, the track table (or the
timeline), then the queue. ⇧Tab was bound to nothing, so the lists left it to AppKit, whose
automatic key-view loop walks every view that can take the keys, in its own order. From the
second column it landed on a view that shows no focus before reaching the first, and it never
mirrored Tab. He asked for ⇧Tab to be Tab's exact inverse everywhere in the main window, for
the columns to take the keys when they're shown, and for Tab to reach the track table after a
column change while a track plays.

That last one: the playing track, selected in All, drops out of the table when another column
item is chosen, and the table reloads with nothing selected. Tab did give the table the keys,
but a table with no selection and no focus ring shows nothing, so the keys looked lost.

He also asked for ⌃→ and ⌃← to seek 10 s, and ⌃⇧→ and ⌃⇧← to seek 5% of the track, knowing
macOS binds ⌃→ and ⌃← to moving between Spaces by default.

## Decision

- **One ordered list.** `MainWindow.focusAreas` is the order: the sidebar, the columns, the
  track table or the timeline, and the queue, each while it shows. One function steps it either
  way, wrapping, so ⇧Tab visits Tab's areas in reverse by construction, and a test walks the
  list both ways with each part shown and hidden.
- **Focus Previous Area** (`focus.previousArea`, ⇧Tab) is a command like Focus Next Area, in the
  View menu after it, rebindable in Settings ▸ Shortcuts.
- **From outside the list**, Tab enters at the first area and ⇧Tab at the last. The search
  field passes its Tab and ⇧Tab to the same commands, so it doesn't fall back to AppKit's loop.
  The search field isn't an area: Tab from the queue doesn't put the keys in a field that takes
  Space and letters.
- **The move shows.** An area given the keys by Tab or ⇧Tab that has rows and no selection
  selects its first row.
- **Showing the columns** gives the first column the keys, except while the timeline shows in
  their place. Hiding them still gives a column's keys to the track table.
- **⌃→ and ⌃←** are second chords of Seek Forward and Seek Back, which already step 10 s:
  one command per action, and the menu keeps showing ⌥⌘→ and ⌥⌘←.
- **Seek Forward 5% and Seek Back 5%** (`playback.seekForwardPercent`,
  `playback.seekBackPercent`) on ⌃⇧→ and ⌃⇧←, in the Controls menu after Seek Back, from links
  as the other seeks are. The step is `AppCommands.seekStepPercent` of the playing track's
  duration, read from the engine's state; with no duration known they do nothing.

## Alternatives considered

- **Building AppKit's key-view loop by hand** (`nextKeyView` over the areas, with
  `autorecalculatesKeyViewLoop` off): rejected. The lists already take Tab as a command so it
  can be rebound, and two mechanisms for one order would drift apart; the toolbar's views would
  still need placing in the loop.
- **Putting the search field in the order**: rejected, as above; ⌘F reaches it.
- **Scrolling the selection into view on Tab** in place of selecting the first row: rejected.
  The selection was gone, not off screen, and a scroll moves the table the user is reading.
- **New commands for the 10 s Control-arrow seeks**: rejected, two commands for one action.

## Consequences

A config file whose shortcuts give ⇧Tab, ⌃→, ⌃←, ⌃⇧→ or ⌃⇧← to another command keeps that
binding, and the new default loses its chord, as for any override that takes a default's chord;
none of them was bound before. No state or config key changed. With macOS's Spaces shortcuts
on, the system takes ⌃→ and ⌃← before the app, so those two do nothing until the owner turns
the Spaces shortcuts off in System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Mission Control.
