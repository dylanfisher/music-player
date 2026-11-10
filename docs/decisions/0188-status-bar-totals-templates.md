# 0188. Templates for the status bar's totals

- **Date:** 2026-11-10
- **Status:** accepted
- **See also:** [0087](0087-toolbar-status-and-window-title.md) (the title template),
  [0085](0085-status-bar-builder.md) (the banner and the builder's Reset to Default)

## Context

The owner asked, on 2026-11-10, for the status bar's totals, "1,204 tracks, 5.1 GiB, 3 days
2 hours (3 tracks selected, …)", to get a template like the title line's, edited the same way
in Settings, with a template for each choice a click on the totals cycles through and one for
the line shown while nothing is selected. Each default had to read as the bar does, so nothing
changes until the owner edits one.

## Decision

- **One template type.** `TitleTemplate` becomes `TokenTemplate<Token>`, generic over a
  `TemplateToken` (its name, help and an example template), and `TitleTemplate` and
  `TotalsTemplate` are typealiases of it. The totals get the title line's braces, empty-field
  rule (the text before an empty token goes with it; a bracketed group of empty tokens goes),
  problems and banner, from the same code.
- **Four settings**, in Settings ▸ Appearance ▸ Status Bar after the layout:
  `appearance.totalsFormat` (nothing selected, `{tracks}, {size}, {duration}`),
  `appearance.totalsListAndSelectionFormat`, `appearance.totalsListFormat` and
  `appearance.totalsSelectionFormat`. They are four template rows rather than one setting of
  four fields, so each is the existing control and each problem names its own key. The click's
  choice stays in `state.json` (`window.statusTotals`).
- **The tokens**: `{tracks}`, `{size}`, `{duration}` and `{albums}` for the list, the same
  four as `{selectedTracks}` … for the selection, and `{missing}`. The selection's are empty
  while nothing is selected. `{albums}` counts the distinct albums the tracks are on, as the
  Album pane separates them; a track with no album adds none.
- **The missing count**: a template that names `{missing}` shows the playlist's missing
  tracks there, and the bar doesn't add " · N tracks not in the library" after it; a template
  without it keeps that line, so the defaults read as before. The timeline still shows its
  plays instead of the totals, and the health check's "N more items with no track to list" is
  still added after them; neither is a token.
- **Checked by its own setting.** A template row's problem line checks what's typed with the
  row's own setting (`SettingDescriptor.problem`), the decoding the config file uses, so a
  totals row refuses `{title}` and a title row `{tracks}`.
- **Reset to Default** on every template row, under the field, off while the value is the
  default, as the bar builder has one. The title rows get it too, since the control is one.
- **Counting albums cheaply.** The totals' cache numbers each track's album from 0, so a list
  counts its albums in an array of flags rather than a set. The bench row for the totals of
  every track after a play went from 0.49 ms to 0.57 ms (42,964 tracks, p95, budget 2 ms); a
  set took 1.24 ms.

## Alternatives considered

- **A time remaining token.** Left out: nothing in the app shows a time remaining today, of
  the queue or of the playing track, so its meaning is the owner's choice. It would also make
  the totals redraw every second, and the browser can't read the queue or the playback
  position without the app passing them in.
- **An artists token.** Left out: the track's artist, the album artist and the Artist pane's
  grouping each give a different count, and which one is the owner's choice.
- **A second parser for the totals.** Rejected: two parsers of the same braces would drift.
- **Placing the health count and the timeline's plays as tokens.** Not now: each would need
  a template of its own for the states it shows in, for lines few would edit.

## Consequences

- The bar's wording is written once, in the defaults; `TrackTotals.text` is gone.
- A template's type name in an error quotes its example ("such as {title} — {artist}").
