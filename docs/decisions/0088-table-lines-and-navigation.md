# 0088. Album lines, line colors, a plain art column, and where the table centers

- **Date:** 2026-11-04
- **Status:** accepted

## Context

The owner's feedback of 2026-11-04 (phase 38b) asked for a line between albums in the track
table, colors for the row and album lines "so we can make it as dark or heavy as we want", the
Album Art column on a plain background without grid lines or alternating rows, ⇧⌘L to center the
selected track, Settings in ⌘K, and the playing track centered when he goes from a browse back to
all music. Several of these left choices open.

## Decision

- **Colors are a setting kind.** `HexColor` holds `"#RRGGBB"` or `"#RRGGBBAA"` (sRGB, the last
  pair the opacity), and `SettingKind.color` gives it a color well with opacity in Settings ▸
  Appearance. `appearance.rowLineColor` and `appearance.albumLineColor` are optional. Null means
  the system's grid color, which follows light and dark mode, where a fixed default wouldn't.
  The row has a Default button that sets null.
- **Column lines share the row lines' color.** One color for the grid. AppKit draws the column
  lines with one `gridColor`, and a separate color would be a third setting for a line the owner
  didn't ask about.
- **The rows draw the row and album lines.** `MarkedRowView` draws a 1 pt line along its bottom
  in the color it's given, so each row can carry the row or the album line. AppKit's horizontal
  grid has one color for every row. The table no longer uses AppKit's horizontal grid, so no
  lines are drawn below the last row.
- **An album ends where the album ID changes**, the same `albumID` the art column groups its runs
  by (album title and album artist). Adjacent rows without an album are one group, so a run of
  untagged tracks doesn't get a heavy line under each one. The art column still gives each of
  those rows a run of its own.
- **The plain art column is the table's own background**: white in light mode, the table's dark
  background in dark mode, and clear on the window's glass. The row view clips the column out of
  the alternating shade, the line, the playing tint and the selection, then fills it with that
  background. Erasing the shade with a clear fill instead drew the column black on glass. The playing row's bar still draws at the row's leading edge. The row view finds
  the column by identifier when it draws, so a moved or resized column is followed.
- **⇧⌘L is Show Selected Track** (`view.showSelectedTrack`), the same step ⌘L takes with nothing
  playing. No link may run it, since it needs a selection only the window has.
- **Settings… is a command** (`app.showSettings`, ⌘,) instead of a standard menu item, so ⌘K and
  the Shortcuts pane list it and the chord can be changed. Open Config File was already in ⌘K.
- **Back at all music, the playing track is selected and centered.** This happens when a user
  change (a source, a pane, a search, Back or Show All Music) takes the table from a narrowed
  list to the whole library. The model marks that change and the browser selects the playing
  row, centered, but leaves the keys where they are, so clicking Music in the sidebar keeps them
  in the sidebar. With nothing playing, the reload centers the selection as before. A palette
  jump or a reveal that widens the table selects its own row after this one.

## Alternatives considered

- **Override `drawGrid(inClipRect:)` or `drawBackground(inClipRect:)` on the table:** rejected.
  Overriding the table's background drawing makes scrolling several times slower (ADR 0084).
- **An opaque background in the art cell:** rejected. It covered the shade and the lines, but
  also the playing row's bar wherever the art column is first.
- **A fixed default color:** rejected. It can't follow dark mode.

## Consequences

The rows draw a line and a clipped selection, which the scroll bench measures. The colors are
checked with the rest of the config file: text that isn't a color is refused before it reaches
the table.
