

### 59. Downloads

Some items change the service (`~/projects/music-recommender`, edited on mbp2021, where it
runs; restart it after) and its `docs/api.md` with it.

- [x] **Copy into staging:** a downloaded job shows "Copying to staging, 5 of 14 files" from
      the `progress` the service already sends with `downloaded`, and "Copying to staging…"
      before the copy starts.
- [x] **Speed and ETA** for downloading and copying jobs, from successive `progress` bytes.
      Computed only while the window or the status item shows it.
- [x] **Search state over time:** a long search says more than "Searching": the attempt, when
      the next search runs, and whatever else the service can report (a service change if
      needed).
- [x] **Open with a selection:** opening Downloads with library rows selected opens the From
      Library sheet for them.
- [x] **Reveal in Finder** for a staged or approved job.
- [x] **Open in slskd:** a command that opens slskd's web page, at an address the service
      reports (a service change).
- [x] **Status bar item:** while a download is in progress, an item at the bottom right of the
      status bar; a click opens Downloads, a right-click picks its style (count, label,
      progress bar).
- [x] **Approve sheet:** redone calmer, with the same views the app uses elsewhere for the
      same data (DRY).

Implementation plan, phase 59 (ADR 0163). The service's half shipped first (its ADR 0014):
`downloads/config` sends `slskd_url`, a job sends `search` while `searching`, and a
`not_found` job's `reason` stays through its next search.

What exists, found by search (map.md recipes):

- `Recommender.DownloadJob` decodes the job strictly, every key required; it has no `search`.
  The client has no `config` route. `DownloadsService` holds the calls as closures.
- `DownloadsModel` polls every 2 s while the window is open and a job moves, else every
  60 s from launch to quit (the coordinator tags and imports off those polls). Nothing in the
  status bar hears it.
- `DownloadRow.state` words a state; `downloaded` is a bare "Downloaded", and `progress` is
  read only while `downloading`.
- The status bar is `LibraryBrowser`'s: its trailing stack ends with the problems button.
- The tagger's tables (`taggerTable`), Library Problems and the Downloads window and Queue
  sheet use one table look: alternating rows, full width, a bezeled scroll view. The Approve
  sheet alone shows its data as monospaced text views.
- File > Downloads… runs `showDownloads`, which calls `Downloads.show()`.

Parts, each its own commit or two, with a test that fails without it:

1. **Contract.** `DownloadJob.Search` (strict, as the rest), the fixture updated;
   `DownloadsConfig` and `RecommenderClient.downloadsConfig()`, whose `slskdURL` puts the
   service's own host in place of a loopback one, keeping scheme and port.
2. **State words** in `DownloadRow.state`: the query, its number of the count, peers and
   files while searching; the attempt and the last miss when searching again; when a
   `not_found` job searches next, or that only Retry starts one; "Copying to staging…" and
   "Copying to staging, 5 of 14 files" for `downloaded`, with its progress bar.
3. **Speed and ETA:** `TransferRates`, pure, fed by the model with its own receive times
   while the window is open only; a reading is kept when its bytes change, the speed is the
   bytes over the time across the last 6, a stalled reading holds its last speed for 120 s
   and then shows none, never 0 B/s. Tests with an injected clock.
4. **Polling pace:** 2 s while the window is open and a job moves; 5 s while the status
   bar shows and a job is on its way; 60 s otherwise, as before.
5. **Status bar item:** `DownloadsStatusItem` in Downloads, put after the problems button
   by a new `LibraryBrowser.setStatusAccessory`; shown while a job is queued, searching or
   downloading; a click opens Downloads; a right-click picks its style, the setting
   `appearance.downloadsStatusStyle` (count, text, progress bar), declared in `Settings`.
6. **Open with a selection:** File > Downloads… with library rows selected opens From
   Library Selection once the window can queue; a selection with no Discogs album opens
   nothing.
7. **Reveal in Finder** (staged through importing, and failed after staging) and **Open
   in slskd** (the window's bar, from the config route, fetched when the window opens).
8. **Approve sheet:** a table of the files (file, where it goes, the lossy-origin check)
   and for an upgrade a table of the old files with a box for each with no new file, in the
   tables' shared look (`NSTableView.inListScrollView`, the tagger's too), a single
   line of warnings and blockers above the buttons.

Result, phase 59: shipped all eight items (ADR 0163, 0145 amended), on the service's new
`search` object and `slskd_url` (music-recommender 3478991 and 5e624ae, its ADR 0014, deployed
on mbp2021). States read "Searching, query 1 of 2: 14 peers, 389 files", "Not found: …;
searching again …", "Copying to staging…" and "Copying to staging, 5 of 14 files"; the window
adds "· 2.4 MB/s, about 3 min left", averaged over six readings by this Mac's receive time,
held through a stall for 120 s and never 0 B/s, and only while the window is open. Polling is
2 s with the window open, 5 s with the status item showing, 60 s otherwise. The status item
(count, text or progress bar, `appearance.downloadsStatusStyle`) opens the window; a
right-click picks the style. File > Downloads… with a selection offers it in From Library
Selection. Reveal in Finder takes only a single folder name under staging, as Approve and
tagging now do. Open slskd strips credentials and query and puts the service's host for a
loopback one. The Approve sheet and the tagger share one table helper in DisplayText. Gate:
one correctness and one simplify review; 4 of 6 correctness findings real and fixed, 2 shown
not real with tests; `theGlassHeadersAreFrosted` fails as in every agent session. Cost:
implementer about 440k tokens, 392 tool calls, 72 min; reviewers 153k tokens, 24 calls, 2 min;
the service half 160k tokens, 57 calls, 9 min. The service's deploy wiped its job history
(three finished jobs).

Owner steps: a real download end to end, watching the State words, the speed through another
job's search, and the copy; the status item, its click and its three styles over a relaunch,
and polling back to 60 s with the status bar hidden; File > Downloads… with tracks selected;
Reveal in Finder on a staged job; Open slskd opens mbp2021's address; Approve… on a new album
and an upgrade; the toolbar at 960 points; anything left under `staging/job-2`.


