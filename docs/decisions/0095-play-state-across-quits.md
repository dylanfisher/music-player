# 0095. The play state across quits, in the config file

- **Date:** 2026-11-05
- **Status:** accepted
- **Amends:** [0015](0015-config-file.md), [0090](0090-one-history-for-plays-and-places.md)

## Context

The owner's feedback of 2026-11-04 night (phase 41f) asked for the app to remember, across a
quit, the track playing, how far it had played, the source it was played from, the selected
item and where the track list was scrolled, kept in the config file so it reaches his other
Macs, which share the file through a synced folder (ADR 0012). He chose to have it come back
paused, on every Mac, the one that saved it included. The track and its place matter most; the
selection and the scroll come second.

Until now the window's source was `browser.source` in `state.json`, which is per Mac and never
synced. Each Mac mounts the NAS at its own path and numbers tracks and playlists its own way.
The engine starts after the first rows draw (ADR 0070) and holds no device until something
plays. `PlaybackEngine.restore` (ADR 0090) loads the track into the output, which opens the
device, takes hog mode and reads the file.

## Decision

- **One key, `playback.resume`**, an object, null until something is saved:
  `{"track", "seconds", "from", "source", "selected", "top"}`. `from` is the source the track
  was played from, whose list is its queue; `source` is the one the window shows; `top` is the
  first visible track. It replaces `browser.source` in the state file, so the window's source
  is kept in one place. The column selections, the search and the scroll's offset within its
  row stay out, to keep the key small; the columns stay in the state file as before.
- **Names every Mac reads the same way.** A track is its sync path (ADR 0026, 0038), which each
  Mac maps to its own mount through `share_roots`, as sync does. A track in a folder stored by
  path, which sync doesn't share, is its absolute path; it starts with `/`, and only a Mac with
  the same path finds it. A source is its `BrowserSource` text with a playlist named by its
  sync ID, null for the library. A playlist made before sync and not changed since has no sync
  ID, and is saved as the library, logged.
- **Put back paused without loading.** `PlaybackEngine.cue` sets the queue and the entry,
  paused at the saved seconds with the index's length, and loads nothing. Play loads the track
  there, as a resume after a lost device does; a seek while cued moves the place. So the launch
  opens no device and reads no file, a share that's asleep fails nothing until Play, and the
  launch stays as fast as before. A cue after the user started something is ignored.
- **The queue is the list of `from`**, read off the main actor after the engine starts, in
  that source's own sort or else the table's. A track that has left the source plays alone.
- **The window** shows `source` in the first load, in place of the state file's, then selects
  `selected` and puts `top` at the top through `show(_:)`, which Back and Undo Selection use
  (ADR 0091). Each name is one lookup in the main thread's index before the rows draw. Show
  Current Track goes to `from` until the next play, as after a play.
- **What can't be found starts without it, logged:** a track this Mac's library lacks loads
  nothing; a source it lacks shows the library; a selected or top track it lacks is left out.
- **When it's written:** a track starting, a pause, a stop, the end of a seek or the queue, a
  source change and a selection change each ask for a write. It runs 5 s after the first ask,
  and at least 30 s after the last write, reading the engine and the window as they are then.
  Playing on asks for nothing, so a Mac playing an album writes about once a track. Quitting
  writes at once, waiting up to 1 s for the engine's place (`terminateLater`). A value equal to
  the file's isn't written. Saving starts only once the saved track is cued, so an early save
  can't replace it with nothing; without an output, the saved track is kept.
- **Two Macs:** the last writer wins. The config store reads the file again before each write
  and patches only this key, so another Mac's write in between is read and replaced, and other
  keys are kept. A Mac running while another writes ignores the change; the key is read only at
  launch.
- **A value of another shape reads as null** and is logged, unlike a bad value of a setting,
  which blocks the file (ADR 0082). It's state the app writes, two Macs can run different
  builds, and the next save replaces it. A config the app can't change while it's blocked logs
  the failed save.
- **No row in the Settings window or the palette**: the key's kind is `.windowState`.

## Alternatives considered

- **`restore` at launch**, loading the track paused: rejected. It opens the device in hog mode
  at every launch, before anyone plays, and reads the file from the NAS, where a share asleep
  would fail the track and skip through the queue.
- **Saving the queue**: rejected. A library-wide queue is tens of thousands of paths in a file
  the owner reads and syncs; the source's list rebuilds it.
- **Writing the position during playback**, every 30 s: rejected. It would change a synced,
  user-visible file all evening for a crash, which loses at most the position since the last
  track start or pause.
- **The state file**, which isn't synced: rejected; the owner wants it on every Mac.
- **Keeping `browser.source` beside the key**: rejected, two places for the window's source.
- **Saving the whole `WindowPlace`**, with the search, column selections and offset: rejected
  for now, to keep the key small; the column selections stay in the state file per Mac.

## Consequences

A state file written before this build names `browser.source`, which this build doesn't know,
so it's discarded once at the first launch, with the banner's notice, and the window layout
starts from its defaults. A Mac on an older build lists `playback.resume` as an obsolete key in
its banner until it's updated. The config file changes when a track starts or playback pauses,
which a sync tool uploads; a few writes an hour while listening. A crash or forced quit loses
the position since the last write. Folders stored by path come back only on a Mac with the same
path. The second Mac shows the first Mac's source and selection, with its own column
selections.
