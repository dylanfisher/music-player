# 0172. Every picture a file holds, and Discogs covers for many albums at once

- **Date:** 2026-11-09
- **Status:** accepted
- **Amended by:** [0177](0177-art-viewer-settings-panes-get-info-steps.md): the viewer shows once its art is decoded and its
  pictures listed, at its final layout.
- **Amended by:** [0189](0189-discogs-covers-kept-on-disk.md): each cover fetched is kept on
  disk, so a run after a quit or a crash fetches only the ones it hadn't reached.
- **See also:** [0020](0020-tag-writing.md) (tag writing), [0021](0021-tag-editor.md) (the
  editor), [0140](0140-discogs-cover-art.md) (Discogs covers), [0133](0133-one-confirmation-for-a-match-set.md)
  (one confirmation), [0138](0138-the-discogs-api-client.md) (the client's pacing)

## Context

Phase 66, asked by the owner on 2026-11-09. Get Info showed one image, and the writer could
replace only the picture players show or remove them all, though files hold back covers,
leaflet pages and disc labels too. The art viewer stretched a small cover to fill the screen.
Covers from Discogs came only with a tagger Apply, so an album tagged earlier had no way to
get one.

## Decision

- **A list of pictures.** `ArtChange.pictures([ArtPicture])` puts the list in place of every
  picture a file holds; an empty list removes them. ID3 gets an `APIC` frame each, where the
  first old one was. ID3 allows one picture a description, so the first has none, as a single
  cover has, and the rest their type's name, numbered from 2 when it repeats ("Back Cover 2").
  FLAC gets a `PICTURE` block each, where the first was. MP4's `covr` keeps no types and
  players show its first, so it gets the front covers first, then the rest in order. The
  write is checked by reading every picture back, its bytes and type. `.replace` stays the
  front cover alone, put where the shown picture was, so a back cover survives Replace
  Artwork… and the Discogs covers.
- **Types.** `PictureType` is ID3's and FLAC's number. The editor offers Front Cover, Back
  Cover, Leaflet Page, Disc Label and Other; a number it doesn't offer, as an artist photo, is
  kept as read until changed. An MP4 picture reads as the front cover when first and Other
  after, since the file says nothing.
- **The Artwork tab.** It lists the pictures the tracks share, each with a thumbnail, a type
  pop-up and its size; + (an open panel of any image), a drop and Paste add, − removes the
  selected. A JPEG or PNG is added as it is, any other image as PNG. The first picture added
  to a list with no front cover is the front cover, the rest Other. Tracks whose pictures
  differ show as mixed and keep theirs until the list is changed; a change then gives every
  file the list. An edit back to what the files hold is none. The undo journal keeps the
  bytes a write replaced, so Undo Tag Edit puts the pictures back as it does the tags.
- **The viewer.** The decoded art is drawn at most a point a pixel. The art it opens with,
  a thumbnail, fills the screen until the decode arrives, so a small cover doesn't flash
  tiny first. Several pictures get a strip of thumbnails along the bottom, above the Dock,
  the art's height less the strip's; a click on one shows it.
- **Get Artwork.** "Get Artwork for N Albums…" in the tagger covers the albums listed whose
  files carry a release id, or that Apply wrote one to this session; "Get Discogs Artwork…"
  in the track menu covers the selected files that carry one. Only a tagged id counts, never
  a match not yet applied, so no album gets a guessed release's cover. It needs the token and
  says so without one. It asks once, with the count: Fill Missing, Replace or Cancel. That
  answer is the user's confirmation of the write (AGENTS.md); nothing is asked again. Fill
  Missing covers a file with no art, or whose shown art has fewer pixels (width times height)
  than the cover; Replace covers every file. Front cover only, by the owner's choice: the
  edit is `.replace`, so the file's other pictures stay. Each release is fetched once through
  `DiscogsAPI.cover(release:)`, paced as every request is (ADR 0138), with "Getting covers:
  3 of 20" where a save shows; the edits then go to the tag editor's queue as one batch, which
  the status bar counts and one Undo Tag Edit puts back. A staged job's tagger has no Get
  Artwork, since its writes go through its own journal (ADR 0146).

## Consequences

- A picture kept from the file is written back with its own bytes and MIME type, a GIF or a
  BMP as much as a JPEG or PNG, so one in the file doesn't block saving an edited list; only
  an image the editor adds is limited to JPEG and PNG, and converted as said above. MP4 labels
  it with its own `data` type code, and any MIME type it has no code for as implicit.
- Fill Missing reads each file's shown art to size it, one file at a time off the main
  thread: on a NAS, an album costs a read a file before its cover is written.
- Every reader of more than one picture sees them in the written order, with the types; a
  player that keys pictures by description, as mutagen does, sees each.
