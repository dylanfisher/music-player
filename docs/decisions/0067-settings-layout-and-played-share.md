# 0067. Settings in titled boxes with checkbox titles on the right; a play counts at a set share

- **Date:** 2026-11-03
- **Status:** accepted
- **Amends:** [0018](0018-playlists-and-stats.md) (when a play counts),
  [0042](0042-window-layout-and-settings-sections.md) (the sections)

## Context

The owner compared our Settings window with Swinsian's on the 2015 MacBook Pro. Ours had every
title in a right-aligned column on the left, a checkbox included, so long titles were cut off
("Pause Network Rescans While Playi…") and the controls were pushed to the right half. The
receiver's three settings read as unrelated rows. Network Scan Readers was an empty number field
nobody could make sense of, the sync folder's full share URL pushed its buttons out of the
window, and File Viewer offered Searcher on Macs without it. The owner also asked whether a
track counts as played before its end, and for a setting, 75% by default.

## Decision

- **Titled boxes.** Each section is a title over a box of its rows: Library, Sync and Receiver
  in General; Audio Output and Play Counts in a new Playback pane, as Swinsian has an Audio pane, so
  General fits a 900-point screen; Appearance alone in its pane. The labels on the left share
  one column width across a pane, the widest label's, so the controls of every box line up. The
  box is a custom `NSBox` drawn behind the rows, not the rows' container: an `NSBox` doesn't
  size itself from its content view's constraints, and the one-row boxes collapsed.
- **A checkbox carries its own title on its right**, with the summary under the title, as
  Swinsian and the system settings have it. Only pop-ups and fields keep a label on the left.
  Titles stay in title case, since the same title is the palette's and the menus' command.
- **A section's switch.** A section may name one checkbox that turns the rest on: the receiver's
  Receiver Control comes first in its box, and the address and volume keys rows are disabled
  while it's off.
- **Network Folders.** The two network rescan settings move to a box under the Watched Folders
  list, as Swinsian puts its watched folders' settings there. Sections now match the longest
  key prefix, so these two full keys win over `library.`.
- **Left to the config file.** Network Scan Readers has no row: it's a tuning number, and
  "none" already tunes it. File Viewer has no row unless an app with Searcher's bundle ID is
  installed when the window is first made. Choosing either in ⌘K opens the config file.
- **The sync folder's row** shows the folder's own name, truncated, with its full place as the
  tooltip, and Change… (Choose… when there's none), Open and Clear. Open finds the folder where
  its share is mounted now, with the watcher's lookup, and opens it in Finder. A share that isn't
  mounted, a share name mounted from more than one host, and a folder that isn't there each
  say so in a sheet.
- **A play counts at a set share.** `playback.playedPercent`, 1 to 100 and 75 by default, is
  the share of a track that has to play, not paused, for it to count. It replaces 0018's "half
  or 240 s, whichever is first", so a long track no longer counts after 4 minutes; 240 s stays
  only for a track whose length isn't known. A track that reached its end counts within a second
  of its share, since the wall-clock time from start to end can come out a little short of the
  length, so 100% counts a track played through. A change applies from the next track.

## Alternatives considered

- **Keeping the 4-minute cap** beside the share. Rejected: the owner asked for "X% listened",
  and with the cap a 20-minute track counts at a fifth of it, whatever the setting says.
- **A pop-up of fixed shares** (50, 75, 90, 100%) for the threshold. Rejected: a choice needs
  string values in the config file, and a number field takes any share the owner wants.
- **A Searcher check on every reload**, so installing Searcher shows the row at once. Rejected:
  it's a Launch Services lookup on each settings change for a rare event; reopening the app
  shows it.
- **Removing Network Scan Readers.** Rejected: `--scan --readers` and the benchmarks tune with
  it, and a config file that sets it should keep working.
- **Sentence case for the checkbox titles**, as Swinsian writes them. Rejected for now: the
  titles are also the commands' names in the palette and menus, where title case is the rule.

## Consequences

The Settings window is taller: each box adds its title and margins. A setting added under a new
key prefix still appears under Other with no UI code. A config file that sets
`library.networkScanReaders` or `library.fileViewer` keeps working; only the window leaves them
out.
