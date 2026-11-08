# 0143. Separate Releases: an album of each Discogs release

- **Date:** 2026-11-08
- **Status:** accepted
- **See also:** [0129](0129-custom-tag-fields.md) (the release id among the custom keys),
  [0136](0136-asking-before-a-rescan-and-undoing-a-tagger-write.md) (the rescan question),
  [0142](0142-library-snapshots.md) (the relaunch, and restores)

## Context

An album is its title and artist (`albums_identity`). A 2025 remaster tagged with the original's
title and artist merges with the original: one album with two track 1s, interleaved, under one
year. The Discogs tagger writes each file's release id (`DISCOGS_RELEASE_ID`), which tells the
two apart (53.13).

## Decision

- **Identity:** `albums` gains `release_id TEXT NOT NULL DEFAULT ''`, and `albums_identity` is
  `(title, ifnull(artist_id, 0), release_id)`. With Separate Releases on, a track's album takes
  its release id, trimmed; off, every album's is `''`, which is the old identity. A track with
  no id has `''` either way, so idless tracks of one title and artist still share one album.
- **A setting, not a rule per album:** `library.separateReleases`, Separate Releases, off by
  default, in the General pane's Library group and the File menu. Splitting or merging single
  albums by hand would need a table of overrides that a rescan keeps; the release id already
  says which files belong together.
- **The release, not the master:** a master id is shared by every version of a release, the
  remaster and the original included, so it would merge them again.
- **The option is in the stored index SQL:** the index part's SQL starts with
  `-- separate releases: on` or `off`, so changing it rebuilds the index part, and the file
  says which way its albums were made. `LibraryIndex.init` takes `separateReleases: Bool?`,
  default nil, which adopts the stored option (off for a new file). Only the window's first
  open at launch passes the setting. Some 15 other connections open the same file (the
  reader, the scanner, the watcher, the caches, the snapshot scheduler and restore, the tools
  and tests); with a plain `Bool` defaulting to off, any of them would see the index as stale,
  drop it and refill it without release ids. An open that passes nil reads the option again
  inside the rebuild's transaction, so it never undoes a rebuild another connection committed.
- **The question says the direction:** `RescanNotice` carries the option when this open changes
  it, and its text starts with "Albums are made of each Discogs release, ..." or "Albums are
  made of title and artist again, ...". `SchemaPart.rescanWhy` is one fixed sentence per part
  and can't know a direction. When the option is the only difference (the stored SQL equals the
  index's SQL built with the stored option), the index's "new shape" sentence is left out, as
  it wouldn't be true.
- **A change while the app runs** asks on the Settings window, or on the main window when made
  from the File menu or the config file, with Rescan Now and Cancel. Cancel sets the setting
  back. Rescan Now relaunches through the relaunch 0142 added for restores, now in
  `Relaunch.swift`, since every connection has to close before the index is rebuilt. It passes
  `--rescan-confirmed on` (or `off`), the value the answer was for. The next launch's open
  takes that as the answer only when Separate Releases changing to that value is the whole
  notice (`RescanNotice.onlySeparatesReleases`); a new shape, a restore waiting with an older
  index, or a config edited to the other value still asks. The relaunch drops the flag and its
  value from the arguments it forwards, so a later relaunch doesn't carry them.
- **A launch with the setting changed** (edited while the app was closed, or after a restore
  of an index built the other way) asks 0136's Rescan Now / Quit. Quit leaves the file as it
  was, so the next launch asks again until the owner rescans or sets the option back.
- **Order:** the Album pane sorts by title, then year (the earliest track's, with the subquery
  Albums by Year uses), so releases of one title list oldest first, and one with no year last,
  as Albums by Year puts albums with none. The track table's fallback
  order adds the album id after the album title, so each release's tracks stay together; it
  sorts by no year, which would cost a subquery per track row, so two releases come in the
  order they were added.

## Alternatives considered

- **A `Bool` every open passes:** rejected above; one forgotten caller rebuilds the index.
- **Asking only at the next launch:** a Quit there leaves the setting changed and the question
  back at every launch. Asking at once has a Cancel that sets it back.
- **A third launch button, Keep, that opens with the stored option:** not needed while the
  config file can be set back by hand; it would make the launch question differ by cause.
- **Rebuilding in place, without a relaunch:** the scanner, the watcher and the readers hold
  their own connections and statements on the tables a rebuild drops.

## Consequences

With the option on, a remaster and its original are two albums, each under its own year. Two
releases of one title and artist read the same in the Album pane, told apart only by order,
oldest first and a release with no year last. Everything else that groups by album id follows:
Listening Stats' top albums, Library Health's album rows and the Discogs tagger's albums list
the releases as separate rows of the same name. Turning the option on or off reads every file
again; plays, ratings and playlists stay.

`--rescan-confirmed` covers one launch and one question: the option changing to the value it
names, with nothing else to rebuild. It isn't forwarded by a later relaunch, and the relaunch
that passes it gives up after 30 seconds if the quit was cancelled.
