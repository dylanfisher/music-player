# 0138. The Discogs API client

- **Date:** 2026-11-08
- **Status:** accepted
- **Amends:** [0025](0025-threat-model.md) (rows 60 to 63)
- **See also:** [0137](0137-the-discogs-token.md) (the token), [0130](0130-discogs-catalog.md)
  (the catalog the API stands in for), [0039](0039-network-control.md) (the LAN client)

## Context

Phase 52 lets the tagger look releases up on the Discogs API, for a Mac with no catalog and
for releases newer than the dump. It is the app's first connection to the internet. Until now
the only HTTP client was `LocalHTTPClient`, which talks to devices on the local subnet only.

## Decision

- **A transport primitive.** `HTTPSClient` (Primitives) GETs over URLSession, which brings
  TLS, HTTP/2 and the system's proxy settings. `LocalHTTPClient` is kept off URLSession so no
  proxy, cache or redirect sits between the app and its subnet checks (ADR 0039); those
  reasons are about the LAN, and an internet client should honor a proxy. `NWConnection`
  would mean writing TLS and HTTP/2 handling the system already has.
- **What it sends to.** Only `https`, port 443 or none, no user or password, and a host in
  its allowlist, which the app sets to `api.discogs.com` and `i.discogs.com`. Anything else is
  refused before a byte is sent. A redirect is never followed: the delegate answers nil, so a
  3xx is a status like any other, and a final URL off the allowlist is refused as well.
- **How.** An ephemeral session with no URL cache, cookies or stored credentials, built from a
  configuration a test can replace with a stub protocol. A body is read as it arrives and
  dropped past its cap (4 MiB for JSON), counting bytes after decompression. A request has 20 s
  in all.
- **The API client.** `DiscogsAPI`, an actor in Core/Discogs over a transport closure, so tests
  answer from written fixtures and nothing opens a socket. Every request carries
  `User-Agent: MusicPlayer/<version>`, which Discogs requires. The token's header is built in
  one function, for `api.discogs.com` only; an image request never carries it. Calls:
  `release(id:)`, `mainRelease(master:)`, and release searches by barcode, by label and
  catalog number, and by artist and title, first page of 25 only. Discogs answers searches
  only with a token, so without one a search throws `tokenRequired` and sends nothing;
  `/releases` and `/masters` work without.
- **Pacing.** Requests go one at a time. They start `60 / limit` seconds apart, the limit
  read from `X-Discogs-Ratelimit` (60 with a token and 25 without until a reply says, at most
  240 believed); when `X-Discogs-Ratelimit-Remaining` is 0 the next waits a whole minute. A
  429 waits its `Retry-After` (else 60 s, at most 300) and is tried again, twice; a third is
  `rateLimited`. A wait of 3 s or more is reported, so the window can say so, and cancelling
  the task stops it.
- **Errors.** `DiscogsAPIError` names each failure in one sentence that holds no token, header,
  URL or response text. A missing or unusable release (404, malformed, too large) is left out
  of its album's candidates. Every other error, a refused token, no connection, a timeout, the
  rate limit, stops the run, so no album becomes No Candidate because the network was down.
- **A release is hostile input.** It decodes by the types the API documents: a key of the
  wrong type fails, extra keys are ignored, since Discogs adds them. It becomes the
  `CatalogRelease` the dump parser would make, by the parser's rules (text trimmed, empty text
  as none, master 0 as none, a row with sub-tracks an index track, one with no position and no
  duration a heading), so the matcher can't tell an API release from a catalog one. The tests
  import the same releases from dump XML and compare field by field. The kind comes from the
  row's shape, as the dump's does, not from `type_`. Its id must be the one asked for; the
  tracklist has at most 2,000 rows, sub-tracks nest at most 3 deep, a text is at most 2,000
  characters. The primary image is the image of type primary, else the first, and is dropped
  unless it is https on `i.discogs.com`; the release itself is kept.
- **The cache.** Releases and masters fetched by id go into `discogs_cache` in the index
  (kind, id, when, JSON text), a schema part of its own, so adding it rebuilt nothing. The
  Library module stores text; Discogs encodes the converted release with the catalog's
  one-letter keys and the image URL, so a hit needs no second conversion. An entry is used for
  30 days (`DiscogsAPI.cacheDays`). One that doesn't decode, or holds another id, is fetched
  again and replaced. Searches aren't cached: their answer changes, and the tagger already
  remembers reviewed albums. A cache that can't be read or written is logged and the request
  goes to the network.

## Alternatives considered

- **Caching searches.** Rejected: a search done a month ago misses releases added since,
  which is half of what the API is for.
- **Following redirects within the allowlist.** Rejected: Discogs's API doesn't redirect, so a
  redirect is a change to understand first.
- **Real recorded fixtures.** Not possible here: no test, tool or agent calls the API
  (AGENTS.md). The fixtures are written to the documented shapes; the owner can replace them
  with recordings (phase 52's owner check has the `curl` lines).

## Consequences

The tagger can match without a catalog. An analysis of many albums through the API takes about
a second a request with a token and 2.4 s without. A cache entry made without a token has no
image until it is 30 days old. The bundle needs no new entitlement: the hardened runtime
without the sandbox allows outbound connections, and ATS allows https.
