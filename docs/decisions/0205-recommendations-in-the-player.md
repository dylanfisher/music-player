# 0205. Recommendations in the player

- **Date:** 2026-11-11
- **Status:** accepted
- **See also:** [0145](0145-the-recommender-client.md) (the recommender client),
  [0198](0198-the-library-profile-export.md) (Export Library Profile…)

## Context

music-recommender serves its lists over HTTP: the whole library's, a seed album's and a seed
artist's, of albums or artists, with filters and paging. It takes the library's profile and the
owner's Not Interested and Already Have marks. Its `docs/api.md` is the contract, and its ADR
0028 says why the route behaves as it does. A seed list's first request computes it, about
23 s, and up to 4 queue behind each other; other routes answer at once. A 503 with code `busy`
means ask again, and a mark drops its album out of every list from the next request on, with
no rebuild, moving later pages by one.

The owner answered the phase's five questions on 2026-11-11, each as recommended.

## Decision

- **A window of its own,** File > Recommendations… beside Downloads…, with Recommendations
  for Album and Recommendations for Artist in the File menu and the track table's context
  menu, seeded from the selection by the profile's rules for an album's release id and artist.
  The rows are albums the library doesn't have, which none of the browser's track tables can
  hold without a second kind of row, and a window can stay open beside the library while a
  seed list computes.
- **Send Library Profile to Service beside Export Library Profile…,** never in its place and
  never unasked. Export stays for `profile load` on another machine and for reading what is
  sent. The profile sends no album rating yet.
- **Timeouts by route.** `call` takes the exchange's timeout. The recommendations route waits
  `seedListTimeout`, 120 s, over the contract's worst case of 4 seed lists at about 23 s each,
  with room for a slower catalog. The profile waits 60 s, for a body of a few MB on Wi-Fi and
  the service's write. Every other route keeps `LocalHTTPClient.timeoutSeconds`.
- **Retries.** A 503 `busy` is asked again after 5 s, up to 6 times, then the window says the
  service is busy, with Try Again. An `out_of_date` list with `rebuilding` true is asked for
  again every 30 s while the window is open. The player branches on `error.code`, never on the
  message.
- **A mark reads the list again.** Not Interested and Already Have, from the row's menu, the
  toolbar and ⌫, take the rows out at once, then read the list again from offset 0 through as
  many rows as were shown, 100 a request. The cap of 3 to an artist and a label is counted
  again after a mark, so a page read after it can hold an album the earlier read left out.
  Edit > Undo removes the marks and reads the list again; a failed mark puts its rows back and
  says why.
- **Marked… names marks from this Mac's catalog.** `feedback/list` answers kind, id, verdict
  and time but no name, so the sheet names each mark from the Discogs catalog where it has the
  master or release, else `release 4242`, with Remove Mark.
- **Download… goes through Downloads.** The selected rows open Downloads' queue sheet through
  a package entry point over its queue, so the snapshot, the format policy and the errors stay
  in one place. Each row is a choice of its album's `release_id`, a master's main release; one
  with `release_id` `null` says so in the sheet.

## Alternatives considered

- **A browser view.** Rejected: every source of the browser is a track table over the index,
  and its files are the ones phase 85 splits.
- **Sending the profile unasked,** at launch and after a scan or a tag edit. Left out until the
  owner asks: it removes a step, but sends without being asked.
- **Dropping only the marked rows.** Rejected: the cap can bring back an album the earlier read
  left out, so only a read from offset 0 shows the list as the service now has it.
- **Names on the marks from the service.** Left to music-recommender: it is a change to a final
  shape, and the catalog names them on a Mac that has one.

## Consequences

- On a Mac without the Discogs catalog, Marked… names every mark by its id.
- A row whose release isn't in this Mac's catalog shows in the sheet and fails when queued,
  saying so, as a pasted release does.
