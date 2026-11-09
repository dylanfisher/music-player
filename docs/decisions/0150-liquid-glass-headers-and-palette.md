# 0150. Liquid Glass on the list headers and the palette, from macOS 26

- **Date:** 2026-11-08
- **Status:** accepted
- **Amends:** [0072](0072-window-chrome-and-status-bar.md) (the window's glass),
  [0084](0084-status-bar-on-glass.md) (the status bar on glass), [0087](0087-toolbar-status-and-window-title.md)
  (the glass headers)

## Context

The status bar has used `NSGlassEffectView` on macOS 26 and later since 0084, but the other
surfaces the app frosts still used `NSVisualEffectView`. That is the older blur, with no
bending at the edges and no highlights. The owner asked for Liquid Glass on the list headers
and the command palette on macOS 26 and later, keeping the current look before that.

## Decision

- **The list headers.** On glass, `GlassHeaderView`'s backdrop is an `NSGlassEffectView` with
  corner radius 0, so it fills the header edge to edge as the status bar's does. Before macOS 26
  it is the `.headerView` material, as before. The titles view stays a sibling over the backdrop,
  not the glass's content view: the header draws nothing itself (0087), and the titles view
  draws the cells in the header's coordinates.
- **The palette.** Its backdrop is an `NSGlassEffectView` with the panel's corner radius, 16,
  holding the field, the line and the list as its content view, so their text takes the
  glass's vibrancy. Before macOS 26 it is the `.popover` material behind the window, with the
  stack over it, as before. `PaletteClip` keeps its mask and edge on both.
- **The window's backdrop stays the sidebar material.** Apple means Liquid Glass for controls
  and bars that float over content, not for a whole window's background, and the backdrop is
  the content's background.

## Consequences

The 2015 MacBook Pro, which stops at macOS 12, sees no change. On macOS 26 and later the
headers and the palette look like the system's own glass. The tests check which material each
surface holds on the system that runs them; how the glass looks is checked by eye.
