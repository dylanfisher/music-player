# 0049. The track context menu runs registry commands on the selection

- **Date:** 2026-11-02
- **Status:** accepted
- **Amends:** [0012](0012-searcher-conventions.md)

## Context

Plan row 25.2 asks for Swinsian's track context menu, grouped as Swinsian groups it, with every
item a command from the registry so ⌘K has it too. The menu had three items of its own (Play,
Play Next, Reveal in Finder) that acted on the clicked row, or on the selection when the
clicked row was in it, as Finder does, by closures that bypassed the registry.

## Decision

- **The menu is data, `AppMenus.trackMenu`**, beside the menu bar's sections, and `MainMenu`
  builds it with the bar's code: each item runs its command through the dispatcher, which also
  enables it, and shows the command's chord. Its groups are Play Next, Add to Playback Queue,
  Play Now · Show Album, Show Artist · Like, Dislike · Rating ▸ · Get Info, Reveal in Finder ·
  Remove… ([0050](0050-remove-from-library.md)) · New Playlist with Selected Tracks, Add to
  Playlist ▸, Show in Playlist ▸.
- **A right-click selects the row it's on when that row isn't selected, and gives its list the
  keys**, as Swinsian does. The commands act on the selection of the list with the keys, so the
  menu needs no rows of its own. A right-click below the last row opens no menu.
- **The track table and the timeline share the menu.** Every item's command already acts on a
  timeline selection, each play's track once ([0022](0022-stable-track-identity-and-play-timeline.md)).
- **Add to Playlist ▸ and Show in Playlist ▸ list playlists as they open.** Their choices aren't
  commands; ⌘K reaches the same through Add to Playlist… and Show in Playlist…, which ask for
  the playlist in a sheet. Show in Playlist lists the manual playlists that list the first
  selected track, since a smart playlist's members would need its rules run for each one.
- **Show Album and Show Artist** narrow the library to the first selected track's album or
  artist (the album artist when the browser groups by it), as the palette's filter does, and
  keep that track selected.
- **Four commands take Swinsian's titles:** Play Selection is Play Now, Edit Tags… is Get Info,
  New Playlist from Selection is New Playlist with Selected Tracks, and Love or Unlove is Like
  ([0048](0048-like-and-dislike.md)). Their IDs, and so their shortcuts in the config file,
  stay.
- **Every new command is also in the menu bar**, as 0012 requires: Add to Playback Queue under
  Controls, the rest under File beside Add to Playlist… and Like.
