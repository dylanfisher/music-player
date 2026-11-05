# 0037. Each output device keeps a profile in the state file

- **Date:** 2026-11-01
- **Status:** accepted
- **Amended by:** [0098](0098-scan-adds-by-folder-hog-mode-off-ember-icon.md): `output.hogMode`
  is off by default, and a device seen first hogs only when it's on and its kind allows it.

## Context

Phase 22 makes each output device remember its own volume, digital volume and hog mode, with
nothing to set up, and the rates and formats it reported. The owner switches between an RME
ADI-2 and the built-in output, and powers the ADI-2 off and on. Until now the output played on
the one device `output.deviceUID` names, and a change to any output setting waited until
playback stopped. Stored data has one shape before release, and the IO proc can't change.

## Decision

- **A profile per device UID in the state file.** `output.profiles` in `state.json` is a list of
  `DeviceProfile`: UID, hog mode, digital volume, volume in dB, and the device's last reported
  `DeviceFormats` (the HAL's available nominal rates and the first output stream's physical
  formats). It follows the state file's rules: one shape, unknown or missing keys at any level
  discard the file, written with `StateStore.set` before the change it protects (a switch, a
  volume step). At most 32 profiles, most recently used first; using a device moves it to the
  front, and the 33rd evicts the least recently used. Each keeps at most 64 rates and 64 formats
  and a UID of at most 512 bytes, so the file stays under about 300 KB whatever devices report.
- **The config's output settings show the device in use.** A device seen for the first time
  takes `output.digitalVolume` as it is, at full volume (there is no volume setting), and hog
  mode from its transport type (amended below). After that:
  - an edit to `output.hogMode` or `output.digitalVolume` (in the file, the settings window or
    the Controls menu) applies to the device in use only. Other profiles keep theirs; unseen
    devices start from the edited digital volume.
  - changing `output.deviceUID` switches to that device with its own profile, and the app writes
    that profile's hog mode and digital volume back into the config, so the menus and the
    settings window read what the device plays with. Null stays null while it names the device.
  - at launch the config's values are taken as an edit to the device it names. An edit made with
    the app closed therefore applies; a device change made with the app closed gives the new
    device the old one's values. That's the price of not keeping a second copy of the config.
- **Switching is mid-queue.** `DeviceOutput.use(_:)` takes a `DeviceChoice` (provider, digital
  volume, gain, recorded formats), closes the old device, which restores it, and reloads the
  track playing on the new one at the same position, paused or playing as it was, with the same
  next track. The reload isn't announced as a new start, so it isn't counted as a play. A change
  of hog mode or digital volume on the device in use goes through the same path. Gain still
  reaches `HALRenderSetGain` only through the control thread.
- **Refused before playback.** Before a track is loaded or queued next, it is checked against the
  device's formats: the live report once the device has sent one, the profile's until then. A
  rate the device doesn't offer, or no integer PCM format with the track's channel count at that
  rate, is `DeviceOutputError.deviceCannotTake`, reported as a failed track and skipped like a
  file that won't open. Mixability isn't checked here, since hog mode decides it once the device
  is open. `PhysicalFormat.carries` is the one rule; format selection uses it too.
- **Returning to a device that comes back.** When the device in use has gone away and the user
  chooses another, the first is remembered and stays watched through its own device-list and
  `IsAlive` listeners. When it reads as connected again, output returns to it, reporting it on
  `DeviceOutput.returns`, unless something is playing elsewhere: **this output is playing a track
  on the device the user chose since.** Paused, stopped or with that device lost too, output goes
  back. Choosing the remembered device by hand, or a return, forgets it. A device that went away
  while nothing else was chosen needs no return: output never left it, and the existing lost and
  returned events cover it. Nothing polls; the check runs when a device-list listener fires and
  when playback pauses, stops or ends, or a track can't play, so a device that came back while
  the other played gets output once that stops.
- **The signal path panel** shows the reported rates and formats in a "Takes" row, from the same
  `SignalPath` snapshot, which now carries `DeviceFormats` and the device's UID. The listeners
  that keep it current gain the device's available nominal rates and the stream's available
  physical formats.

- **One exception to save-before-change: an automatic return.** The output decides to go back
  on its own control thread, and the app saves the returned device's profile (moved first, and
  the config written to show it) when it hears of it on `returns`, just after. Nothing is lost
  if the app dies in between: that profile was saved while the device was in use, and since then
  only its place in the list would change. In that moment a volume key still saves to the
  profile of the device output left, which then plays at that volume next time it is chosen.

- **Hog mode by kind of device (amended 2026-11-01).** Hog mode turns off the Mac's volume keys
  for the device, and the owner's 2015 MacBook Pro plays through its speakers, so a default of
  on left the keys dead there. A device seen for the first time now hogs only when it's on USB,
  Thunderbolt, FireWire, PCI or AVB, which is how an external DAC plays bit-perfect. The
  built-in output, AirPlay, Bluetooth, HDMI, DisplayPort, virtual and aggregate devices don't:
  macOS mixes or resamples them anyway, or they have their own volume. A device that isn't
  connected when first chosen starts from `output.hogMode` as before, since its kind can't be
  read. Its profile decides after that, and the Controls menu's Hog Mode toggle still changes
  it. `output.hogMode` stays: it is how the menus and the settings window show and change the
  device in use. A profile saved before this keeps its hog mode, so a built-in output already
  seen needs Hog Mode turned off once.

## Alternatives considered

- **Profiles in the config file** — rejected by the plan, and the config is what the user edits,
  not where the app records what it saw.
- **A profile's settings only from the profile, with the config as a template for new devices**
  — rejected: the Controls menu and the settings window show and toggle the config, which would
  then disagree with the device playing.
- **Remembering the config values last applied, to tell an edit from a device change at
  launch** — rejected for now: a second copy of the config's output settings for one edge case.
- **Returning whenever the remembered device comes back** — rejected: it would cut off music the
  user started on the other device.
- **Deleting `output.hogMode`, with hog mode only in the profile** — rejected: the toggle would
  need a second path from the menus and the settings window to the profile, for the same effect.
- **Recreating the output and engine per device** — rejected: the queue, position and
  subscribers live in the engine, and closing the output ends its streams.

## Consequences

- The app writes `output.deviceUID`, `output.hogMode` and `output.digitalVolume` itself on a
  switch or a return; the writes are marked so they aren't taken as edits.
- A phase 9 renderer gets a profile keyed by its UDN through the same list.
- The remembered device is held only for this run; after a relaunch the config's device is the
  one in use.
