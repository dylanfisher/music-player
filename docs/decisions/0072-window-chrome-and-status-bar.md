# 0072. Window chrome: the status bar's parts and material, glass, distraction-free mode

- **Date:** 2026-11-03
- **Status:** accepted
- **Amends:** [0054](0054-status-bar-totals.md), [0055](0055-customizable-toolbar.md)

## Context

The owner tried phase 29 on the 2015 MacBook Pro (macOS 12) and asked for: the now playing
built from parts he arranges, in the status bar as in Swinsian, in a minimal or a taller style,
in place of Now Playing (Centered); the status bar in the toolbar's gray, and the glass he
expected on it and on the table headers, which he didn't see on macOS 12; an option for the
sidebar's translucent material behind the whole window; a toggle for the toolbar and one
shortcut that hides the toolbar, sidebar and status bar and brings them back.

## Decision

**Status bar parts.** `appearance.statusBarParts` lists the parts left to right: Art, Title and
Artist, Format and Bit Rate, Seek Bar and Track Totals, each at most once, since each is one
view; a list naming one twice is refused like any invalid setting. `appearance.statusBarStyle`
is Minimal, the track table header's height with the track on one line ("Title — Artist —
Album"), or Tall, 44 points with larger art and the title over the artist and album. The
defaults are today's bar: the totals alone, minimal. The seek bar takes the width the other
parts leave, or else the totals do, their text centered. Settings ▸ Appearance shows the parts
as a list with a checkbox each, dragged to reorder; any setting that is a list of choices gets
that control. Only ticked parts are dragged, among themselves, and they always come first, so the
order the list shows is the order the setting keeps. The style is also in the View menu, as the other appearance choices are. The
playing track's parts are NowPlaying's views and the totals the browser's; the browser lays
them out and the app hands it the views. With the totals left out, their label still shows a
failure, so hiding them never hides an error. Now Playing (Centered) is gone; a state file that
still lists `centeredStatus` is discarded whole, as any state that doesn't match is.

**The toolbar customization sheet** shows a drawing of every item whose view is a feature's:
the transport's buttons, the volume slider, a miniature of the now-playing status with a
placeholder title and a part-played seek bar, and a search field. Each is a copy wired to
nothing, since a view can be in one place only. On macOS 12 the sheet drew no image for these
items, which had an image and no view; the items that were buttons showed. With drawings, the
default set reads as the toolbar it makes.

**The status bar's material is the title bar's**, `NSVisualEffectView.Material.titlebar`, so
the bar is the toolbar's gray, not the table header's (phase 29.3 used `headerView`). Within the
window a material shows only what's inside the window behind it. Nothing scrolls behind the
status bar or the table headers, so on macOS 12 to 15 both look solid; that is what the owner
saw, and AppKit draws the table headers opaque on those versions in any case. The translucency
he means, the sidebar's, blends with what's behind the window, which is the glass option below.

**Glass**, `appearance.glass`, off by default. The window's content sits on the sidebar's
material blending behind the window; the window gets a full-size content view and a
transparent title bar, so the toolbar is drawn over the same material, and the content is laid
out from the window's content layout guide, under the toolbar. Every table but the sidebar's
outline draws no background, its scroll view none either, and its alternating rows are off,
since their colors are opaque. Table header cells are swapped for ones that draw the title, the
sort indicator and a separator but no background. Materials that blend within the window, the
status bar's, blend behind it instead. Off, each of these is put back as it was, and the track
table's alternating rows follow `appearance.alternatingRows` again. With the full-size content
view, AppKit lines the toolbar's items up with the sidebar's edge.

**Show Toolbar** (⌥⌘T) is saved as `window.toolbarVisible` as it changes. The toolbar's own
menu can hide it too; `NSToolbar.isVisible` reports that to an observer only from macOS 14, so
before it the state is also saved as the window closes and the app quits. A save happens only
when the value changed. **Distraction-Free Mode** (⇧⌘F) hides the toolbar, the sidebar and the status bar,
remembering which showed; pressed with all three hidden it shows what it hid, or all three when
it hid nothing, as after a relaunch with everything hidden. Each part saves its visibility as
its own toggle does, so a relaunch keeps what showed.

**The seek bar** is a view of the app's own: a mouse down moves the playhead there at once and
seeks, a drag seeks where it ends, and the playhead is a 2-point vertical line. `NSSlider`
animated the knob to a clicked point and drew a round knob. The bars keep the target until the
engine reports the seek done, so the playhead doesn't jump back for one tick. They're off while
the track has no known length, and a track change, or the bar leaving its window, lets go of a
drag without seeking.

## Alternatives considered

- **A free-form status bar editor dragging parts into a bar drawing**, like the toolbar sheet.
  Rejected for now: five parts in one row are an order and a set, which a checklist edits in
  fewer steps, and the bar itself shows the result as it changes.
- **The now-playing parts as toolbar items too.** Rejected: the toolbar keeps its Now Playing
  item for the detailed status; the parts are the status bar's.
- **Translucent status bar by default, behind the window.** Rejected: over a light or busy
  desktop the bar stops matching the toolbar's gray, which is what the owner asked for first.
- **Glass through each feature's views.** Rejected: the lists are in four controllers in three
  modules; one pass over the window's views, remembering what it changed, keeps the option in
  one place.

## Consequences

- With glass on, a table column added after the glass was turned on (a column shown from the
  header's menu) gets AppKit's opaque header cell until the glass is turned off and on.
- Scrolling with glass on composites the rows over the material; the scroll budget is measured
  with it off, the default.
- A config that sets a part twice, or a part the app doesn't have, shows the config banner.
