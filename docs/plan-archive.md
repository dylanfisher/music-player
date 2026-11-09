

### 58. Tagger

- [x] **Look Up Release:** search for a release by artist, title, catalog number or id, in
      the local Discogs catalog first and the Discogs API when the catalog has no match or no
      catalog is present (tests use the stand-in transport, AGENTS.md).
- [x] **Exclude tracks:** files can be left out of a match (duplicates of another release),
      so the rest match the release's track count and can be tagged.
- [x] **Two tables:** our files and the release's tracks in two tables side by side that read
      as one row each, so it's clear where each column comes from. The match mark gets a word
      ("Exact", "Close", …) beside the symbol.
- [x] **Counts in buttons:** "9 other releases…" and "44 changes" where the number is known.
- [x] **Progress in the window:** the tagger shows its write progress as well as the status
      bar, with whatever detail it has (album or file n of m), else a plain bar.
- [x] **Saved field mappings:** can be removed from the "Start from" menu, or by a button.

Implementation plan, phase 58 (ADR 0157):

What exists, found by search (map.md recipes): the tagger is `TaggerModel` (no AppKit, driven
by `Effects`), `TaggerWindow` and its sheets in `Features/DiscogsTagger`; matching is
`matchAlbums` and `AlbumMatcher` in `Core/Discogs`, with `Catalog`'s folded-key lookups
(`releaseIDs(label:catalogNumber:)`, `titleMatches`) and `DiscogsAPI.search(_:)`, private, over
`/database/search`. Other Releases… is `ReleasesSheet`; its rows are `ReleaseSummary`. The
tagger writes through `TagEditing.write(_:over:completion:)`, whose progress reaches only the
status bar's `saving`. Saved mappings are `MappingDraft.saved`.

- 58.1 Saved mappings (`MappingDraft.remove(_:)`, `MappingSheet`): a Remove button beside
  Start from, on for a saved mapping only; the removal is the draft's, so Cancel keeps it.
- 58.2 Counts in buttons (`TaggerWindow`, `TaggerModel`): "9 Other Releases…" from the match's
  candidates, and "View 44 Changes…" once the selected album's files are read: the model reads
  them in the background after a short pause on a selection, and forgets the count whenever an
  album, the mapping or the choices change. A plural helper of `DisplayText` gives the forms.
- 58.3 Two tables (`TaggerWindow`, `TaggerTitles`): "Your Files" (number, title, length) and
  "Discogs Release" (position, title, length, state), the same rows, scrolled and selected
  together, the left one's scroller hidden. The state reads "✓ Same", "≠ Differs", "– No
  file", "– No track". A drag goes from the files onto either table's row.
- 58.4 Leaving files out (`TaggerModel.Album.leftOut`): an Include box in the files table.
  A file left out isn't matched, read or written: the album is matched again without it, with
  the release the user chose if any, and is listed last, greyed, as "Left out". Kept for the
  session by album, through a new Analyze; not in the staged tagger (ADR 0157).
- 58.5 Look Up Release (`Core/Discogs/ReleaseLookup.swift`, `ReleasesSheet` in a look-up
  mode): fields for artist, title, catalog number and release ID or URL, filled from the
  album's tags; Search asks the catalog first (the id, then label and catalog number or the
  number alone, then artist and title by their folded keys, every field given then checked
  against each release), and the API only when the catalog finds nothing or there's none
  (`DiscogsAPI.search(artist:title:catalogNumber:)`, the release by id without a token). Each
  release found is scored against the album's files for the Fit column. Use Release chooses it
  as Other Releases does; a release from the API is matched with the API.
- 58.6 Progress in the window (`TagEditing.write(_:over:progress:completion:)`, App wiring,
  `TaggerModel.writing`): "Writing 120 tags to 20 files: 3 of 20 written" with the bar, shown
  while nothing else runs; a staged write has no counts, so a plain spinning bar.
- 58.7 Tests: each of the above in `DiscogsTaggerTests` and `DiscogsTests`, the look-up over a
  fixture catalog and a stand-in transport, never the real API.

Order: 58.1, 58.2, 58.3, 58.4, 58.5, 58.6, then the ADR.

Result, phase 58: shipped all six items (ADR 0157). Look Up searches the catalog first and
Discogs when the catalog has no match or there is none, filters by every field before listing
200, and stops on a catalog it can't read. Files can be left out of a match for the session;
Apply never reads or writes them. The files and the release sit in two tables kept in step,
the match column reading "✓ Same", "≠ Differs", "– No file" or "– No track". The buttons read
"9 Other Releases…" and "View 44 Changes…", the count read in the background per album. A write
shows its progress beside Analyze. A saved mapping has a Remove button that sticks on OK. Gate:
one correctness and one simplify review, 14 findings fixed in 16 commits, each correctness fix
with a test that fails without it; `theGlassHeadersAreFrosted` fails as in every agent session,
and `aRunAgainReadsEveryFileAndCarriesOnAfterARelaunch` failed once under load and passed 3 of 3
alone. No bench row covers the tagger. Cost: implementer about 870k tokens, 443 tool calls,
70 min; reviewers 169k tokens, 28 calls, 3 min.

Owner steps: the two tables with a trackpad and a mouse, a drag onto either, their widths on the
2015 MacBook Pro; untick a duplicate on a real album, see it go Exact, Apply, and check the
left-out file in YATE; Look Up on the real catalog by catalog number or title alone (its time on
both Macs), by API with the token, by an ID typed beside the artist and title, and with an old
catalog; the change count moving through albums on the NAS; write progress during a large Apply;
Remove in the Field Mapping sheet, then OK and Cancel; the Title column in the Look Up sheet.


