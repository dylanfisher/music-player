# 0211. An output that goes away falls back to System Default, paused

- **Date:** 2026-11-19
- **Status:** accepted
- **Amends:** [0011](0011-playback-engine-and-hal-output.md) (the lost device),
  [0023](0023-failure-table.md) (the unplugged DAC's row and the rejected alternative),
  [0037](0037-device-profiles.md) (returning while the other device plays),
  [0045](0045-output-picker.md) (the check mark and the search)

## Context

The owner (2026-11-19): "audio output device should fall back to using default if the other
one you were listening to goes offline", and "when i first start music-player, i don't see the
denon input in the list of output devices. can we show a searching indicator". Until now a lost
device or renderer paused playback and nothing moved: ADR 0011 rejected following macOS to the
new default because it would play out of the speakers at the DAC's volume. The owner chose to
fall back to System Default and stay paused, so nothing plays on the speakers until Play is
pressed, and to keep searching for renderers only when a list opens (ADR 0045), with a row that
says a search is running.

## Decision

**The fallback.** When the output the config names goes away, a device `output.deviceUID`
names or the renderer `output.renderer` names, playback moves to System Default (resolved as
ADR 0066 says), paused where the loss left it. Nothing plays until the user presses Play, and
System Default plays with its own profile's volume and hog mode, so the DAC's volume never
reaches the speakers. The config isn't written: `output.deviceUID` and `output.renderer` keep
naming the chosen output, and the menus' hog mode and digital volume keep showing its profile.
When the chosen output returns, playback moves back to it, paused or playing as it is then.
The user never chose System Default, so unlike ADR 0037's return this one happens while
System Default plays too.

**Where it lives.** The app decides, since only it knows what the config names and builds
System Default's profile: it reacts to the engine's `deviceLost`. The move happens where each
output's return is already watched for:

- **A device:** `DeviceOutput.fallBack(to:)` moves to System Default's device the way a pick
  after a loss does (ADR 0037), so the lost device is remembered and watched through its own
  listeners, and output returns to it when it reads as connected. The move reports
  `fellBack` rather than `deviceReturned`, and the return reports `deviceReturned`.
- **A renderer:** `PlaybackEngine.fallBack(to:)` moves to the device output without stopping
  the lost `RendererOutput`, which goes on asking every five seconds whether the renderer
  answers (ADR 0041); a stop would end that. The engine keeps reading the lost output's
  events, and its `deviceReturned` moves playback back to it. The device output moves to
  System Default first when `output.deviceUID` names another device, and back once the renderer
  has returned.

**What the user sees.** Now Playing says "The output went away, so playback paused and moved to
System Default. Press Play to play there; it moves back once the output returns." Controls ▸
Output, the toolbar's Output menu and the ⌘K rows check System Default, with the chosen output
listed as "(not connected)" or "(not found)" as before. The Settings window's Output Device
popup still shows the config's value, the chosen output, since that's what the setting holds.
On the return, Now Playing says the device is back, as now, unless something plays.

**When there's nothing to fall back to, it stays lost, as before:** `output.deviceUID` is null
and no renderer is set (System Default is the device that went), System Default resolves to the
device that went, or macOS has no default output. A System Default device that goes before
the device output moves to it leaves the fallback undone, on the device that went. A System
Default device lost during a fallback is lost the same way, and the chosen output still gets playback back when it returns.

**Ending a fallback.** A pick, or an edit of `output.deviceUID` or `output.renderer`, ends it:
output moves as for any change, and a pick of the chosen output, which changes no setting,
moves playback back to it, lost until it returns. ADR 0037's return applies from then on. An
edit of `output.hogMode` or `output.digitalVolume` during a fallback is saved to the chosen device's
profile, which the config shows, and output stays on System Default. For the same reason a
playback problem's details show System Default's device's own hog mode during a fallback, and
its Turn On Hog Mode fix beeps rather than turn hog mode on for the chosen device; picking
System Default ends the fallback, and the fix works then.

**The Searching row.** While a renderer search runs, Controls ▸ Output, the toolbar's Output
menu and the Settings popup end with a disabled "Searching for network players…" row. An open
menu or popup updates when the search starts and when it ends. Searches still start only when
one of the menus or the popup opens. The ⌘K output rows have no Searching row: the palette
lists its rows once as it opens and has no rows that change while it's open, so one would stay
after the search ended.

## Alternatives considered

- **The whole fallback in the engine,** with a second `DeviceOutput` for System Default —
  rejected: two outputs would hold profiles, signal paths and restore records for the HAL, and
  ADR 0037's watch of the remembered device already does the device's half.
- **The whole fallback in the app,** writing System Default to the config — rejected: it loses
  the user's choice, and the return would have to tell the app's own write from the user's.
- **Searching for a lost renderer on a timer** from the app — rejected as in ADR 0045, and the
  output already probes for it.
- **Falling back to the device `output.deviceUID` names when a renderer goes** — rejected: the
  owner chose System Default for both.
- **Searching for renderers at launch** so the Denon is listed at once — rejected by the owner,
  as in ADR 0045.

## Consequences

- A device that comes back while System Default plays takes the music back mid-track, at its own
  volume.
- The config can name a device or renderer that isn't playing; the pickers' check mark and Now
  Playing say what is.
- A quit during a fallback leaves the config naming the chosen output, which the next launch
  plays on, or loses again and falls back from at the first Play.
