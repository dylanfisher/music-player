# 0151. A scan whose listings repeat a file removes nothing

- **Date:** 2026-11-08
- **Status:** accepted
- **Amends:** [0009](0009-scanning-and-watching.md) (what a whole scan removes)

## Context

On 8 Nov at 16:44 the launch scan of `/Volumes/music/library`, which holds about 43,400 audio
files, reported "0 read, 165,511 unchanged, 20,140 removed, 624 moved, 0 issues". The listings
the share returned gave the walk many files several times over and left out most folders from
M on, with no error. The scan took every file it hadn't seen as deleted and removed it from the
index, with its plays, ratings and playlist entries, then matched 624 moves among what was
left and pushed them to the sync folder. The music files were untouched.

The scan already removed nothing when the root went missing, vanished or listed nothing, but
nothing checked that the listings were whole. Read-only walks of the share afterwards, three
one directory at a time and three with four listers at once as the scan lists, each found 9,613
folders and 43,344 files, none twice, so the bad listing couldn't be made to happen again.

## Decision

- **The walk counts a file it was given before as listed twice,** and doesn't count it as
  unchanged or read it again. The first such path and the count go in the outcome.
- **A whole or subtree scan with any file listed twice removes nothing and matches no moves,**
  as for a vanished root. It reports a `listedTwice` issue on the folder, which the problems
  list shows, and logs an error. A whole scan doesn't record its start, so the folder is scanned
  again at the next launch (ADR 0149).
- **A repeated file is the signal, not a count of removals.** A real deletion of half a folder
  is the owner's to make, and a threshold would either hold it or let a bad listing through. A
  repeat is never right: a directory can't hold two entries with one name.

## Alternatives considered

- **Ask before removing more than a share of a folder.** Not done now: it would also stop a
  real large deletion, and the repeat already catches the listing seen here. It stays an option
  if a bad listing ever leaves files out without repeating any.
- **List each directory twice and compare.** Rejected: it doubles a walk of the NAS, about 40 s
  each, to catch a fault seen once.

## Consequences

- A volume that repeats files in its listings keeps every indexed file from that folder until a
  scan sees each file once. Files really deleted in the meantime stay listed and fail when
  played.
- A listing that leaves files out without repeating any still removes them.
