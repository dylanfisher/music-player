# 0126. The file server doesn't close a connection for idling while it sends a body

- **Date:** 2026-11-06
- **Status:** accepted
- **Amends:** [0039](0039-network-control.md) (the server's 30 s idle close),
  [0025](0025-threat-model.md) (row 28)

## Context

Playing to the Denon AVR-X1800H, tracks stopped partway through and playback ended with
"playback was stopped on Denon AVR-X1800H", where the next track should have started. The
owner's log of 2026-11-06 showed the same thing each time. The server cancelled the Denon's
fetch with a send still pending, with no FIN or reset from the Denon. About a second later the
Denon reported STOPPED, short of the track's end both by the app's clock and by its own
position. One fetch had sent 7.8 MB in 139 s of a 320 kbps MP3, and those files are 5.7–18 MB.

The server closed every connection after 30 s without progress, and a chunk counted as
progress only once the peer took it. The Denon fills a buffer and then reads nothing until it
has played some of it. At 320 kbps a gap in reading can pass 30 s; at 192 kHz FLAC the same
buffer holds a few seconds. A paused renderer reads nothing at all. Either way the server cut
the stream, and the renderer stopped when it ran out.

## Decision

The idle timer runs until a reply's body starts and stops while the body is being sent. The
connection then ends when the body has gone, when the peer closes or the connection fails,
or when the server stops.

A peer that asks for a body and never reads now holds its connection until the server stops.
That stays bounded: the UPnP output's server takes connections only from its renderer's
address, at most 8 of them, and stops when nothing is loaded.

Rejected: a longer idle time for bodies. Any limit is shorter than some pause, and a renderer
that loses its stream while paused can't resume.
