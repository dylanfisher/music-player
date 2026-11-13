# 0206. Rediscover

- **Date:** 2026-11-12
- **Status:** accepted
- **Amends:** [0198](0198-the-library-profile-export.md) (the profile's fields)
- **See also:** [0205](0205-recommendations-in-the-player.md) (the client, its timeouts and
  errors), [0102](0102-listening-stats.md) (a sidebar source with a panel),
  [0105](0105-stats-clicks-filter-and-imported-last-plays.md) (an import's Last Played)

## Context

Phase 86. music-recommender's phase 9 scores the albums the library already has by how long
since they were played, by the community's ratings and haves, and by the owner's loves, and
`POST /v1/rediscover` answers a day's draw of them with reasons and threads (its `docs/api.md`,
Rediscover). It reads three new fields of each album in the profile, `key`, `last_played` and
`skips`, and gives `key` back so the player can find the album. The owner's answers
(2026-11-12): a sidebar source like Listening Stats, with a setting to leave its row out of the
sidebar; albums never played and added recently take part; Not Now is kept by the service; the
profile is sent on its own.

## Decision

### The profile's new fields

- **`key`** is `a` and the index's album id, `a812`. The album id is what the browser's
  Album column selects and the track table lists by, so a reply maps back to its tracks with
  no lookup by name. It changes only when an index rebuild numbers the albums again, which
  the unknown key below covers.
- **`last_played`** is the latest `history` row of the album's tracks: a play recorded here or
  synced from another Mac. `plays.last_played_seconds` isn't read, since an import sets it to
  another app's Last Played, which isn't a play (ADR 0105); an album whose only date is an
  import's goes with `null`, as never played.
- **`skips`** are the tracks' skip counts summed, as the Skips column shows them, imported
  skips included: a skip has no date to tell them apart by.
- Export Library Profile… writes the same fields, so the file stays what is sent.

### The profile is sent on its own

ADR 0205 sent it only when asked. Rediscover's list is only as current as the last profile, so
it now goes unasked:

- **When:** at launch, after a scan that read or removed files, and when Rediscover opens or is
  refreshed. Each time the profile is read again and sent only if it differs from the one this
  run last sent, so a scan of a network folder that changed nothing sends nothing.
- **Not after a play.** The service scores its recommendation list again whenever the plays
  or loves in the profile change, so a send after every play would rebuild it all day.
  Rediscover opening sends the plays since; the service's list follows the next launch or scan.
- **One at a time.** `ProfileSender` keeps one send out; every ask made meanwhile is answered
  by one more send after it, which reads the profile then. A send that fails is tried again at
  the next ask; an unasked one says only its failure in the status bar, naming the address.
- **Send Library Profile to Service stays,** and sends the profile though it hasn't changed,
  through the same sender, saying what the service kept.

### The client

- **Three routes** on `RecommenderClient`: `rediscover(day:)`, `notNow(_:days:)` with 30 days
  unless asked, and `undoNotNow(_:)`, each with the usual 5 s timeout: the service answers
  from scores it already has, budgeted under 1 s.
- **Strict, as every reply:** a field missing or not in the contract fails the reply, naming
  it, and so does a reason's or a thread's `kind` this player doesn't know, which is shown as
  the panel's error, never skipped. `no_profile` is a refusal like any other.
- **The day** is the Mac's local date in the Gregorian calendar, whatever calendar it shows,
  so two Macs in one time zone ask for the same draw.

### The source

- **`BrowserSource.rediscover`,** saved as `rediscover`, is the Rediscover row after Stats in
  the sidebar's Library group, as Listening Stats is a source (ADR 0102): a panel in the
  columns' place over the track table, so the day's tracks play, queue and drag as any
  table's. The panel takes Listening Stats' height, which the divider drag saves; a second
  saved height for a panel of the same cards wasn't worth a key.
- **The panel** has the day and Refresh in its header, and three cards: Today, with how many
  albums of how many considered and when they were scored, or what went wrong; Threads, a line
  each, with the titles of the day's albums in it; and Why This Album, the selected track's
  album and its reasons, as the service words them.
- **The table** lists the tracks of the day's albums the index has, in the reply's order, each
  album in disc and track order: Rediscover opens in the Order column's sort, as a manual
  playlist does, and the user can sort it otherwise. The album ids are kept in memory on both
  of the window's connections, as the refresh connection lists a source during a scan, so no
  table is written.
- **Reading:** each time Rediscover starts showing and on Refresh, the profile is sent if it
  changed, then the day is asked for: the Mac's local date. A day's draw is the service's to
  keep the same.
- **Mapping back:** a reply's `key` is read as `a` and an album id, and the album must be in
  the index under the reply's title. A key that isn't, after the index was rebuilt or when
  another Mac sent the last profile, sends this Mac's profile, forced, and asks for the day once
  more; keys still unknown then are said in the Today card, and the albums found still list.
- **Show Rediscover in Sidebar,** `library.showRediscover`, on by default, in Settings'
  Browsing section. Off, the row goes; Show Rediscover, in the File menu beside Show Listening
  Stats, still shows the source, with no row selected, as Library Health shows.

### Not Now

- **The service's mark.** Not Now, in the track table's context menu, the File menu beside
  Show Rediscover and the Why This Album card, marks the selected tracks' albums of the day for
  30 days with `rediscover/not_now`, so every Mac leaves them out. Albums of the selection that
  aren't the day's are ignored.
- **At once, then read again:** the albums leave the table before the service answers, and the
  day is read again after, so the draw fills their place. A mark that fails is said in the
  Today card, and the read puts its album back.
- **Edit > Undo** removes the marks with `not_now/undo` and reads the day again, on the main
  window's undo manager, named Not Now.

### Not answering

- **The panel says it,** as the Recommendations window does, in the error's own words, which
  name the address tried: the header says Not answering for no answer or an address off the
  local subnets, with a line in the Today card to check the service runs there and the address
  in Settings, and Token refused for a 401, whose words say it must match `player_token`. Any
  other error is said in the Today card alone.
- **The day read before stays** in the table under the error, so a service down for a minute
  doesn't empty the source; Refresh asks again.

## Alternatives considered

- **A window of its own,** as Recommendations has. Rejected by the owner: the albums are the
  library's own, so a track table over the index holds them, and play, queue and drag work as
  everywhere.
- **The day's albums in a temporary table** on the window's connection, as Library Health's
  tracks are. Rejected: the refresh connection is read-only and lists the source during a
  scan, so it would list nothing; a list of 60 ids in memory on each connection costs nothing.
- **Matching a reply's album by artist and title** instead of `key`. Rejected: the key names
  the album row, and the title is checked against it, so an album of another Mac's profile
  isn't taken for one of this library.
- **Sending the profile after every play,** so Rediscover never misses one. Rejected: the
  service scores its recommendation list again when plays change.
- **Keeping Not Now in the player,** in the state file. Rejected by the owner: the service's
  mark holds on every Mac and the draw leaves the album out itself.

## Consequences

- The first open after a launch on a Mac that didn't send the last profile sends this Mac's,
  so the two Macs' profiles take turns at the service, each replacing the other's.
- Rediscover's height is Listening Stats', and a drag of either divider sets both.
