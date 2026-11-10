# 0139. The Discogs API as a source in matching

- **Date:** 2026-11-08
- **Status:** accepted
- **Amends:** [0131](0131-discogs-matching.md) (where candidates come from)
- **Amended by:** [0190](0190-an-unfinished-analyze-resumes.md): the API alone keeps the albums
  it matched when it stops, and a run after one that stopped resumes where it stopped.
- **See also:** [0138](0138-the-discogs-api-client.md) (the client), [0133](0133-one-confirmation-for-a-match-set.md)
  (reviews), [0137](0137-the-discogs-token.md) (the token),
  [0179](0179-combining-albums-for-tagging.md) (Combine Albums for
  Tagging asks the API at once: the command is the click)

## Context

The tagger's Source pop-up had Local Catalog, Discogs API and Both since phase 51, with the
last two disabled. Phase 52 makes them work: the API for a Mac with no catalog (the 2015 MacBook
Pro has no room for one), Both for releases newer than the monthly dump.

## Decision

- **One matcher.** `AlbumMatcher` takes an optional catalog, extra candidates with how they
  were found, and releases already fetched, read before the catalog. An API release is the
  `CatalogRelease` the dump would give (ADR 0138), so scoring, the tie-break, the tiers, the
  reasons and the mapping are the same whichever source a release came from. A match records
  its release's origin, which the window shows under the title and Apply's plan reads.
- **What the API is asked, per album.** The chosen release and the tagged release ids,
  fetched by id. Then, with a token, searches in the catalog's order, using its rules for
  spellings (`labelNames`, `artistNames`, `CatalogKey.titleVariants`): barcode; if that found
  nothing, label and catalog number, each label name until one finds something; if those found
  nothing, artist and title, each spelling until one finds something. Each search reads the
  first page of 25.
- **Budget.** At most 8 releases fetched an album (`ApiCandidates.maximumReleases`), in the
  order found. Masters aren't expanded to their releases, which for a popular album is hundreds
  of requests; when two or more fetched releases share a master, the master is fetched once to
  say which is its main release, which the tie-break prefers. A release that is missing or
  unusable is left out of the album's candidates. A refused token, no connection, a failed
  secure connection, a timeout, a server error or the rate limit stops the API with one alert.
  With the API alone that stops the run, and the albums shown stay the last run's. In Both the
  catalog pass is already done, so its matches are kept, with the API's for the albums it did
  before it stopped (`APIStoppedMatching`), and the status line says some albums have only the
  catalog's match.
- **Without a token** only releases fetched by id are looked up: the tagged ids and a chosen
  release. Nothing searches, since Discogs answers searches only with a token. The pop-up's API
  items say so in their tooltip.
- **Both.** The catalog pass runs over every album first, as Local Catalog does. The API is then
  asked about the albums the catalog can't place: no candidate, tagged with a release id the
  catalog lacks, or whose chosen release it lacks. The owner asked for "releases newer than the
  dump"; the dump has no date for each release, so newer is decided as not in the catalog.
  Those albums are matched again with the catalog's candidates and the fetched ones together,
  and only releases the catalog lacks are fetched. An Exact album costs no request. With no
  catalog on the Mac, Both runs as the API alone and the status line says so.
- **Only on a click.** Opening the window on a library selection analyzes at once only with
  Local Catalog. The API is never asked without the user's click on Analyze.
- **The source is this Mac's.** `discogsTagger.source` in `state.json`, since one Mac has a
  catalog and another doesn't. With none saved: Local Catalog when there is a catalog, else the
  Discogs API. `DiscogsSource` in Settings is the one list of sources, which the window and
  `matchAlbums` both take.
- **The sheets.** Other Releases and View Release read a release the catalog lacks from the
  Discogs cache, which holds every release a run fetched, so they need no request.

## Alternatives considered

- **Expanding masters.** Rejected: the dump's catalog can list a master's releases for free;
  the API pages them at one request per 100, plus one per release to score it.
- **Both asking the API about every album.** Rejected: a library of thousands of albums at one
  request a second, for answers the catalog already has.
- **Comparing dates for "newer than the dump".** Not possible: a release's date in the dump is
  when it was released, not when it was added to Discogs.

## Consequences

An Analyze through the API takes a second or more an album with a token, and up to 8 releases,
the master and the searches can make that ten. Albums with no barcode, catalog number or tagged
id are found by title only, as in the catalog, and say so. A release added to Discogs after the
dump is found by Both only for an album the catalog can't place.
