# 0161. Moving by album, typed palette search, the Edit menu, and more browser columns

- **Date:** 2026-11-09
- **Status:** accepted
- **Amends:** [0012](0012-searcher-conventions.md) (Move 10 Rows loses its ⌃⇧↓ / ⌃⇧↑
  alternate), [0106](0106-column-groupings-in-the-config-file.md) (the columns' count)
- **See also:** [0088](0088-table-lines-and-navigation.md) (where an album ends),
  [0141](0141-copy-only-drag-out-of-the-app.md) (a drag out offers a copy only)

## Context

The owner's feedback of 2026-11-09 (phase 56) asked for Shift with ⌥↑/⌥↓ to select the rows
the jump passes, ⌃↑/⌃↓ to move to the first track of the previous or next album, `album:` and
`song:` searches in ⌘P, Copy, Paste and Delete in the Edit menu, and more than three browser
columns. He chose that Copy puts text only on the pasteboard, one "Artist – Title" line per
track, and that Paste and Delete work in playlists and the queue only. Each left choices open.

## Decision

- **Shift with ⌥↑/⌥↓** are two commands, Extend Selection Up and Down 10 Rows, so they can be
  rebound like the rest.
- **The album moves** are Select Next and Previous Album (⌃↓, ⌃↑) and Extend Selection to Next
  and Previous Album (⌃⇧↓, ⌃⇧↑). An album ends where the album ID changes, as the album lines
  draw it, and adjacent rows without an album are one. From inside an album, ⌃↑ goes to the
  album before it, not to its own first track, as the owner worded it. In the first album it
  goes to the first row; past the last, ⌃↓ stays. The track table has album IDs; the timeline,
  the queue and the panes have none, and leave their selection alone. The track table reads
  only the album IDs from the index, 500 rows at a time off the main actor, not the rows
  through its page cache: a long run without an album would fetch a page per 100 rows in the
  key handler. A read that fails is reported and moves nothing, rather than reading as no
  album. Each move waits for the one before, so a held key moves an album per repeat. Move
  10 Rows gives up its ⌃⇧ alternate for them, since ⌥↓ and ⌥↑ already do the same.
- **Mission Control** takes ⌃↑ (Mission Control) and ⌃↓ (Application Windows) by default,
  system-wide, before the app sees them. The defaults stay what the owner asked for. To use
  them he turns those two off in System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Mission
  Control, or gives the commands other chords in the Shortcuts pane. ⌃⇧↑ and ⌃⇧↓ aren't system
  shortcuts, so extending works either way.
- **Typed palette search:** a query that starts with a kind's name and a colon lists only that
  kind, matched on the rest: `artist:`, `album:`, `song:` or `track:`, `genre:`, `playlist:`,
  and in ⌘K `command:`, `setting:` and `output:`. Any case, spaces after the colon ignored. A
  word before a colon that names no kind leaves the query as typed, so a title with a colon in
  it still matches.
- **Copy** writes the text only, so pasting in Finder or a mail can't copy a library file. The
  app keeps the copied files' paths with the pasteboard's change count; Paste uses them only
  while the pasteboard still holds that copy, and is off otherwise. A pasted list of names
  from elsewhere isn't matched against the library: the matches would be guesses.
- **Paste** adds to the queue as Add to Playback Queue does, after the tracks already queued,
  or to the manual playlist shown, after the last selected row when it's in its own order. A
  playlist holds a track once, so a track it has already moves there. The tracks keep the
  order they were copied in, where a drag of rows keeps the playlist's. Never to the library or
  a smart playlist. Copied queue files the library doesn't know are left out of a playlist,
  and the status line says how many.
- **Delete** is a new Edit item without a chord, which runs Remove from Queue or Playlist. ⌫
  stays Remove…. Copy, Paste and Delete stay standard items, which the app delegate answers,
  so a text field's editor takes ⌘C and ⌘V first.
- **Browser columns:** one to six, three by default. Six beside the sidebar on the 2015
  MacBook Pro's 1440-point-wide screen leave each column about 150 points, about the narrowest
  an album title reads in. A column's header menu adds one to its right, grouping by the first
  grouping no column shows, and removes the column. Both write `browser.columnGroupings`, as a
  grouping chosen there does (`groupingsChosen`), so the count is in the config file, and the
  config file's count wins over the state file's at launch.

## Alternatives considered

- **⌃↑ to the start of the album first, then the previous album,** as Option-Up does in text:
  rejected, since the owner asked for the previous album.
- **Other defaults to avoid Mission Control:** rejected; the owner chose ⌃↑/⌃↓, and the
  Shortcuts pane can change them.
- **File URLs on the pasteboard beside the text:** rejected by the owner's choice; Finder would
  paste copies of the files.
- **Paste at the queue's selection:** needs a new engine call for one place in the queue; Add
  to Playback Queue's place is the one the queue's own commands use.
- **No limit on the columns:** past six, they're too narrow to read on the old Mac.

## Consequences

Whoever used ⌃⇧↓ for ten rows now extends to the next album with it; ⌥↓ still moves ten. The
app delegate validates the Edit items, so they're on only when the main window is key and a
track list or the queue has the keys.
