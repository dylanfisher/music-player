# 0032. Playlist files: M3U, M3U8 and PLS in, M3U8 out, entries matched by path in NFC

- **Date:** 2026-11-01
- **Status:** accepted
- **Amends:** [0018](0018-playlists-and-stats.md), [0025](0025-threat-model.md)

## Context

Phase 17 imports playlist files as manual playlists and exports a playlist as one. The files
come from other players and other people, on this Mac and from Windows, so their encoding,
line ends and paths vary, and they are hostile input (0025). The index stores each path as the
walk listed it: decomposed under an APFS root, precomposed names under a share's root that
`canonicalPath` decomposed (0009). Swinsian and iTunes write either form.

## Decision

- **Formats.** `.m3u`, `.m3u8` and `.pls` are read, chosen by extension in any case; only M3U8
  is written. `PlaylistFile` in Library is a pure function of the bytes, the format and the
  file's folder, so the fuzzer and the tests drive it without a disk.
- **Encoding.** `.m3u8` is UTF-8; a line that isn't is skipped and reported. `.m3u` and `.pls`
  are UTF-8 when the whole file is, else Windows-1252, a superset of Latin-1's printable
  characters; its five undefined bytes map to the C1 controls, so that decode never fails. A
  UTF-8 BOM is dropped and means UTF-8; a UTF-16 BOM refuses the file with a reason. Lines end at
  LF, CRLF or a lone CR.
- **Entries.** A line starting with `#` is a comment or directive (`#EXTINF` included) and is
  skipped. An entry is an absolute path, a path relative to the playlist file's folder, or a
  `file:` URL with no host or `localhost`, whose `%` escapes decode as UTF-8 by our own code,
  since Foundation's URL parsing of unescaped spaces differs between macOS versions. Another
  `scheme://` and a Windows drive path are reported. `name:` without `//` is a relative path,
  since folder names hold colons ("Live: 1999"). PLS takes `FileN=` in number order and ignores
  `Title`, `Length`, `NumberOfEntries`, `Version` and `;` comments; any other line is reported.
- **Paths by text.** `.` and `..` are folded on the text, and the result only goes to an index
  lookup: nothing is opened, stat'd or resolved, so a playlist naming a path through a link
  finds nothing and says so.
- **Lookup.** A path is matched as written, then in NFC against every track's path in NFC, read
  once per import and only when some path misses. That covers both forms and a share's mixed
  paths.
- **Import.** A new manual playlist named after the file (in NFC) gets the tracks the index
  holds, in order. Entries it doesn't hold are not added and not dropped silently: the status
  bar counts them, and the Problems window opens on the summary, each missing path and each
  skipped line, 100 of each and then a count. A track listed twice is added once (0018) and
  counted. The report is kept for the session until the next import or export.
- **Export.** The playlist shown, in the table's current sort, ignoring the search and the
  panes; a smart playlist gives its current tracks. `#EXTM3U`, then `#EXTINF:<seconds>,<artist>
  - <title>` (seconds -1 when unknown or a day or more; a control character in the text becomes
  a space) and the path in NFC. Paths are absolute unless the save panel's "Paths relative to
  the playlist file" is checked; a relative path the reader would take for a comment, a blank
  line or a URL starts with `./`. A path holding CR, LF or NUL, or longer than a line the reader
  takes, isn't written and is reported, as is a manual playlist's count of entries not in the
  library. The file is written only to the save panel's URL, atomically.
- **Caps.** 16 MiB a file, 4 KiB a line, 100,000 entries, 100 problems listed.

## Alternatives considered

- **Deciding the encoding per line.** Rejected: a file is written by one program in one
  encoding, and a per-line guess would read a Windows-1252 line that happens to be valid UTF-8
  differently from its neighbors.
- **Adding missing entries as path IDs**, so they appear if the file is scanned later. Rejected:
  it would add rows to `paths` for files the library never saw, with a Date Added, and the
  playlist would count tracks that may never exist.
- **Exporting a manual playlist in its own order whatever the table shows.** Rejected: the
  owner sees one order and gets another; sorting by Order first gives that file.
- **Writing paths as the index stores them.** Rejected: a share's paths are mixed NFD and NFC;
  other systems and players expect NFC.
- **Following links or resolving the path with `realpath`** to match more entries. Rejected:
  it reads the disk at paths a hostile file chose (0025).

## Consequences

An import never touches the files a playlist names, so an entry whose path differs from the
index only by a link, a case or a trailing space is reported as not in the library. A UTF-16
playlist has to be saved again as UTF-8. Exported files open in other players on macOS and,
with relative paths and the same folder layout, on other systems.
