# 0106. The browser columns' groupings live in the config file

- **Date:** 2026-11-05
- **Status:** accepted
- **Amends:** [0069](0069-browser-column-groupings.md)

## Context

The owner asked for each browser column's grouping to be kept in `config.json` (phase 44d), and
noticed that `state.json` held no `browser.columns`. ADR 0069 saved each column's grouping and
selection together in the state file.

Why the key was missing, from the owner's files (read through copies) and the app's log:

- The state file holds only values that differ from their defaults (`StateStore.update`
  filters the rest out). `browser.columns` at the default groupings, Genres, Artists and Albums,
  with every column at All, is the default, so it isn't written.
- The owner's `state.json` has `window.browserVisible` false. Hiding the columns selects All in
  each (`clearPanes`), so with the default groupings nothing differs from the default.
- Groupings the owner picked before 11:53 on 2026-11-05 were lost. Until a75656f, a column at
  All was saved without its `selection` key, which the decoder requires, so the next launch
  refused `browser.columns` and discarded the whole state file. The unified log shows one such
  discard in the app (`MusicPlayer`, 2026-11-05 11:49:48, "discarded … which doesn't match this
  build", `SettingsError` code 3, a bad value). After that launch the window layout was saved
  again key by key, but the groupings went back to the default and stayed there.
- Since a75656f a non-default grouping is written and read back
  (`browserColumnsShowingAllReadBackAfterASave`), so groupings changed since then would be in
  the file. None are, so the owner hasn't changed one since.

## Decision

- **A new config key, `browser.columnGroupings`**: a list of three groupings, left to right,
  such as `["genres", "artists", "albums"]`, with the default under its comment in a new file.
  Like every config key it's optional: a file that doesn't name it applies the rest. It's
  `.windowState`, so the Settings window has no row for it and the palette no item; the
  columns' header menu is where it changes. It's synced with the config file to the other
  Macs (ADR 0012), as the owner asked for the groupings; the selections, which name entries of
  this Mac's library, stay in each Mac's state file.
- **The state key keeps its shape.** `browser.columns` still saves each column's grouping and
  selection. At launch the columns take the config's groupings when the file gives them
  (`ConfigStore.fileValue`), and a saved selection stays only in a column whose saved grouping
  is the config's for it (`BrowserColumn.restored`); any other is dropped, since a name means
  nothing in another grouping. A file that doesn't name the key, or that a problem blocks,
  gives no groupings, so the columns are the state file's, as before.
- **The header menu writes the config file, which regroups the columns.** A choice asks for
  the groupings it makes (a grouping another column shows trades places, as ADR 0069 has it)
  through `LibraryBrowser.groupingsChosen`. The app sets the key, then regroups the columns
  with `setGroupings`. The columns don't change on their own, so the window never shows
  groupings the file refused.
- **An edit by hand applies while the app runs**, as every other key's does: the file's change
  regroups the columns, each column whose grouping changed at All, and the columns to its right
  reload. An edit that takes the key out leaves the columns as they are, as a launch without it
  keeps the state file's, rather than jumping to the default.
- **An invalid value blocks the file**, as ADR 0082 has for a bad value of any known key:
  fewer or more than three groupings, one listed twice, or one the app doesn't know. The banner
  names the line and the problem, nothing in the file applies, and a choice in the header menu
  is refused with an alert naming the problem, until the file is fixed. The columns keep what
  they show.

## Alternatives considered

- **Taking the grouping out of the state key** — rejected: state and config keys change only
  by adding optional keys in this phase, and the state's grouping is what tells whether a saved
  selection still belongs to its column.
- **Default groupings when the config doesn't name the key** — rejected: a launch with a
  blocked file would show the default columns instead of the ones last used, and a state file
  with groupings would lose them at the first launch of this build. None of the owner's Macs
  has any now (this Mac's and the 2015 MacBook Pro's state files hold no `browser.columns`, and
  mbp2021 has no state file; read only), so this costs nothing today.
- **Changing the columns first and writing the config after** — rejected: while the file is
  blocked the window would show groupings the file doesn't have, and the state file would save
  them.
- **Writing the key at launch from the state file's groupings** — rejected: the app writes the
  config file only for a change the user makes (or the device in use, ADR 0082).

## Consequences

- The owner's `config.json` and `state.json` decode as they are (checked on copies). The
  config file gains the key, with its comment, at the first choice in a header menu.
- A hand edit of the groupings resets the regrouped columns' selections to All on every Mac
  that reads the synced file.
