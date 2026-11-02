# 0046. A device failure stops playback, and three failed tracks in a row do too

- **Date:** 2026-11-02
- **Status:** accepted

## Context

The owner turned hog mode off while a track played. `DeviceOutput.use(_:)` closed the device,
which restores it and releases hog mode, and reopened it for the track playing
([0037](0037-device-profiles.md)). Configuring the device failed, and the output reported that
as the track failing (`trackFailed`, then `finished`), the same as a file that won't open. The
engine skipped to the next track, whose load reopened the device straight after the failed
track's close had restored it, and failed the same way. Skipping only stopped once every track
in the queue had failed ([0011](0011-playback-engine-and-hal-output.md)), so the whole list went
by in a few seconds, each with its own "Couldn't play" message.

Two things were wrong: a device failure was reported as a file failure, and nothing bounded a
run of file failures short of the queue's length. A run of file failures usually has one cause
too, such as a share that went offline.

## Decision

- **Configuring the device is the device's failure.** `DeviceOutput` checks a track against the
  device's formats before it touches the device (`refuseUntakeable`), so once a track is past
  that, an error from `configure` (the device's rate and format, then the ring buffer for it) is
  reported as `.failed` for that item, after the device is released. The engine stops on
  `.failed` without advancing and publishes it once. This holds for the first load, the reload
  after a settings change or device switch, and the rate switch between tracks. A decoder
  error while feeding the track stays a failed track, which is skipped.
- **Three failed tracks in a row stop playback.** `PlaybackEngine.failureLimit` is 3. The count
  is the existing `failuresInARow`, reset when a track starts, the queue is replaced, play is
  pressed or a track is chosen. Once it reaches the limit, or the queue's length if that is
  shorter, no next track is handed over. When the output finishes, the engine stops, and
  publishes `.failed("3 tracks in a row couldn't play")` instead of `.finished` if the limit was
  the reason.

## Alternatives considered

- **Retry the reload after a pause** — rejected: nothing the app knows says when, or whether, a
  device that refused a setting will take it, and a retry loop hides the error the owner needs
  to see.
- **Classify errors by type in the engine** — rejected: the engine sees `any Error` from every
  output. The output knows which step failed, so it picks the event.
- **Stop on the first failed track** — rejected: one missing or corrupt file in an album
  shouldn't stop the album.

## Consequences

The now-playing bar shows at most three "Couldn't play" messages, then "Playback stopped" with
the reason. Pressing Play starts the count again. A device that won't take a setting now
stops playback with the device's own error, which names the cause, instead of the track's.
