# 0107. Tags that fit the padding are written in place, journaled first

- **Date:** 2026-11-05
- **Status:** accepted
- **Amends:** [0020](0020-tag-writing.md), [0100](0100-get-info-windows-and-smb-temp-files.md)
- **Amended by:** [0108](0108-faster-tag-writes.md): no whole-file hashes, the journal on the
  region, two drive flushes a batch, four writes at once.
- **Amended by:** [0196](0196-faster-whole-file-rewrites.md): a batch's rewrites several at
  once, the original hashed while it's copied.

## Context

Every tag write went through a temp file beside the original, checked and renamed over it
(ADR 0020). On the NAS that is about four transfers of the whole file for a one-word title
edit: the original's hash, the copy (SMB can't clone), and the read-back. ADR 0100 listed
writing in place within the padding as an alternative and left it to the owner, who chose it
(phase 44, part 44e): a save whose new tag fits the file's existing padding overwrites only the
tag's bytes in the original, with the same checks before and the read-back after; one that
doesn't fit uses the temp file as before. Swinsian, for comparison, writes through TagLib 2.0.2,
which always writes in place and shifts the rest of the file when a tag grows.

## Decision

**When.** The format model plans every edit as segments, new bytes and ranges of the old file,
as before (ADR 0020). A plan is written in place when the new file has the original's size and
every kept range stays at its own offset: for FLAC, the metadata blocks before the audio with
the last `PADDING` block taking the size change; for ID3v2 in an MP3, AIFF or WAV, the tag
keeping its declared size with its padding taking the change, so the `ID3 `/`id3 ` chunk and
the `FORM`/`RIFF` sizes are unchanged; for MP4, `moov` rebuilt with a `free` beside `ilst`,
`meta` or `udta`, or the top-level `free` after `moov`, taking the change, so no `mdat` moves
and no chunk offset changes. The region written is from the first byte that differs from the
original to the last, usually the edited frames and the padding after them, and it must not
overlap the audio payload. Anything else, a tag past its padding, a `moov` after `mdat` with no
`free`, goes through the temp file as before.

**Before a byte is written.** The same checks as the temp path, then more:

1. The file and its folder must be writable, unlocked, one link (ADR 0020). The folder has to
   be writable although a write in place doesn't need it, because putting the original back
   after a failure goes through a temp file.
2. One pass over the original hashes the whole file, the audio payload, and the whole file as
   the write will leave it (the planned bytes in place of the region).
3. The planned file is read back before it exists: the reader and the writer's parser read the
   original through a source that substitutes the region, and the tags, audio format, art and
   MP4 chunk offsets must read as meant, the payload in the same place. A plan that wouldn't
   read back, such as clearing a field a WAV's `LIST/INFO` fills in, is refused here, with the
   original not even opened for writing.
4. The journal record and the region's old bytes are written as for any edit, plus the hash the
   file will have once written (`unconfirmedSHA256` in the record) and an empty marker file
   `tag-undo/<entry>.<number>.unconfirmed`. The bytes, the record and the marker are flushed
   with `fsync`, then their folders, then one `F_FULLFSYNC` on the journal folder empties the
   drive's cache, which may write what it holds in any order. Only then is the original opened.
   The same order now applies to every record and every record update: before, the record's
   `F_FULLFSYNC` came before its folder's `fsync`, which left the folder entry in the drive's
   cache.
5. The original is opened for writing without following a link. Its `fstat` must still give the
   device, inode, size and mtime read at the start, with one link, and a `pread` of the region
   must give exactly the old bytes the journal holds. Another process that wrote the file since
   it was read is caught by the mtime, and one that wrote the tag bytes and set the mtime back
   is caught by the bytes. What's left is the moment between that `pread` and the `pwrite`; a
   write there by another process is caught by the read-back.

**The write.** One `pwrite` of the whole region (looped only for a short write), then
`F_FULLFSYNC`, which falls back to `fsync` on volumes without it (SMB, where the flush is sent to
the server), then `close`, whose result is checked, since a network volume may report a failed
write only there. The torn window is that one `pwrite` of a few kilobytes, about 1 ms locally.

**After.** The file is read back from the disk as a temp file was: the reader's tags, audio
format and art and the MP4 chunk offsets as meant, the payload's hash the original's, and now
also the whole file's hash the one the plan predicted, from the same pass. Then the record takes
the file's identity as the volume reports it after the close (ADR 0100), loses its
`unconfirmedSHA256`, and the marker is removed. A record that can't be confirmed is reported
as written with a journal problem; the next call finds its marker and confirms it.

**A failure after the write started**, from the `pwrite`, the flush, the close or the read-back,
puts the original back from the journal before the write reports: if the file already hashes as
the original nothing is written; otherwise it is rebuilt through the temp-file path from the
file's bytes around the region and the journaled old bytes, must hash as the original, and is
renamed over the file. The original is overwritten once per edit; every repair goes through the
checked temp file, so a repair can't tear it again. If the repair fails too (the folder refuses
the temp file, the disk is full), the error says the original isn't back yet, and the record and
marker stay for the next call.

**After a crash.** Every write and undo, and the app at launch on the writes queue, first looks
for markers and finishes each write they name: a file that's gone or no longer has the
original's inode and size is reported and its record dropped, since the old bytes no longer
apply; a file that hashes as the planned file keeps the edit (the write landed, the crash came
before its confirmation), its record taking its identity; a file that hashes as the original is
left and its record dropped (the crash came before the write); any other file was torn and is
put back as above. A torn file whose bytes outside the region changed too is reported and left
as it is. Undo skips a record still unconfirmed, with an error, rather than treat it as changed
since. Crash recovery is the only write the app makes without a Save in that moment, and it
only finishes or takes back an edit the user confirmed, through the same module.

**Undo** of an edit written in place is unchanged: its record puts the original together from
the edited file and the old bytes, through the temp file, checked by hash.

**What this does to ADR 0020's guarantee.** ADR 0020 promised that a failure at any step leaves
the original as it was, because the original was never written until a checked copy replaced it
whole. For a write in place that is no longer true. For about a millisecond the original holds
part of the old tag and part of the new one, and a crash, a power cut or a dropped share in that
moment leaves the original damaged on the disk. The audio bytes are never written, so the
damage is confined to the tag region, and the journal holds the old bytes flushed to the disk
before the write, so the next launch, write or undo puts the original back byte for byte. What
is lost is the guarantee that the file on the disk is always whole without the journal: until
recovery runs, another app (Swinsian, Finder, a scan) can read the torn tag, and if the journal
is lost with the crash (another disk failing, the data directory deleted), the damage stays. A
failure that isn't a crash, a refused write, a failed read-back, is put right before the write
reports, as before; the difference is that the original was touched first and is put back
rather than never touched. On the NAS the window also covers the server: the `pwrite` reaches
the server's cache, the flush asks it to write it, and what the NAS does after a power cut is
the NAS's.

## Alternatives considered

- **Keep the temp file for every write** — rejected by the owner: on the NAS it costs about four
  transfers of the file for a few kilobytes of tag.
- **Write in place always, shifting the rest of the file when the tag grows, as TagLib does** —
  rejected: it rewrites the audio in place, so a crash damages audio, which the journal doesn't
  hold.
- **Journal the new bytes and roll a torn write forward** — rejected: rolling back to the
  original needs only the old bytes, which undo keeps anyway, and a torn write is one whose
  read-back never passed.
- **Mark the record unconfirmed without a marker file, and find it by reading every record** —
  rejected: the journal holds up to 50 edits of a thousand files each, which every write would
  read.
- **Put the original back by overwriting the region again** — rejected: a crash during the
  repair would tear it again; the temp file's rename is whole.
- **Lock the file while writing (`O_EXLOCK`, SMB deny modes)** — not done: locks on macOS are
  advisory for other apps locally, and on SMB a deny mode would fail every write while Swinsian
  plays the file. The `pread` of the old bytes and the read-back catch what a lock would.
- **Skip the read-back, since the plan was read back before the write** — rejected: the owner
  asked for it, and it's what shows the server stored the bytes; it costs one pass over the
  file, the same pass that compares the payload's hash.

## Consequences

- A tag edit that fits reads the file twice (the hash and the read-back) and writes a few
  kilobytes, instead of reading it three times and writing it once. Undo still writes the whole
  file through the temp file.
- The file keeps its inode, creation date, extended attributes, ACL and permissions without
  copying them; a hard-linked file is still refused, for the temp-file repair.
- A crash during the `pwrite` leaves a torn tag until the next launch, write or undo.
- The corpus run (`scripts/tag-corpus`) injects a crash one byte into a write in place for each
  container and checks recovery puts the clone back. The 61 corpus MP4s with `moov` after
  `mdat` and no padding still take the temp file (ADR 0020's survey).
- Bench (Apple Silicon, fixture FLAC on APFS, median of 5): a title written in place and read
  back into the index 14.8 to 15.8 ms (the write 12.3 to 13.2 ms) against 12.7 to 13.1 ms
  (the write 9.9 to 10.5 ms) through the temp file. Locally the temp file is an APFS clone and
  costs nothing to copy, so the write in place is slower by its extra flushes (the marker, the
  file, the confirmation) and the third hash. The saving is on the NAS, where the clone isn't
  available: two passes over the file instead of four, which the build Mac can't measure. A
  1000-file journal batch with 1 MB art each is 5.6 to 6.4 s.
