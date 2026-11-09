# 0152. A field that replaces its tags matches Discogs exactly

- **Date:** 2026-11-08
- **Status:** accepted
- **Amends:** [0132](0132-discogs-field-mapping.md) (a field Discogs has no value for, and the
  album artist URL key), [0133](0133-one-confirmation-for-a-match-set.md) (the tiers Apply to
  All writes)
- **See also:** [0128](0128-discogs-survey.md) (YATE's keys), [0146](0146-staged-tag-writes.md)
  (staged downloads, which replace every field)

## Context

On 8 Nov the owner ran the tagger with the One to one preset and Keep existing values off on
FLAC albums YATE had tagged. Each mapped field got Discogs's value, but the keys YATE had
spelled another way stayed beside the new ones: `Track Number Text` next to
`TRACK_NUMBER_TEXT`, `Discogs Release Ordinal Position` next to
`DISCOGS_RELEASE_ORDINAL_POSITION`, `Discogs Album Release Country` next to `COUNTRY`, and
YATE's `DISCOGS_ALBUMARTIST_URL` next to this app's `DISCOGS_ALBUM_ARTIST_URL`. The owner decided
that One to one means one to one: with Keep existing values off, the tags match Discogs, with
no new checkbox.

The last of those was this app's mistake: the survey found `DISCOGS_ALBUMARTIST_URL` in 12,198
files, numbered `-2` to `-7` and as `WXXX:DISCOGS_ALBUMARTIST_URL` in ID3, and
`DISCOGS_ALBUM_ARTIST_URL` only in the 10 files this app wrote.

The owner also asked for Apply to All in the Matched tab, to re-tag the albums already tagged
with one release, thousands of them, with the current mapping.

## Decision

When a field's rule is replace (Keep existing values off, or a field it doesn't keep):

- **Other spellings are removed.** When the field writes a custom key, every other spelling of
  that field's key the file holds is removed, its numbered `-2`, `-3` keys included. The
  spellings are every custom key any preset sends the field to, in every format (Vorbis, MP4
  and ID3 names, numbered names), worked out from `DiscogsPreset.all`
  (`DiscogsPreset.spellings`), plus `DiscogsKey.albumArtistURLUnderscored`, which no preset
  writes now. Keys compare uppercased. A key the active mapping writes for any field is never
  removed. Under One to one, `DISCOGS_ALBUM_RELEASECOUNTRY` and `Discogs Album Release Country`
  go and `COUNTRY` stays; under YATE all three are targets and stay. A key no field has, such
  as `DISCOGS_IMPORT_SETTINGS`, is left.
- **A field Discogs has no value for clears its tags.** Each target tag the file has is removed:
  a release without a barcode clears `BARCODE`. A template that fills to no text clears its tag
  the same way. A track's field for a file the match maps to no track, such as a bonus track the
  release lacks, is still left as it is, and so are its other spellings.
- **Fill empty and off remove nothing,** as before.

`DiscogsKey.albumArtistURL` is `DISCOGS_ALBUMARTIST_URL`, YATE's spelling, in both presets.

Staged downloads apply the mapping with every field replacing (ADR 0146), so they get the same
removals: an uploader's tags aren't kept over the release's.

**Apply to All in Matched.** `TaggerModel.appliedTiers` is Exact, Likely and Matched. A Matched
album's release is the one its tracks name, so Apply there is a refresh; the confirmation is
the one ADR 0133 describes. Incomplete and No candidate still have no Apply to All.

## Alternatives considered

- **A checkbox for "remove other spellings".** Rejected by the owner: Keep existing values off
  already says the tags should be Discogs's.
- **A hand-kept list of YATE's spellings.** Rejected: it would be a second copy of the keys the
  presets name, and would miss a spelling a preset gains.
- **Removing other spellings in fill empty mode too.** Rejected: fill empty keeps what the file
  has, and a value under another spelling is something it has.
- **Leaving a field Discogs lacks alone, as ADR 0132 did.** Rejected now: it leaves a value from
  another release or another tagger, which isn't one to one. Keep existing values, or the
  field's rule set to fill empty, is how a user keeps their own.

## Consequences

The first Apply under One to one on a YATE-tagged album removes many keys, and View Changes
lists each as `(removed)` under its field, so the owner sees them before confirming. Undo Tag
Edit puts them back. A preset that gains a key makes it another field's spelling at once.
