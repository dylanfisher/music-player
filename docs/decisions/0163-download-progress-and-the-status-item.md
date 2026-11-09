# 0163. Download progress, its speed, the status bar item and slskd's page

- **Date:** 2026-11-09
- **Status:** accepted
- **Amends:** [0145](0145-the-recommender-client.md) (the client reads `downloads/config` too)
- **Amended:** 2026-11-09, phase 62: the status bar item moves to the left.
- **See also:** [0147](0147-moving-downloads-into-the-library.md) (Approve),
  music-recommender's ADR 0014 (the search's progress and the last miss)

## Context

Phase 59 is the owner's feedback on the Downloads window. A queued job said "Searching" and
nothing more for over a minute; a downloaded job said "Downloaded" while the service copied it
into staging, which "looks stuck"; there was no speed or time left, no way to see a download
without the window open, no way to open slskd, and the Approve sheet was "too hectic looking".
The owner asked that the work be efficient: "we only compute when window is open, etc."

The service's half shipped first: a `searching` job carries `search` (the query, its number of
the attempt's one or two, the peers and files that have answered), a `not_found` job's `reason`
stays through its next search, `progress` is set while the copy into staging runs, and
`downloads/config` reports `slskd_url`. A download's `progress` is rewritten about every 5 s,
and stands still for up to about 77 s while any job searches, since the service's runner is one
thread.

## Decision

- **The state in words** says the query's number and the answers so far; a search after a miss
  says what the last one found; a job not found says when it searches next, or that only Retry
  starts another; a downloaded job says "Copying to staging…" until the copy starts, then
  "Copying to staging, 5 of 14 files", with the download's progress bar. The query text and the
  attempt are in the tooltip, so the column stays one line.
- **Speed from this Mac's own receive times.** The model keeps a reading of a job's bytes, with
  the time it received them, each time a poll finds them changed, and only while the window is
  open; closing it forgets them. The speed is the bytes over the time across the last six
  readings, over at least 8 s, so a 2 s poll of a value written every 5 s doesn't swing it. A
  reading that stops changing keeps its speed for 120 s, longer than a search's stall, then
  shows none; it never shows 0 B/s. The time left is the bytes left at that speed, rounded up
  to the minute. The copy into staging starts its own readings. A gap between readings
  doesn't restart them: slskd goes on downloading while a search holds the job's progress
  still, so the first reading after a stall carries the bytes got meanwhile, and the speed
  across it is the true one.
- **Polling.** 2 s while the window is open and a job moves, as before; 5 s while the status bar
  is in view and a job is on its way to staging (queued, searching, downloading, copying), the
  pace the service writes progress at; 60 s otherwise, as before. The 60 s poll never stops: the
  background tagging and import run from it, and a job queued on another Mac appears through
  it. Hiding the status bar returns to it after the wait running.
- **The status bar item** is on the bar's left, after the scan, saving and analysis text and
  before the leading columns, put there by `LibraryBrowser.setStatusAccessory` and drawn by
  the Downloads feature. Phase 59 put it at the right end, after the problems button; the
  owner moved it in phase 62. While the window is
  closed, a poll updates the item alone, not the window's table. It shows while a job
  is on its way, in one of three styles, the setting `appearance.downloadsStatusStyle`: a
  symbol and the count, text ("Downloading 3 albums, 50%"), or a 48 pt bar and the count (the
  default). The bar and the percentage average the albums: a search counts as none, a download
  by its bytes, the copy as the download done. The tooltip lists each album's state. A click
  opens Downloads; a right-click lists the styles with the current one ticked. The setting is
  also in Settings > Toolbar under Status Bar, and is a command (ADR 0159).
- **Opening with a selection.** File > Downloads… with library tracks selected opens From
  Library Selection once the window can queue, after the catalog check and the service's first
  answer. It offers the tracks selected when the window opened, not a later selection. Any
  other sheet on the window drops the offer, so it never comes up over or after one; closing
  the window drops it too. A selection with no album to queue opens nothing, and the status
  item's click opens the window without an offer of its own, leaving one that waits.
- **Reveal in Finder** shows a job's staged folder from `staged` until the import, failed jobs
  too. It doesn't need the service, so it works while the service is down. The service's
  `staged_path` is used only when it's one folder name (`DownloadJob.stagedFolder`): no `/`,
  not empty, `.` or `..`; and a folder that is a link out of the staging folder isn't shown.
  The plan, the approved import and the tagger take `stagedFolder` too.
- **Open slskd** opens `slskd_url`, asked each time the window opens. A loopback host
  (any 127.0.0.0/8 address, `::1`, `localhost` or `localhost.`, and the unspecified `0.0.0.0`
  and `::`) means slskd runs on the service's Mac, so the address the player reaches the
  service at takes its place, with the scheme and port kept. A user, password, query or
  fragment is dropped before the page is opened, shown or logged. Only an http or https URL
  with a host is opened, and only when the owner clicks.
- **The Approve sheet** takes the tagger's sheet layout: a heading and a line under it, a table
  of the staged files (where each goes, relative to the library folder, and what the
  lossy-origin check found), and for an upgrade a table of the old files with a box in the row
  of each that has no new file. What blocks Approve is one line beside the buttons. The tables
  are `NSTableView.inListScrollView`'s, in `DisplayText`, the look the Downloads window, the
  Queue sheet and the tagger's tables share.

## Alternatives considered

- **Restarting the readings after a long gap.** Rejected: it would blank the speed for 8 s or
  more after every search, to correct only a peer that really stopped, whose average catches
  up within the six readings kept.
- **The speed from the last two readings.** Rejected: with 2 s polls of a value written every
  5 s, it swings by half from one poll to the next.
- **The service's own transfer speed**, which slskd knows. Rejected for now: the contract
  doesn't send it, and the copy into staging has none.
- **Polling at the window's 2 s pace for the status item.** Rejected: the service writes
  progress every 5 s, so a faster poll shows nothing new, and the item is on screen far more of
  the time than the window.
- **Stopping the poll while neither the window nor the item is in view.** Rejected: the
  coordinator's tagging and the outbox run off it.
- **A status bar part in the bar's builder** (`StatusPart`). Rejected: the owner asked for it at
  the bottom right while a download runs, not as a part to place, and it isn't the playing
  track's.
- **Opening From Library Selection on every show.** Rejected: a click on the status item, or a
  look at the downloads, would bring up a sheet.
- **Get Info's form for the Approve sheet.** Rejected: it edits one album's tags; Approve is a
  list of moves and deletes, as the tagger's View Changes is.

## Consequences

- A download's speed reads only from the second reading 8 s apart, so about 10 s after the
  window opens on it.
- The status bar's 5 s poll runs whenever the main window's status bar shows a job on its way,
  including while the window is behind others; a minimized window isn't seen.
- The service's reply decides a page the app opens in the browser, on the owner's click. The
  reply is a LAN device's input (ADR 0025, row 65): a service that isn't the owner's could
  point Open slskd at any http or https page, which the owner sees in the button's tooltip
  before clicking.
- The tagger and the downloads build their tables with the same two `NSTableView` helpers, in
  the `DisplayText` primitive, so the look is one copy.
