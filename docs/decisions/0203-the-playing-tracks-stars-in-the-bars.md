# 0203. The playing track's stars in the status bar and the toolbar

- **Date:** 2026-11-10
- **Status:** accepted
- **See also:** [0202](0202-rating-marks-stars-and-message.md) (the rating's marks, Get Info's
  stars and the message), [0085](0085-status-bar-builder.md) (the bars' layouts)

## Context

The owner asked for a Rating part in the status bar's layout and in the toolbar's Now Playing
and Custom Status layouts: the playing track's stars, empty for an unrated track and nothing
while nothing plays, following a rating set anywhere, a sync from another Mac included, and
clickable to rate if that fits the bars' hit areas.

## Decision

- **The stars take clicks in both bars,** as Get Info's do: the star under the pointer, and a
  click on the track's rating clears it. Both bars already take clicks in their parts (the seek
  bar, the status bar's art and format line), and the stars are a view of their own, five
  glyphs wide, so nothing else in a bar has a hit area there. Like the seek bar, they don't let
  a mouse down move the window, which the toolbar and a glass window's status bar would
  otherwise do.
- **A click rates the playing track by its path at once,** through the browser, as Get Info's
  stars do, and shows no message, as a click in the Rating column shows none: the stars the
  user clicked change in place.
- **With nothing playing the stars keep their place unseen,** and take no click, as the art
  does, so the parts beside them don't move and a stack's height doesn't change when a track
  starts. A playing file the index doesn't have shows five dimmed empty stars that take no
  click, since it can't be rated, as Get Info's are for such a file.
- **They follow every rating** through the browser's `ratingsChanged`, which the app now also
  sends to the bar, with the tracks rated and their stars. The bar changes the playing track's
  rating only if it's one of them, without reading the index, so a rating of another track
  costs nothing and leaves the bar's message alone; after a write that failed, the stars show
  the track's rating again. A sync that changed the index refreshes the library, which reads
  the row again already.
- **`RatingStars` moved from Get Info to the bar views' module,** the lowest that Get Info and
  the bars both import, with the font size an argument: Get Info's system size, the status
  bar's 11 points in both styles, and the toolbar's small size, its artist and album's.

## Alternatives considered

- **Shown only, not clickable.** Rejected: the stars have their own hit area, and a click
  there is the quickest way to rate what's playing without selecting it.
- **Hiding the stars with nothing playing.** Rejected: the parts beside them would move when a
  track starts, and in the tall style the bar's height could change.
- **A second stars view in the now-playing feature.** Rejected: it would repeat Get Info's
  drawing, hover and click, which the two features can share from a core module.

## Consequences

- The rating part is in both builders' trays, after the seek bar.
- A Get Info window open on the playing track and the bars follow each other's clicks, since
  both go through the browser.
