# 0055. The header is a toolbar the user customizes

- **Date:** 2026-11-02
- **Status:** accepted; the status styles amended on 2026-11-02 (phase 29.2); Now Playing (Centered) removed by [0072](0072-window-chrome-and-status-bar.md) (phase 30c.2); the default set, the status's width and its layout amended by [0085](0085-status-bar-builder.md) (phase 37b); the Custom Status items added by [0089](0089-custom-status-items.md) (phase 40c)

## Context

The owner wants the header to work like Swinsian's: a toolbar the user arranges with the
standard Customize Toolbar sheet, and a second way to draw the playing track, Swinsian's
centered title over a thin progress bar. The header was a stack of views above the browser,
with the transport, the now-playing status, a queue button and the search field fixed in place.

## Decision

- **An `NSToolbar` in the window.** Its items are the transport, volume, the now-playing
  status, search, shuffle, repeat, the queue toggle, the output picker, the signal path toggle,
  and AppKit's flexible space and space. Any of them can be removed, down to an empty toolbar.
  The defaults are the old header's items in its order: transport, status, queue, search.
  View ▸ Customize Toolbar… and the toolbar's context menu open the sheet.
- **The items run commands.** Shuffle, repeat and the two toggles are buttons that run their
  commands through the dispatcher and show whether the command is on, as the menus do. Repeat
  steps Off, All, One and shows Repeat One's symbol in that mode. The output picker is a menu
  item filled by the Controls ▸ Output menu's delegate. Volume is a slider over -60 to 0 dB of
  the digital volume, off when the device has none the app sets; a drag saves the device's
  profile once, when it ends.
- **The items are saved in `state.json`**, as `window.toolbarItems`, not by AppKit's
  autosave in user defaults, so window layout stays in one file. AppKit fills a toolbar with
  the default items as it joins a window, so the saved items replace them after.
- **The expanded toolbar style**, under the title. The unified style keeps the toolbar at the
  title bar's height, which clips the detailed status (art, three lines and a seek bar); the
  expanded style grows to the tallest item.
- **The status grows into the free width** through `NSToolbarItem.maxSize`, set by key-value
  coding. AppKit measures a view item at its fitting size, so constraints alone kept the status
  at its minimum width; the property is deprecated since macOS 12 with nothing in its place for
  a flexible width, and KVC sets it without the deprecation warning, which the build treats as an
  error.
- **Two status styles, each a toolbar item**, picked by customizing the toolbar as in
  Swinsian: Now Playing (`status`, in the defaults), the old status, and Now Playing
  (Centered) (`centeredStatus`), "Title by Artist from Album" centered in bold over a capsule
  with the elapsed time, a thin bar without a knob, which seeks, and the total time. Each is its
  own view, so the toolbar can hold either or both; the centered one is as tall as the art, the
  detailed one's tallest view. Phase 29.2 moved the choice here from the config's
  `appearance.nowPlaying`, which is gone: a config file that still sets it shows the banner
  until the line is deleted.
- **Liquid glass is the system's.** On macOS 26 AppKit draws toolbar items on glass; on 12 to
  15 the toolbar has the title bar's material. The app draws no backdrop of its own.

## Alternatives considered

- **AppKit's autosaved configuration.** Rejected: it writes to user defaults, a second place
  for window state beside `state.json`.
- **The unified style with a two-line status.** Rejected: the format line and the seek bar
  would have to go, and the owner uses both.
- **One `NSToolbar` delegate per feature.** Rejected: the toolbar mixes items of several
  features and the app's own commands, so the app tier builds it, as it builds the menus.

## Consequences

- AppKit keeps every toolbar with the same identifier showing the same items, so the tests
  give each toolbar an identifier of its own.
- A state file naming an item the app no longer has is discarded whole, as any state that
  doesn't match is.
