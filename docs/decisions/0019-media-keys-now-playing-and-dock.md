# 0019. Media keys, Now Playing and the Dock menu run registry commands and set the time only on state changes

- **Date:** 2026-10-31
- **Status:** accepted

## Context

Phase 8 adds media keys and headphone buttons (`MPRemoteCommandCenter`), Now Playing in Control
Center with art (`MPNowPlayingInfoCenter`), and a Dock menu. Every action already goes through
the command registry and `CommandDispatcher` (phase 6), and the engine publishes one stream of
updates. Playback CPU is at 2.8% against a 3% budget, so nothing new may tick while playing.
MediaPlayer is a system framework, available on macOS 12 for everything used here.

## Decision

- **The logic is in `Features/NowPlaying`**, beside the bar's `NowPlayingModel`, which it reuses
  for the title, artist and album. `MediaControls` works through two protocols,
  `RemoteCommandCenter` and `NowPlayingCenter`, which `SystemRemoteCommands` and
  `SystemNowPlaying` implement on MediaPlayer; tests use fakes. The App tier only builds them,
  connects the engine and answers `applicationDockMenu`.
- **Remote commands run registry commands.** Toggle, play and pause run Play/Pause (play while
  playing and pause while paused do nothing and report success); stop, next and previous run
  Stop, Next Track and Previous Track. A command is offered only while the dispatcher has it on
  and the state allows it, and the set is sent to the system only when it changes.
- **The scrubber seeks the engine directly**, as the bar's slider does. Commands take no
  argument, and a position needs one.
- **No skip-by-interval commands.** With `skipForward` and `skipBackward` on, Control Center and
  headphones offer ±seconds in place of next and previous track, and the owner's keys skip
  tracks.
- **The time is set only on state changes.** The engine publishes `.seeked(seconds:)` after a
  seek. Now Playing is set on track start, pause, resume, seek and device changes, with the
  position read from the output, and cleared on stop, on failure and at the end of the queue.
  The system extrapolates the time from the last value and the rate (1 playing, 0 paused).
  Other events set nothing unless what's shown changed, such as art arriving or a rescan
  retitling the track; then the time carries on from the last value by an injected clock. Since
  every state change re-reads the output's position, which runs on the DAC's clock, the system's
  count can drift from it only within one uninterrupted stretch of playing: at 50 ppm, 30 ms over
  ten minutes.
- **Art comes from a second `ArtworkLoader`** at 512 px with room for two images, decoded off
  the main thread. The bar's loader holds 64 thumbnails at 96 px, which would look soft in
  Control Center, and putting large images in it would cost 64 MB. The system's request for a
  size gets the decoded image wrapped at that size, never upscaled.
- **The Dock menu** lists the current track's title and "artist — album" while playing or
  paused, then Play/Pause, Next Track and Previous Track with the registry's titles, each enabled
  from the dispatcher. It's built each time the Dock asks.

## Alternatives considered

- **A timer that sets the time every second** — rejected: it wakes the main thread while
  playing, against the CPU budget, and the system already extrapolates.
- **A new feature module** — rejected: features can't import each other, so it would duplicate
  the model's title and subtitle rules.
- **A "seek to position" command** — rejected: the registry's commands take no argument, and
  one that did would have no menu item or chord.
- **Reusing the bar's art cache** — rejected for the size and memory reasons above.

## Consequences

Anything else that shows the time can follow `.seeked` instead of polling. The MediaPlayer
adapters are tested only on the owner's DAC Mac (the phase 8 checkpoint). If a remote command
arrives off the main thread, it's run on the main actor afterwards and reported as done.
