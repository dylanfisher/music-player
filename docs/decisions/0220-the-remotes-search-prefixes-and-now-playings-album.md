# 0220. The web remote's search prefixes and Now Playing's album

- **Date:** 2026-11-22
- **Status:** accepted
- **Amends:** [0161](0161-albums-by-key-typed-search-and-the-edit-menu.md): the grammar lives in
  `Core/Settings`; [0215](0215-the-web-remote-page.md): `q` takes a prefix, and Now Playing
  lists the playing album.

## Context

The owner (2026-11-22) asked that the web remote's search take the palette's commands, so
`a:dream` lists albums matching `dream`, and that Now Playing list the playing track's album
below it, with a playing indicator on the current track. The palette's grammar was in
`Features/Palette`, which `Core/Remote` can't import.

## Decision

**One grammar.** `TypedQuery`, the `QueryKind` protocol and `SearchKind` (playlist, genre,
artist, album and track, with their short names `p`, `g`, `ar`, `a` and `t`) are in
`Core/Settings`, the lowest module both `Remote` and `Palette` import. `PaletteQuery` is
`TypedQuery<PaletteItem.Kind>`; the palette's kinds keep their own names, which frecency keys
use, and take their short names from `SearchKind`. The rules are ADR 0161's: any case, spaces
after the colon ignored, and a word before a colon that names no kind leaves the query as typed.

**The server reads the prefix.** `/api/search` parses `q` into a `TypedQuery<SearchKind>`, so
the page holds no copy of the grammar. A prefix lists only its kind, and its words must be in
that kind's tags, through an FTS5 column filter (`TrackFilter.searchField`): an album's title
for `a:`, the artist or album artist for `ar:`, the title for `t:`. So `a:dream` lists the
albums whose title has a word starting "dream", not every album with a song called "Dream On",
as the palette matches an album by its name. `g:` and `p:` answer an empty result with a 200:
the remote's search lists no genres or playlists, as the palette lists nothing of a kind it
doesn't have. `/api/tracks` and Play List read `q` the same way, so a prefixed search's songs
play as it lists them; there `g:` and `p:` are a 400, since a track list can't be narrowed to a
genre's or a playlist's name and the page never asks for one. The search field's placeholder
names the three short prefixes, which `RemotePageTests` checks against `SearchKind`.

**A query with no word.** A query left with no word to match after its prefix (`a:`, `t: `,
`:`, `!!!`) would narrow nothing, so the remote doesn't treat it as one: `/api/search` answers
empty sections, and `/api/tracks` and Play List refuse it with a 400, so `q=t:` can't play the
whole library. The palette keeps its own rule, where `artist:` lists every artist.

**Now Playing's album.** Below the controls, the playing track's album is listed in disc and
track order, read through `/api/tracks?album=…&sort=album`, the album view's route, a range at
a time until the album is whole. It's read once per Mac and album, not per state event: a
track change within the album only moves the indicator. The indicator is Phosphor's
`speaker-high` (regular weight, 2.1.1, checked as ADR 0219 checks icons) before the current
track's title, with that row in the accent color. A tap plays the album from that track, and
the + queues it, as the album view's rows do. A track with no album, or nothing playing, shows
no list. A failed read is said once and tried again only for the next album or when the Mac's
event stream connects again, not at every state event. The list is plain rows rather than a
virtual list: an album is at most a few hundred tracks.

**The volume sliders after release** (amending 0219). The app and receiver sliders share one
`SentSlider` in `app.js`. After a release each shows the value it sent while the state still
has the value from before the send, for up to two seconds (`sliderValue`, `SENT_HOLD_MS` in
`logic.js`), so a state event sent before the change doesn't snap it back. Any other state
value, a ± press or another phone's change, shows at once, and a receiver that's off or lost
shows "–" at once. A cancelled touch, or a drag that ends where it started, sends no
`change`, so a cancel, a lift or a blur also ends the drag and the slider follows the state
again.

## Alternatives considered

- **A new Core module for the grammar** — rejected: three small types, and Settings already
  holds the facts several modules share (`BrowserGrouping`, `TrackColumn`).
- **A prefix choosing the kind only, the words matching any tag** — rejected: `a:dream` would
  list an album for a song or an artist named Dream, which isn't "album matching dream".
- **A 400 for `g:` and `p:` in the search** — rejected: the palette lists nothing for a kind it
  lacks rather than an error, and a phone typing `g:` mid-word shouldn't flash one.
- **Parsing the prefix in the page** — rejected: a second copy of the grammar.

## Consequences

The library's search field and the palette are unchanged. A future remote list of genres or
playlists in search would make `g:` and `p:` list them.
