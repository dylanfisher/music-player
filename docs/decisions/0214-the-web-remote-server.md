# 0214. The web remote's server: pairing, Bonjour, state, events and commands

- **Date:** 2026-11-20
- **Status:** accepted
- **Amends:** [0039](0039-network-control.md): the app now advertises and browses one Bonjour
  service, so `Info.plist` names it in `NSBonjourServices`; [0025](0025-threat-model.md): rows
  77 to 84, the web remote.

## Context

Phase 10 lets the owner control "the macbook that is connected to the denon receiver from my
phone", with no iOS app and no Shortcuts, and lets the page find and choose among the three
Macs that may be playing. A web page can't discover anything on the LAN, so each app does that
for it. Part 10a is the server side: listening, pairing, discovery, state, push and commands.
Part 10b adds browsing and the page itself (ADR 0215).

## Decision

**The server.** `RemoteServer` in `LocalNetwork` is a second hand-written server on
`NWListener`, beside phase 9's `HTTPServer`, sharing its head parser (`HTTPHead`) and its subnet
check (`NetworkInterface.holds`). It's a type of its own because it answers any device on a
local subnet, not one renderer by token. `remote.enabled` is off by default; nothing listens or
advertises until the owner turns it on, and turning it off closes every connection. It listens
on each address of each interface `currentInterfaces()` gives (up, running, multicast, not
loopback or point-to-point) on `remote.port`, 47800 by default, a fixed port so a home-screen
link keeps working, and takes a connection only from that interface's subnet. An `NWPathMonitor`
starts it again when the interfaces change; the code shown survives that. The app keeps one
`RemoteService` for the launch, and its starts run one at a time, in the order asked: a start
asked for before a stop does nothing, a stop closes a server that's still binding, and a new
server waits for the old one's listeners to close, so two starts at once, a quick off and on, or
a port change never leave two servers or none. A listener that fails after it was ready is
reported and dropped, and the service starts again. Refused connections are logged ten a
session, then counted in one line when the server stops, so a LAN scanner can't flood the log.

Each request's head passes `RemoteRules` before anything else sees it:

- `GET`, `POST` and `OPTIONS` only, HTTP/1.1 or 1.0, a target starting with `/` of at most
  2048 bytes.
- `Host` must be exactly one of the bound `address:port`s or `<host>.local:port`, which stops a
  page that rebinds its own name to the Mac's address (DNS rebinding).
- No `Transfer-Encoding`; one plain `Content-Length` of at most 16 KiB, and a body only on a
  `POST`.
- An `Origin`, when sent, must be this server's own or one of the other instances it found on
  Bonjour; anything else is a 403 before the handler runs, so a page from any other site can't
  even make a request count, a pairing guess included.

Heads are at most 8 KiB, and a request's head and body must be whole within 10 s of its first
byte. Connections are kept alive between requests and closed after 30 s idle. At most 32 at once,
of which 24 may be event streams. Replies of 512 bytes or more are gzipped through the system
zlib when `Accept-Encoding` takes gzip.

**CORS.** The page served by one Mac talks to the others directly, so each echoes
`Access-Control-Allow-Origin` with `Vary: Origin` only for another instance's origin from its own
Bonjour list (`http://<address>:<port>` for each advertised address on this Mac's subnets, and
`http://<host>.local:<port>`), and answers the `OPTIONS` preflight that the `Authorization`
header causes with the methods and headers allowed and a 10-minute max age. Every reply sends
`Vary: Origin`, with an `Origin` or without, so a cache never hands one origin's reply to
another.

**Pairing.** Settings → Remote shows a 6-digit code, live for 2 minutes, from the system's
cryptographic generator, and a QR code of `http://<host>.local:<port>/#pair=<code>`, with the LAN
address beside it as text. `POST /api/pair` with `{code, device}` trades it for a 128-bit token
as 32 hex digits; the code then ends, so one code pairs one device. Guesses are compared in
constant time, and the fifth wrong one ends the code until a new one is shown. Those five can
come from any host on the LAN, so one can end every code shown: a denial of service the owner
answers by showing a new code, accepted since it reaches nothing. The Mac keeps
only each token's SHA-256, with the device's name, when it paired and when it was last seen,
in the state file's `remote.devices`, at most 32, the device seen least recently making room.
So the Mac holds no secret, only a way to check one, and AGENTS.md says so instead of naming a
third secret. A token is compared against every stored hash, in constant time, whatever matches
first. Last seen is written at most every 10 minutes, so a busy page doesn't rewrite the state
file. Forget in Settings removes the hash and closes the device's event streams.

Every route but `GET /` and the trade needs `Authorization: Bearer <token>`; without one that
matches, any path, known or not, is a 401 with no body and no `WWW-Authenticate`, so a stranger
learns nothing about the routes. Bodies are `application/json` (else 415) and decoded strictly:
an unknown or missing key is a 400.

**Discovery.** Each app keeps a random 128-bit instance ID in the state file
(`remote.instanceID`) and advertises `_music-player._tcp` through dns_sd under the computer's
name, with `id`, `host` (its `.local` name), `port` and `addr` (its addresses, IPv4 first,
without link-local ones, as many as fit 255 bytes) in the TXT record. It doesn't say whether
it's playing: anyone on the LAN reads TXT records. `NWBrowser` gives a service's name and TXT
record but not its addresses or port without a resolve per service, which is why they're in the
TXT record. A found advert is taken only with a well-formed ID, host label, port and at least one
address on this Mac's subnets; others are logged once by name, at most 64 a session. Adverts
that claim one ID with different addresses are all left out and reported, since anyone on the
LAN can claim another Mac's ID. 10b's page keys each token by instance ID and the origin it
paired with, and never sends a token to another origin for that ID. An advert's name is made
terminal-safe and cut to 256 characters before it reaches `/api/instances` or a log line, and
the page puts it on screen only through `textContent`. `GET /api/instances` returns this
instance first, then the others (ID, name, host, addresses, port). A Mac that sleeps or quits
drops off when its advert goes. The advertiser and browser are behind `BonjourAdvertising` and
`BonjourBrowsing`, so no test advertises or browses the LAN.

**State and push.** `GET /api/state` returns the instance and its name, playing or paused or
stopped, the track (ID, album ID, title, artist, album, duration), the position with the time
it was read, the queue's change stamp, length and place, shuffle and repeat, the app's volume
when it can be set, the output by `OutputChoice.text` and name, the receiver's power, volume,
mute and input while receiver control runs, and `lastPlayedAt`, when this Mac last started
playing. `lastPlayedAt` is kept in memory only, so it resets at launch; a Mac that hasn't played
since then has none, and the page falls back as 10.6 describes, to the Mac controlled last and
then the one whose page was opened. A key without a value is left out. `GET /api/events` is a Server-Sent Events stream of
the same state: while any stream is open the hub reads the state every 250 ms and sends it when
anything but the position changed, or the position drifted more than a second from where
playing on puts it, so at most four events a second and none while nothing changes. A comment
line every 15 s finds a stream whose reader left. A stream holds four events for a slow reader,
and the server closes one with 16 sends untaken. A device may hold four streams, one per Mac's
page with room for a reload, so one device can't take all 24.

SSE rather than WebSocket: it's plain HTTP on the same server, and commands go up as `POST`
anyway. The browser's `EventSource` can't send an `Authorization` header, so the page (10b) reads
the stream with `fetch` and a `ReadableStream`, which iOS 15 Safari has, and reconnects it on
`visibilitychange` itself. A token in the URL instead would end up in history and logs.

**Commands.** `POST /api/command {name, argument}` goes through `ScriptRouter.handle` as
`Origin.remote`, never a second dispatcher, by the command's whole ID. It runs only commands
marked `runsFromRemote`: play, pause and stop, next and previous, the seeks, shuffle and repeat,
the app's volume, the output, and the receiver's volume, mute, power and input. Seek To
(`playback.seekTo`, seconds), Set Volume (`playback.setAppVolume`, dB, 0 or under) and Choose
Output (`output.chooseOutput`, `OutputChoice.text`) are new, for the page's seek bar, slider and
output menu; like Set Receiver Volume they need their argument, so they're in no menu. Choose
Output writes `output.deviceUID` and `output.renderer`, as the output menu does. It's the one
setting the remote changes, a deliberate exception, because the owner chooses the Mac's output
from the phone; it takes only an output the Mac's own picker lists now, never a UID or UDN a
request makes up. The volume commands run from the remote, Volume Up, Receiver Volume Up to
+18 dB and Set Volume to 0 dB among them, though links may only lower a volume (ADR 0036):
any web page can open a link, while only a device the owner paired holds a token. Nothing
that writes tags, moves or deletes files, changes another setting or approves a download is
marked, since AGENTS.md lets those happen only after a confirmation in the Mac's own UI. The
selection-based commands (Play Now, Play Next, Add to Playback Queue, Remove from Queue) act on
the Mac's window, not the phone's, so they aren't marked either; `playTracks`, `queueTracks` and
the queue's reorder and remove come in 10b, by the IDs browsing gives the page.

## Alternatives considered

- **WebSocket for push** — rejected: framing, masking and the upgrade handshake by hand, for
  messages that only go one way.
- **Resolving each found service for its addresses** — rejected: a connection or a resolve per
  Mac each time the set changes, and nothing a test can drive; the TXT record already carries
  what the advertiser knows of itself.
- **The token in the events URL** — rejected: URLs are kept in history and logs.
- **Storing the token** — rejected by the owner: a hash checks it as well and can't be sent.
- **Refusing a pairing when 32 devices are paired** — rejected: the owner would have to find
  Forget first; the device seen least recently is the one least likely missed.

## Consequences

The token goes in plain text on the LAN, as the recommender's does (ADR 0025 row 65): a passive
sniffer on the LAN can take it and use it until the owner forgets that device in Settings →
Remote, which is the remedy. The page is plain `http`, so it has no service
worker. A Mac with the remote on answers its subnet on port 47800, and any LAN device can read
its advert's ID, name and addresses. The pane's QR code points at `<host>.local`, which some
phones' networks don't resolve; the LAN address beside it covers that.
