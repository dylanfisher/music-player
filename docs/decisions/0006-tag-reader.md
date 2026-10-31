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
- **Strictness.** Structure that breaks the format fails the file with a typed `MetadataError`:
  the path, the byte offset, and what was wrong. So do values that don't parse: a track number
  that isn't a number, text that isn't valid in its declared encoding, an ID3 frame ID with
  characters outside A–Z and 0–9.
  The scanner reports these to the owner instead of showing guessed data. Unknown tag fields
  (Vorbis keys, ID3 frames, MP4 items) are skipped: they are the user's own data, not a schema.
- **Values.** When a field appears twice, the first wins, including multi-valued Vorbis and
  ID3v2.4 fields. Empty values count as absent, and so do zero track and disc numbers. In WAV,
  ID3 wins over `LIST/INFO` field by field. RIFF INFO text that isn't UTF-8 is read as Latin-1,
  since INFO declares no encoding. The art is the front cover if there is one, else the first
  picture.
- **ID3v2** reads from any byte range, so WAV, AIFF and later DSF reuse it. Whole-tag
  unsynchronisation (2.2, 2.3) decodes the tag in memory and maps offsets back to the file; art in
  an unsynchronised tag or frame is flagged so `readArt` removes the escapes.
- **Length.** FLAC: STREAMINFO. MP4: `mdhd`, or `iTunSMPB` for AAC, which excludes priming and
  remainder frames. MP3: the Xing/Info or VBRI frame count, else the file size at the first
  frame's bit rate. WAV: `data` size over block align. AIFF: `COMM` frames.
- **A truncated file whose damage is in the audio parses**: tag reading never looks at audio, so
  phase 4's decoder reports it.

Not read: DSF (phase 12), Ogg, APE, WavPack, RF64; ID3v1 and APE tags at the end of an MP3, an
ID3v2 tag in front of FLAC, a second ID3v2 tag in a row; AIFF `NAME`/`AUTH`/`ANNO`; RIFF `bext`;
MP4 freeform items other than `iTunSMPB`, ID3 `TXXX`; compressed or encrypted ID3 frames, which
fail the file when they're a frame this reads; MPEG Layer I and II; fragmented MP4. LAME's
encoder delay is counted in an MP3's length, AAC without `iTunSMPB` includes priming, and HE-AAC
reports its core rate.

## Alternatives considered

- **AudioToolbox (`AudioFileGetProperty`, `kAudioFilePropertyInfoDictionary`)** — rejected: no
  album artist, disc or compilation fields, no art location, and no control over how much of a
  NAS file it reads. Tests still use it as an independent check of rate, channels and length.
- **AVFoundation metadata** — rejected: asynchronous, heavyweight per file, and the same missing
  control over reads.
- **`mmap` the whole file** — rejected: a NAS read fault stalls in the kernel with no error, and
  a file truncated while mapped raises SIGBUS.
- **Lenient parsing (skip bad frames, keep going)** — rejected for now: it shows partly wrong
  tags with no signal. Loosen per case if the owner's library has many files that fail.

## Consequences

The scanner can store art references for every file without reading art, and bytes read per
file stay near 16 KiB on a typical library. A file with one bad value fails as a whole, so the
first scan of a real library may report files that other players read; each report names the
offset to look at. Every new format adds a parser here and a case in `parse`.
