# 0087. Swinsian's seek bar colors, a centered toolbar status, and a window title template

- **Date:** 2026-11-04
- **Status:** accepted
- **Amends:** [0084](0084-status-bar-on-glass.md) (the list headers on glass),
  [0085](0085-status-bar-builder.md) (the toolbar status)

## Context

The owner's feedback on phase 37b: with nothing playing, the toolbar status showed a gray box
where the art goes; the progress bar's colors were off against Swinsian's; the status should
stay centered between flexible spaces, with nothing on the left and Search on the right; a
"toolbar title" setting should change the window's title, which always said MusicPlayer and
had no setting at all; and on glass the table headers should be more translucent. The
screenshots of Swinsian's bar didn't reach the session.

## Decision

**With nothing playing the art is transparent, not hidden.** The toolbar status's and the
status bar's art views keep their place at alpha 0 while no track is current, so the text and
the seek bar beside them don't move when a track starts. A track that plays without art still
shows the gray box, which says the art is missing rather than nothing playing.

**The seek bar takes Swinsian 3.1's colors from its binary.** Swinsian's `Assets.car` holds
only its table backgrounds and icons, and its themes are the desktop overlay's HTML. Its main
window's nib names `ProgressControl` for the bar, and that class's `drawRect:` in the arm64
slice of the binary (copied from mbp2015's `/Applications/Swinsian.app`, read only) fills the
track with `colorWithCalibratedWhite:0.86` and the played part with
`colorWithCalibratedRed:0.265625 green:0.51171875 blue:0.91015625`, or `darkGrayColor` when
`currentControlTint` is graphite. Neither depends on the appearance, so the bar is the same in
light and dark and on glass. Swinsian draws no knob and no buffered part, so neither does
ours. Its bar is a plain rectangle inset 8.5 by 3 points; ours keeps its rounded 4-point
track, since only the colors were in question.

**AppKit centers the status.** `NSToolbar.centeredItemIdentifiers` (macOS 13) names the
status, and on macOS 12 the older `centeredItemIdentifier`. A probe on this Mac measured the
status's middle against the window's at 1440, 1000 and 800 points, with nothing, the default
set and four buttons on its left, plain and with the glass's full-size content view. Without
the identifier the status sat 110 points left of center in the owner's layout and 20 in the
default set; with either property it was on the window's center to the point, the same on
both, while it fit there at its width. When it doesn't, at about 1000 points with Search alone
on the right and 560 points of status, AppKit moves it as little as it can. The toolbar's
center is the window's, glass or not, though on glass the title and the status bar's middle
center beside the sidebar (0085).

**`appearance.windowTitle` is a template.** `TitleToken` lists the fields a template can name,
with a help line each: title, artist, album, album artist, composer, genre, year, track and
disc number, and the file's format. Their names follow the track table's columns. The default
is `{title} — {artist}`. Braces hold only a token, so an unknown name, `{}` or a stray brace is
the value's problem, refused at load and in Settings like any other, with every token in the
message. NowPlaying fills the template from the playing track; separators (spaces, dashes,
bars, dots, colons, slashes, commas) are trimmed from the ends, so a track without an artist is
titled "Song", not "Song —". With nothing playing, or with every named field empty, the window
takes the app's name. The title updates on a track change, a rescan of its tags and a change of
the setting. Settings ▸ Appearance shows a text field and a help button whose tooltip and
popover list the tokens, from the setting's kind, a new `SettingKind.template`. The window's
title shows over the expanded toolbar with the glass on and off; the glass makes the title bar
transparent but leaves `titleVisibility` alone.

**On glass the list headers are a translucent tint.** The glass gave the headers cells that
draw no background, but `NSTableHeaderView` fills itself opaque behind any cell that isn't its
own: 0.97 white in light and 0.26 in dark, measured by drawing a header here. The glass now
also swaps each list's header view for a `GlassHeaderView` that draws the text color at 8%, a
separator line under it and the cells, the dragged column last at its offset. Taking the glass
off puts the original header view back with whatever menu was set meanwhile.

## Alternatives considered

- **Hiding the art views.** Rejected: the status's stacks drop hidden views, so the text would
  jump left when a track started.
- **Shrinking the status to stay centered in a narrow window**, from the measured insets of the
  items beside it. Not done: AppKit gives the item views' frames only after it lays the toolbar
  out, items like Output and the spaces have no view to measure, and changing the status's
  width on every resize step would lay the toolbar out twice a frame.
- **Plain text with `%artist%` tokens, or the track table's 50 columns as tokens.** Rejected:
  braces are what the owner wrote, and the columns' text lives in LibraryBrowser, which
  NowPlaying can't import; the ten fields cover what a title shows.
- **Unknown tokens left as typed.** Rejected: a typo would show in every window title with no
  report.
- **A clearer header without a tint.** Rejected: the titles would float over the rows scrolling
  under them, with nothing to mark the header's edge.

## Consequences

- The colors need the owner's eye against Swinsian on the same screen: they're Swinsian's
  values, but its window may draw the bar over a background that changes how they look.
- The macOS 12 centering path and the headers on macOS 12 to 15 were not run on those systems
  here; the 2015 MacBook Pro's owner check covers them.
- On macOS 26 the scroll view also draws a scroll edge effect under the header, which has no
  public API; it softens rows under the header and stays as AppKit draws it.
