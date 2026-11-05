# 0093. Signal path stages, Sonos groups and one receiver switch

- **Date:** 2026-11-04
- **Status:** accepted
- **Amends:** [0035](0035-signal-path-panel.md) (the panel's layout and verdict wording),
  [0039](0039-network-control.md) (`receiver.enabled`), [0041](0041-upnp-output.md)
  (renderer names, the volume keys)

## Context

The owner's feedback of 2026-11-04 night (phase 41d). The signal path panel listed raw rows:
four-character codes, "2 ch 32-bit int", every format the device takes, a hog mode PID. The
status line showed `44.1 kHz 16-bit PCM → ADI-2 DAC (57850288): 'lpcm' 2 ch 32-bit int @
44.1 kHz`, the log's summary. "Not bit-perfect" showed whenever hog mode was off, though
usually nothing else plays and the samples reach the DAC unchanged. The Output menu listed each
Sonos player by its MediaRenderer's friendly name (`Test Room - Sonos Era 100 Media Renderer -
RINCON_…`), and each player of a group on its own, where the owner's phone and Spotify show one
group, "Top Floor". The receiver settings had two switches, `receiver.enabled` and
`receiver.volumeKeys`, and an address that looked required.

## Decision

- **Verdict wording.** When the only changes are ones another app's sound would make, a mixable
  format and hog mode free, the badge says "Not guaranteed bit-perfect". A change the app or
  macOS makes to the samples still says "Not bit-perfect", or "Converted".
- **Stages.** The panel is a row of boxes joined by arrows: the file, the decoder only when it
  changes the samples, then the device or renderer. Each has a title, a value such as
  "44.1 kHz · 16-bit" (`formatText`, DisplayText) and a short note ("FLAC · stereo",
  "Exclusive · volume -6.0 dB", "Gapless · its own volume"), tinted where the samples change.
  The device's format list, renderer address and PIDs are gone from the panel; `--list-devices`
  and the log keep them. The status line's output half is `DeviceFormat.shown`,
  "ADI-2 DAC: 44.1 kHz · 32-bit"; `summary` stays for the log.
- **Device names.** The number in `ADI-2 DAC (57850288)` isn't an ID the app adds: RME's DACs
  put their serial in the name they give Core Audio. `deviceDisplayName` drops a trailing
  parenthesized run of six or more digits, unless another output device would then read the
  same, and then keeps the full name, since the serial is what tells the two apart. The provider,
  the Output menu and Settings use it.
- **Sonos names and groups.** A Sonos player's root device names its room (`roomName`) and lists
  ZoneGroupTopology. Discovery names each player by its room, then asks the first player that
  answers for `GetZoneGroupState`, which covers the household. A group is named as the Sonos app
  names it: its room when every visible member is in that room (a stereo pair, a speaker with a
  sub), else the coordinator's room and "+ N" for the other rooms. Members that aren't the
  coordinator are left out of the picker, since a track sent to one doesn't play; a member
  picked before it joined a group plays to its coordinator. One whose coordinator didn't answer
  stays listed. A failed topology call is reported and leaves the rooms. `--capture-renderers`
  saves the reply. The rule is checked against replies written in Sonos's documented shape, not
  captured from the owner's players.
- **Receiver volume slider.** With receiver control connected, the panel shows a slider from
  −80 to 0 dB, not the protocol's +18, so a slip can't take the receiver to its top. It follows
  the `MV` status lines and ignores them while dragged. The connection replaces a level still
  waiting with the next, so a drag sends one line per 50 ms gap and ends on the last.
- **One switch.** `receiver.volumeKeys` folds into `receiver.enabled`, titled "Control the
  Receiver with the Volume Keys". While receiver control runs, on by the setting or while the
  app plays to the Denon as a renderer (ADR 0041), the volume and mute keys go to the receiver.
  Before, they went only while playing to the Denon renderer, so with the DAC into the receiver
  the keys stayed the Mac's whatever both switches said; and the one case `volumeKeys` off
  served, a Denon renderer with the Mac's keys, has no Mac volume to set. `receiver.address`
  sits under a "Can't find the receiver?" disclosure, open when it has a value. The key names
  stay; `receiver.volumeKeys` in a config file is reported as unknown, pre-release.

## Alternatives considered

- **"Not guaranteed" for every change** — rejected: a resampled or volume-scaled stream is
  certainly changed, and saying otherwise hides it.
- **Hiding a serial only when the app knows the maker** — rejected: the rule is about the name's
  shape, and the collision check keeps two such devices apart whoever makes them.
- **The Sonos group name from a `Name` attribute** — not used: no documented topology attribute
  carries one. If the owner's capture shows one, it replaces the rule.
- **Keeping `receiver.volumeKeys`** — rejected: two switches for what the owner reads as one
  choice, and the keys never reached the receiver in the DAC setup.

## Consequences

The owner checks by eye: the panel on the 2015 MacBook Pro, Sonos names against the Sonos app
(and sends `--capture-renderers` output if they differ), and the slider with the receiver. With
the setting on and the Mac's own speakers playing, the volume keys still go to the receiver;
turning the setting off gives them back.
