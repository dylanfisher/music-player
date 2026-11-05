# 0101. Get Info edits YATE's fields that map onto every format, in tabs

- **Date:** 2026-11-05
- **Status:** accepted
- **Amends:** [0006](0006-tag-reader.md), [0020](0020-tag-writing.md),
  [0021](0021-tag-editor.md), [0100](0100-get-info-windows-and-smb-temp-files.md)

## Context

The owner's feedback of 2026-11-05 (part 42g): compare Get Info with YATE's panels and make the
same fields editable, grouped so they're easy to find. Get Info edited thirteen fields in one
list. The reader already read sixteen more (phase 16) and the index stored them, but nothing
wrote them. The writer's read-back check compares every field of `TrackTags` (ADR 0020), so a
field the reader reads is checked by every write.

## Decision

**Which fields.** A field is editable when it has a key in FLAC's Vorbis comments, MP4's `ilst`
and ID3v2.3 and 2.4 alike, as MusicBrainz Picard maps them, or Mp3tag where Picard has none
(the webpages). The plan's table (part 42g) lists each YATE field with what's added and why the
rest isn't: ratings are the app's own (ADR 0068); iTunes database items (play count, start and
stop time, volume adjustment, skip when shuffling, remember position), podcast items, the
ID3-only ownership and radio frames, encoder settings and tagging times have no Vorbis or MP4
key or aren't edited by hand. Involved people and musician credits are one ID3 frame of role and
name pairs against a key per role elsewhere, so no field maps onto all three; user-defined text
and URLs need a list editor whose mixed values across a selection want a design of their own.
Both are left for the owner to ask for. Other pictures than the front cover are kept, not listed.

**Keys.** Each field's written key per format is one table in `Metadata` beside the reader's
map, which is built from it, plus other taggers' spellings:

| Field | Vorbis | MP4 | ID3v2.4 (2.3 where different) |
|---|---|---|---|
| Grouping | `GROUPING` | `©grp` | `TIT1`, or `GRP1` when the tag has one |
| BPM | `BPM` | `tmpo` | `TBPM` |
| Key | `KEY` | `----:initialkey` | `TKEY` |
| Conductor, Lyricist, Remixer | `CONDUCTOR`, `LYRICIST`, `REMIXER` | `----:` the same | `TPE3`, `TEXT`, `TPE4` |
| Original Artist, Original Album | `ORIGINALARTIST`, `ORIGINALALBUM` | `----:` the same | `TOPE`, `TOAL` |
| Label | `LABEL` (`PUBLISHER` read) | `----:LABEL` | `TPUB` |
| Copyright | `COPYRIGHT` | `cprt` | `TCOP` |
| Catalog Number, Barcode | `CATALOGNUMBER`, `BARCODE` | `----:` the same | `TXXX:` the same |
| ISRC, Language, Media | `ISRC`, `LANGUAGE`, `MEDIA` | `----:` the same | `TSRC`, `TLAN`, `TMED` |
| Mood | `MOOD` | `----:MOOD` | `TMOO` (`TXXX:MOOD`) |
| Encoded By | `ENCODEDBY` | `©too` | `TENC` |
| Description | `DESCRIPTION` | `desc` | `TXXX:DESCRIPTION` |
| Disc Subtitle | `DISCSUBTITLE` | `----:DISCSUBTITLE` | `TSST` (`TXXX:DISCSUBTITLE`) |
| Work | `WORK` | `©wrk` | `TXXX:WORK` |
| Movement n of m, its name | `MOVEMENT`, `MOVEMENTTOTAL`, `MOVEMENTNAME` | `©mvi`, `©mvc`, `©mvn` | `MVIN` n/m, `MVNM` |
| Original Date | `ORIGINALDATE` | `----:ORIGINALDATE` | `TDOR` (`TORY` for a year, else `TXXX:ORIGINALDATE`) |
| Lyrics | `LYRICS` (`UNSYNCEDLYRICS` read) | `©lyr` | `USLT` without a description |
| Sort Title, Artist, Album, Album Artist, Composer | `TITLESORT` … `COMPOSERSORT` | `sonm`, `soar`, `soal`, `soaa`, `soco` | `TSOT`, `TSOP`, `TSOA`, `TSO2`, `TSOC` |
| Webpages: artist, audio file, audio source, commercial, copyright, payment, publisher, radio station | `WWWARTIST` … `WWWRADIOPAGE` | `----:` the same | `WOAR`, `WOAF`, `WOAS`, `WCOM`, `WCOP`, `WPAY`, `WPUB`, `WORS` |

`----:` is an iTunes freeform item (`mean` com.apple.iTunes) by `name`, compared uppercased. The
2.3 spellings follow Picard: 2.3 has no `TSST`, `TMOO` or `TDOR`. The sort frames are 2.4's but
iTunes writes them in 2.3 tags and every player reads them there, so both versions use them. ID3
URL frames hold Latin-1 only; other text is refused for that file, which the window reports. A
`USLT` or `COMM` with a description is a player's own and stays. Grouping is written to `GRP1`
when the tag has it, since iTunes then keeps the work in `TIT1`.

**The layout and the check.** The layout names each `TXXX` and freeform block's field by its
description or name, so the round trip's check that blocks outside the edit are unchanged covers
them as it does the rest. Each write is still checked by reading it back whole (ADR 0020).

**The index.** No column is added: the new fields are read into `TrackTags` from the file and
the index stores what it stored before. A change to the index part's SQL drops and rebuilds that
part, reading every file again (an hour or more over the NAS); plays, history, ratings and
playlists live in the stats part, keyed by path ID, and are kept. Nothing here needs a column or
a search, so no rebuild. A file whose `TXXX:DESCRIPTION`, `TXXX:MOOD` or `TXXX:ORIGINALDATE` the
reader now maps shows it in the Description or Original Date column once it's next rescanned.

**The window.** Tabs, as YATE's side panel has: Info (title; artist and date; album artist and
track of total; album and disc of total; grouping and BPM; composer; genre; the comment beside
the art; compilation), Sorting (each sort field directly above the field it sorts), Credits,
Details (YATE's More Info), Rights & Label (YATE's Privacy, renamed for what it holds), URLs,
Lyrics, Artwork (a large preview, its type, pixels and size, Replace and Remove) and File (format,
rate, depth, channels, length, average bit rate, size, tag kind, dates and folder; read-only).
A field on two tabs is one field. Every field shows Mixed across a selection, and a dot by its
label once typed differently from what it showed, as YATE's edited mark. The window opens on the
tab last chosen, and each tab's views are made when it's first shown.

## Alternatives considered

- **Columns for the new fields in the index** — not done: nothing sorts or searches by them yet,
  and the schema change would rescan the owner's whole library.
- **YATE's ID3-only fields (owner, radio station, terms of use…) in ID3 files only** — rejected:
  a field that exists for some of a selection's files and not others can't be edited across it,
  and the owner's library is mostly FLAC.
- **One long scrolling list** — rejected: sixty fields don't fit a window, and YATE's grouping
  is what the owner asked for.
- **Make every tab at open** — rejected: it took Get Info on one track from 31 ms to 55 ms to
  its fields; making a tab when first shown brought it back to 30 ms.

## Consequences

- Picard, Mp3tag, foobar2000 and Swinsian read what the window writes; YATE reads the ID3 frames.
- The scanner reads lyrics and the other new fields into memory per file and drops them; the
  index is unchanged.
- Producer, engineer and mixer credits, and user-defined fields, are the next fields to add if
  the owner wants them.
