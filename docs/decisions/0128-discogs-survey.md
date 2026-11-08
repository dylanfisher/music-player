# 0128. What the owner's Discogs tags look like, and agents reading the library to find out

- **Date:** 2026-11-07
- **Status:** accepted; amended 2026-11-07 (51f): the layout is a test fixture, not a preset
- **Amends:** [0020](0020-tag-writing.md) (no test or tool touches a real library)

## Context

Phase 51's Discogs tagger has to write tags the way the owner's matched albums already carry
them: YATE's Discogs Wizard tagged them, and the owner's own templates put genre, styles and
label where they like them. The plan's sample (2026-11-07) described them from a few FLAC
albums; the mapping's "Like my library" preset (51.10) needs the whole library, every format.
AGENTS.md said no test or tool touches a real library or the NAS. The owner decided on
2026-11-07 that agents may read the real library, read only, for three parts of phase 51:
51.1's survey, 51.8's tuning of the matcher on the matched albums, and 51.13's budgets.

## Decision

**The exception.** For 51.1, 51.8 and 51.13 an agent may read the watched folders
(`library.watchedFolders` in `config.json`: `/Volumes/music/library` and `/Volumes/music/dsd`
on the owner's Macs) and the Discogs dumps folder. It opens files read only, never writes,
renames or moves anything there, and writes its reports under `.build/` in its worktree.
AGENTS.md's music files line names this ADR.

**The survey.** `TagCorpus --discogs-survey <folder>…` (`./scripts/tag-corpus` passes it
through) walks the folders by the scanner's extensions and reads each file once, through
`FileSource`, which opens it `O_RDONLY`. Each file is a JSON line in
`.build/discogs-survey/files.jsonl`, so a run that stops resumes at the next file; the report,
`report.txt` beside it, is folded from the lines. Every write is checked to be inside that
folder and outside `/Volumes`. A folder that is missing, or one inside it that can't be listed,
fails the run rather than surveying part of the library. An album is the library's: album title
plus album artist, else artist.

**What it found** (run 2026-11-07, 43,384 files, 6,676 albums, none unreadable, 7 minutes over
SMB at 100 files a second):

| | Files | Albums | Every track one release id | Several ids | Some tracks | None |
|---|---|---|---|---|---|---|
| All | 43,384 | 6,676 | 1,741 | 4 | 26 | 4,905 |
| MP4 | 17,605 | 1,746 | 1,176 | 3 | 14 | 553 |
| MP3 | 23,679 | 4,695 | 411 | 1 | 4 | 4,279 |
| FLAC | 1,005 | 95 | 88 | 0 | 2 | 5 |
| AIFF | 1,017 | 157 | 78 | 0 | 2 | 77 |
| DSF | 53 | 5 | 0 | 0 | 0 | 5 |
| WAV | 25 | 3 | 0 | 0 | 0 | 3 |

15,842 files carry `DISCOGS_RELEASE_ID`, every one of them all digits. The conventions below
are measured on those files. Of the 27,542 without it, 2,227 have a `GENRE` of the same shape
and 518 a `GROUPING`; the rest have plain genres such as `Dub Techno`.

**YATE's keys, by format.** Album-level keys are constant within 97–99% of the albums that
carry them; `DISCOGS_ARTIST_LIST` and `DISCOGS_ARTIST_URL` vary in about 8%, where track
artists differ. Per track: the ordinal position and the track number text.

| Field | FLAC (Vorbis) | MP4 (`----:com.apple.iTunes:`) | MP3, AIFF (ID3) |
|---|---|---|---|
| Release id | `DISCOGS_RELEASE_ID` | `DISCOGS_RELEASE_ID` | `TXXX:DISCOGS_RELEASE_ID` |
| Master id, as `m` and digits; absent for a release without a master (12,300 of 15,842 have one) | `DISCOGS_MASTER_ID` | `DISCOGS_MASTER_ID` | `TXXX:DISCOGS_MASTER_ID` |
| First label's catalog number, as `Label: catno` | `DISCOGS_CATALOG_NUMBER` | `DISCOGS_CATALOG_NUMBER` | `TXXX:DISCOGS_CATALOG_NUMBER` |
| The other labels' | `DISCOGS CATALOG NUMBER-2` … `-6` | `DISCOGS_CATALOG_NUMBER-2` or `Discogs Catalog Number-2` … `-7` | as MP4 |
| Artists, canonical names, `;;;` between | `DISCOGS_ARTIST_LIST` | `DISCOGS_ARTIST_LIST` | `TXXX:DISCOGS_ARTIST_LIST` |
| ANVs, `canonical=ANV`, `;;;` between | `DISCOGS_ANV_LIST` | `DISCOGS_ANV_LIST` | `TXXX:DISCOGS_ANV_LIST` |
| Import settings, always `.5555555555555555555551` | `DISCOGS_IMPORT_SETTINGS` | `DISCOGS_IMPORT_SETTINGS` | `TXXX:DISCOGS_IMPORT_SETTINGS` |
| Position in the release's tracklist | `DISCOGS_RELEASE_ORDINAL_POSITION` | `Discogs Release Ordinal Position` | `TXXX:Discogs Release Ordinal Position` |
| Position as Discogs writes it (`A1`, `2`) | `TRACK_NUMBER_TEXT` | `Track Number Text` | `TXXX:Track Number Text` |
| Release country | `DISCOGS_ALBUM_RELEASECOUNTRY` and `COUNTRY` | `Discogs Album Release Country` and `Country` | as MP4 |
| Release notes | `DISCOGS_RELEASE_NOTES` | `Discogs Release Notes` | as MP4 |
| Release, master, artist, album artist, label and artwork URLs (`-2`… for each further one) | `DISCOGS_RELEASE_URL` and so on | `DISCOGS_RELEASE_URL` and so on | `WXXX` frames, read as `WXXX:<name>` (ADR 0129) |
| Credits | `INVOLVEDPEOPLE` (`Name (Role)`), `PRODUCER`, `PERFORMER` | `INVOLVEDPEOPLE` (`Role;;;Name,Name`), `PRODUCER`, `MUSICIANCREDITS` (`Role;;;Name`) | `TIPL` frames, read as `TIPL` (ADR 0129) |

Key names are compared uppercased when read (ADR 0129); the table spells them as the files do.

**The owner's layout**, a test fixture since 51f; the shipped YATE preset takes its keys and
spellings but not its `GENRE` and `GROUPING` (ADR 0132):

- `GENRE` is `{genre} - {styles}`: the first Discogs genre, " - ", then the styles joined with
  ", " (15,761 of 15,842 files), as `Electronic - Dub Techno, House, Techno, Minimal`. With no
  styles it is `{genre} - ` (591 files). Discogs genre names hold commas themselves
  (`Folk, World, & Country`, 390 files), so the genre is everything before the first " - ".
- `MOOD` is `{styles}`, joined with ", " (15,163 of the 15,216 files that have one).
- `GROUPING` is `LABEL` (15,771 of 15,789).
- `LABEL` is every label of the release, Discogs's order, joined with " & ", repeats kept
  (`Columbia & Columbia`; 2,187 files have more than one). `CATALOGNUMBER` is the first label's
  catalog number.
- `ARTIST` and `ALBUMARTIST` use canonical names, not ANVs (1,926 of 2,016 ANV pairs; none use
  the ANV), with Discogs's `(2)` suffix dropped (no file has one; 31 canonical names in
  `DISCOGS_ANV_LIST` do), joined with Discogs's join words (`Alice Coltrane Featuring Pharoah
  Sanders`, `Benedek , Tom Noble`).
- `ALBUM` is Discogs's title as written, with no year added.
- `DATE` is the release date as Discogs has it: `YYYY-MM-DD` (10,421 files) or `YYYY` (5,260).
- `MEDIA` is the format and its descriptions, `{format} ({descriptions joined with ","})`, or
  the format alone without descriptions: `CD (Album)`, `File (FLAC,Album)`, `Vinyl (LP,Album)`,
  `CD`.
- In ID3, grouping is `GRP1`, mood `TMOO`, label `TPUB` and media `TMED`; in MP4 they are
  `©grp` and freeform `MOOD`, `LABEL`, `MEDIA` and `CATALOGNUMBER`, where the reader and the
  writer already put them.

**Where the plan's sample was wrong:**

- The sample was "400 random FLAC albums, 90 with a release id". The library has 95 FLAC
  albums (1,005 files), 88 matched; most matched albums are MP4 (1,176) and MP3 (411).
- The doubled styles are a second " - " and the styles again
  (`Electronic - Ambient, Abstract - Ambient, Abstract`, 240 files, sometimes three times), not
  the style list given twice. `MOOD` never repeats.
- `DISCOGS_RELEASE_ORDINAL_POSITION` and `TRACK_NUMBER_TEXT` are FLAC's spellings. MP4 and ID3
  spell those, the release country and the notes in title case with spaces.
- MP3 has no `DISCOGS_*_URL` keys a reader of `TXXX` finds: YATE writes them as `WXXX` frames.
- `LABEL` can hold several labels joined with " & ", and `GROUPING` copies the whole of it.

Other taggers' keys are in the report too: Picard's `MUSICBRAINZ_*`, and a Discogs plugin's
`DISCOGS_LABEL`, `DISCOGS_COUNTRY`, `DISCOGS_RATING` and the like on 3 FLAC and a few MP3 albums,
which the tagger leaves alone.

## Alternatives considered

- **Taking the plan's FLAC sample as the layout.** Rejected: FLAC is 6% of the matched
  albums, and its key names differ from MP4's and ID3's.
- **Surveying a copy of the library.** Rejected: 43k files on the NAS, and a copy shows nothing
  a read-only pass doesn't.
- **Reading through the library index.** Rejected: the index keeps the fields the browser
  shows, not custom keys; only the two Discogs ids join it (ADR 0129).
- **One pass with no saved lines.** Rejected: a stopped run over SMB would start again.

## Consequences

51.10's preset can be built from the tables above, and 51.8's tuning can run over the 1,741
matched albums. Writing a URL field or the credits to an MP3 needed `WXXX` and `TIPL` support
in the reader and the writer, which 51d added (ADR 0129). A
later run of the survey reads only the paths `files.jsonl` doesn't hold yet; to read changed
files again, delete it. The exception covers only the three parts named; any other read of the real library needs the
owner again.
