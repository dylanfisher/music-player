# 0202. The rating's menu marks, Get Info's stars and the status bar's message

- **Date:** 2026-11-10
- **Status:** accepted
- **See also:** [0162](0162-a-hand-set-play-count.md) (the index's play count in Get Info),
  [0163](0163-download-progress-and-the-status-item.md) (another feature on the status bar's left)

## Context

The Rating submenu showed no rating as chosen, Get Info showed none, and the six rating commands
had no default chords. The owner asked for the menu's tick, five stars in Get Info that rate as
the track table's Rating column does, ⌘⌥⇧0 to ⌘⌥⇧5, and a message saying what a rating set,
which mustn't cover a scan's progress.

## Decision

- **The commands act on the selection,** the track table's or the timeline's, as Like and
  Dislike do. The menu ticks the rating every selected track has, Clear Rating for unrated, and
  gives each rating of a mixed selection the mixed mark. The dispatcher takes an `isMixed` rule
  beside `isOn`, so a menu item can say it. The browser reads the selection's ratings once per
  change of the selection or of the index's change stamp, so validating the submenu's six items
  reads them once.
- **⌘⌥⇧0 clears and ⌘⌥⇧1 to ⌘⌥⇧5 rate.** No default had ⌘⌥⇧ with a digit, and macOS's own
  digit shortcuts (⌘⇧3 to ⌘⇧5) don't hold ⌥. AppKit matches the menu item "1" with ⌘⌥⇧
  against the real key event, whose `charactersIgnoringModifiers` is "!" on a US layout.
- **The message has a label of its own** on the status bar's left, after the scan, saving and
  analysis text and the Downloads accessory, and before the leading columns. With nothing
  running it's at the bar's bottom left; during a scan it sits beside the scan's text and bar.
  The totals' label, which failures use, isn't touched. It fades after 3 seconds, and a newer
  message replaces it and restarts the wait. Only the menus and shortcuts show it: a click in
  the Rating column or on Get Info's stars changes stars the user is looking at.
- **Get Info rates at once,** not on Save: the rating is the index's, and no tag is written, as
  for the play count (ADR 0162), but without the Plays field's Save, since a click is already a
  choice. Tracks the index doesn't have can't be rated, so the stars are off while none of the
  window's tracks is in it.
- **Mixed, in Get Info,** is the five empty stars dimmed, with "Mixed", the fields' placeholder,
  as their tooltip and accessibility value. A click sets the star's rating; none clears, since
  there's no shared rating to clear.
- **`RatingClick` moved to the library module,** the lowest both features import, and gained
  the hover mapping.

## Alternatives considered

- **Rating the playing track when nothing is selected.** Rejected for now: no track command
  falls back to the playing track, and adding that to one would make the others surprising.
  Phase 80 adds the playing track's stars to the status bar and the toolbar.
- **The message in the totals' label,** as failures show. Rejected: it would hide the totals for
  3 seconds after every rating, and the totals' column may be anywhere in the bar's layout.
- **Mixed as a dash or "Mixed" text in place of the stars.** Rejected: the stars would then
  change width, and the hover still needs them to show what a click would set.

## Consequences

- A rating synced from another Mac shows in an open Get Info window only when it's opened
  again; phase 80 makes the bar follow syncs.
- Every rating the browser sets tells the info windows, which read their tracks' ratings again.
