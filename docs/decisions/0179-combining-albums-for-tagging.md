# 0179. Combining albums for tagging

- **Date:** 2026-11-09
- **Status:** accepted
- **See also:** [0133](0133-one-confirmation-for-a-match-set.md) (reviews and the one
  confirmation), [0139](0139-the-api-as-a-source-in-matching.md) (when the API is asked),
  [0143](0143-separate-releases.md) (what makes an album), [0157](0157-looking-up-a-release-and-leaving-files-out.md)
  (files left out)

## Context

The library makes an album of a title and an artist, and with Separate Releases a release id
too (ADR 0143). A disc set tagged "X (CD1)" and "X (CD2)", or an album and the extra tracks of
its reissue under "X [Expanded Reissue]", is several albums, and the tagger matched each alone:
no release of the whole count ranked first, and a write gave each piece its own release. The
owner asked for Combine Albums for Tagging, on the albums selected in the library, and chose
that albums with different titles or artists can be combined, with the tagger naming every
source album so a mistake shows before writing.

## Decision

**A scope the command opens.** Combine Albums for Tagging puts the tagger in a scope, Selected
Albums as One, which keeps the library files selected at that moment. Analyze takes the albums
those files are in and joins them into one `DiscogsAlbum` for the matcher and the writer. A
selection of one album is an alert, not a match. Analyze again, a change of source or of Skip
video joins the same albums again, whatever the library selects by then, so a stray click in
the library can't change what's being reviewed. The Scope pop-up lists the scope only while a
combination is open; choosing another scope closes it, and only the command opens one, so
the pop-up can't combine whatever happens to be selected.

**The order of the files.** The albums go by their first disc number, a file without one
counting as disc 1, then by title, then by id; each album keeps its own disc and track order.
A disc set split by disc reads in disc order, and two albums of the same discs, as an album and
its reissue, are put one after the other instead of interleaved track by track. Sorting every
file by disc and track would interleave those.

**What the matcher searches with.** The first album's title, and for the artist, label,
catalog number, barcode, date, media and country the first album's that has one, as a
compilation without an album artist has no artist. The matcher
already ranks a release of the album's count first, so the whole set's release beats one
disc's. The matcher reads the files in this order and never their disc or track numbers
(`AlbumMatcher` and the scores compare titles and lengths by position; only `CombinedAlbum`
reads `DiscogsAlbum.Track.discNumber`), so two albums numbered 1 to 10 and 1 to 14 aren't
renumbered. A file two files would share is left on no track, as for any album: the review shows
it as Missing and keeps the album out of Exact.

**An id of its own.** The combined album's id is its first source's, negated; library album
ids are positive. The session keeps files left out (ADR 0157) and change counts by album id,
and the combination's must not land on a source album shown later under another scope. Two
combinations that start with the same album have the same id, so opening a combination
forgets the files left out under that id; Analyze again within it keeps them.

**Reviews.** A review is saved on the files, here all of the combination's, and read back by
library album. The combination takes a review only when every source album has the same one:
a release chosen for one album alone fits only that album's files, and would force a release
of the wrong count on the whole. A release chosen or a rejection on the combination is saved
on every file of every source, so each source album, shown alone later, takes it too.

**The files become one album.** Each file gets the release id, as any tagger write. That's
enough only when the sources already agree on title and artist, so where their titles differ
the combination's mapping replaces the album title with the release's, and where their
artists differ, the album artist. Both override the field's mode and Keep existing values,
and add the plain tag (`ALBUM`, `ALBUMARTIST`) to its targets when the mapping writes the field
only to a custom key (`DiscogsMapping.combining`). View Changes shows these like any change.
Rejected: writing the first album's own title to every file. The release's is the one Discogs
gives every file, and the one a single album's write gives too.

**Naming the sources.** The album list names the combination by every source ("Persuader –
1983 + Persuader – 1983 [Expanded Reissue]"); its row's tooltip and a line over the tracklists
list each with its file count; Apply's question says which albums its files come from and that
they become one album of the release.

**The command analyzes at once, from any source.** Combine Albums for Tagging… is in the
palette, the track menu and the File menu, enabled with tracks selected. It opens the tagger in
the combined scope and analyzes, the Discogs API included, though opening the tagger with a
selection never asks the API (ADR 0139): the command is the user's click. A busy tagger, an
empty selection or a catalog the source needs and doesn't have is an alert, since the user
asked for something that didn't happen.

## Consequences

- Writing and undo are unchanged: Apply writes through the tag editor's queue with one
  confirmation (ADR 0133), and Undo Tag Edit puts the files back, their old titles included.
- With Separate Releases off, files of different titles become one album by their new title;
  with it on, by title, artist and release id together.
- Other Releases… and Look Up… act on the combined album as on any, a chosen release saved on
  all its files.
- The combination lasts as long as its Analyze: there's no saved set of albums to combine,
  and the next Analyze takes the library's selection as it is then.
