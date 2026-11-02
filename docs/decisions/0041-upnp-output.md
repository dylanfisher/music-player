# 0041. UPnP output: the file's own bytes to a renderer, chosen by UDN, polled

- **Date:** 2026-11-01
- **Status:** accepted
- **Amends:** [0025](0025-threat-model.md) (rows 28 and 29), [0039](0039-network-control.md)

## Context

Phase 9b plays to the owner's Denon AVR-X1800H as a UPnP MediaRenderer, through 9a's HTTP
server and the phase 4 output protocol. It starts from what the owner captured with
`--capture-renderers` on the real network: the Denon (HEOS firmware, its MediaRenderer nested
in an `AiosDevice` root, description on port 60006) and two Sonos Era 100s. Scrubbed copies
are the test fixtures: addresses moved to 192.0.2.x, UUIDs, serials, MACs, Sonos household and
HEOS network IDs replaced with made-up values, every other byte as captured.

What the captures settle:

- The Denon's sink lists `audio/flac`, `audio/wav`, `audio/mpeg`, `audio/mp3`, `audio/aac`,
  `audio/m4a`, `audio/x-ms-wma`, `audio/vnd.dlna.adts`, `audio/L16` at 44.1 and 48 kHz only,
  and seven DSD types. It lists no `audio/mp4`, `audio/x-m4a`, ALAC type or AIFF type. No
  entry limits a rate or a depth.
- The Sonos lists `audio/mp4`, `audio/x-m4a`, `audio/aiff`, `audio/x-aiff`, `audio/flac`,
  `audio/wav` and `audio/mpeg`, among others.
- Both AVTransport descriptions list `SetNextAVTransportURI`.
- On connecting, the Denon said `PWON`, `MV30`, `SINET`, `MSDIRECT`, and a second later
  `SYSDA PCM`: the input the UPnP stream plays on is NET (HEOS), and the model 9a built follows
  those lines as they are (`theReceiversOwnLinesBuildItsState`).

## Decision

**A Core module, `UPnPOutput`.** `RendererOutput` implements `Output` for one renderer. One
task runs every command and every poll to its end before the next, so no two replies can
interleave and nothing runs on the main thread; the `Output` methods only queue work and
return. `UPnP` gains the AVTransport actions, SOAP faults, DIDL-Lite and service descriptions.

**Choosing a renderer.** `output.renderer`, beside `output.deviceUID`, holds a renderer's UDN,
which survives a renamed renderer and a new DHCP address. Null, the default, plays on the
device. Set, the app searches the local network for it and moves playback there; cleared, it
moves back. `output.deviceUID` and the device profiles stay the device's, so the renderer
adds nothing to them. `--list-devices` lists the devices, then searches and lists the
renderers with their UDNs. A picker lists `AudioDevice.outputDevices()` and the renderers a
search finds, and sets one setting or the other: a device clears `output.renderer`. Moving
playback is `PlaybackEngine.use(_:)`: the old output stops, the new one loads what played at
the position it had, playing or paused as it was, and only the current output's events count.

A UDN is the renderer's own text, escaped and cut like its name. It's also the only thing
naming the renderer, so a host that copies the Denon's UDN and answers the search first would
get it. A UDN that answers from two addresses is used for neither, and the conflict is
reported. A renderer lost and searched for again is found by its UDN wherever it is now: the
next load after a loss searches again, as receiver control does on the next command after a
drop, and plays to the address the search finds, since DHCP can move it.

**Formats, offered as the file's own bytes.** A track is read by the Metadata parsers, by
content, and offered under the first of its container's types the renderer lists over
`http-get`, with the renderer's own sink entry as the DIDL `protocolInfo`. Nothing is
transcoded; a file the renderer lists no type for is reported as the track's failure, naming
what it takes, and the queue moves on.

| Container | Types, in order | Denon | Sonos |
|---|---|---|---|
| FLAC | `audio/flac`, `audio/x-flac` | `audio/flac` | `audio/flac` |
| WAV | `audio/wav`, `audio/x-wav`, `audio/wave` | `audio/wav` | `audio/wav` |
| MP4 (ALAC, AAC) | `audio/mp4`, `audio/x-m4a`, `audio/m4a` | `audio/m4a`† | `audio/mp4` |
| AIFF | `audio/aiff`, `audio/x-aiff` | reported | `audio/aiff` |
| MP3 | `audio/mpeg`, `audio/mp3` | `audio/mpeg` | `audio/mpeg` |

- **ALAC** goes to the Denon as `audio/m4a`, the one MP4 type it lists; HEOS's spec sheet says
  it plays ALAC. † until the checkpoint plays one.
- **AIFF** is reported on the Denon. `audio/L16` would mean stripping the header and sending
  raw big-endian samples, which is no longer the file's bytes, and only at 44.1 or 48 kHz.
- **Hi-res** FLAC and WAV, 24/96 and 24/192, are offered as they are, since no sink entry limits
  a rate. A renderer that can't play one says so by refusing the URI or by stopping without
  playing, and either is reported.
- **DSD**: the library scans no DSF or DFF files, so there's nothing to send. The Denon's sink
  lists the types for when it does.

The DIDL-Lite carries the title (the file name when the file has none), artist, album,
`protocolInfo`, duration, size, rate, depth and channels. Every tag is the file's own text:
escaped, cut to 512 characters, one line, and characters XML can't hold dropped, so a tag
can't change the request; a byte order mark is dropped too, since `XMLParser` drops it from
text. Tab, LF and CR go as character references, so they read back unchanged. The
`didl-lite` fuzz target checks every tag reads back as written, through the DIDL-Lite and the
SOAP request around it.

**Gapless.** The renderer's AVTransport description is fetched once per session; when it lists
`SetNextAVTransportURI`, the next track goes over while one plays, and a `TrackURI` that
changes to it is the track change, with no gap. Otherwise, or once the renderer refuses the
action or stops instead of playing what it was given, each track is set and played after the
last has stopped: the gap, from the stop being seen to Play being answered, is logged, and the
signal path panel says which way the renderer plays and why.

A next track the renderer was given and then told to drop, as when the queue changes in a
track's last second, may still be what it plays: the current track then counts as ended, and
what the engine has next is set in its place. `TrackURI`s are compared with the scheme and
host in any case, the default port and percent-encoding undone, so a renderer that rewrites
the URI it was given isn't taken for another app.

**Polling, not GENA.** `GetTransportInfo` and `GetPositionInfo` once a second, while a track is
loaded, and nothing at all once nothing is loaded or watched for. GENA events would need the app to accept `NOTIFY` requests with bodies from the
renderer, which 9a's server refuses by design, plus a callback URL and renewals; polling keeps
every exchange one the app starts, under the client's caps and deadline. The cost is up to a
second before a track end is seen without gapless, and two connections a second.

**What the polls decide.** Playing or paused: the position, and a seek, Play or Pause that
waited for the renderer to start (some refuse one given before they play). A renderer that
plays or pauses other than the engine said, for two polls running, from its own remote or a
refused command, is followed: `transportChanged` tells the engine, which shows it. A refused
Play or Pause tells the engine at once, and a refused seek sends `seekFailed` with where
playback stayed, which the engine publishes in place of the seek it showed. A seek lands at
least a second short of the end, where a renderer would stop. Stopped after playing, within
3 s of the renderer's duration (it resets its position when it stops, so the last poll is what
counts): the track ended. Stopped earlier: stopped on the renderer, its remote or another app,
reported and the engine stops. Stopped five polls running without ever playing: it won't
decode the track, reported, and the queue moves on. `ERROR_OCCURRED`: the same. A `TrackURI`
that's neither the current nor the next track: another app took the renderer, reported, and
the engine stops.

**Hostile input and a renderer that goes.** Every reply is fetched by 9a's client (1 MiB, 5 s,
the local subnet, no redirects), read by `XMLTree` (no DTD, UTF-8 only), and checked: control
and description URLs on the description's host, times only `H+:MM:SS[.F]` and under 11 days,
unknown states and fault text escaped as display text. An action that gets no answer, or three
polls in a row, loses the renderer: `deviceLost` with the position, the server stopped, and
playback pauses there as for a lost DAC. A lost renderer is asked every five seconds whether
it answers; the first answer sends `deviceReturned`, as the DAC's return does, and the polls
stop. Nothing waits on the renderer: `close()` ends the streams and stops the server at once,
and sends `Stop` without waiting for it.

**Serving.** The server starts on the interface the renderer's description came from, on the
first load, and stops when nothing is loaded: after Stop, the last track, a loss or close. It
takes connections only from the renderer's own address, the `LOCATION` host, not the whole
subnet: a renderer fetches the streams it plays itself, and nothing in the captures or in
AVTransport has another host fetch for it. Its keys are the engine's item IDs, and only the
current and next items resolve, which is narrower than "a track the index holds": a token the
server issued for an item since replaced is 404.

The tokens travel in plain HTTP on the LAN, as UPnP has no other way. Anyone on the network
who sees the traffic sees the URLs and the audio of the current and next tracks, while the
server runs; with the server taking only the renderer's address, a copied token alone gets
nothing, though a host that can also spoof that address could fetch those two tracks. Nothing
else in the library is reachable, and the tokens end when the server stops.

**Volume.** `RendererOutput.hasVolume` is false, and the app's Volume Up and Down are off while
a renderer plays. On the Denon, the volume is the receiver's, which receiver control sets over
port 23 and follows from its `MV` lines: one value, one control. RenderingControl isn't used:
HEOS maps it onto that same master volume in coarser steps, and a `SetVolume` from the app's
digital-volume level would jump the receiver to a level the app never read. A Sonos keeps the
volume its own app sets. The signal path panel says which.

**The signal path panel** says the file's bytes go unchanged over HTTP as the offered type, the
renderer decodes them, and bit-perfect can't be checked from the Mac (`SignalVerdict
.unverifiable`), with the renderer's name and address, whether it's gapless, and the volume.

## Alternatives considered

- **`output.deviceUID` holding a renderer as `upnp:<UDN>`** — rejected: every use of the
  device UID (profiles, hog mode, the restore record, `HALDeviceProvider.resolve`) would have
  to tell the two apart, and a profile would be kept for a renderer that has none of it.
- **GENA subscriptions** — rejected above: the server would have to accept requests with bodies
  from the LAN.
- **Transcoding AIFF to FLAC or L16 for the Denon** — rejected: the plan sends original bytes
  and reports what can't go.
- **RenderingControl volume for every renderer** — rejected for 9b, above; a renderer's own
  volume is a later phase's, read before it's set.
- **Serving any track the index holds** — rejected: the renderer only ever needs the two loaded
  items, and a narrower set leaves less to guess.

## Consequences

Nothing reaches the network for playback until `output.renderer` is set. To be checked at the
receiver (the 9b checkpoint): what the display shows for 16/44.1, 24/96 and 24/192 FLAC,
whether HEOS plays the next track gaplessly, seek while playing and paused, an ALAC file as
`audio/m4a`, and an AIFF being reported. The app's own volume is off while a renderer plays;
Receiver Volume Up and Down are the Denon's.
