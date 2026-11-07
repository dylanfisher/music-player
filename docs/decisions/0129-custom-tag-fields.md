# 0129. Custom tag keys: read by name, written as spelled, two of them in the index

- **Date:** 2026-11-07
- **Status:** accepted
- **See also:** [0006](0006-tag-reader.md) maps the standard fields' keys,
  [0128](0128-discogs-survey.md) lists the keys YATE writes.

## Context

The Discogs tagger reads and writes YATE's keys: `DISCOGS_RELEASE_ID` and some forty more, which
no standard field maps. Until now the reader skipped any Vorbis comment, `TXXX` frame or iTunes
freeform item it didn't map, and the writer could only write the fields `TagEditField` names.
The window has to know which albums are matched without opening 43k files on the NAS, and the
survey (ADR 0128) found YATE spells some keys differently in each format.

## Decision

**A custom key** is any Vorbis comment key, ID3 `TXXX` description, or name of a `----` item
whose `mean` is `com.apple.iTunes`, that the reader doesn't map to a field. iTunes's gapless
item, `iTunSMPB`, isn't one, and neither is a freeform item holding binary data.

**Read.** `TrackTags.custom` holds them by name uppercased, as taggers compare names; the
first value of a name wins, empty values are skipped and a value is read up to a NUL, as for
the fields. A WAV's ID3 tag fills it before its RIFF INFO list. `WXXX` and `TIPL` frames, where
YATE puts URLs and credits in ID3, aren't custom keys and stay unread.

**Written.** `TagEdit.custom` maps a name to its text; empty text removes the key. The name is
written as the edit spells it, and replaces every key of that name in any case, wherever the
first of them was: a Vorbis comment `NAME=text`, a `TXXX` frame described `NAME`, or a
`----:com.apple.iTunes:NAME` item with UTF-8 text. A name must be printable ASCII without
"=", the Vorbis rule and the strictest of the three, must not be a name the reader maps to a
field in any format (`LABEL` is the publisher in Vorbis), and an edit can't name one key in two
cases. Each of these is a `TagValueError` before anything is written. The writer's other rules
hold: the edit is checked on the new file, journaled and undoable, and the blocks it doesn't
name stay byte for byte.

**Indexed.** `DISCOGS_RELEASE_ID` and `DISCOGS_MASTER_ID` are columns on `tracks`
(`discogs_release_id`, `discogs_master_id`), as written; `DiscogsKey` names them once. The
other custom keys aren't stored: the window reads them from the files of the album it shows.
`LibraryIndex.discogsMatches()` gives each album's state: matched when every track has the same
release id, incomplete when some tracks have none or they differ, unmatched when none has one.
The index's SQL changed, so it is rebuilt on open, as any change to it is.

## Alternatives considered

- **Writing names uppercased.** Rejected: YATE writes `Discogs Release Notes` in MP4 and ID3,
  and a write that renamed it might leave YATE unable to find it.
- **Keeping the names' case when read.** Rejected: Vorbis keys are case-insensitive by its
  spec, and the same key spelled two ways in one file would be two keys.
- **A custom key per Discogs field in `TagEditField`.** Rejected: YATE writes forty keys, other
  taggers more, and the mapping lets the user send a field to any key.
- **Storing every custom key in the index.** Rejected: 15,842 files carry a dozen or more each,
  release notes among them, for a window that reads one album at a time. The release id is what
  tells matched albums apart, and the master id what groups them.
- **Matching albums by folder.** Rejected: the library's album is its title and album artist,
  which the browser shows; a folder holding two albums, or an album split over discs, would
  disagree with it.

## Consequences

Any tool or feature can read a custom key by its uppercased name, and the tag editor could show
them later. A custom key edit replaces a key spelled in another case, so a write unifies a
file's spelling to the edit's. ID3's URL and credit frames need their own support before the
mapping can write YATE's ID3 URLs (ADR 0128). The match state counts tracks in the index, so a
file that doesn't scan doesn't count against its album.
