# 0111. Playback errors say why in plain words, open their details and offer their fix

- **Date:** 2026-11-06
- **Status:** accepted
- **Amended by:** [0118](0118-hog-mode-fix-plays-the-chosen-track-and-log-values.md): a fix
  that can't play its track again says why in an alert, and the playback log's values are
  public, paths hashed.

## Context

The owner's third round of feedback of 2026-11-05 (part 48c). When a track couldn't play,
the status bar showed "Playback stopped: " and the error's `description`, which is often a
type name or an OSStatus code. The owner hit it playing a DSD file with hog mode off, where
`DeviceOutputError` already had the reason in words. Nothing showed more than that line,
nothing offered to turn hog mode on, and tracks failing in a row ended on a count alone.

## Decision

- **Every error that can stop playback has a message for people beside its description.**
  The protocol `PlaybackFailure` in Playback asks for `userMessage`, a short lowercase clause
  that reads after "Playback stopped: " or "Couldn't play a.flac: ", with no type name or
  code, and an optional `fix`. `PlaybackError`, `DeviceOutputError`, `HALDeviceError`,
  `HALDeviceProviderError`, `HALError`, `OSStatusError`, `RendererOutputError` and
  `MetadataError` adopt it, each message in a switch next to its description. An OSStatus
  error's message goes by the API that failed: decoding, converting or the device.
  `MetadataError`'s message is by kind, in Metadata; Playback imports Metadata so the
  conformance sits with the protocol.
- **The events carry a `PlaybackProblem`**: the message, the error's full text, the fix and,
  for tracks failing in a row, their causes. An error that isn't a `PlaybackFailure`, such as
  a test stand-in, shows its description as the message. The status bar shows the message;
  the command line and the bench print the full text.
- **A problem in the status bar opens its details.** A question mark follows it, and a click
  on either opens the Playback Problem window: the message, the track and its format, the
  output device and its format from the last signal path, the device's hog mode setting, the
  error's full text and the Playback, HALOutput and UPnPOutput log lines of the last 10
  minutes, which Copy Details puts on the pasteboard as text.
- **The log comes from `OSLogStore` for the current process**, read off the main thread, as
  opening the store takes seconds. A value logged without `privacy: .public` reads as
  `<private>` there.
- **A fix is a `PlaybackFix`**, with one case: turn on hog mode for a device, by UID. DoP
  refused because hog mode is off carries it, with a message that names neither the DSD rate
  nor the device, so every DSD track refused for it has one cause. A problem with a fix shows a dialog at once,
  and the details window shows the fix as a button. Either sets `output.hogMode`, which the
  config mirrors from the device in use, so the existing settings path saves the device's
  profile and moves the output to it. It plays the failed queue entry again, which the event
  carries, while that entry still holds the track and is the current one or nothing plays,
  as after tracks fail in a row from mid-queue and the engine points back at its start. With
  another track playing or paused, or the entry changed, it logs why and, since ADR 0118, says
  it in an alert. A fix for a device that is no longer the output beeps. Hog mode held by another
  app names that app, from its pid's process name, with no fix; a device that reads as held
  by no one after the app asked for it says so, naming no app.
- **Tracks failing in a row say why.** `PlaybackError.failedInARow` carries each track and
  its problem, grouped into causes by message and fix. One cause: the message says it. A
  fix every cause shares is the run's. Several: the message counts them, and the dialog lists each with its
  number of tracks and a Show Details button.
- **One dialog at a time.** A dialog is a sheet over the main window, and none shows while a
  sheet is up there, so a DSD album with hog mode off asks once.

## Alternatives considered

- **Using `localizedDescription` for errors without a message**: rejected. For a Swift error
  it reads "The operation couldn't be completed. (Module.Type error 1.)", which is the type
  name the part removes.
- **Messages in one table in the UI**: rejected. A case added to an error without a message
  would compile; beside the error, the switch over its cases has to cover it, and a test
  walks every case for a message that reads as plain text.
- **Marking every playback log value public** so the details show paths and errors in full:
  left out. It changes what `log show` prints for every user, and the details already have
  the error's full text and the track's path.
- **Naming the app holding hog mode with `NSRunningApplication`**: rejected. HALOutput is a
  core module without AppKit; the process name is what `proc_name` gives, which for an app
  is its executable's name.

## Consequences

A new error that can reach the engine adopts `PlaybackFailure` with a message and is added to
its module's message test. Opening a problem's details reads the process's log, which can
take seconds before the lines appear; the rest of the window shows at once. The details window
shows one problem at a time, the last one opened.
