# 0145. The music-recommender client: bearer POSTs over the local HTTP client, strict replies

- **Date:** 2026-11-08
- **Status:** accepted
- **See also:** [0025](0025-threat-model.md) (the threat model, row 65),
  [0039](0039-network-control.md) (local subnets, IP literals, `LocalHTTPClient`),
  [0144](0144-the-service-token.md) (the token and the settings),
  [0146](0146-staged-tag-writes.md) and [0147](0147-moving-downloads-into-the-library.md) (what
  the jobs are for)

## Context

Phase 54's player talks to music-recommender, the service on mbp2021 that searches Soulseek,
downloads albums and stages them on the NAS. The contract is the service's `docs/api.md`: every
route is a POST of a JSON object with `Authorization: Bearer <token>`, and the answer is a 200
with `{"ok": true, ...}`, a 200 with `{"ok": false, "error": {...}}` for a request understood
and refused, or a 400, 401, 404, 405, 408 or 503 for one that wasn't. The service is on the
LAN, so its replies are a LAN device's input (ADR 0025), and the request carries the app's second
secret (ADR 0144).

## Decision

**A new core module, `Recommender`**, importing `LocalNetwork`, `Settings` and `DisplayText`.
It holds the client, the request and reply models, the job's states, and the client's copy of
the job list. `Discogs` builds the release snapshot that `create` sends (54.2), so the wire
types live here and `Discogs` imports `Recommender`, not the other way round.

**`LocalHTTPClient.post`, unchanged.** The bearer header and `Content-Type: application/json`
go in `post`'s `fields`, and the call passes `keepingRefusals`, so a 401 or a 400 is read with
its body for the code. The client's caps stay: 1 MiB a reply, 5 s an exchange, no redirects,
no chunked request bodies. The one change to `LocalNetwork` is a public
`LocalURL(host:port:path:on:)`, since this is the first URL built from an address the owner
typed rather than one a device described.

**The address.** `recommender.address` is an IP literal (ADR 0144). The client is made only
when it's another device's address on a local subnet, `LocalSubnets.interface(forHost:)`, as
`receiver.address` is: not loopback, not this Mac's own address, not a network or broadcast
address. So the player and the service don't run on one Mac.

**Errors are typed and name the URL, never the token.** `RecommenderError` carries the URL the
request went to and a kind: off the subnet, unreachable (refused, failed or timed out),
cancelled, unauthorized (401), a bad request (400, with `bad_request` or `too_large`), another
status with its code, a refusal (`ok: false`, with its typed code and the fields that code
brings), over the cap, unreadable, or a job in an unknown state. The token is only ever in the
request's header; the URL, the kinds and their descriptions can't hold it, and a test checks a
401's text. The service's own text is escaped with `terminalSafe` where it's shown.

**Replies decode strictly.** Every object must have exactly its fields: a field the contract
says may be null must still be there, and an unknown one fails the reply, as the service
refuses unknown fields in requests. An error code, a format, a policy, a source, a tagging
status or a failed stage outside the contract's lists fails it too. A state this player doesn't
know is its own error kind, which the window shows as an error, never a row skipped. A fuzz
target, `recommender-reply`, runs each reply shape.

**Requests are typed to what the contract allows.** An upgrade's format policy is a type with
only `flac` and `lossless`, so an upgrade can't ask for a lossy policy. A `handoff`'s failed
stage is one the player reports (`tag`, `move`, `delete`, `carry`). `list`'s `epoch` is sent as
`null` on the first request, not left out.

**The snapshot is built in `Discogs`** from the local catalog, and refused at queue time when
the release isn't there or the service would refuse it: no artist or title, a tracklist of none
or over 500 tracks, or positions missing or repeated. A position is how the service names each
file's track, so it must be unique and not empty: a track's own; for an index track without
one, its parts' joined with "+"; for a list where no track has one, its place from 1. 54.4's
mapping names tracks the same way, through `ReleaseSnapshot.positions`.

**The job list is paged to the end and replaced on a reset.** `DownloadJobs` holds the rows by
id, the epoch and the revision of the last job taken. A refresh asks with them until `more` is
false, taking `after` from the last job of each page. A `reset` drops every row before taking
that page, wherever it comes in the paging, and starts `after` again from 0. A page whose jobs
aren't in ascending revision above `after`, or that says `more` with no jobs, is unreadable
rather than looped on.

## Alternatives considered

- **URLSession.** Rejected, as in ADR 0039: a proxy, a cache or a redirect could sit between the
  app and the checks, and the token would go wherever a redirect pointed.
- **Allowing loopback or this Mac's address**, so a player on mbp2021 could reach its own
  service. Rejected for now: the player Macs are other machines, and the receiver's rule is the
  one the code has. It's a one-line change if the owner wants it.
- **Lenient replies,** skipping unknown fields. Rejected: the service and the player change
  together pre-release, and a field the player ignores is one it may be getting wrong.
- **Taking `reply.revision` as the next `after`.** Rejected: the contract says the last job's
  revision, and a job changed between the page and the store's revision would be missed.

## Consequences

The token goes over the LAN in plaintext, as the UPnP output's file tokens do (ADR 0041): any
device that can see the traffic can read it, and anything that answers at the service's address
gets it. The service's API can only download, stage and delete inside its staging folder, and
the player tags and imports staged albums only after the owner's review (ADR 0147), so a stolen
token can queue downloads or reject staged ones, not reach the library.

A reply with a field the service added breaks the player until it learns the field, by design.

## Threat model row

ADR 0025's table has this as row 65, after the Discogs rows:

| 65 | the service token; the app | LAN device | music-recommender's replies, and anything answering at its address | the address only a configured IP literal, another device's on a local subnet; POST to that address alone, no redirects, 1 MiB and 5 s; the token only in the `Authorization` header, never in a URL, an error, a log line or a problem, and kept in `config.json` as the Discogs token is ([0137](0137-the-discogs-token.md), [0144](0144-the-service-token.md)): every write mode 0600, a token in a file others can read not used, `ServiceToken` printing as `<service token>`; every reply decoded strictly at every level, unknown fields, codes and values refused, an unknown job state an error; the service's text escaped; `list` paging that must advance; the token in plaintext on the LAN ([0145](0145-the-recommender-client.md)) | `aCallPostsTheBearerTokenAndItsJSONBody`, `a401IsUnauthorizedAndNamesTheAddressButNeverTheToken`, `anAddressOffEverySubnetOrThisMacsOwnIsRefused`, `aReplyOverTheCapIsRefused`, `repliesOfAnyOtherShapeAreUnreadable`, `aJobWithAFieldMissingUnknownOrOutOfTheContractIsUnreadable`, `anUnknownStateIsAnErrorOfItsOwnNeverASkippedJob`, `aPageThatDoesntAdvanceIsUnreadable`, `theServiceTokenNeverPrintsItsValue`, `aRefusedServiceTokenIsNotInTheProblem`, `aServiceTokenInAFileOthersCanReadIsntUsed`; `scripts/fuzz recommender-reply` |
