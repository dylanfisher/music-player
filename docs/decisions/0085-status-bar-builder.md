# 0085. The status bar builder: columns around a centered middle, stacks in the tall style

- **Date:** 2026-11-03
- **Status:** accepted
- **Supersedes:** [0072](0072-window-chrome-and-status-bar.md)'s rejected "free-form status
  bar editor" and its list of status bar parts. Phase 37b supersedes 0072's rejected "now-playing
  parts as toolbar items".
- **Amends:** [0084](0084-status-bar-on-glass.md) (the bar's middle)

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
that; a taller stack is centered and runs past the bar's edges. The art fills the bar's height in
either style, which is why it can't stack.

**The builder** opens from Edit Layout… on the Status Bar Layout row in Settings ▸
Appearance, in its own window, one per setting. The settings window's rows come from the
schema, so the row is the `.barLayout` setting kind's control, and the builder works on the
parts' config names with the titles the kind carries: phase 37b's header layout is a second
`BarLayout` setting with its own part type, and gets its own row and builder window with no
change to the builder. Its preview draws the columns across its own width, about a narrow
window's, fixed widths at their points, by the layout's rules approximated with arithmetic, with the center column dashed, and each part as a chip;
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
the config keeps the last good one.

The checklist control, whose only setting this was, is gone.

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

- Phase 37b's toolbar status needs the column views outside LibraryBrowser, since NowPlaying
  can't import it; `StatusColumn` and `CenteredRow` depend only on AppKit and Settings, so they
  move down a tier then.
- The preview's arithmetic gives every flexible column a share and lets the sides reach the
  center; the bar's constraints make the flexible widths exactly equal. The two can differ by a
  few points when a flexible center and a flexible side meet.
