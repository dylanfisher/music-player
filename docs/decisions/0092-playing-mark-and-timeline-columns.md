# 0092. The playing mark, album lines across the art, and the timeline's columns

- **Date:** 2026-11-04
- **Status:** accepted
- **Amends:** [0088](0088-table-lines-and-navigation.md) (which lines cross the art column)

## Context

The owner's feedback of 2026-11-04 night (phase 41b) asked for a play triangle before the
playing track's title, an optional narrow column for the same mark, the album line drawn across
the Album Art column too, and the timeline showing the library's columns with Played first until
he changes the timeline's own. Each left a choice open: where the mark goes when both places
could show it, how a line gets over the art, and what "until he changes them" is stored as.

## Decision

- **The mark shows once.** The Title cell starts with `▶` on the playing row only while the
  Now Playing column is hidden; with the column shown, the column has it and Title doesn't.
  The owner picks where it goes by showing or hiding the column, with no setting for it.
  Amended 2026-11-05 (phase 42b, [0097](0097-playing-row-text-and-keeping-the-queue.md)): the
  Now Playing column centers its mark, the Title's mark has 4 points more space after it, and
  a dark playing row color turns the row's text white.
- **Now Playing is a track column** (`TrackColumn.nowPlaying`), so it's shown, moved, resized
  and saved like the others. It isn't sortable, its header is empty with its name in the
  tooltip and the menu, and it's 20 points wide by default, the narrowest a column may be.
- **The art cell draws the album line.** The row view's lines stay clipped out of the plain art
  column, as 0088 has them. The art cells draw over the row's background, so a line drawn there
  would hide under art that reaches its album's last row. The cell draws the album line along
  its bottom, over its art, when its row ends an album. Row and column lines still don't cross
  the column. The cell is inside its row view, and the hover is a subview of the table over the
  row views, so the hover covers the line.
- **The timeline's columns are one optional state key**, `browser.timelineTable`, a
  `TimelineLayout`: Played's width and the track columns after it. Null, the default, means
  the track table's columns after Played at its default width, following each change of the
  track table. The owner's first change in the timeline's header (a column shown or hidden from
  its menu, a column moved, or one resized by its header) saves the layout, and from then the
  timeline keeps it. A resize because the table's width changed isn't his, so a window resize
  doesn't freeze the timeline's columns. Played can't be moved, nor anything put before it.
- **The timeline leaves out Album Art, Order and Now Playing.** A play has no album run to span
  art over, no playlist position, and the timeline doesn't mark the playing track. The config
  check refuses them in a saved layout.

## Alternatives considered

- **The mark in both places**, or a setting to choose: rejected. Twice is noise, and showing
  the column already says which the owner wants.
- **The album line drawn by the row view across the art column**: rejected. The art covers it.
- **A "customized" flag beside a copy of the layout**: rejected. Null already says "follow";
  a flag would be a second fact that could disagree with the layout.
- **Played as a `TrackColumn`**: rejected. The track table's header menu would offer it, and
  it means nothing outside the timeline.

## Consequences

The track table's playing-row change and Now Playing being shown or hidden reload the Title and
Now Playing cells on screen. A timeline layout saved before a column is added to the track table
won't show that column until the owner adds it from the timeline's header.
