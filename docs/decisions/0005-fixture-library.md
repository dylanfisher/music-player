# 0005. Generate fixtures by cloning tiny seeds with hand-written tag blocks

- **Date:** 2026-10-30
- **Status:** accepted

## Context

Phases 2 and 3 need a 43k-file library shaped like the real one: FLAC, ALAC, AAC, MP3, WAV and
AIFF, varied tags, embedded art and some malformed files, with the expected values known so tests
can assert against them. Binaries can't go in git, and no dependency may be added.

## Decision

`GenerateFixtures` encodes one 0.1 s seed per codec, rate and bit depth with `afconvert`, splits
each into its container parts, and writes every fixture as seed parts plus freshly built tag
blocks: Vorbis comments and PICTURE, MP4 `ilst` (rewriting `stco` because `moov` grows),
ID3v2.2/2.3/2.4, and RIFF `LIST/INFO`. A seeded generator plans artists, albums and tags, so a
count always gives the same library. `manifest.json` records each file's expected tags and audio
properties, and flags the malformed ones. A rerun renders the plan in memory, and skips writing
when the stored manifest and file sizes match.

MP3 seeds are built by hand as silent MPEG-1 Layer III frames, because macOS has no MP3 encoder.
RIFF `INFO` text is written as UTF-8, as most taggers do.

The tag writers stay inside the fixture tool. They are not the phase 11 tag writer: they never
read an existing file, and they only write under the fixture directory.

## Alternatives considered

- **Encode every file with afconvert, then tag it** — rejected: 43k process launches take minutes
  even in parallel, and afconvert writes no tags of its own.
- **Commit seed files** — rejected: binaries in git, and the seeds would drift from the code that
  describes them.
- **A content hash in the manifest to detect staleness** — rejected: comparing the planned
  manifest, which includes every byte count, already catches a changed plan or seed.

## Consequences

The whole library generates in seconds and holds about 550 MB. Seeds depend on the installed
afconvert; a different encoder version changes byte counts, which regenerates the library. The
manifest is the contract phase 2 tests against, so changing what a format stores means changing
the manifest fields with it.
