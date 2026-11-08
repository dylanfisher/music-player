# 0132. The Discogs field mapping, its presets, and the changes it works out

- **Date:** 2026-11-07
- **Status:** accepted; amended 2026-11-07 (51f): the shipped presets and styles to `MOOD`
  only
- **See also:** [0003](0003-settings-schema.md) (the settings schema), [0128](0128-discogs-survey.md)
  (the owner's layout and YATE's keys), [0129](0129-custom-tag-fields.md) (custom keys, `WXXX`
  and `TIPL`), [0131](0131-discogs-matching.md) (the match a mapping is applied to)

## Context

Phase 51's tagger writes a matched release's data to an album's files. The owner decided on
2026-11-07 that which tags are written is a YATE-style mapping the user edits, one to one by
default, set once and used for every album, with per-field replace or fill-empty, and that his
own layout is a preset. YATE spells some keys differently in FLAC, MP4 and ID3, and writes URLs
and credits to ID3 as `WXXX` and `TIPL` (ADR 0128). The window's View Changes sheet and Apply to
All need, per file and tag, what the file holds now against what would be written, before
anything is.

## Decision

### The fields

The fields are YATE's Release screen's, limited to what the catalog keeps (ADR 0130). Release
fields: release and master ids and URLs, album, album artist and their URLs, label and label
URLs, catalog number, every label's catalog number (`Label: catno`), barcode, country, date,
genres, styles, media (`CD (Album)`, as the tie-break reads it), compilation (the release's
artist is Various) and disc count. Track fields: title, artist, artist list, name variations
(`canonical=ANV`), artist URLs, track and disc numbers, the track count of its disc, the
position as Discogs writes it, the ordinal position (counted from 0, as YATE's is), the heading
over it as the disc subtitle, and the credits. A track's artists are its own, else the
release's. Its credits are its own and the release's that name no tracks or name it ("A1 to
B2, C1"). Composer (Composed By, Written-By, Music By, Songwriter), lyricist (Lyrics By, Words
By), conductor, remixer (Remix) and producer take their roles, whatever their notes in
brackets; the involved people take every other role. A disc is the number before a dash in
"CD2-4" or "2-4" when every track has one; otherwise the album is one disc, vinyl sides
included.

Not in the catalog, so not fields: artwork and its URL, release notes, community counts, prices,
series, companies (so copyright), video URLs, and YATE's musician credits, whose split of
performers from other credits YATE doesn't document. `DISCOGS_IMPORT_SETTINGS` is YATE's state,
not the release's, and is left alone.

### A rule per field

Each field has a rule: a mode, targets and a format.

- **Mode:** replace, fill empty only, or off. A field Discogs has no value for leaves its tags
  as they are in either mode: the mapping never clears a tag because a release lacks the data.
  The one removal is a numbered key past the release's values (`DISCOGS_LABEL_URL-3` when the
  release has two labels), left by another release.
- **Targets:** a field the tag editor knows (`TagEditField`), the same in every format, or a
  custom key spelled per tag format (Vorbis, MP4, ID3), and any number of them. A numbered key
  gives each value of a list its own key: the first to the key, the rest to a second spelling
  and "-2", "-3", as YATE writes several labels' catalog numbers (FLAC's further ones are
  `DISCOGS CATALOG NUMBER-2`, with spaces).
- **Format,** each part optional: the join between values; canonical names or the release's
  ANVs; Discogs's "(2)" kept or dropped, for artists and labels; the date in full or as its year;
  a template, whose tokens are the fields' names in braces plus `{genre}` for the first genre;
  and the credit style per format, `Name (Role)` or `Role;;;Name,Name`. Artists without a join
  get Discogs's join words with a space each side, as YATE writes `Benedek , Tom Noble`.

A date Discogs knows only in part (`1965-01-00`) is written as its year: no reader takes a day
or month of 00, and ID3v2.3 can't hold a month alone, so the full date would fail the writer's
read-back check in some files. The survey found only full dates and years in the owner's tags.

### Saved in the settings

`discogs.mapping` holds the mapping in use, One to one by default, and `discogs.savedMappings`
the user's, each with a name that isn't a preset's. Both are read in Settings only and hidden
from the Settings window, as the dumps folder is: the tagger's Field Mapping sheet edits them.
In JSON the mapping is an object with a rule for every field by name; a target is a string, a
field's name when it is one and a custom key's otherwise, or an object for a key spelled per
format or numbered. A mapping is refused, with the reason, when a field has no rule, an unknown
field or key is named, a list has no join, a template names no field, a key couldn't be written
(a name the writer refuses, a field's name, `WXXX:` or `TIPL` outside ID3), or two fields that
are on write one tag in one format.

### The presets

The owner decided on 2026-11-07 that no preset is made from his library, since the app will be
shared, and that the styles go to one tag, `MOOD`, in every preset: it is a standard field in
all three tag formats, so other apps read it, and the index keeps it (51.19). No preset writes
a `STYLE` key.

- **One to one**, the default: each field to its own tag, replaced. Genres to `GENRE` and
  styles to `MOOD`, each joined with ", ", label to `LABEL` (" & " between labels), and YATE's
  key names for the rest.
- **Minimal**: the release id, the label, the catalog number and the year; the rest off.
- **YATE**: YATE's keys and spellings per format (ADR 0128), every field replaced. `GENRE` the
  genres joined with ", ", `MOOD` the styles, `LABEL` every label with " & ", repeats kept,
  `ARTIST` and `ALBUMARTIST` canonical with "(2)" dropped and Discogs's joins, `DATE` in full,
  `MEDIA` as YATE writes it, the artist list canonical with "(2)" kept; the ordinal position
  and track number text in title case in MP4 and ID3, the release country under its own key
  and `COUNTRY`, URLs as `WXXX` frames in ID3, credits in `INVOLVEDPEOPLE` (`Name (Role)` in
  FLAC, `Role;;;Name,Name` in MP4) and `TIPL` in ID3, `PRODUCER` apart.

**The owner's layout,** which shipped as "Like my library" until 51f, is a test fixture
(`Tests/DiscogsTests/OwnersLayout.swift`): YATE with `GENRE` as `{genre} - {styles}`,
`GROUPING` the labels too, titles, track and disc numbers and totals, composer, lyricist,
conductor and remixer filling empty tags only (the survey didn't measure how the owner's albums
hold them), and compilation and the disc subtitle off. The write-back tests apply it to a test
album for each format, hand-written from ADR 0128's examples, and check that every tag it has
is kept, URLs apart; the survey's cache of the library is gone and no test reads the library.

What the survey didn't record, and YATE's preset guesses: a URL is
`https://www.discogs.com/<kind>/<id>`; `PRODUCER` and the credits put `;;;` between values;
labels keep Discogs's "(2)".

**The owner's saved mapping, "Mine"**, is One to one with "Keep existing values" applied
(`DiscogsMapping.keepingExistingValues()`): titles, artists, album artists, track and disc
numbers and totals, composer, conductor, lyricist, remixer and the date fill only empty tags.
It lives in his `config.json` under `discogs.savedMappings`, as any saved mapping does; the app
ships no copy of it.

### The change set

`changeSet(for:match:mapping:)` is a pure function of the album's files with the tags read from
them now, the match (the release and each file's track) and the mapping. Per file it gives each
tag that would change: the field, the current value and the new one (nil to remove). A tag that
already holds the value, or a fill-empty tag with any value, is no change. A file the match maps
to no track, such as a bonus track, gets the release's fields only; a DSD file is unwritable and
says so. `edits(including:)` turns the changes the user kept into one `TagEdit` per file, and
checks each as the writer will, so a value no format holds is shown before anything is written.
Nothing in it reads or writes a file: the window reads the album's files and hands the edits to
`TagWriter` after the user confirms (51.12).

## Alternatives considered

- **A mapping only of the fields that are on.** Rejected: a misspelled field name would be off
  without a word. Every field has a rule, off included, and the sheet shows them all.
- **Targets as objects everywhere.** Rejected: the config file lists every setting, and the
  default mapping would take hundreds of lines; a plain string covers almost every target.
- **One key spelling for every format.** Rejected: YATE spells the ordinal position, the track
  number text, the country and the notes in title case in MP4 and ID3, and a write unifies a
  file's spelling to the edit's (ADR 0129), so the owner's files would change spelling.
- **Replace clearing a tag Discogs has no value for.** Rejected: a release without a barcode or
  a date would clear the user's; the numbered keys are the exception, since they're the
  mapping's own.
- **Deciding the disc from vinyl sides.** Rejected: a side isn't a disc, and a two-LP set's
  positions (A to D) don't say which sides share one.

## Consequences

The window (51.11 to 51.13) makes public the change set's types and functions when it calls
them. A saved mapping names its fields, so a field added later makes every saved mapping a
problem until it has a rule, as pre-release data that doesn't match is discarded. The guesses
listed above are the first things to check against YATE at the owner's check.
