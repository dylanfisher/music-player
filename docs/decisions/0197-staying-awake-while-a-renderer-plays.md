# 0197. Staying awake while a renderer plays

- **Date:** 2026-11-10
- **Status:** accepted
- **See also:** [0041](0041-upnp-output.md) (the UPnP output)

## Context

Playing to the Denon from the 2015 MacBook Pro on battery stopped about a minute after the
display slept. That Mac's battery profile has `displaysleep 5` and `sleep 1`, and `pmset -g log`
showed an `Idle Sleep` each time. Playing to a local device keeps the Mac awake because
CoreAudio holds a power assertion while a device's IO runs. A renderer pulls the stream from the
app's HTTP server instead, so no IO runs, and the app held no assertion of its own.

## Decision

- **The renderer output holds its own assertion while the engine says the track plays.**
  `RendererSession` settles it after each command and each poll from one fact,
  `current?.playing == true`, beside the ticker's want. Pause (also one queued while the
  renderer starts), Stop, a pause on the renderer's own remote once the session follows it, a
  refused or failed track, a lost renderer and the queue's end all clear that fact through
  paths that already existed, so none of them needs a release of its own. `close()` releases
  it at once, without waiting on the session, and no later hold takes one.
- **A renderer that never starts a track fails it.** Before a renderer has said it plays a
  track, the app's clock doesn't run, so a renderer that stays `TRANSITIONING`, or in a state
  the app doesn't know, would keep `playing` true, and the Mac awake, for good. After
  `notStartingTransitionPolls` such polls in a row (30, half a minute) the session sends Stop
  and reports the track as never started, as it does for one that stops without playing. Once
  a track has started, the clock runs and its deadline ends any wait.
- **One assertion, taken on a change.** `SleepAssertion` creates one only when the want turns
  true and releases it when it turns false, so a poll each second can't take a second one. A
  failed create is logged as an error with its IOReturn and tried again only at the next change,
  so it doesn't log each second either.
- **`PreventUserIdleSystemSleep`, not `PreventUserIdleDisplaySleep`.** The display has nothing
  to show for audio and on battery it should still sleep. Idle system sleep is what stopped
  playback. This assertion type still lets the lid, a user's Sleep and a low battery sleep the
  Mac, the same as local playback, which the CoreAudio assertion doesn't prevent either.
- **Named for the app and the renderer**, "Music Player playing to Denon AVR-X1800H", so
  `pmset -g assertions` says who holds it and why.
- **Nothing for a local device.** CoreAudio's assertion already covers it, and a second one
  from the app would only be a second thing to release.

## Alternatives considered

- **`ProcessInfo.beginActivity(options: .idleSystemSleepDisabled)`.** It takes the same
  assertion, but returns an opaque token and reports no failure, so a failed create couldn't be
  logged.
- **Holding it while a track is loaded, paused or not.** A Mac left paused on a renderer
  would never idle-sleep.
- **A primitive in `Sources/Primitives`.** It has one caller; it moves down if a second one
  comes (principle 3).

## Consequences

- While a renderer plays, the Mac stays awake on battery until the lid closes, the user
  chooses Sleep or the battery runs low; the display sleeps on its own schedule.
- Paused on a renderer, the Mac idle-sleeps as it would with nothing playing.
- The want follows the engine, a command behind: it's settled as each command or poll ends,
  so it lags by at most one action's timeout, far short of any idle-sleep delay. A Pause
  given while the renderer is still starting releases the assertion at once, though the
  renderer streams on until the next poll sends the queued Pause, a second or so.
