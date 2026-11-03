# 0061. Importing Swinsian's column layout from its preferences file

- **Date:** 2026-11-02
- **Status:** accepted
- **Amends:** [0033](0033-import-from-other-players.md)

## Context

Row 26.4 asks for the import from Swinsian to bring across its track table's columns, their
order and widths, and its sort. Swinsian keeps none of this in `Library.sqlite` or in its
Application Support folder. It's in its preferences,
`~/Library/Preferences/com.swinsian.Swinsian.plist`, read from the owner's on 2026-11-02:

| Key | Holds |
|---|---|
| `MainTableColumns-Ver1` | The visible columns, left to right: dictionaries of `TableColumnIdentifier` (text) and `TableColumnWidth` (a number, points) |
| `NSTableView Columns v3 main_track_table` | `NSTableView`'s own autosave, an `NSKeyedArchiver` archive of every column with `Identifier`, `Width` and `Hidden`; the visible ones match the key above |
| `NSTableView Sort Ordering v2 main_track_table` | The sort, an `NSKeyedArchiver` archive whose `$top` key `Array` holds an array of dictionaries of `Identifier` and `Ascending` |
| `BrowserColumns`, `GridSortKey` | The browser panes and the album grid, which this row doesn't read |

The file also holds Swinsian's license key and email, so it's never copied into a fixture or a
test; fixtures build their own with only the keys above.

## Decision

- **The Swinsian import's sheet gains "Import column layout"**, a checkbox, off at first, under
  the details, with what it would bring: "6 columns, sorted by Artist; 1 skipped". Ticking it
  enables Import even when the library has nothing new. The import writes the library first,
  then shows the columns, sorts the table, and saves the layout to `browser.trackTable` as a
  change by hand would. The report adds "· column layout", and the Problems window lists each
  skipped column. iTunes keeps no column layout in `Library.xml`, so its sheet has no checkbox.
- **Read only, as a hostile file (0025).** The plist is read through `FileSource` (`O_NOFOLLOW`,
  a regular file only, 4 MiB at most) and parsed by `PropertyListSerialization`. It's read
  beside the library, before the sheet opens; a failure leaves the checkbox off and disabled
  with the reason, and the rest of the import goes on.
- **Columns come from `MainTableColumns-Ver1`**, a plain list, rather than the `NSTableView`
  archive. At most 200 are read. A column is skipped and listed when its ID has no match here,
  it's listed twice, or its width is missing or outside our 20 to 2,000 points. If none is
  left, the layout can't be imported.
- **The sort is the first entry of the sort archive**, whose objects are read by number from
  the property list, as the smart playlists' are (0033), never by `NSKeyedUnarchiver`. When
  there's none, it can't be read, or its column has no match, the table keeps its sort and the
  report says so.
- **Only IDs seen in the owner's preferences map.** Same name: `title`, `artist`, `album`,
  `albumArtist`, `composer`, `conductor`, `lyricist`, `grouping`, `work`, `movementName`,
  `genre`, `year`, `trackNumber`, `discSubtitle`, `bpm`, `fileType`, `bitRate`, `sampleRate`,
  `bitDepth`, `channels`, `fileName`, `path`, `dateAdded`, `dateCreated`, `dateModified`,
  `playCount`, `lastPlayed`, `rating`, `publisher`, `catalogNumber`, `barcode`, `copyright`,
  `encoder`, `comment`. Renamed: `artwork` is Art, `movement` Movement Number,
  `originalReleaseDate` Original Date, `totalNumberOfTracks` Track Total, `trackNumbers` Track
  of Total, `disc` Disc, `totalNumberOfDiscs` Disc Total, `discNumbersString` Disc of Total,
  `length` Time, `initialKey` Key, `fileSize` Size, `favourite` Loved, `descriptionTag`
  Description. `currentlyPlaying` (we mark the playing row instead) and `enabled` (we have no
  disabled tracks) have no match. `trackNumbers` and `discNumbersString` are taken to be the
  "3 of 12" columns, from their names and widths beside `trackNumber` and `disc`; unverified
  until the owner compares the tables. `fileType` maps to File Type, as its smart rule does.

## Alternatives considered

- **Reading through `CFPreferences` for Swinsian's domain**, which gets values Swinsian hasn't
  flushed to the file yet. Rejected: it goes through `cfprefsd` rather than the file the user
  can see, and tests couldn't give it a fixture. Changes Swinsian made in the last few seconds
  may be missing; quitting it first writes them.
- **A separate command, Import Column Layout from Swinsian.** Rejected: the plan puts it in the
  import, which already reads Swinsian's files and reports what it skipped.
- **Clamping a width outside our range.** Rejected: a width we'd change without saying is a
  silent fallback; skipping lists it.
- **Importing the browser panes (`BrowserColumns`) and the album grid's sort.** Not asked for,
  and our panes are fixed; left for a later row.

## Consequences

The import may change the table's columns and sort as well as the library; there is no undo
beyond not ticking the box, and the header's menu changes them back. A Swinsian that renames its
keys makes the checkbox disabled with which key is missing.
