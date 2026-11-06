# 0069. Each browser column groups by what the user picks

- **Date:** 2026-11-03
- **Status:** accepted
- **Amended by:** [0106](0106-column-groupings-in-the-config-file.md): the groupings are saved
  in the config file as `browser.columnGroupings`; the selections stay in the state file.

## Context

The owner, 2026-11-02: "swinsian's column browser column on right click... allows you to select
which of the 3 columns display each type of information. we should do that too, so each of the
3 columns can show a user configurable metadata grouping". Swinsian's menu (`s3548`) lists
Artists, Album Artists, Artists / Album Artists, Albums, Albums by Year, Years, Genres,
Composers, Publishers, Groupings, Audio Quality, Channels, File Types, File Names, Conductors,
Comments, Descriptions, Folders, Ratings, Lyricists, Work, Original Release Date and Initial
Key. The browser had three fixed panes, Genre, Artist and Album, each selecting a row of its
table by ID, and the palette, `music-player play`, and Show Artist and Show Album select in them.

## Decision

- **Every grouping in Swinsian's list, in its order and words.** Right-clicking a column's
  header shows them, the column's own checked. `BrowserGrouping` (Settings) names them; the
  SQL for each is in Library.
- **Two kinds of grouping.** Genres, the three artist groupings and the two album ones list rows
  of the genres, artists and albums tables and select by ID, through the existing indexes.
  Artists follows `library.groupByAlbumArtist` as the Artist pane did; Album Artists is always
  the tag, and Artists / Album Artists always the grouped artist. Albums by Year lists albums by
  their earliest track's year. Every other grouping lists the distinct text of a track's tag or
  file: text tags ignore case, as the table sorts them; Years, Channels and Ratings list numbers
  as text and sort by number; Audio Quality reads "24-bit 96 kHz"; Folders is the file's folder's
  path; File Types is the extension, as the File Type column shows it. Tracks with no value are
  left out of the column, as tracks with no genre are.
- **A filter holds one selection per grouping**, `TrackFilter.selections`, so any column order
  works. A click selects by grouping, not by the column's place, and is ignored when a change
  still loading has taken that grouping out of the columns, since an ID means nothing in
  another grouping. A text selection in a grouping that ignores case is kept, in the new
  spelling, when the spelling the column lists for it changes, as SQLite's NOCASE compares
  (ASCII letters only). A column lists the tracks that the source and the columns to its left let through, as
  before.
- **No two columns show the same grouping.** Choosing one another column shows swaps the two.
  A column whose grouping changes goes back to All, and so do the columns to its right, which
  load again.
- **Saved in the state file** as `browser.columns`: each column's grouping and its selection's
  name (the entry's name or title, or the text), replacing `browser.genre`, `browser.artist` and
  `browser.album`. A state file holding one of the old keys doesn't match and is discarded
  whole, as any such file is (pre-release, no migration); the state file on the 2015 MacBook
  Pro holds none of them, since a selection at All isn't written.
- **The palette, `play`, Show Artist and Show Album** select in the column that shows that kind
  of entry (Albums by Year counts as albums). With none showing it, the palette's genre, and an
  artist or album with ⌥, go to the entry's first track in the whole library instead, and Show
  Artist and Show Album select the track in the whole library. `music-player play album:…`
  still plays the album when no column shows albums; the browser's columns show All then, and
  Show All Music clears the album.

## Alternatives considered

- **Keeping three panes and letting each show a fixed alternative** — rejected: the owner asked
  for Swinsian's whole list in every column.
- **Giving text entries IDs** (an entry's first track's ID, or a table per tag) — rejected: an ID
  borrowed from a track changes when that track goes, and a table per tag is a schema change for
  what one `SELECT DISTINCT` gives. The text is its own key.
- **An index per tag** — not now: a text grouping reads every track once, which costs about what a
  sort by that column does, and only when the user picks it. The default columns read through
  the same indexes as before.

## Consequences

`TrackFilter` keeps `genre`, `artist` and `album` as accessors of the selections for the
benchmarks and tests that build filters by ID.
