# 0118. The hog mode fix plays the chosen track; playback log values are public

- **Date:** 2026-11-06
- **Status:** accepted
- **Amends:** [0025](0025-threat-model.md) (row 35, the log), [0111](0111-playback-errors-for-people.md)
  (a fix that can't replay, and the log's values in the details)

## Context

The owner's feedback of 2026-11-06 (part 50b). With hog mode off, double-clicking a DSD track
and choosing Turn On Hog Mode in the dialog started the first row instead. A play from a list
runs as a one-track queue until the whole list is read (ADR 0078), and DoP's refusal comes
before the list does, so the failure named entry 0 of the one-track queue. Once the list
arrived the album's next tracks failed too, the engine stopped on entry 0, and the fix found
row 0's track at entry 0 and only logged that it wouldn't play it.

The owner also asked whether the playback log lines should be public, so Copy Details shows
their values instead of `<private>`. ADR 0111 had left that out. `os.Logger` keeps every
interpolated string private unless it's marked, numbers public; the errors were strings, so
the details showed lines like `<private> went away: <private>`. Some errors name a path:
`MetadataError`, which the DSD reader and the MP3 length check throw, prints the file's path
first, and the HTTP server's "isn't a regular file" names the served file's.

## Decision

- **A failure before the queue is about the chosen row.** While `play(starting:completing:)`
  waits for its queue, a failure is recorded and its event held, as the track's end already
  is. When the queue arrives, every failure recorded so far, all of them of the one track,
  moves to that track's entry in the whole queue, and the held events go out before the end
  is handled. When the queue isn't coming, they go out with entry 0, which is right for the
  one-track queue that stays. A new queue drops them; the log has each.
- **A run of failures stops on its first track.** Playback stopped by failures in a row
  points the cursor at the first of them, so Play tries the track the user chose or moved to
  again; at the queue's end it points at the start as before. A queue shorter than the limit
  whose every track failed ends as it did, at the start: that's the queue's end, not a stop.
- **A fix that can't replay says why.** `replayPosition` is unchanged and never plays a
  different track. When it refuses, an alert sheet on the window the fix was asked from (the
  main window under the dialog, or the Playback Problem window) says the fix is made, why the
  track isn't played and to play it from the list. ADR 0111's "it only logs why" no longer
  holds.
- **The log's values are public, except paths.** The values that are the app's own or the
  device's are logged `privacy: .public` in Playback, HALOutput and UPnPOutput: errors,
  OSStatus codes and four-character codes, formats, device names, UIDs and IDs, renderer
  names and addresses. A track's path is logged `privacy: .private(mask: .hash)`, so the
  lines about one file share a hash and can be matched without naming it.
- **An error about a track is logged without its path.** `logText(_:without:)` in Log gives
  the error's description with the track's path replaced by "the track's file", and that is
  what's public. Errors that aren't about a track (HAL, OSStatus, SOAP and device description
  problems, `DeviceOutputError`, `HALDeviceError`, the renderer's) name no path and are
  logged public as they are. A run of failures is logged by its count only: a cause's message
  is an error's whole text when the error isn't a `PlaybackFailure`, and each track's own line
  already has its error. `logText` removes the path exactly as given; an error that names the
  file another way (its name alone, percent-encoded) keeps that, and none of the logged ones
  does now.
- **What stays private:** the HTTP server's problems for a renderer (`serving <renderer>: …`),
  which can name a served file's path, and every module outside the three Copy Details reads.

## Alternatives considered

- **Re-sending the failure with the right entry once the queue arrives**: rejected. The dialog
  is already up for the first event, and only one dialog shows at a time, so the second would
  never reach the user; holding the event costs only the time the list takes to read.
- **Remapping entries in the dialog instead of the engine**: rejected. The engine is the one
  that knows the queue changed under the failure; the dialog, the details and the run's
  causes would each have to repeat it.
- **Logging errors public as they are**: rejected. `MetadataError` prints the path, which
  would then be in the stored log for anyone who runs `log show`.
- **Keeping errors with a path private**: rejected. The decoder's and the DSD reader's errors
  are the most common track failures, and they are what the owner wants to read.
- **Logging file names public**: rejected. A file name is the path's most telling part, the
  album and track title; the hash matches lines just as well.

## Consequences

Copy Details shows the playback log's values; `log show` prints them for every user too, and
a track's path only as a hash. A new log line in the three modules marks its values public
and logs a path hashed; a new error type whose description names a path is logged through
`logText(_:without:)` with that path. `scripts/arch.swift` fails an interpolation that names
a path or URL and marks it public, outside `logText`; it reads names, so a path held in a
variable named otherwise passes it, and review catches that. An error type that starts
naming another file's path, not the track's, would be public through `logText`; none does
now.
