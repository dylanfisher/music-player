# 0108. Faster tag writes: the region only, two flushes a batch, more room

- **Date:** 2026-11-06
- **Status:** accepted
- **Amends:** [0020](0020-tag-writing.md), [0107](0107-tags-written-in-place-within-the-padding.md)

## Context

The owner reported saving tags as very slow, worst with several tracks selected, and asked
for edits in place as Swinsian makes them, without risking the files (phase 47). ADR 0107
already wrote a tag that fits its padding in place, but each such save still read the whole
file twice to hash it: before, the file as it was and as it would be; after, the file again.
Swinsian (TagLib) reads the header and writes a few kilobytes. A 40 MB FLAC takes about 0.7 s
over gigabit and 2 to 3 s over Wi-Fi, so a hi-res album over Wi-Fi took minutes. Each file
also flushed the drive's cache three times (its record, its write, its confirmation), listed
its folder for leftover temp files, and was read once more by the rescan after the save. A
save past the padding went through the temp file, about four passes over the file, and left
only 2,048 bytes of room, so the next edit that grew the tag went that way again.

## Decision

**No whole-file hashes in place.** A write in place changes only its region, and the plan
already refuses a region that overlaps the audio, so hashing bytes the write never touches
proves nothing about it. Before the write the checks stay as ADR 0107 has them: the identity,
the planned file read back through `PlannedSource`, then `fstat` and a `pread` of the region
against the journaled old bytes. After it the file is opened again through `FileSource`,
which sets `F_NOCACHE`, so an SMB client can't answer from its cache; the file must have the
planned size and its region the new bytes, and the reader and the writer's parser must read
its tags, format, art, chunk offsets and audio ranges as meant. All of that reads about as
much as the tag.

**The journal keys on the region.** A record holds either `originalSHA256`, the whole
original's hash, for a write through the temp file as before, or `inPlace`: the region's
offset, the SHA-256 of its old bytes (which the bytes file holds) and the length and SHA-256
of its new bytes. The marker alone says a write in place is unconfirmed; the record no longer
carries a hash for it. Recovery reads the region: the new bytes at the new size keep the edit,
the old bytes at the original's size drop the record, anything else is torn and put back.
Undo checks the journaled bytes against their hash before writing, and the restored temp
file's size and region after.

**A failed write in place is put back over itself.** A torn write, or one whose read-back
failed, gets its journaled old bytes back over the region with `pwrite`, a file that grew is
cut back with `ftruncate`, then `F_FULLFSYNC`, all on one descriptor whose inode, link count
and size (from the original's to what the write leaves) must still be the original's. A file
something else put at the path is left alone. ADR 0107 rejected this for the temp file, since
a crash during the repair would tear the file again; but the record and its marker stay until
the region reads back as the old bytes, so such a crash is put back again by the next call,
and the temp file needs as much free space as the file, which a growth that filled the disk
doesn't leave.

**Two flushes a batch.** A batch reads and plans its files first, a chunk of up to 32 files
or 64 MB of tag bytes at a time, so a thousand-file art change doesn't hold every plan. For
the chunk's in-place files it writes every old-bytes file, record and marker with an `fsync`
each, their folders, then one `F_FULLFSYNC`; then each file's write with an `fsync`, which on
SMB is what sends the flush to the server; then one `F_FULLFSYNC` per volume written; then
each record's confirmation with no drive flush. A 20-track album goes from about 60 drive
flushes to 2. The per-file markers still cover a crash at any step: a crash before the writes
leaves files whose region holds the old bytes, so recovery drops their records; a crash during
them leaves torn files that recovery puts back; a crash after leaves new bytes that recovery
confirms. A power cut that keeps a marker's removal and loses the record update leaves a
record with the original's identity, which undo refuses as changed since rather than
misapplying. Files that don't fit go through the temp file when they're reached, each with
its own flush, as before.

**More room.** One function gives a rewrite's padding for FLAC, ID3 and MP4: 64 KiB, or as
much again as the new tag when that's more, so lyrics, a small cover, or a cover up to twice
the size of the one there fit the next edit. A file of 4 MB with a 1 MB cover grows by 1 MB the
one time its tag is rewritten. An MP3 with no padding takes the slow path once instead of
every time.

**MP4 growing at its end.** An MP4 whose `moov` is the last atom grows in place by writing
past its end: no `mdat` moves and no chunk offset changes. A plan may now grow the file when
every kept range stays at its offset; the region runs to the new end, `PlannedSource` serves
the bytes past the old one, and recovery and undo take any size from the original's to the
new one, cutting a torn file back. ADR 0020's survey has all 61 corpus MP4s with `moov` after
`mdat` ending in `moov`, with only an 8-byte `free` before `mdat`, so all 61 now save in place;
the layout notes "moov last" so the corpus run can count them. A file that grows with a
header before its audio, as an AIFF whose `FORM` size changes, still uses the temp file.

**Four at once.** A chunk's writes and read-backs run four at a time, each on a thread of its
own, since SMB is bound by round trips and the work blocks on the network. Each touches only
its own file; the journal steps before and after stay one at a time.

**Less bookkeeping.** A batch, an undo and recovery list each folder once for the temp files
a crash left, not once per file. The report carries each written file's read-back parse,
stamped with the file's size and mtime from right after its write, and
`LibraryScanner.rescan(files:parsed:)` stores it instead of reading the file again while a
fresh stat still matches the stamp; a file another app changed in between is read again. A
path named twice in a batch is written once.

**Progress.** The writer reports each file read and each written; Get Info's saves show
"Saving tags: 3 of 20" on the status bar's scan line, the bar filling as files are read and
then written.

**Server-side copy, a probe.** `scripts/smb-copy-probe.swift` finds out whether macOS copies
a file on the owner's NAS without the bytes crossing the network (`clonefile`, `copyfile` with
`COPYFILE_CLONE_FORCE` or `COPYFILE_DATA`). No agent or test touches the NAS, so the owner runs
it on a scratch folder there. macOS copies whole files only, so even if it works it helps only
where the kept ranges stay at their offsets: undo and the put-back of a write in place, which
`writeTemp` would then make without moving the audio. A tag that grows at the front of the
file still has to move the audio. Until the owner reports, the temp-file path is unchanged.

## Alternatives considered

- **Keep the whole-file hash after the write, as the server's proof** — rejected: the region
  read back uncached and the tags parsed from it show what the server stored for the bytes
  written; the rest of the file was never sent.
- **Journal per file as before, only skip the hashes** — rejected: on the local disk each
  `F_FULLFSYNC` costs about a millisecond and on a batch they add up; the markers cover a crash
  between the steps either way.
- **A fixed 16 KiB of padding** — rejected: it holds lyrics but not a cover, and the owner
  asked for adding art to fit.
- **Write four at once only on network volumes** — not done: four at once costs nothing on
  the local disk, and one rule is simpler than two.
- **Hand the rescan the writer's tags only, not the parse** — rejected: the scanner stores the
  parse's warnings and format with the tags, and the parse is what it would have read.

## Consequences

- What recovery no longer sees: a torn file whose bytes outside the region changed since,
  which the whole-file hash caught (ADR 0107). The write never touches those bytes, so only
  another app could have changed them, and the put-back keeps that change.
- A file written in place is read about as much as its tag. On the slow simulated NAS (10 ms
  a file system call, 57 MB/s on one link), 20 FLACs of 40 MB in one batch save in place in
  4.3 s against 42.8 s before, 2 MB over the link against 1,602 MB; through the temp file they
  take 74 s, as before. On this Mac's disk the batch in place takes 0.04 s against 1.56 s.
- A save through the temp file leaves 64 KiB or the tag's size as padding, so files grow by
  that much the first time.
- The temp-file path is otherwise unchanged: on the NAS it still reads the file to hash it,
  copies it, and reads the copy back.
