# 0217. An artist's discography in Recommendations

- **Date:** 2026-11-20
- **Status:** accepted
- **See also:** [0205](0205-recommendations-in-the-player.md) (the Recommendations window),
  music-recommender's ADR 0037 and its `docs/api.md`, "A discography"

## Context

The owner (2026-11-20) asked to "view all albums by an artist (according to our local discogs
database), sort by community user rating, etc." in the Recommendations window. The service's
phase 12 lists them: `list: "discography"` with an `artist_id`, every album the artist is a
main artist on, in every format, owned and marked albums included, each with its master's
main release's values, and the discography's missing values fetched before the rest. It added
`formats`, `in_library` and `mark` to every album of every list, and `list.artist` and
`pending` to every reply, so the player's strict decoder has to read them on every list. The
owner chose to open one only from a Discogs artist the player already knows, never from a name
typed in, and to leave it out of the web remote.

## Decision

- **The seed is `discography(artistID:name:)`.** The service is asked by id; the name is only
  for the pop-up's "Discography: <artist>", as an album seed carries its title. It comes from
  the catalog or the row that offered the artist, or "Discogs artist <id>" for a pasted artist
  this Mac's catalog doesn't have, which is still asked for: the service answers whether it
  has it. Opening an artist already in the pop-up chooses that entry.
- **The orders:** a discography offers Year (the default), Title and the community values,
  never Score; the scored lists never offer Year or Title. A query moved from one kind of list
  to the other takes the new list's default order, and a discography always shows Albums.
- **Missing** isn't sent for a discography, which the service refuses. It hides the rows read
  whose `in_library` is true, without asking again; reading more pages still counts every
  row read.
- **Where it opens from.** The track menu (the track table and the timeline) has a Show
  Discography item for the first selected track, filled as the menu opens: the track's
  `discogs_release_id`, then the release's main artists that Discogs links, read by id from
  this Mac's catalog. A Recommendations row's menu uses the artist ids the row carries. One
  artist is a plain item, several a submenu, and none a disabled item whose tooltip says why
  (no release id, a release the catalog doesn't have, a catalog that can't be read, or only
  Various Artists). Various Artists (194) is never offered, since the service refuses it.
  Show Discography… (palette, File menu and a button in the window) takes a release id, or a
  discogs.com release, master or artist page, with a slug or a locale prefix; several artists
  are chosen in a sheet. `pastedReleaseID` reads through the same parser and still takes
  releases only. There is no search by name. The command doesn't run from links or the web
  remote.
- **Left out for now:** the queue, Now Playing, and the Downloads and Threads rows have no Show
  Discography item. Their menus hold no track commands yet, and Downloads' jobs and Threads'
  albums carry a release id but no artist ids, so each needs its own catalog read and menu
  wiring. A track in them opens a discography through the track table, and any album through a
  pasted link.
- **Columns:** Format, In Library and Mark show only for a discography; Score, Why and Rank
  only for the other lists. Each column keeps the shown or hidden state last chosen while a
  list without it shows, so it comes back as it was.
- **Values coming in:** while the last page's `pending` is over 0, the status line says
  "Fetching ratings, <n> left", and the rows read so far are read again every 15 s while the
  window is open, in place of the rows shown, so nothing blanks between reads. A new list, a
  closed window or `pending` of 0 stops it; the window opened again starts it again. The
  selection follows its albums as they reorder, and the scroll stays where it is. Albums
  without values sort last, as the service orders them.

## Alternatives considered

- **Seeding by id alone, and taking the name from the reply's `list.artist`.** Rejected: the
  pop-up would have no title until the first page arrived, or after a failure.
- **Opening the first artist of a release with several.** Rejected: on a split or a
  collaboration the owner wants to choose.
- **A track-menu submenu even for one artist.** Rejected: the owner asked for one item to open
  it at once; the menu's data model lists the item as a live entry, and Recommendations makes it a
  plain item or a submenu as the menu opens.
- **Sending Missing to the service.** Not possible: the service refuses it for a discography,
  since it lists everything.

## Consequences

- Opening the track menu reads one track's release id from the index and one release from the
  catalog on the main thread, both by primary key.
- A reply without the new fields, from a service before its phase 12, fails to decode, naming
  the field, as any reply outside the contract does.
- Phase 91's text filter and Show in All Music, built later, cover a discography as they do
  the other lists.
