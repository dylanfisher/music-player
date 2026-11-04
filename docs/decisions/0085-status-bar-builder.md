# 0085. The status bar builder: columns around a centered middle, stacks in the tall style

- **Date:** 2026-11-03
- **Status:** accepted
- **Supersedes:** [0072](0072-window-chrome-and-status-bar.md)'s rejected "free-form status
  bar editor" and its list of status bar parts, and (phase 37b) its rejected "now-playing parts
  as toolbar items".
- **Amends:** [0084](0084-status-bar-on-glass.md) (the bar's middle), [0055](0055-customizable-toolbar.md)
  (the toolbar's default set and the status's width, phase 37b)

## Context

Phase 37 asks for the status bar to be built from columns the owner adds, each fixed or
flexible with its own alignment, like flexbox, with a middle column that stays centered on the
window (phase 36, ADR 0084), and, in the tall style, columns that stack their parts and grow
the bar. Phase 37b builds the header's now-playing status with the same builder, as its own
instance. ADR 0072 had rejected a free-form editor while the bar was one row of five parts,
which a checklist edited in fewer steps; columns, widths, alignment and stacks are more than a
checklist can say.

## Decision

**The layout model** is `BarLayout<Part>` in Settings, generic over its parts: `leading` and
`trailing` lists of columns and one `center` column. The center is required and single by the
shape of the value, so no layout can have two middles or none. A column has its `parts`, in
order; a `width`, `"flexible"` or a number of points (16 to 1200); an `alignment`, leading,
center or trailing, for its parts when it's wider than they are; and `stacks`. Flexible
columns share the width the fixed ones leave equally. In each column the seek bar takes the
width its parts leave, or else the totals do, their text aligned as the column is.

**The config shape**, `appearance.statusBarLayout`, replacing `appearance.statusBarParts`:

```json
"appearance.statusBarLayout": {
  "leading": [{ "parts": ["art", "track"], "width": 240, "alignment": "leading", "stacks": true }],
  "center": { "parts": ["seek"], "width": "flexible", "alignment": "center", "stacks": false },
  "trailing": []
}
```

Every key is required at every level, and an unknown one fails, as does a width that is
neither a whole number nor `"flexible"` and a part the bar doesn't have. A layout that decodes
is then checked, and every problem is a typed `BarLayoutProblem` naming its column: an empty
column, a part listed twice (each part is one view), a fixed width out of range, and the art,
which is as tall as the bar, in a column that stacks. A bad value applies nothing and the
banner shows it, as for any setting (ADR 0082); an old config's `appearance.statusBarParts` is
an obsolete key, reported and skipped, with Remove Obsolete Setting offered. The default is
the totals alone in a flexible, centered center column, which is the bar as it was: a test
checks that its label spans the middle, centered on the window, up to the spacing beside the
nearer edge, at the header's height.

**Laying it out.** `CenteredRow` keeps its three views: the leading stack holds the scan
progress and then the leading columns, the trailing stack the trailing columns and then the
problems button, and the middle is the center column, centered on the window as before. Each
column is a `StatusColumn`, a view around a stack of its parts, placed by its alignment, or
pinned across the column when a part stretches. The constraints keep ADR 0084's rule that
nothing in the bar outranks 250: a fixed width holds at 235, under the clearance from the edge
views (240) and over the centering (230), so the middle moves aside before a fixed column
shrinks; flexible columns' equal widths hold at 215, over the text's compression resistance
(210), so they share before any text truncates; and a side with a flexible column reaches
toward the middle at 200, as the middle's own fill does. With the totals in no column, their
label goes last in the center column, shown only while it says what failed, as before.

**Under the title on glass.** Phase 36 left the middle half the sidebar's width left of the
title on glass (ADR 0084): with a full-size content view AppKit centers the title over the
area beside the sidebar. The middle now centers there whenever the window has a full-size
content view, on a layout guide from the browser pane's leading edge to the window's trailing
edge, and on the whole window otherwise. With the sidebar hidden the pane starts at the
window's edge, so both are the window's center. A snapshot at 1440x900 on glass puts the
middle's text and the title on the same line; a test checks the middle against the pane, with
glass on and off and the sidebar shown and hidden. The title's own position isn't tested: in
a test's window AppKit places it at the leading edge, not centered as on screen.

**Stacks in the tall style.** A column that stacks puts its parts one over another in the tall
style only; the minimal style stays one line, so they sit side by side there. The bar grows to
the tallest stack's fitting height plus the art's inset, from the tall style's 44 points up to
80, three lines of text with the seek bar under them, so it never takes more of the lists than
that; a taller stack is centered and cut at the bar's edges, which clip. The height is
measured again whenever the bar's parts show or hide, such as the totals' label with a
failure in a stacked column, and the lists' inset follows it. Both heights are
`StatusBarStyle`'s, so the bar and the builder's preview share them. The art fills the bar's
height in either style, which is why it can't stack.

**The builder** opens from Edit Layout… on the Status Bar Layout row in Settings ▸
Appearance, in its own window, one per setting. The settings window's rows come from the
schema, so the row is the `.barLayout` setting kind's control, and the builder works on the
parts' config names with the titles the kind carries: phase 37b's header layout is a second
`BarLayout` setting with its own part type, and gets its own row and builder window with no
change to the builder. Its preview draws the columns across its own width, about a narrow
window's, fixed widths at their points, by the layout's rules approximated with arithmetic,
with the center column dashed, and each part as a chip;
below it a tray holds the parts not in the bar. Chips drag between columns and to and from the
tray. Buttons add a column before or after the selected one, remove it, add an unused part or
remove the selected one; a popup and a field set the width, a segmented control the alignment,
a checkbox the stacking. Every control is a standard one, so Tab reaches it, and with the
preview selected ← and → select parts, ⌘← and ⌘→ move one across columns, and Delete takes one
out; the preview takes those keys before the menus, which play the previous and next track on
the arrows. The bar itself is the live preview too: each edit saves at once, as a patch to its
own key, and the bar lays out again. A column just added is empty until a part goes in, so the
builder holds back saving, and says so, while any column is empty; a layout the setting refuses
(the art in a stacking column, a width out of range) stays shown with the setting's reason, and
the config keeps the last good one. When the config file changes, the builder shows its layout:
a column waiting for a part survives only a change that left this layout alone, and a refused
edit gives way to the file's layout, marked "Not saved" with the reason. While the config file
has a problem that refuses every change (ADR 0082), the builder edits nothing, turns its
controls off and says so in the banner's words. The width field commits on Return and when it
loses the keys. A layout's error lists its first three problems and a count of the rest.

The checklist control, whose only setting this was, is gone.

**The toolbar's status (phase 37b).** The header's now-playing status is a second layout,
`appearance.headerStatusLayout`, a `BarLayout<HeaderPart>` of the art, the title, the artist
and album, the format line and the seek bar (phase 35's `SeekBox`, which keeps its window-drag
and seek-hold behavior). Its row in Settings ▸ Appearance opens the same builder. The default
is the detailed header as it was:

```json
"appearance.headerStatusLayout": {
  "leading": [{ "parts": ["art"], "width": 48, "alignment": "leading", "stacks": false }],
  "center": { "parts": ["title", "subtitle", "format", "seek"], "width": "flexible",
              "alignment": "leading", "stacks": true },
  "trailing": []
}
```

A test builds the old stack by hand and checks that the default puts every part in the same
place at the same height. `CenteredRow`, `StatusColumn` and `BarColumns`, which places a
layout's columns in a row, are in the Core module BarView, so the status bar and the toolbar's
status each lay out their own with the same code. The toolbar's row differs from the status
bar's in two ways, both choices of the row: it **fills before it centers**, since a toolbar
item isn't in the window's content view and the old header gave the text all the width beside
the art. A flexible middle's pull to the row's width holds at 213, over the centering (212),
which is over the text's compression resistance (210) and under the flexible columns' equal
widths (215); a fixed middle centers on the item. And **an empty side keeps no spacing**, so
the default's lines reach the item's edge as they did. Stacked columns always stack in the
toolbar, which has no style; their lines sit 1 point apart and the seek bar 2 points under the
line above it, as before, and the status is as tall as its tallest column. With five parts the
tallest stack is the default's, so it needs no cap. The art is a 48-point square that doesn't
stack, for the same reason as the status bar's.

The builder is unchanged, so for this layout two of its words are the status bar's: the stack
checkbox says "Stack in Tall Style", and the help says the dashed column centers on the window,
where the toolbar's centers on its item.

**The toolbar's items (phase 37b, superseding ADR 0072's rejected "now-playing parts as
toolbar items").** Customize Toolbar offers Controls (previous, play and next), Volume, Status
(this layout), Search, Shuffle, Repeat, Output (the Output menu, whose devices include AirPlay
and UPnP renderers), Show Queue, Show Signal Path, Flexible Space and Space. There is no Mini
Window item while there is no mini window. The default set is Swinsian's: Controls, flexible
space, Volume, flexible space, Status, flexible space, Shuffle, flexible space, Search. The
status grows to 560 points, about Swinsian's, rather than without limit, so the flexible
spaces beside it keep a share and it sits near the toolbar's middle. Its drawing in the sheet
is a status of the current layout with a placeholder track, drawn at 70%, since the sheet's
default set row is about a button row tall. A layout change sets the status item's height
again.

The items stay in `state.json`'s `window.toolbarItems` (ADR 0055), not NSToolbar's autosave:
the toolbar keeps `autosavesConfiguration` off, so nothing is read from user defaults. Every
item keeps its raw value (Controls is still `transport`, the status still `status`), so a
toolbar saved before this phase names only items the app has and comes back as it was, with no
migration; one that names an item the app doesn't have is discarded with the rest of the state
file, under the pre-release rule, and the toolbar falls back to the default set, so nothing
crashes and no item is left empty. Only a saved toolbar keeps the old items; a toolbar never
customized has nothing saved and gets the new default set.

Every item is a standard control or one of the features' views, and none has a key
equivalent of its own: the transport, shuffle, repeat, output and the toggles are commands in
the menus, which keep their key equivalents, and the Search field keeps its text-editing chords
through the window's key monitor as before.

## Alternatives considered

- **A flat list of columns with one marked as the center.** Rejected: two marked, or none, would
  be one more problem to report, and the builder would have to keep the mark moving with the
  column. Three fields make the center structural.
- **A "fit" width besides fixed and flexible.** Not added: in the center, a flexible column with
  its parts centered looks the same as one that fits them, and at a side a flexible column with
  its parts aligned to that edge does too.
- **The preview built from the bar's real views.** Rejected: a view is in one place only, and
  Settings can't import the browser's feature. The real bar shows each change as it saves.
- **Stacking in both styles.** Rejected: the minimal style is the table header's height, one line.

## Consequences

- The column views are in the Core module BarView, the only Core module that imports AppKit,
  since NowPlaying can't import LibraryBrowser and they depend only on AppKit and Settings.
- With the toolbar's middle filling before it centers, a flexible center beside fixed sides
  is drawn by the builder's preview as the toolbar lays it out, and differs from the status bar,
  which keeps it centered on the window.
- The preview's arithmetic gives every flexible column a share and lets the sides reach the
  center; the bar's constraints make the flexible widths exactly equal. The two can differ by a
  few points when a flexible center and a flexible side meet.
