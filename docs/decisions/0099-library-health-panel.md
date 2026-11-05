# 0099. Library Health as a panel over the track table, in a slot a source's panel can take

- **Date:** 2026-11-05
- **Status:** accepted
- **Amends:** [0034](0034-folders-and-library-health.md) (where the checks are listed),
  [0042](0042-window-layout-and-settings-sections.md) (what Show Browser hides)

## Context

The owner's feedback of 2026-11-05 (part 42d): Library Health should leave the sidebar, open
from a button in Settings ▸ Library and a menu item, and show the track table with a panel
above it, placed like the browser columns, listing the checks. Phase 43's Listening Stats puts
a panel of its own in the same place, so the place has to take more than one panel. Each check
was already a source, `.health(check)`, listed through `temp.health_tracks`, so the table,
search, sort, play and Get Info already worked on it.

## Decision

- **One command.** `library.checkHealth` keeps its ID, so a shortcut saved for it still holds,
  and is titled Show Library Health. It shows the check already shown, else the first
  (Unreadable), and runs the report again. The File menu's item, the palette, the command line
  (`checkHealth`) and Settings ▸ General ▸ Library's button all run that entry; the button goes
  through `SettingsActions.showHealth`, and the handler brings the main window forward.
- **No sidebar row.** The Library Health row and its check rows are gone, and the sidebar's
  count cell with them. While a check shows, no sidebar row is selected, so any row, Music
  included, is a click away.
- **The panel slot.** The browser's split has one first subview, a slot, holding the browser
  columns or, in their place, the panel `LibraryBrowser.panel(for:)` names for the source
  shown. A panel is an `NSViewController` conforming to `SourcePanel`, whose one method,
  `sourceShown(_:)`, is called after each change of the list while it shows. The panel takes
  the columns' height (`window.browserHeight`) and divider, and a drag saves the height as for
  the columns; it shows whether Show Browser is on or off, and the slot and its divider hide
  only when there's no panel and Show Browser is off. When another source shows, the panel
  leaves and the columns come back as Show Browser says. Keys in the panel go to the track
  table when it leaves.
- **The health panel.** A header line (Library Health, when the report ran or "Checking…",
  Check Again) over a tile per check in `HealthCheck` order, which flow into as many columns of
  180 points or more as fit and scroll when the slot is short. A tile shows the check's name,
  its count (a dash before the first report) and what it finds, truncated, in full in its
  tooltip; a check that found nothing is dimmed, and the one listed below is filled with the
  accent color. A click lists that check. The panel draws no background of its own, so the
  window's color or glass sets it apart from the table's rows.
- **Hidden columns don't narrow it.** Showing a check selects All in every column, in the same
  change, since the columns are hidden behind the panel.
- **Saved state.** A saved `health:<check>` source still decodes. At launch the window shows
  the library in its place, logged; the rest of the play state (selected and first visible
  track, the queue's source) is read as before. No key in `state.json` or `config.json`
  changes.

## Alternatives considered

- **A third split subview above the columns**, so health and the columns could show together.
  Rejected: the columns would narrow a check's list, and the owner asked for the columns' place.
- **A height of its own for the panel.** Rejected: it needs a new state key, and the owner asked
  for the browser's place and size; one divider position is what a user drags.
- **A new command ID, `library.showHealth`.** Rejected: the old ID's title is all that changed,
  and a new one would drop a shortcut the owner bound.
- **An `NSCollectionView` for the tiles.** Rejected: thirteen fixed tiles need a frame each in
  `layout()`, not a data source, layout object and item class.
- **Restoring a saved check at launch.** Rejected: Library Health opens from its command now,
  and a launch into it would leave the sidebar with nothing selected.

## Consequences

Phase 43 adds its Stats panel as a case of `panel(for:)` and a `SourcePanel` controller; the
slot, its height and divider, and the columns' return come with it. The panel isn't in the Tab
order: its tiles take clicks and VoiceOver's press, not keys. The browser columns and the
panel share one height, so a panel dragged taller leaves the columns taller.
