# 0081. File access that can hang on a share runs off the main thread

- **Date:** 2026-11-03
- **Status:** accepted

## Context

The library and the sync folder are on an SMB share. When the NAS drops off the network, a
call that touches a file there can block for minutes before SMB gives up. Most of the app
already reads files off the main thread: scans, art, tags and playback each have their own
threads. A few calls on the main actor still asked the volume directly: Open Sync Folder's
`fileExists` and its open in Finder, the volume check when a watched folder or the sync folder
is chosen, and Reveal in Finder, which looks at the files it selects. Any of them on a hung
share froze the window. Quitting waited on the output's close, which runs on the output's
control thread, and that thread decodes from the file being played, so a read stuck on the
share held the quit forever too.

## Decision

`blockingFileWork` (Metadata) runs a closure on a global dispatch queue and returns its result
to the caller's actor, as the tag editor's read already did; it now uses it too. Open Sync
Folder looks the folder up there (`existingSyncFolder`, Library) and opens it there; choosing a
folder finds what to watch there (`folderToWatch(at:)`, Library); Reveal in Finder and in
Searcher runs there. Paths the app keeps locally, the config file and a library file moved
aside, still reveal on the main thread.

Quitting waits at most 6 s for the outputs to close (`finishes(within:)`), longer than a
device's format restore, which waits up to 3 s. Past that it logs and quits, and the device's
restore record, written when the app took it, puts it back at the next launch. The renderer
output's `close()` can block too: it stops the HTTP server with `queue.sync`, and that queue
also runs the `pread` of the file being served, so a hung share holds it. It closes in the same
bounded wait, concurrently with the device output, so one constant bounds both.

Choosing the sync folder more than once before the first check returns applies only the last
pick; a counter drops an earlier check that comes back late.

Get Info reads every selected file before the editor opens. Above 200 files it asks first,
naming the count and saying the read may take minutes on a network share
(`TagEditing.confirmReadAbove`). 32d measured 200 NAS tracks at 3.2 s, about 16 ms a file, so
200 is the largest read measured to be a short wait; the fixture library reads in 0.06 ms a
file locally, which makes a whole library 2.4 s here and minutes on the NAS.

## Alternatives considered

- **A timeout on each file call** — rejected: POSIX file calls take no timeout, and a thread
  blocked in one can't be cancelled, so a timeout still needs the call on another thread.
- **Checking that the share is mounted first** — rejected: a share can be mounted and not
  answering, which is the case here; the mount list is already read without asking volumes
  (`MNT_NOWAIT`).
- **Closing the output without waiting at quit** — rejected: on a healthy device the close puts
  back its format and hog mode, which the user expects at once, not at the next launch.

## Consequences

- A call stuck on a share holds a dispatch thread until SMB gives up; GCD adds threads, so
  other work goes on.
- Choosing a folder and Open Sync Folder finish a moment after the panel closes instead of
  before it returns.
- A quit during a hung read leaves the DAC at the app's rate and format until the next launch
  restores it; Core Audio ends hog mode when the process ends.
