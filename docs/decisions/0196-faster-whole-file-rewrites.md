# 0196. Faster whole-file rewrites: several at once, hashed while copied

- **Date:** 2026-11-10
- **Status:** accepted
- **Amends:** [0107](0107-tags-written-in-place-within-the-padding.md),
  [0108](0108-faster-tag-writes.md)

## Context

The owner ran a Discogs tagger Apply with covers over 15,435 files on the NAS. Its undo journal
showed 8,104 of the first 14,376 files (56%) rewritten through the temp file, since the new
cover didn't fit the tag's padding: 169 GB of originals at about 75 files a minute, or about
15 MB/s of audio. ADR 0108 made writes in place cheap and left this path as it was. A rewrite
ran inside the batch's loop, one file at a time, and read the original about three times: a
pass of its own to hash it, the copy into the temp file, and the temp file's read-back. Only a
chunk's writes in place ran four at a time.

## Decision

**Hash while copying.** `writeTemp` hashes the original, whole and its audio payload, from the
descriptor it copies from, whose identity it checked, instead of `fileHashes` opening the file
by path and reading it first. When the kept ranges are in the original's order, as every FLAC,
ID3 and MP4 rewrite builds them, it hashes each 4 MB block it copies and `pread`s the bytes
between and after them, the old tags, only to hash them. When the temp file is an APFS clone,
which copies nothing, or the ranges aren't in order, it reads that descriptor once to hash it.
A file that ends before its identity's size fails as changed during the write. The read-back
still hashes the temp file's payload against the original's, the record still carries
`originalSHA256` for undo, and a file another app changes during the copy is still caught by
the identity checks before the rename. One `FileHasher` feeds both digests for the copy and for
`fileHashes`, so the payload's overlap with each block is computed in one place.

**Several rewrites at once.** The batch still reads and plans its files in order. A file that
doesn't fit comes back from `prepare` as a `RewriteJob`, with the old bytes its undo needs
already read, and runs on a thread of its own; at most `rewritesAtOnce` are in flight, and the
loop waits for a free slot before it hands over the next. That is
`max(writesAtOnce, min(filesReadAtOnce, 8))`: 4 on the 2015 MacBook Pro, whose two cores give
`filesReadAtOnce` 3 (ADR 0074), up to 8 on a larger Mac. Each holds a 4 MB copy buffer, a 4 MB
read-back buffer and its tag bytes, so eight with covers of a few MB stay near 100 MB.

Each rewrite keeps ADR 0107's order for its own file: the temp file written and read back, its
record and old bytes, the rename, the record brought up to the renamed file. It touches only
its own file and temp file. Its journal calls go through one lock, so appends stay one at a
time, and a chunk of writes in place waits for the rewrites under way before its own journal
steps, so the two never run beside each other. Results go into the batch's array by index, so
the report lists files in the batch's order.

A rewrite that stops the batch, on a full disk or a journal that can't be written, sets a flag.
The loop starts no new file, and a slot that comes free after the flag isn't used. The
rewrites under way finish or are put back as one rewrite is today, and a chunk already read is
still written, as today's chunk before a stopping file was. Every file without a result is
reported not written.

## Alternatives considered

- **Hash the old tag bytes from the journal's copy instead of reading them again** — rejected:
  `restoreSegments` reads them through the parser's source, opened by path; hashing what the
  checked descriptor reads keeps the hash about the file the copy came from, for a few hundred
  KB more per file.
- **Lock every journal call, writes in place included, and let chunks run beside rewrites** —
  rejected for now: it touches every journal step of ADR 0108's chunk, and the wait it saves
  is a few rewrites every 32 files written in place.
- **Number records in the batch's order** — rejected: it would make each append wait for every
  earlier file's, and a slow file would hold up the rest. Undo restores each file on its own, so
  only the order of its report changes.
- **Plan files concurrently too** — not done here: planning reads only the tags, and the copy
  is what takes the time.

## Consequences

- On the slow simulated NAS (10 ms a call, 57 MB/s on one link), a 2 MB cover saved to 20
  FLACs of 40 MB, every file rewritten, takes 47.5 s against 81.4 s, with 2,682 MB over the
  link against 3,482 MB and 1,581 calls against 1,821. The link is the limit there: on the real
  NAS, whose reads and writes don't share one link, the owner's next large change shows the
  files a minute.
- An undo of a batch with several rewrites reports them in the order their records were
  appended, not the reverse of the batch's.
- A journal failure in one rewrite no longer stops the files after it that are already in
  flight; they finish, and only the files not yet started are left unwritten.
