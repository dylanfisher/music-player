# 0219. The web remote's icons, denser rows, the scrubber and the receiver slider

- **Date:** 2026-11-22
- **Status:** accepted
- **Amends:** [0215](0215-the-web-remote-page.md): rows are 40 pixels, the jump bar is on the
  left, and the page has a fifth file, `icons.js`.

## Context

The owner (2026-11-22) asked for Phosphor icons in place of the page's glyphs, denser lists at
the same font size, the A–Z bar on the left with a scrubber on the right that slows as the
finger moves left, and a slider for the receiver's volume. The page runs under a content policy
of `script-src 'self'; style-src 'self'; img-src 'self' blob:`, and nothing from a Mac may reach
it as markup.

## Decision

**Icons.** The SVGs of only the ten icons the page draws come from the npm package
`@phosphor-icons/core` 2.1.1 (MIT): play and pause in the fill weight, since the button shows
the state it toggles, and the rest (skip back and forward, shuffle, repeat, repeat once, caret
left, minus, plus) in the regular weight. Each was checked to be one `<svg>` holding one
`<path>` with no other attributes, and only the path data is kept, in `Support/Remote/icons.js`
with Phosphor's MIT notice, which `RemotePage.files` serves. `app.js` builds each icon with
`createElementNS`, filled with `currentColor`, from a button's `data-icon` name or a name the
state picks, so no markup is parsed and the content policy is unchanged. `RemotePageTests`
checks every icon is path commands only, and that the names the page uses and the icons the
file has are the same set. Each icon button keeps its `aria-label`. The `→` in the pairing
hint's "Settings → Remote" and the dashes in times and the subtitle are text, not icons, and stay.

**Density.** Rows are 40 pixels, not 56: 40% more on screen, two lines of text at their old
sizes still fit, and a row is above 36 pixels to tap. `ROW` in `app.js` and `--row` in
`style.css` change together, as before.

**The jump bar and the scrubber.** The jump bar is on the left edge, and a lettered list's rows
leave it clear. A 28-pixel strip on the right edge of every Browse list (whole lists, Songs and
an album's tracks, and the album grid) scrubs. Touching it puts the list at the same share of its
scroll as the finger is of the strip's height; a drag then moves the list by its share of the
strip's height times a speed: 1 on the strip and up to 32 pixels left of it, a half from 32, a
quarter from 96 and an eighth from 160 (`SCRUB_STEPS_PX`, `scrubSpeed` and `scrubbed` in
`logic.js`, tested in `RemotePageTests`). A label beside the finger names the row at the top of
the view: a name in a whole list, an album's title in the grid, a track's artist in Songs or
its title in an album, or "1,234 of 43,210" for a row not read yet. It uses pointer events
with pointer capture, so the finger keeps scrubbing after it leaves the strip, and sets
`scrollTop`, which the virtual list already draws from. The queue and search results don't
have one: the queue is rarely long, and the results are 20 of each kind.

**The receiver slider.** The receiver row gets a slider beside its − and + buttons, over the
range the state names (`volumeFloorDecibels` and `volumeCeilingDecibels` of `receiver`, which
the app passes from the signal path panel's slider, −80 to 0 dB), in half-decibel steps. It
shows its value while dragged, sends `receiver.setVolume` on release, and isn't moved by the
state while dragged.

## Alternatives considered

- **An SVG sprite referenced with `<use href="icons.svg#play">`** — rejected: whether an
  external `<use>` falls under `img-src` or `default-src` differs between engines, and
  `default-src 'none'` might block it on iOS 15.
- **Icons as `<img>` files** — rejected: an image can't take `currentColor`, so the accent and
  the dark appearance would need a copy of each icon per colour.
- **The icon font** — rejected: a font file per weight, most of it icons the page never shows.
- **A scrubber that only moves from where the list is** — rejected: a touch on the strip's
  bottom should reach the end of the list at once, as the jump bar reaches a letter.

## Consequences

The scrubber's smoothness on a long list (Songs, 43k rows) on the owner's phone is checked by
the owner; if it stutters, the strip comes out and the right side keeps the default scroll.
A new icon is fetched from the same version and checked the same way before its path data is
added to `icons.js`.
