# 0006. Read tags with our own strict parsers, by targeted reads

- **Date:** 2026-10-30
- **Status:** accepted

## Context

Phase 3 scans 43k files, many on a NAS, and stores each file's tags, audio properties and art
location in SQLite. No dependency may be added, and AudioToolbox's info dictionary misses fields
the library needs (album artist, disc numbers, compilation, composer) and reads every file whole
through its own I/O. Files on the NAS are slow to read, and a few are damaged.

## Decision

`Metadata` (Core) parses FLAC, MP4, MP3, WAV and AIFF itself and returns `TrackMetadata`: tags,
codec, rate, bit depth, channels, length in frames, and art as offset, length and MIME type.
`readArt` reads the picture later.

- **I/O.** One `open` per file and `pread`, never `mmap`, so a file that shrinks fails a read
  instead of raising SIGBUS. Each read outside the last one fetches at least 16 KiB, so a header's
  fields arrive together and a file whose tags fit in 16 KiB costs one read. Art, audio and
  unknown blocks are skipped by length. A trailing `moov` costs one more read. Parsing never
  reads more than 16 MiB at once, and every length from the file is checked against the file (and its parent
  block) before anything is read or allocated.
- **Strictness.** Damage that stops the container being walked or the audio properties being
  found fails the file with a typed `MetadataError`: the path, the byte offset, and what was
  wrong. A block or frame whose length runs past its parent counts, since nothing after it can
  be located. Damage to one field doesn't fail the file: the field is dropped, read in part, or
  decoded leniently, and `ParsedFile.warnings` records a typed `MetadataWarning` with the kind,
  the offset and what happened, which the scanner reports to the owner. Numbers keep their
  leading digits ("3 of 10" is 3, "A1" is dropped). Invalid UTF-8 reads as Latin-1, which a
  mislabelled tag almost always is; invalid UTF-16 gets U+FFFD; UTF-16 without a byte-order mark
  reads as little-endian. An ID3 frame, MP4 item or FLAC picture that can't be read inside its
  checked bounds is skipped, including compressed or encrypted ID3 frames. An invalid ID3 frame
  ID ends the tag, because its size can't be trusted. ID3v2.4 frame sizes that iTunes wrote as
  plain integers are read when the syncsafe reading doesn't land on the next frame and the plain
  one does. Unknown tag fields (Vorbis keys, ID3 frames, MP4 items) are skipped without a warning:
  they are the user's own data, not a schema.
- **Values.** When a field appears twice, the first wins, including multi-valued Vorbis and
  ID3v2.4 fields. Empty values count as absent, and so do zero track and disc numbers. In WAV,
  ID3 wins over `LIST/INFO` field by field. RIFF INFO text that isn't UTF-8 is read as Latin-1,
  since INFO declares no encoding. The art is the front cover if there is one, else the first
  picture.
- **ID3v2** reads from any byte range, so WAV, AIFF, DSF and DSDIFF reuse it (0064). Whole-tag
  unsynchronisation (2.2, 2.3) decodes the tag in memory and maps offsets back to the file; art in
  an unsynchronised tag or frame is flagged so `readArt` removes the escapes.
- **Length.** FLAC: STREAMINFO. MP4: `mdhd`, or `iTunSMPB` for AAC, which excludes priming and
  remainder frames. MP3: the Xing/Info or VBRI frame count, else the file size at the first
  frame's bit rate. WAV: `data` size over block align. AIFF: `COMM` frames. DSF: the sample count, DSDIFF: the
  `DSD ` chunk's size, both in 1-bit samples at the DSD rate.
- **A truncated file whose damage is in the audio parses**: tag reading never looks at audio, so
  phase 4's decoder reports it. For WAV and AIFF that includes a form size or a `data`/`SSND`
  chunk running past the end of the file: the sizes are clamped to the file, the length counts the
  bytes present, and a `truncated` warning says so. A streamed size of `0xFFFFFFFF` reads to the
  end of the file without a warning.

Not read: DSDIFF `DIIN` text, Ogg, APE, WavPack, RF64; ID3v1 and APE tags at the end of an MP3, an
ID3v2 tag in front of FLAC, a second ID3v2 tag in a row; AIFF `NAME`/`AUTH`/`ANNO`; RIFF `bext`;
MP4 freeform items and ID3 `TXXX` frames the table below doesn't name; compressed or encrypted ID3 frames,
which are skipped with a warning; MPEG Layer I and II; fragmented MP4. LAME's
encoder delay is counted in an MP3's length, AAC without `iTunSMPB` includes priming, and HE-AAC
reports its core rate.

### Fields added in phase 16

Each format's key follows MusicBrainz Picard's tag mapping table, written from memory without
the table to hand; the keys marked † are the ones to check against it. Vorbis keys, `TXXX`
descriptions and freeform names compare uppercased. Freeform items are `----` with the `mean`
`com.apple.iTunes`. ID3v2.2 reads the three-letter forms of the 2.3 frames (`TT1`, `TBP`,
`TKE`, `TP3`, `TXT`, `TPB`, `TCR`, `TEN`, `TOR`, `TXX`). A field a file doesn't hold is empty.

| Field | Vorbis | ID3v2.3 and 2.4 | MP4 | RIFF INFO |
|---|---|---|---|---|
| grouping | `GROUPING` | `GRP1`, else `TIT1` † | `©grp` | |
| catalog number | `CATALOGNUMBER` | `TXXX:CATALOGNUMBER` | `----:CATALOGNUMBER` | |
| barcode | `BARCODE` | `TXXX:BARCODE` | `----:BARCODE` | |
| BPM | `BPM` | `TBPM` | `tmpo` (integer) | |
| key | `KEY` | `TKEY` | `----:initialkey` | |
| conductor | `CONDUCTOR` | `TPE3` | `----:CONDUCTOR` | |
| lyricist | `LYRICIST` | `TEXT` | `----:LYRICIST` | |
| publisher (label) | `LABEL`, `PUBLISHER` † | `TPUB` | `----:LABEL` | |
| copyright | `COPYRIGHT` | `TCOP` | `cprt` | `ICOP` |
| encoder (Picard's "encoded by") | `ENCODEDBY` † | `TENC` † | `©too` | |
| description | `DESCRIPTION` † | not read † | `desc` † | |
| disc subtitle | `DISCSUBTITLE` | `TSST`, `TXXX:DISCSUBTITLE` † | `----:DISCSUBTITLE` | |
| work | `WORK` | `TXXX:WORK` † | `©wrk` | |
| movement number | `MOVEMENT` | `MVIN` | `©mvi` (integer) | |
| movement name | `MOVEMENTNAME` | `MVNM` | `©mvn` | |
| original release date | `ORIGINALDATE` | `TDOR`, `TORY` (2.3's year) | `----:ORIGINALDATE` | |

- **Grouping.** `GRP1` wins over `TIT1` wherever it is: iTunes 12.5 and Picard's iTunes option
  write the grouping to `GRP1` and the work to `TIT1`. `TIT1` isn't read as the work, since
  without `GRP1` it is the grouping.
- **Description** was read as the comment where the comment was missing; it's a field of its
  own now, so a Vorbis `DESCRIPTION` no longer shows as the comment, and editing the comment
  no longer replaces it. Picard maps no ID3 or INFO key to it.
- **Encoder** is who or what encoded the file as the tagger names it. `TSSE`, `ENCODERSETTINGS`
  and INFO's `ISFT` (Picard's "encoder settings") aren't read, nor is INFO's `ITCH`.
- **Numbers.** BPM reads whole or decimal text and rounds it; movement numbers read like track
  numbers, and the movement total isn't kept. MP4's `tmpo` and `©mvi` are 1- to 8-byte
  big-endian integers (data type 0 or 21); any other type skips the item with a warning.

## Alternatives considered

- **AudioToolbox (`AudioFileGetProperty`, `kAudioFilePropertyInfoDictionary`)** — rejected: no
  album artist, disc or compilation fields, no art location, and no control over how much of a
  NAS file it reads. Tests still use it as an independent check of rate, channels and length.
- **AVFoundation metadata** — rejected: asynchronous, heavyweight per file, and the same missing
  control over reads.
- **`mmap` the whole file** — rejected: a NAS read fault stalls in the kernel with no error, and
  a file truncated while mapped raises SIGBUS.
- **Fail the file on any bad value** — rejected: one junk track number in a real library would
  hide every other field of the file. Warnings keep the signal without losing the file.
- **Skip bad fields silently** — rejected: it shows partly wrong tags with no signal.

## Consequences

The scanner can store art references for every file without reading art, and bytes read per
file stay near 16 KiB on a typical library. A file with bad fields still enters the library,
with each warning naming the offset to look at; only structural damage keeps a file out.
Every new format adds a parser here and a case in `parse`.
