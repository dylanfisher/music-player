# 0215. The web remote's page: choosing a Mac, browsing quickly, and the page itself

- **Date:** 2026-11-20
- **Status:** accepted
- **Amends:** [0214](0214-the-web-remote-server.md): the server serves a fixed set of files, not
  one page, and adds the library reads, the queue, covers and four commands;
  [0025](0025-threat-model.md): rows 85 to 87.

## Context

Part 10b of phase 10 is what the phone shows: a page that finds every Mac the page's own Mac
found, controls the right one, and browses its library of 43k tracks quickly on iOS 15 Safari,
with no framework, no build step and no dependency. ADR 0214 is the server it talks to.

## Decision

**Static files.** `RemotePage.files` lists the page's files: `index.html`, `style.css`,
`app.js`, `logic.js` and `icon.png`. They're read once, when the service is made, from the
bundle's `Remote` folder into replies keyed by exact path; a path not in the list is a 401 like
any other unknown path, and nothing from a request's path reaches the file system. Each carries
`Cache-Control: no-cache`, an `ETag` of its bytes and `nosniff`; the page also carries a
`Content-Security-Policy` that runs only its own scripts and styles and shows images only from
itself and `blob:`, and `Referrer-Policy: no-referrer`. The `Origin` rule of ADR 0214 holds for
every route here and their 304s: an `Origin` that isn't this Mac's or a found instance's is a
403 before any of them runs. `scripts/bundle` makes `icon.png`, the home-screen icon, from the app's
icon before its corners are cut, since iOS rounds them itself and shows transparent ones black.

**Library reads.** `RemoteLibrary` reads on a query-only connection of its own, so a phone
never waits for the window's queries or holds them up, and only through the queries the window
runs: `genres`, `artists`, `albums`, `trackNames` and the search. Two additions to those, and
no second query set: `trackNames` takes a window, `LIMIT` and `OFFSET` on the same statement,
with `trackCount` over the same conditions for the total; and `searchEntries` reads the Artist
and Album panes with the search applied and a limit, since the panes themselves ignore the
search field. One new read, `artTracks`, gives each album of a set a track with art, the first
by disc and track number, for the album grid.

- `/api/genres`, `/api/artists` (`genre`), `/api/albums` (`genre`, `artist`): whole, as
  `{rows: [[id, name]]}`, albums `[id, name, artist]`. The jump bar's letters are worked out on
  the phone from the names, a letter only moving forward, so the server sends no second copy.
- `/api/tracks` (`genre`, `artist`, `album`, `q`, `sort`, `descending`, `offset`, `limit`):
  `{total, offset, stamp, rows: [[id, title, artist, album]]}`, at most 200, sorted by any
  sortable `TrackColumn` as the table sorts; `stamp` is the reply's tag, and an `offset` past
  the total is refused. An album alone is listed grouped by album artist, so its
  tracks are in disc and track order whoever plays on them, the order Play Tracks plays it in.
- `/api/search` (`q`, 1 to 256 bytes): `{artists, albums, tracks}`, 20 of each.
- `/api/queue` (`offset`, `limit`): `{stamp, total, offset, position, rows}` in play order; a
  file the index lacks has a null ID and its file name. An `offset` past the queue is refused.
- `/api/covers` (`albums`, 1 to 200 IDs): `{album: cover ID}` for those with art.
- `/api/art/<s|l>/<cover ID>`: the cover at 160 or 640 pixels, JPEG or PNG as
  `ThumbnailStore` keeps it, made and kept on a miss, read off the actor and the cooperative
  pool since the file may be on the NAS, at most four reads and decodes at once for the whole
  server and 64 waiting behind them; past that a cover is a 503 at once. A cover's ID is `<track ID>-<picture name>`, the name
  being the hash `ThumbnailStore` names the picture's files by, which changes with the file.
  The server serves it only while that track's art has that name, so a URL always means one
  picture, and it goes out `private, max-age=31536000, immutable`, not gzipped.

A query string is taken strictly: each key once, only the keys the read takes, IDs as 1 to 18
digits, else a 400, and it's checked before the tag, so a malformed one is a 400 even when the
tag matches. Every library read carries `ETag` from `changeStamp`, a nonce for the
launch, since `data_version` starts over with each connection, and the grouping, which changes
the Artists list; a matching `If-None-Match` gets a 304 with no body. The preflight allows
`If-None-Match` and replies expose `ETag`, so another Mac's page can revalidate too. The page
keeps whole lists in IndexedDB under their tags; a failing IndexedDB is logged and the page
reads the network instead.

**Commands.** Play List (`playback.playList`) takes a track list as `/api/tracks` reads it, by
the same keys, and `playFrom=` with the ID of the track to start from; the Mac reads the list
with `trackIDs` and plays it whole, as the window plays a list however long, and refuses a
start track that's no longer in it. Songs, an artist's All Songs and a search's songs play
through it. Play Tracks (`playback.playTracks`) takes `tracks:` and up to 100 IDs, or
`album:<id>` and optionally `:<track ID>` to start from; Queue Tracks (`playback.queueTracks`)
the same without a start. 100 IDs fit a command's 1,024-byte argument. Move in Queue
(`queue.moveItem`, `<stamp>:<from>:<before>`) and Remove from Queue at (`queue.removeItem`,
`<stamp>:<position>`) name positions in play order from 0 and the queue's stamp the page read
them under; once the queue moved, the stamp is refused, so a stale page can't remove the wrong
track. The stamp's queue and order go to the engine with the edit, which checks them and edits
in one step on its actor, so the queue can't change between the check and the edit. After a
refused edit the page reads the queue again at once. All five run through `ScriptRouter` as
`Origin.remote` and need their argument, so they're in no menu. A tap on a track in an album
plays the album from that track.

**Choosing a Mac.** The page keeps tokens in its origin's `localStorage`, each by instance ID
and the origin it paired at, and sends one only to that origin, so an advert that claims a
Mac's ID at an address of its own gets nothing; a pairing whose reply names another ID is
refused. It reaches another Mac at an origin it holds a token for, else by `.local` name when the
page was opened by one, else by its first IPv4 address. The strip shows each Mac with a dot:
green playing, orange paused, grey stopped, hollow unpaired, faded while its stream is down.
Tapping an unpaired Mac asks for its code; tapping a paired one picks it, and Auto undoes the
pick. Unpicked, the page controls the Mac playing, the one that started most recently among
several; none playing, the one controlled last, kept in `localStorage`; then the page's own Mac;
then any paired one. Macs' clocks may differ by seconds, so they're compared by how long ago
each started: `now - lastPlayedAt` on that Mac's own clock, `now` being when the state was read,
plus the time since the event arrived on the phone's. Now Playing, the transport and Queue
follow the chosen Mac at once. Browse and Search stay on the Mac they were opened on when the
page switches by itself, saying which Mac they show, and their commands go to that Mac, since
their IDs are its library's; they follow the chosen Mac again when the owner picks one or goes
back to Browse's top. Until something is opened in Browse they follow the chosen Mac, and
they leave a Mac that is no longer paired.

**Event streams.** One per paired Mac, read with `fetch` and a stream reader, since
`EventSource` can't send the token. The server sends a comment every 15 s; a stream the page
hears nothing on for 40 s is taken for dead, aborted and connected again. A stream that fails,
ends or goes quiet connects again after 1 s, doubling to 30 s, and the count starts over only
once a stream has stayed up for 30 s, so one that drops at once keeps backing off. The event
parser holds a `\r` that ends a chunk until the next shows whether `\n` follows. The page closes every stream when
it's hidden and opens them all at once when it's shown again, since iOS suspends a page while
the phone is locked. The position bar moves on the phone's own clock from when an event
arrived, not the Mac's `now`, since the two clocks may differ by seconds.

**The virtual list.** Fixed 40-pixel rows ([0219](0219-the-web-remote-icons-scrubber-and-volume.md)) over a spacer as tall as all of them, and 40 row
elements reused for what's on screen. A ranged list fetches the ranges of 200 in view and one
either side once scrolling has settled for 100 ms, at most three at once, nearest first, and
aborts those no longer wanted; during a fast flick it shows placeholder rows. It keeps an arrival
only while it's still wanted, and the 20 used last. A page whose tag or total isn't that of the
ranges held means the library changed: the list drops them and reads what's in view again, its
scroll position kept. Whole lists use the same list with every row present; the album
grid is the same list with a few covers to a row, asking `/api/covers` for the rows in view.
Covers are fetched with the token and shown from blob URLs, the 300 used last kept.

**Search.** 120 ms after the last keystroke, at most one request in flight; text typed while
one is out waits in its place, replacing any that waited before, and only the reply for the
text typed last is shown.

**The page's logic.** What needs no page is in `logic.js`, a module of top-level exports:
choosing a Mac and how long ago each started, the tokens' keys and origins, range planning,
fetching and its cache, telling a changed list, search ordering, the event stream's parser, its
silence and backoff, the jump bar's letters, the position and clock text, Play List's argument,
which Mac Browse reads, and what a refused queue edit does. `RemotePageTests` runs it in JavaScriptCore, compiles `app.js` without
running it, checks every command name in `app.js` is one marked `runsFromRemote`, that it sets
no markup, and that the page's limits are the server's.

## Alternatives considered

- **Cursor-based track ranges** — rejected, as 10.7 says: a full-height list jumps to any point.
- **Cover URLs by album ID** — rejected: they'd change meaning when the art does, so they
  couldn't be kept for good.
- **Covers without the token, for plain `<img>` URLs** — rejected: ADR 0214 leaves only the
  page and the trade open, and a hash names a picture another library may also hold.
- **Drag to reorder the queue** — rejected for now: Up, Down and Play Next on a selected row
  need no touch-drag code to get right on iOS 15.
- **An output menu** — left out: the state names the output, but listing the outputs would
  need a read of its own. Choose Output stays for a later page.

## Consequences

A cover's thumbnails go in the same `ThumbnailStore` as the window's, at two more sizes, and
count toward its capacity. The page needs the page's own Mac paired first, since that Mac lists
the others. A Mac's page and the other Macs' tokens live in one origin's storage, so opening the
page by another Mac's address starts with no tokens. The remote's search reads three queries a
keystroke on its own connection.
