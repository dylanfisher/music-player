# 0113. The window across quits

- **Date:** 2026-11-06
- **Status:** accepted
- **Amends:** [0095](0095-play-state-across-quits.md)

## Context

The owner quit and relaunched, and the track list had lost the column it was sorted by (phase
48d). The sort is kept in `browser.trackTable` with the columns, and the table reported that
layout only when a column moved, resized, showed or hid, so a sort alone was never saved. A
look at every other piece of window state found three more losses: a manual playlist, History
or Stats saved as the source opened in the table's sort instead of its own; the search was saved
nowhere; and a frame saved while in full screen opened as a plain window the size of the screen.
On macOS 26 the sidebar's view is inset in its split item, so the saved sidebar width was 8
points short of the divider and the sidebar narrowed at every launch.

## Decision

- **Where each piece lives.** Per Mac, in the state file: the columns, their order and widths,
  and the table's sort (`browser.trackTable`); the timeline's columns; the panes' groupings and
  selections (`browser.columns`); the sort chosen in a source with its own
  (`browser.sourceSort`); the search (`browser.search`); the sidebar, queue, browser and Stats
  sizes; the queue, sidebar, browser, toolbar, status bar and signal path's visibility; and the
  frame. In the synced config, as ADR 0095 has it: the source, the selected track and the first
  visible track (`playback.resume`). Nothing moves between the two.
- **Two sorts.** `browser.trackTable` keeps the table's sort: the one sources without a sort of
  their own show. A manual playlist, History and Stats open in their own sort, at launch as on a
  click. A sort the user chose inside one of those is `browser.sourceSort`, with the source it
  was chosen in, and is put back only when the loaded source is that one, since the source comes
  from the synced key and may be another Mac's.
- **When it's saved.** The table reports its layout after any reload that changed the table's
  sort, as well as after a column change.
- **The search** loads only while the toolbar has the search field: without it nothing on screen
  says why the table is narrowed.
- **Full screen** isn't saved: the frame isn't saved from entering full screen until it's left,
  so the window opens at its windowed frame. Full screen itself isn't put back.
- **Split widths** are measured from divider to edge, the way they're put back.

## Alternatives considered

- **The sort and search in `playback.resume`**: rejected; ADR 0095 keeps the synced key small,
  and both are where this Mac left its window.
- **Saving the shown sort as the table's**: rejected. A quit while a playlist showed in its own
  order would save playlist order as the library's sort.
- **The whole multi-track selection**: left out. `playback.resume` names one track, which
  comes back selected; a selection of thousands of tracks would be a list of thousands of paths
  in a file saved at every change.
- **Putting full screen back at launch**: left out for now; it animates into a space of its own
  as the window opens, which is the owner's call.

## Consequences

A state file from an earlier build has no `browser.sourceSort` or `browser.search` and loads with
neither. A selection of several tracks comes back as the one `playback.resume` names, and the
scroll to that track's row, not the points within it. A Mac that quits in full screen opens
windowed. A sort chosen in History on one Mac isn't applied to a playlist another Mac's play
state opens.
