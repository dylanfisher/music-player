# 0020. Write tags only through TagWriter, checked on a temp file, tested on clones

- **Date:** 2026-10-31
- **Status:** accepted
- **Amended by:** [0050](0050-remove-from-library.md): Remove and Move to Trash moves the
  files the user confirmed to the Trash. [0100](0100-get-info-windows-and-smb-temp-files.md): the temp file's identity is taken
  after it closes. [0107](0107-tags-written-in-place-within-the-padding.md): tags that fit the
  padding are written in place, journaled first, so a crash mid-write can tear the original
  until the journal puts it back. [0108](0108-faster-tag-writes.md): a rewrite leaves 64 KiB
  of padding or the tag's size, and an MP4 with `moov` last grows in place.
  [0128](0128-discogs-survey.md): agents may read the real library, read only, for phase 51's
  survey, tuning and budgets. [0164](0164-keep-files-organized.md): the undo journal's
  records follow a file Keep Files Organized renamed.
- **See also:** [0025](0025-threat-model.md) records the writer's threats and how the temp file is made and checked.

## Context

Until phase 11 the app never wrote a music file, and AGENTS.md said so. The tag editor has to
write the owner's 43k files, most of them on a NAS, and a bad write destroys audio the owner may
not have anywhere else. The owner put 159 real files (11 GB) in a reference folder to show how
real tags are laid out and to try writes on.

## Decision

**The boundary.** Music files are written only by the `TagWriter` module
(`Sources/Core/TagWriter`), and only for an edit the user confirmed in the tag editor: Save in the
sheet, plus a confirmation when it changes more than one file. The app has no flag or command
line mode that writes tags. Nothing else in the app writes, renames, moves or deletes a music
file. Tests write only to files they generate under `.build/` or the temp directory.

**The corpus.** `/Users/dylanfisher/Music/music-player/test` is the reference copy and is only
ever read. Every write in a corpus run goes to APFS clones (`cp -c`) in
`~/Library/Caches/MusicPlayer/tag-corpus/`, which `scripts/tag-corpus` deletes and makes again
from the reference before each run. The tool refuses to write anywhere but that folder and the
temp directory, and it never reads or writes under `/Volumes`. Its full-disk test attaches a
small disk image at a mount point inside the clone folder, never under `/Volumes`.

`./scripts/check` stays hermetic and never reads the corpus. The phase gate runs
`scripts/tag-corpus --round-trip` separately.

**What the corpus holds** (`scripts/tag-corpus`, 2026-10-31): 99 MP4 (61 with `moov` after
`mdat`, 38 before), 24 MP3 and 36 AIFF, all ID3v2.4. Every file's layout reads, with no reader
warnings. What stood out:

- The 38 MP4s with `moov` first keep 1.9–4 KB of `free` inside `udta/meta`, after `ilst`. The 61
  with `moov` last have no padding in `moov`, only an 8-byte `free` before `mdat`, so any edit
  that grows them grows `moov` at the end of the file.
- One MP4 has three `trak`s (two are chapter text tracks, joined by `tref`) and two `mdat`s; its
  `stco`s point into both.
- `covr` often holds two images (the first is what readers show), up to 1.1 MB.
- The AIFF tags hold both `TDRC` and `TYER` (28 files), though 2.4 has no `TYER`. Most hold two
  `COMM` frames, one with a description (a player's own), and several `APIC`s (57 in 36 files).
- MP3 padding runs from 21 bytes to 98 KB; one `APIC` is 1.1 MB. Discogs tagging left hundreds
  of `TXXX`, `WXXX` and `----` items, which must survive every edit.
- A `.DS_Store` sits among the files; the tool takes audio files by extension and skips hidden
  ones.

**How a file is written** (`TagWriter`): the format model plans the new file as segments, new
bytes and ranges of the old file, and keeps every frame, item, comment and chunk the edit doesn't
name byte for byte and in order. An edited group (a field, or a number with its total) loses
every key the reader maps onto it (`TDRC` and `TYER`; `©gen` and `gnre`; `COMMENT` and
`DESCRIPTION`), and its new value goes where the first of them was. A described `COMM` is kept.

- **Padding first.** MP4 grows into `free` beside `ilst`, `meta` or `udta`, then a `free` right
  after `moov`; ID3 and FLAC into their padding. Past that the tags are rewritten with 2 KB of new
  padding, and when audio follows `moov`, every `stco`/`co64` entry moves with it (an `stco`
  entry past 4 GB is refused). ID3v2.3 keeps 2.3: a date is split into `TYER`, `TDAT` (DDMM)
  and `TIME` (HHMM), which the reader joins back, and a date 2.3 can't hold (a month without a
  day, free text) is refused. A file without a tag gets 2.4.
- **Temp file and rename.** The temp file is `.<name>.<random>.tagwrite` in the same folder:
  hidden, so the scanner skips one a crash leaves, and random, so nobody else can make the name
  first; the next write removes any a crash left. How it's made and checked against swaps is
  in ADR 0025, row 13. When nothing moves it starts as an APFS clone and only the new bytes are written; where
  the volume can't clone, or the audio moves, it's written whole. It gets the original's mode,
  flags, ACL, extended attributes (Finder tags, quarantine) and creation date; the mtime is new,
  so the scanner sees the change.
- **Checks before the rename.** The new file must parse; its audio payload (MP4 `mdat` bodies,
  the MP3 frames, the AIFF `SSND` or WAV `data` body, the FLAC frames) must hash the same as the
  original's; its audio properties, tags and art must read back as meant; MP4 chunk offsets must
  point at the same byte of the same `mdat`. The original's identity (device, inode, size,
  mtime) must still match what was read. Any failure removes the temp file and leaves the
  original as it was.
- **Refused:** a file that or whose folder can't be written, a locked file, a file with more
  than one hard link (the rename would leave the other names on the old bytes), a frame or tag
  past ID3's 256 MB, ID3v2.2, an ID3 tag
  that's unsynchronised or has an extended header or footer, a fragmented MP4, a WAV or AIFF
  whose form is cut off. A WAV whose `LIST/INFO` holds a field the edit clears fails the
  read-back check, since the reader falls back to INFO; INFO isn't edited.
- **Undo journal.** Each edit (one file or a batch) is a folder in `tag-undo` under the data
  directory (Application Support, or `--home`'s folder). Each file adds a small JSON record
  (where the kept ranges went, the original's SHA-256, the edited file's size, mtime and inode)
  and a raw file of the bytes the edit replaced, so a batch appends rather than rewriting, and
  art never goes through JSON. The bytes, the record and the folder are flushed (one
  `F_FULLFSYNC` per record) before the music file is renamed; after the rename the record takes
  the size, mtime and inode the volume reports, in case it rounded or renumbered them. Undo
  refuses a file whose size, mtime or inode no longer match, rebuilds the original through the
  same temp-file write and must match the hash byte for byte. A record also keeps the file's
  size, mtime and inode from before its edit. When undo puts a file back and the file's record
  in an older edit names that identity as what it left, that record takes the restored file's,
  so a file's edits undo one after another; a file changed in between still refuses. The last 50 edits are kept, and
  fewer when they pass 512 MB, though never fewer than the newest. A record with any key or
  value its type doesn't have, or whose bytes file doesn't match it, is deleted and reported.
  A full disk, or a journal that can't be written, stops a batch after that file and reports
  the files not written; a 1000-file batch with 1 MB art each journals in 14 s on Apple Silicon.

**SMB.** Rename over an open file, `F_FULLFSYNC`, `clonefile` and creation dates behave
differently on SMB, and the build Mac never touches the NAS. `clonefile` fails there with
`ENOTSUP`, so writes go whole; `F_FULLFSYNC` falls back to `fsync`. The owner's checkpoint
verifies the rest on copies of NAS files first: the edit reads back in Swinsian and Finder, the
file's Finder tags and permissions survive, `ls -l@` shows no `.tagwrite` file left, an edit
while Swinsian has the file open either succeeds or fails cleanly with the file intact, and undo
still recognises the file, since SMB may round the mtime or report a new file ID on rename.

## Alternatives considered

- **Keep the app read-only and leave tagging to other apps.** Rejected: the owner asked for an
  editor (phase 11).
- **Let any module write, with a review rule.** Rejected: one module is one place to audit, and
  the tier check plus `rg TagWriter` shows every caller.
- **Test writes on copies of NAS files from the build Mac.** Rejected: the build Mac never reads
  the NAS (CLAUDE.local.md). The owner does that at the checkpoint.
- **Write in place.** Rejected: a crash or a full disk mid-write leaves a damaged file, and the
  original can't be compared with the result before it's gone.
- **A dependency (TagLib).** Rejected: no new dependencies, and it doesn't check its own writes.
  AVFoundation's `AVAsset` and `afinfo` serve as the independent readers in the corpus run.
- **Rewrite every tag from scratch.** Rejected: it drops the frames and items the app doesn't
  know, which hold the owner's Discogs data and other players' state.
- **A second set of walkers in the writer, or the reader's made `public`.** Rejected: the writer
  must replace exactly the keys the reader maps onto a field, so it uses the reader's key tables
  and walkers through `package` access, which keeps them out of the public API.
- **Copy the original's mtime too.** Rejected: the scanner rescans on size and mtime, and an edit
  that keeps the size would go unseen.

## Consequences

AGENTS.md's read-only boundary is replaced by this one. A second writer anywhere else is a review
finding. Every edit reads the whole file twice (the original's hash, then the temp file's
payload), which on the NAS costs a few seconds for a large file; the safety is worth it. Undo
restores bytes, not the mtime, so a restored file rescans once. A field whose frame or item holds
several values (an ID3v2.4 text frame, an MP4 item with several `data` atoms, a repeated Vorbis
key) is written back with the one value the editor shows; the editor says so before saving.
