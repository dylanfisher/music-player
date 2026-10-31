# 0020. Write tags only through TagWriter, checked on a temp file, tested on clones

- **Date:** 2026-10-31
- **Status:** accepted

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

## Alternatives considered

- **Keep the app read-only and leave tagging to other apps.** Rejected: the owner asked for an
  editor (phase 11).
- **Let any module write, with a review rule.** Rejected: one module is one place to audit, and
  the tier check plus `rg TagWriter` shows every caller.
- **Test writes on copies of NAS files from the build Mac.** Rejected: the build Mac never reads
  the NAS (CLAUDE.local.md). The owner does that at the checkpoint.

## Consequences

AGENTS.md's read-only boundary is replaced by this one. A second writer anywhere else is a review
finding.
