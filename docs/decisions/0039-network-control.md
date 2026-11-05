# 0039. Network control: the LAN primitive, SSDP discovery and Denon receiver control

- **Date:** 2026-11-01
- **Status:** accepted
- **Amends:** [0025](0025-threat-model.md) (rows 28 to 30)
- **Amended by:** [0091](0091-signal-path-stages-sonos-groups-receiver-keys.md):
  `receiver.enabled` also takes the volume keys, and the address sits under a disclosure.

## Context

Phase 9a puts the app on the LAN for the first time: an HTTP server that 9b's UPnP output will
serve tracks from, SSDP discovery of MediaRenderers with their descriptions and
`GetProtocolInfo`, and control of the owner's Denon AVR-X1800H over its TCP port 23 protocol.
Every byte from the LAN is hostile (ADR 0025's "LAN device"). The work was done with no access
to the receiver, so everything is checked against loopback stand-ins, and nothing in a test, a
script or an app run on the build Mac sends a packet past loopback.

The protocol reference is Denon's "AVR control protocol" v03 for the AVR-X1000/E300 (2013).
The X1800H's spec sheet describes an 8K, HEOS-based model, later than the X1000 by several
generations. The owner already drives this X1800H from shell scripts that send `<command>\r`
to port 23, which confirms `SIAUX1`, `SIBD`, `SIGAME`, `SINET` (labeled HEOS), `SIMPLAY`,
`PWON`, `PWSTANDBY` and two-digit `MV` levels (`MV30`, `MV40`, `MV50`) on the real receiver.
Values below marked † come from the X1000's spec alone; 9b starts from the owner's captures of
the real receiver, which settle them. The receiver has also lost its DHCP reservation and moved
address once, so the app finds it rather than storing where it was.

## Decision

**Off by default.** `receiver.enabled` is false. Until the owner turns it on, nothing searches,
connects or listens, so `./scripts/dev` and `--snapshot` send nothing. Turning it off closes
the connection and forgets the receiver.

**Three modules.** `LocalNetwork` (primitive) holds what's music-agnostic: addresses, the local
subnets, one HTTP head parser, SSDP, a fetch client and the HTTP server. They're one module
because a primitive imports no other, and the server, the client and SSDP all need the subnet
check and the head parser. `UPnP` (core) reads descriptions and SOAP and turns SSDP replies
into `Renderer`s. `Receiver` (core) speaks Denon's line protocol.

**Local subnet.** For each interface that's up, running and able to multicast, not loopback and not point-to-point (a VPN
isn't a LAN), its address and netmask or IPv6 prefix, from `getifaddrs`. An address is local
to the interface with the longest prefix holding it, then the first listed, so a Mac on one LAN
by Wi-Fi and Ethernet answers by one interface. A link-local IPv6 address matches only the
interface its zone names. The list is passed in, and tests make interfaces up.

**SSDP.** An M-SEARCH for `MediaRenderer:1` goes to 239.255.255.250:1900 out of each IPv4
interface, with a TTL of 1 so it stays on the subnet; an interface that can't send is skipped,
and the search fails only when none could. IPv6 SSDP isn't searched. The transport
is injected; the real one takes its destination as an argument, and tests aim it at a UDP
stand-in on 127.0.0.1. Replies from off the local subnets, over 64 KiB, malformed or without
one `LOCATION`, `ST` and `USN` are reported and ignored, at most 20 listed and the rest
counted, and at most 64 devices kept. A `LOCATION` is followed only when it's `http`, its host
is an IP literal (a name could resolve anywhere) and the very address the reply came from, with
no user or fragment, and that address is another device's: not the subnet's network or
broadcast address and not one of the Mac's own. A URL a description names, such as a control URL, must stay on the description's
host and port.

**Fetching.** `LocalHTTPClient` is HTTP/1.1 over `NWConnection`, not URLSession, so no proxy,
cache, cookie, App Transport Security rule or redirect sits between the app and these checks.
Any status but 200 is refused, a redirect included. Heads are capped at 64 KiB, bodies at
1 MiB (by `Content-Length` before reading, while reading otherwise), chunked bodies decoded,
and the whole exchange, connecting included, at 5 s. A connection that would wait for the
network is refused, not retried.

**XML.** Descriptions and SOAP replies are read by `XMLParser` with external entities off. Any
`<!DOCTYPE` or `<!ENTITY`, in any case, is refused before the parser sees the bytes, so neither
an external entity nor an entity expansion runs; no UPnP document has a DTD. So is a document
with a NUL or a byte order mark, one that doesn't start with `<`, and one whose declaration
names an encoding other than UTF-8, so the parser never guesses at an encoding. 1 MiB, 32 levels,
10,000 elements and 256 KiB of text in one element at most. A renderer's name, manufacturer
and model are escaped with `terminalSafe` (row 9) and cut to 256 characters. `GetProtocolInfo`
keeps at most 1,024 sink entries of four parts each. A renderer whose `GetProtocolInfo` fails
is kept with no formats and the reason, since receiver control doesn't need them.

**The HTTP server**, for 9b. It listens on one interface's address, on a port the system picks,
and accepts connections only from that interface's subnet, and in 9b only from the one renderer it serves ([0041](0041-upnp-output.md)). A URL is `/<token>`: 128 bits from
`SystemRandomNumberGenerator` (`arc4random_buf` on Darwin), one per key per server session,
renewed after 24 hours, gone when the server stops. The key, a track ID for 9b, maps to a file
through the caller's `resolve` at request time, so a track the index no longer holds is 404.
Anything that isn't a live token is 404 before `resolve` or the file system sees it. Files are
opened `O_RDONLY | O_NOFOLLOW | O_NONBLOCK` and must be regular files by `fstat`. `GET` and
`HEAD` only; `Host` must be the bound address and port, which stops DNS rebinding; heads over
8 KiB are 431; a body, a `Transfer-Encoding`, two `Range` fields, a range list, a unit other
than bytes or a range outside the file are refused. At most 8 connections, each closed when its
request head isn't whole within 10 s however slowly it trickles in, after 30 s without progress,
and after its one reply (`Connection: close`). Its public entry point has
no caller until 9b, the one exception to "no type without a caller"; `scripts/surface-allow.txt`
says so.

**Finding the receiver.** Receiver control runs discovery and takes the renderers whose
manufacturer contains "Denon"†. A Denon Home or HEOS speaker answers too, so among them it
prefers the one at `receiver.address`, and otherwise keeps those whose model name contains
"AVR"†. One receiver can answer as more than one device, all at its one address; with more than
one address left, it names each and asks for `receiver.address`, and connects to nothing. With
none, or when the search itself fails, it falls back to `receiver.address`, null by default: a
literal IPv4 or IPv6 address, never a host name (the config check refuses one), used only while
it's another device's address on the local subnet of an interface that's up (not the network or
broadcast address, nor the Mac's own), by the same injected check SSDP replies get. Otherwise it
reports why and connects to nothing. The address comes only from a `Renderer`, which only
discovery makes, or from that setting. Port 23 is fixed. Turning the setting off cancels a
search under way along with the connection.

**The line protocol**, from the X1000 spec:

- Lines are printable ASCII ending in CR. A line over 135 bytes without a CR, the spec's
  message cap (the plan said 128), drops the connection and reports it. A LF is skipped, in case
  a receiver ends lines in CR LF. A line with any other byte outside 0x20–0x7E is reported and
  ignored.
- The model follows `PW` (`ON`, `STANDBY`), `MV` (`00`–`98`, or three digits ending in 5 for a
  half step†; `99` is the minimum too, as the spec's note I says†; `MVMAX` lines ignored†), `MU`
  (`ON`, `OFF`), `SI` and `MS` (any name of 1 to 25 characters, since the X1800H has more modes
  than the X1000 lists†; `MSQUICK` lines ignored). Every other command, such as the channel
  levels the receiver sends after a mode change, is ignored quietly.
- A value out of range is reported and the model keeps what it had. An `SI` input the app has
  no name for is reported, and the model shows no input rather than keep the old one, which
  would claim an input the receiver has left. At most 20 ignored lines are reported per
  connection, then one line saying the rest aren't.
- The model changes only on a status line, so it follows the receiver's own remote and front
  panel, and shows what the app sent only once the receiver says so. On connect the app sends
  the commands that waited for it, then asks `PW?`, `MV?`, `MU?`, `SI?` and `MS?`, which reads
  state and changes nothing.

**Commands.** Built only from typed values (`ReceiverCommand`), never from received text: volume
up and down (`MVUP`, `MVDOWN`), set (`MV` and a level), mute (`MUON`, `MUOFF`), Pure Direct†
(the X1000 spec says North America only), Direct and Stereo (`MS`), each input (`SI`), power
on and standby (`PWON`, `PWSTANDBY`). The inputs are PHONO†, CD†, TUNER†, DVD†, BD, TV†,
SAT/CBL†, MPLAY, GAME, AUX1, NET (titled HEOS, as the receiver labels it) and BT†; the X1000's network services (Pandora, Spotify and the rest)
are left out, as HEOS has them on the X1800H. Lines go out at least 50 ms apart, 1 s after
`PWON` as the spec asks. A line equal to the last one waiting is dropped, so a held key moves
the volume a step per 50 ms and stops when let go; past 16 waiting, a command is refused and
reported.

**Unreachable.** A refused connection (Network.framework's waiting state), a failure, a close by
the receiver, an overlong line, over 200 lines in a second, no connection within 5 s, or a
connection that says nothing within 1 s of opening (another app, HEOS or AVR Remote, may hold
the receiver's one control connection) ends the connection, clears the model so no check mark
shows a state from before, and shows "the receiver is unreachable", with the owner's own
scripts' hint, "Is it on the network, with Network Control set to Always On?", in the status
bar. Status shows connected only once a line has come. Nothing searches or connects on its own:
the owner's next receiver command runs discovery again, then the fallback, connects and sends,
since the receiver may have moved (the owner's did, by DHCP) and a silent retry would fight the
owner's other app for the one control slot. Turning the setting on searches too. At most 16
commands wait for a search; past that, and past 16 lines waiting on a connection, a command is
refused and reported, and one sent as the connection ends starts the search instead. Updates
from the connection reach the main actor through a buffer of the newest 64.

**In the registry.** The receiver's commands sit in a Receiver submenu of Controls with the
setting's toggle, an Input submenu inside it. Their IDs' last parts (`raiseVolume`,
`lowerVolume`, `modePureDirect`, `inputCd`) differ from every other command's, so the command
line's short names for the app's own volume commands still work. Check marks show what the
receiver reported: power, mute, sound mode and input. Set Receiver Volume takes a level in dB,
−80 to +18 in half steps, and runs only from the command line. Every menu item runs when
chosen, so a command that needs its argument (`runsFromMenus` false) is in no menu and not in
the palette.
Only Receiver Volume Down runs from `music-player://` links, as the app's own Volume Down does:
a page could raise the volume, wake the receiver or switch its input, none of which it should.

**Info.plist** gets `NSLocalNetworkUsageDescription` and nothing else. SSDP isn't Bonjour and
the app browses no Bonjour service, so `NSBonjourServices` would list nothing true. No
entitlement: the app isn't sandboxed, and the release signature check stays as it was.

## Alternatives considered

- **URLSession for descriptions and SOAP** — rejected: it applies proxy settings and App
  Transport Security, and follows redirects unless every task's delegate stops them; the caps
  and the deadline would sit on top of behavior the app doesn't control.
- **Primitives `HTTPServer` and `SSDP` apart** — rejected: a primitive imports no other, so the
  subnet check and the head parser would be copied into each.
- **Retrying a dropped receiver connection** — rejected: the plan asks for none, and it would
  take the receiver's one control slot from the owner's phone app.
- **A command per volume level, or a palette prompt for Set Receiver Volume** — rejected for
  now: 197 commands, or a new kind of palette entry, for what the command line does.
- **Keeping the last input when an unknown `SI` arrives** — rejected: the check mark would show
  an input the receiver has left.

## Capture mode

`MusicPlayer --capture-renderers <folder>` is for the owner to run at the receiver, so 9b starts
from what it sends. It searches for MediaRenderers for 5 s, then saves, unparsed, the SSDP replies
(`ssdp.txt`, replies discovery ignores included), each renderer's description
(`<n>-description.xml`), `GetProtocolInfo` reply (`<n>-protocolinfo.xml`) and AVTransport,
RenderingControl and ConnectionManager descriptions (`<n>-<service>-scpd.xml`). Then it opens the
receiver's control port, at the Denon found or else `receiver.address`, sends `PW?`, `MV?`, `MU?`,
`SI?` and `MS?` and records every line for 10 s with its time (`status-lines.txt`). It sends what
discovery and receiver control send, under the same caps and local subnet checks; a document
discovery would refuse, such as one with a DOCTYPE, is still saved. A failure is printed and the
rest carries on; it exits nonzero only when no file was written.

## Consequences

Nothing reaches the LAN until the owner turns receiver control on, and only SSDP, HTTP to
addresses on the subnet a reply came from, and port 23 of the one Denon found. Phase 9b adds
`output.renderer` and `--list-devices`, which search too ([0041](0041-upnp-output.md)). The receiver's
volume isn't shown anywhere yet, only logged under the Receiver category as each `MV` line comes; 9b's
output picker and the signal path panel are where it can go. Every † above is checked against
the owner's captures before 9b builds on it: the device description's device types and
manufacturer, the `GetProtocolInfo` sink list, and the status lines for each input and mode.
