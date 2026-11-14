# 0208. Threads

- **Date:** 2026-11-14
- **Status:** accepted
- **See also:** [0206](0206-rediscover.md) (the source this copies, its key mapping and its
  errors), [0205](0205-recommendations-in-the-player.md) (the seed rule),
  [0090](0090-one-history-for-plays-and-places.md) (Back and Forward)

## Context

The owner (2026-11-14): "if i'm on an album, i can generate a view of other albums already in
my library that are connected (using the recommendation engine)", a sidebar item named
Threads. music-recommender's seed lists hold only albums the library lacks, so the service
gets a route for it, `POST /v1/threads`, in its phase 10 (its ADR 0035; the contract is its
`docs/api.md`, Threads).

The owner's answers the same day, each as recommended but two: a new service route; seeded
from the selected album and kept until another is chosen; the threads in a panel, one
filtering the table; walking from album to album with Back and Forward; every connection
kind, styles only when rare, ranked last and capped; nothing left out; no new playback; the
command off for an untagged album; and, not as recommended, the name Threads kept for both
this source and Rediscover's card.

## Decision

- **`BrowserSource.threads`,** saved as `threads`, the Threads row after Rediscover in the
  sidebar's Library group: a panel over the track table, as Rediscover is, so the albums play,
  queue and drag as any table's. It takes Listening Stats' height, as Rediscover does.
- **One name, one idea.** Rediscover's Threads card and this source show the same object, the
  service's thread, in the same words, so both keep the name. The client decodes the two
  replies' threads and albums with one type.
- **Show Threads,** in the File menu beside Show Rediscover and in the track table's context
  menu, seeds from the selection by the seed rule of Recommendations for Album: one album, with
  one Discogs release on every track. Any other selection disables it; the menu item's
  validation says nothing, and the palette lists it greyed, as other disabled commands are.
  The seed is the album's `key`, `a` and its album id, as the profile sends it.
- **The seed is a place.** Show Threads visits a window place of the Threads source with that
  album, so ⌘[ and ⌘] step back and forward through the seeds walked as through every other
  place (ADR 0090), and Show Threads on one of the source's own albums walks to it. The source
  keeps its seed while another source shows; its row with no seed yet says to choose Show
  Threads on an album. The seed isn't saved across launches: an album id can change at an
  index rebuild.
- **The client's `threads(key:)`** decodes the reply as `AlbumThreads`, its seed and albums
  Rediscover's album decoded unscored: `score` nil and `reasons` empty, and either key in the
  reply fails it as an unknown key does, so a Rediscover album can't pass for one of Threads.
  The refusal `untagged` is a code of its own; `no_seed` keeps its one case for both routes.
- **The panel** has the seed's title, artist and year in its header, with Refresh, and two
  cards: Threads, a line each in the service's words, with All above them, chosen unless
  another is, a click on one listing only its albums; and Why This Album, the threads the
  selected track's album is in.
- **The table** lists the tracks of the reply's albums the index has, in the reply's order or
  the chosen thread's, each album in disc and track order, opening in the Order column's sort
  as Rediscover's does. The album ids are kept in memory on both connections, as Rediscover's
  are.
- **Reading, mapping back and not answering are Rediscover's:** the profile is sent first if
  it changed; a key the index doesn't have under the reply's title sends this Mac's profile,
  forced, and asks once more; the header says Not answering or Token refused, and the threads
  read before stay under the error.
- **No Not Now and no marks.** Threads only follows connections; the albums are the library's.
- **Show Threads in Sidebar,** `library.showThreads`, on by default, in Settings' Browsing
  section, as Show Rediscover in Sidebar is.

## Alternatives considered

- **Following the playing album.** Rejected by the owner: the view would change under the
  user while they read it.
- **A trail of seeds in the panel, with its own Back and Forward.** Rejected: the window's
  history already walks places with ⌘[ and ⌘], and a second trail would disagree with it.
- **A ranked list of albums, each with its reasons.** Rejected by the owner for threads that
  filter the table: which connection is followed is the point.
- **Renaming Rediscover's card** to free the name. Rejected by the owner: both are the same
  object.
- **Linking untagged albums by their own tags** (artist, label, composer). Rejected by the
  owner: a second way of linking albums to keep in step with the service's.

## Consequences

- Threads needs the service and a profile it has read; with neither it shows only the error.
- An untagged album can't seed Threads and is in no thread, so a library tagged in part
  shows threads for that part.
