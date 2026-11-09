# 0158. Every window keeps its frame in the state file

- **Date:** 2026-11-09
- **Status:** accepted
- **See also:** [0055](0055-customizable-toolbar.md) (window layout in `state.json`, not user
  defaults), [0136](0136-asking-before-a-rescan-and-undoing-a-tagger-write.md) (the tagger's
  sheets' sizes)

## Context

The main window has kept its frame in `state.json` since phase 5. The other windows didn't. Settings
and Library Health called `center()` on first show, so they opened in the middle of the screen
the window was made on at every launch. Downloads, the tagger and Year in Review set an AppKit
frame autosave name, which writes user defaults, and Downloads then called `center()` as well,
which put it back on the primary screen. With a window of `NSWindowController` the controller's
own, empty autosave name can also clear the window's. The owner, whose main window is on a
second display, saw Settings move after every relaunch, and Downloads open at the bottom left
of the primary display.

## Decision

- **One mechanism, one call.** A primitive, `WindowPlacement`: `placedFrame` decides where a
  window opens, and `PlacedWindows` places it and hears its moves and resizes. A window takes
  part with `window.keepsFrame(as: name)`, once its size is set and before it first shows;
  later calls for the same window do nothing, so a `show` can make the call every time.
- **Where it opens.** The saved frame when a screen still shows part of it. A window that
  doesn't resize (Settings, the bar builders) keeps the size its content gives it, under the
  saved top left, since Settings changes height by pane. Otherwise, the first time or with the
  display gone, it's centered on the screen of the main window, the anchor, not the primary
  one; a resizable window larger than that screen is shrunk to fit.
- **Saved in `state.json`**, as `window.frames`, an object by window name, through the layout
  saver the main window's frame goes through. Not AppKit's autosave: ADR 0055 keeps window
  layout out of user defaults, so it's one file and a reset is one delete. A frame in full
  screen isn't saved.
- **The names are the windows' titles** where they have a fixed one ("Settings", "Downloads",
  "Discogs Tagger", "Year in Review", "Library Problems", "Playback Problem", "Spectrum"), and
  "Bar Builder: <setting key>" for each bar builder.
- **Who takes part now:** Settings, Downloads, the tagger, Year in Review, Library Health, the
  playback problem panel, each bar builder, and the first Spectrum window; later Spectrum
  windows cascade from the last one open, as before. Get Info keeps its own top-left place
  (`tagEditor.place`) until phase 57 makes it resizable on this mechanism. The palette keeps
  its own place, near the top of the screen. The main window keeps its own frame, with its
  full-screen and layout-restoring rules.

## Alternatives considered

- **`setFrameAutosaveName` on every window:** user defaults, a second store for layout, and
  it doesn't choose the main window's screen for a first open.
- **A frame per window in `AppState`, one setting each:** a new setting for every window that
  joins, where a map takes a new window with no schema change.
- **Passing a frame store into each feature:** plumbing in every window's init for one fact;
  the shared `PlacedWindows`, set up once at launch by the app, keeps adoption to one call.

## Consequences

A window that joins later, Get Info in phase 57, calls `keepsFrame(as:)` and nothing else. Frames
saved under a name no window uses any more stay in the file until it's deleted; they cost a few
bytes. A window first opened before the main window exists centers on the screen with the key
window.
