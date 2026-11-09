# 0140. Discogs cover art

- **Date:** 2026-11-08
- **Status:** accepted
- **Amends:** [0025](0025-threat-model.md) (row 64)
- **See also:** [0132](0132-discogs-field-mapping.md) (the mapping), [0133](0133-one-confirmation-for-a-match-set.md)
  (one confirmation), [0138](0138-the-discogs-api-client.md) (the client), [0136](0136-asking-before-a-rescan-and-undoing-a-tagger-write.md)
  (undo), [0172](0172-every-picture-and-bulk-covers.md) (Get Artwork, the covers alone)

## Context

The Discogs dumps have no images, so the tagger couldn't write covers. The API gives a
release's images to a request with a token. Phase 52.4 asks for the mapping's Artwork to fetch
the release's primary image and write it as the cover, through `TagWriter`.

## Decision

- **A setting, not a mapping field.** `discogs.artwork` (`DiscogsArtworkMode`: off, fill empty,
  replace), default off. `DiscogsMapping` needs a rule for every `DiscogsField` and a bad value
  blocks the config file (ADR 0082), so a new field would make the owner's saved mapping, and
  every saved one, refuse to load. Presets don't carry it. The Field Mapping sheet shows it under
  the fields, disabled with "Needs a Discogs token in config.json" when there is none, and OK
  saves it with the mapping. It is in the menus with the tagger's other choices.
- **When it's fetched.** When View Changes opens or Apply plans, with the files being read,
  before the confirmation: the release through the cache, then its primary image, once a
  release a session. A catalog match has no image in the catalog, so it costs one request for
  the release by id (cached after) and one for the image, which the confirmation's text says
  ("Each cover is its release's primary image from Discogs"). Without a token nothing is asked.
- **What "fill empty" means for art.** A file with any embedded cover keeps it; one with none
  gets the release's. Replace writes it over any. Every file of an album gets the same image.
- **Checks.** The image comes from `i.discogs.com` only, over https, at most 10 MiB, in 20 s,
  paced as the API's requests are, and with no token. Its type is read from its signature
  (JPEG `FF D8 FF`, PNG's eight bytes), never from `Content-Type`, and it must end with its
  format's end marker (JPEG's `FF D9`, PNG's IEND chunk), so a cut-off download is refused
  rather than written half grey. ImageIO's header must say at most 8,000 pixels a side, and it
  must decode through `thumbnail(of:maxPixelSize:)`, the one decode of art (row 4). `TagWriter`'s
  own art checks, the 64 MiB cap among them, apply unchanged when it writes.
- **Writing.** The cover is an `ArtChange.replace` in each file's `TagEdit`, beside the tags: one
  batch, one confirmation (ADR 0133), and one Undo Tag Edit puts back the art and the tags
  together. It is a tag edit by `TagWriter`, so AGENTS.md's boundary on music files needs no new
  exception. View Changes shows it as one row with a box ("600 × 600 JPEG from Discogs", the
  files it adds to or replaces in); unticked, it isn't written. The confirmation counts covers
  beside tags, files and albums.
- **Problems.** An album whose cover can't be had (no token, no image, a fetch error, a bad
  image) gets a line in the plan's problems, "no cover: …"; its tags still apply. A fetch error
  here doesn't stop Apply, since the tags don't depend on it.

## Alternatives considered

- **An Artwork field in the mapping.** Rejected above: it would invalidate saved mappings.
- **Sending the token to `i.discogs.com`.** Not done: the token goes to `api.discogs.com` only
  (ADR 0137). If Discogs's image host refuses requests without it, covers can't be fetched,
  and the owner check will show it; the decision is the owner's then.
- **Showing the size of the cover a file has now.** Rejected: it means reading every file's art
  from the NAS when View Changes opens. The row says how many files it replaces a cover in.

## Consequences

Covers need a token. An Apply with artwork on makes up to two requests an album that isn't
cached, a second or two each, before its confirmation shows. A release cached before a token
was added has no image until its entry is 30 days old.
