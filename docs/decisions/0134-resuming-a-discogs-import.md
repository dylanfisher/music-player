# 0134. A Discogs import resumes from its last checkpoint

- **Date:** 2026-11-07
- **Status:** accepted
- **Amends:** [0130](0130-discogs-catalog.md) (the import's transactions and journal, the
  title keys)

## Context

The first real import of the 2026-11-01 dump trapped at 76% of the releases, on a duration
too long for an `Int`, and started over: the import writes `<catalog>.importing` and removed it
on any failure, and a trap removes nothing but leaves nothing usable either. A whole import
takes 1,530 s on this Mac and makes a 35.89 GB catalog. The owner asked on 2026-11-07 that an
import stopped, quit or killed carries on where it was (phase 51e), and chose this round to add
the artists' name variations to the title keys, as the catalog is imported again anyway.

## Decision

### The checkpoint

`import_checkpoint` holds one row: a JSON object and its SHA-256. It has the dump date and
each file's checksum from the set, the schema the file was built with, the set's size, the
files finished and their compressed bytes, the records committed by dump, and, inside the file
being read, where to start: the inflated offset and line of the next record, and a zlib access
point before it. The access point, after zlib's `zran.c`, is a deflate block boundary: the
compressed bytes before it, the bits of the last of them still to read, the 32 KB window
(`inflateGetDictionary`), the member's CRC-32 and inflated size so far, and the bytes of the
`CC_SHA256_CTX` over the compressed bytes. CryptoKit's hash can't be saved, so the hash is
CommonCrypto's; it now covers the bytes inflate has taken rather than the bytes read, so its
state matches the access point exactly.

The rows are committed only with a checkpoint, in the same transaction: one transaction from
each checkpoint to the next, so the rows always match the checkpoint a resume starts from. A
checkpoint is taken about every GiB of compressed input (about two minutes here, a dozen in
the real import), at the end of each file once its hash matched, and when the import is
stopped. The stream asks inflate to stop at block boundaries (`Z_BLOCK`) once a point is due,
and `DumpBatches` reads in 32 KB steps until a record ends past it, cutting the batch there.
A point just past a gzip header is passed over for the block's end, so a read stops after some
bytes.

### The journal

The catalog keeps its journal on disk, not in memory, and still skips the syncs. A killed
process leaves the journal, and the next connection to open the file rolls the open
transaction back, so the file holds exactly the last checkpoint's rows. WAL would write every
page twice. The journal holds only the pages a transaction changes that were there before it,
which are few while rows are appended. A power cut can still leave a damaged file: that case
is not covered: a resume then fails on it and removes it, and the next import starts over. `Database(rollbackJournalAt:)` opens
such a file.

### Resuming

An import of a set looks for `<catalog>.importing`:

- With a checkpoint that matches its hash and is of the same dump date, checksums, size and
  schema, it carries on. In the file being read it opens the gzip file at the access point:
  raw inflate (`-15`), the remaining bits fed with `inflatePrime`, the window with
  `inflateSetDictionary`, the hash state restored, and the member's trailer checked against
  the saved CRC and size, since raw inflate doesn't check it. It drops the bytes between the
  access point and the record, and parses on. Finished files are skipped. The hash still
  covers every byte, and the swap is unchanged.
- With a checkpoint that says the indexes are built, the import was killed between its last
  commit and the swap: it is synced and swapped in.
- Of another set or build, damaged, without a checkpoint, or not a database: it is removed and
  the import starts over. So does Start Over, and the tool's `--start-over`.

A stop by cancelling the task waits for the next access point, at most one deflate block and
a record on, commits a checkpoint there and throws `stopped`; the parser no longer checks for
a stop itself. A stop, and a failure to read the dumps (a share disconnected), keep the
unfinished catalog; any other failure removes it, as a resume would hit it again.

The writer's JSON has sorted keys, so a resumed import writes the bytes an import straight
through does; the tests compare every row of every table.

### The window and the tool

After a stop, a quit or a crash the window says which dump's import stopped and how far it got,
and offers Resume Import and Start Over, both from the dumps folder. `DiscogsImport` carries an
unfinished import on by default, prints a line at each stage and checkpoint, and for the tests
takes `--checkpoint-bytes` and `--crash-at <stage>`, which kills it with SIGKILL at the first
report after a checkpoint in that stage. A connection opened on the old catalog before a swap
now reads on in the file it opened, or gets an I/O error from the system SQLite; callers open
the new one after an import either way.

### The schema and the title keys

`import_checkpoint` is part of the schema, so a catalog from an older build is refused as built
by another version and the window offers the import. A finished catalog keeps its last
checkpoint, with the record counts.

`title_keys` also holds each master's and master-less release's artists by their name
variations (ANVs), folded as names are, and for a release of a master the ANVs its master
doesn't print, keyed to the master: an album tagged with the name a release prints is found by
its title, not only by its barcode or catalog number. The fixture catalog grew from 43.2 MB to
47.9 MB; its synthetic releases all credit an ANV, which real ones mostly don't.

### Fuzzing

The fuzzer's `discogs-dump` target runs a batch of any dump's records through `DumpParser`, as
`DumpBatches` hands it one, so a record that traps is found on fixtures: Swift can't catch a
trap.

### Costs

On the 20,000-release fixture: 1.67 s straight through (1.56 s before), 1.82 s stopped past
halfway and resumed, and about 83 ms a checkpoint, mostly the parser waiting for the writer to
commit what it has; the real import's dozen add about a second to 1,530 s.

Rejected:

- Committing every batch, as before, and deleting the rows past the checkpoint on a resume:
  the key tables have no key to find them by, and the dumps aren't guaranteed in id order.
- A checkpoint file beside the catalog: it can't be committed with the rows it covers.
- Checkpointing only at file ends: the releases are 11.4 GB of the 12.6.
- Unpacking the dumps to disk to seek in them: 51b reads each gzip once, in place on the NAS.
