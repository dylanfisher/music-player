# 0046. Go to Item goes to an entry, and filters on a key of the palette's own

- **Date:** 2026-11-02
- **Status:** accepted
- **Amends:** [0016](0016-palette.md)
- **Amended by:** [0052](0052-left-and-right-skip-tracks.md): → in the app is Next Track's.

## Context

Choosing an artist or an album in ⌘P narrowed the browser panes to it. The owner wants ↩ to show
it in the full track list instead, and to filter only on ⌘↩, ⌘-click, or a key set in Shortcuts
that is → by default. → is already Focus Next Pane's, and a key had one meaning across the app.

## Decision

- **↩ or a click on an artist or album** shows the whole library, with no pane or search
  narrowing it, and selects and centers the first row of that list that is one of the entry's
  tracks. ⌘↩ and ⌘-click filter, as ↩ did. A genre in ⌘K still filters on either, and a track
  still shows where it is.
- **⌘↩ is a fixed palette key**, as ⌘W is: the palette takes it before the menu bar whatever the
  user binds it to, since it is the modified ↩ the palette's rows already answer to. Only the
  filter key that acts beside the query, → by default, is set in Shortcuts.
- **Filter to Item is a palette key**: a command marked `inPalette`, whose chords are claimed
  apart from the app's, so it can share → with Focus Next Pane. It runs from no menu, and the
  Shortcuts pane lists it last, under Palette. Reserved chords and fixed primaries (⌘A) stay out of
  it too, since the palette's field needs them, and so does any chord that types in the field: a
  character, Space or Delete with no modifier but ⇧ or ⌥. The palette takes its keys before the
  field, so a Space binding would keep "Miles Davis" from being typed.
- **The filter key acts on an artist or album row only with the insertion point at the end of
  the field.** Elsewhere, or on any other row, the key goes to the field, so → still moves
  through the query.

## Alternatives considered

- **A setting for the filter key** — rejected: chords are recorded and checked in the Shortcuts
  pane, and a second recorder would need the same clash rules.
- **Giving the palette key a chord no app command has** — rejected: the owner asked for →.
- **→ filtering wherever the insertion point is** — rejected: editing a typo in the query would
  close the palette.

## Consequences

A command line `filterToItem` finds no handler and reports that it can't run. A second palette
key goes in the same scope with no further work.
