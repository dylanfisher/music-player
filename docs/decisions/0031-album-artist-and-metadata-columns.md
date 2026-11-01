# 0031. The Artist pane groups by album artist, and every tag has a column

- **Date:** 2026-11-01
- **Status:** accepted
- **Amends:** [0006](0006-tag-reader.md) (the fields read, with Picard's keys),
  [0013](0013-library-window-data-flow.md) (art in the table), [0018](0018-playlists-and-stats.md)
  (the rule fields), [0022](0022-stable-track-identity-and-play-timeline.md) (a stats part for
  loved)

## Context

The Artist pane listed track artists, so a compilation or an album with guests spread across
many entries, and the owner wants a column for every piece of metadata Swinsian shows. The
metadata parse is within 0.8 s of its 5 s budget and the scan's stat per file was removed in
phase 14e, so new fields can't cost a read or a call per file. The owner's plays, ratings and
playlists shouldn't be lost to add a stat.

## Decision

- **`library.groupByAlbumArtist`**, on by default, is an ordinary setting, so the Settings window,
  ⌘K and the File menu list it. `TrackFilter` carries it to every query.
- **Grouping is stored per track** as `tracks.group_artist_id`: the album artist, else Various
  Artists for a compilation, else the track artist, indexed with genre and with album like
  `artist_id`. Various Artists is an `artists` row of that name, so an album artist tagged
  "Various Artists" lists in the same entry. Grouped, the Artist pane, its selection and the
  palette's artists use it; off, they use the track artist as before.
- **Grouped sorts.** Artist orders by album artist, then album title, then album; Album by
  album title, then album artist, then album; then each by disc and track, ascending in either
  direction, so an album's tracks stay together. Other columns break ties by album artist
  instead of track artist. The plan asked Album to order by album artist first too; that made
  it the same order as Artist, so it orders by title first.
- **The Album pane** adds " — " and the album artist (Various Artists for a compilation without
  one) to a title only where another listed album has the same title.
- **Columns.** Every tag field is stored on `tracks` and is a column, sortable, and a rule field
  where it holds text, a number or a date. Text the tags hold as written sorts with
  `COLLATE NOCASE`; the names that already had folded sort keys keep them. Derived columns are
  SQL expressions that the rows select and the sort uses, so each is defined once: bit rate is
  the file's bytes without its art over its length (kilobits a second; container and tag bytes
  count), file name is the path from `files.name_offset`, stored at insert so the sort costs no
  string search, and file type is the name's extension uppercased. Track of Total and Disc of
  Total sort as the numbers. Album Art sorts by whether a track has art. Size compares in
  megabytes in a rule; Loved and Compilation compare as 1 or 0.
- **Dates from the walk.** Date Created is `creationDateKey`, fetched with each directory
  listing like the size and modification date (ADR 0010), so it costs no call per file. A
  volume that keeps no creation date leaves it empty.
- **`#`** is the row's position as shown. It isn't stored and can't be sorted by: the header has
  no sort for it and a saved layout sorting by it is refused.
- **Album Art** cells take thumbnails from their own `ArtworkLoader`, at 36 pixels for the
  18-point rows, 300 kept. A cache miss queues the request and loads one at a time off the main
  thread, newest first; requests for rows scrolled away are dropped, and at most 200 wait.
  A failed file is logged (the first 100) and not asked for again.
- **Loved** is a table of its own in a schema part of its own, `loved`, keyed by path ID. A
  part that doesn't match is rebuilt alone and its rows counted in the discard notice; a stats
  rebuild rebuilds it too, since it refers to `paths`. Adding it rebuilt only it and the index,
  so the plays, ratings and playlists stayed. "Love or Unlove" loves the selection, or unloves
  it when all of it is loved.
- **Default widths** per column, used when one is first shown, add up for the owner's sixteen
  (#, Album Art, Title, Artist, Album, Track of Total, Time, Year, Genre, Grouping, Catalog
  Number, Bit Rate, Sample Rate, Size, Plays, Date Added) to 1,027 points with spacing, which
  fits a 1440-point window with the sidebar and queue open. The default 1280-point window
  scrolls them sideways. The track number's header is now "Track", since "#" is the row number.

## Alternatives considered

- **Grouping computed in each query** (`coalesce(album_artist_id, …)`) — rejected: no index can
  serve it, and every pane query would scan the tracks.
- **Various Artists as a sentinel ID** — rejected: every query would need a special case, and an
  album artist tagged "Various Artists" would list twice.
- **Loved in the stats part** — rejected: changing the stats SQL discards every play, rating and
  playlist.
- **File name by string functions on the path** — rejected: SQLite has no last-index function,
  and the `rtrim` trick costs about 100 character comparisons per row per sort.
- **Bit rate from the stream** (MP3 frame headers, MP4 `esds`) — rejected for now: no reader
  records it for every format, and the size-based figure needs no read.
- **Sorting by `#`** — rejected: the position is the result of the sort.

## Consequences

The index shape changed, so the first launch rebuilds it and rescans. The tag editor still edits
only the fields it did; editing a comment no longer touches a Vorbis `DESCRIPTION`. A thumbnail
column on a slow NAS shows art a row at a time as each loads.
