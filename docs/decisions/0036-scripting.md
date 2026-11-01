# 0036. Scripting: a socket for the command line, links for playback only

- **Date:** 2026-11-01
- **Status:** accepted
- **Amends:** [0025](0025-threat-model.md) (rows 47 to 50)

## Context

Phase 21 adds a `music-player` command line that runs registry commands in the running app,
and a `music-player://` URL scheme for Shortcuts, Raycast and links. Both need a channel into
the app. The release bundle is ad-hoc signed with the hardened runtime and no entitlements
(ADR 0025, row 26), and `scripts/check-signature` fails on any entitlement it doesn't list.
A URL can be opened by any web page, so it's hostile input.

## Decision

**The command line talks to the app over a Unix-domain socket**, at
`<data folder>/scripting/socket`, so `--home` moves it with the library and the state file
(`scriptSocketPath`). The primitive `LocalSocket` makes it:

- The folder is created 0700 and must be a folder, not a link, owned by this user, with no
  group or other bits; anything else is refused with its reason, never fixed up. The socket is
  0600. A stale socket (nothing answers on it) is removed; a live one means another instance
  answers there, and this one doesn't serve; anything other than this user's socket at the path
  is left alone and reported. A server that loses the bind to another removes only a socket
  it bound itself, checked by inode, so it never deletes the winner's.
- Every connection's peer uid (`getpeereid`) must be this user's, before a byte is read. The
  tool checks the server's uid the same way.
- A message is a 4-byte big-endian length and then JSON. A request over 4 KiB is refused
  before it's read; a request must arrive whole within 2 s, its reply within 10 s on the
  tool's side, and a reply over 64 KiB is refused. One thread accepts and reads connections in
  turn, blocked in `poll` while none come, so the idle budget sees no wakeups; a slow client
  holds the next for at most 2 s. At most 16 replies wait to be sent at once; a connection
  past that is closed unread and logged. `stop` may be called any number of times, also after
  the thread ended on its own, and writes to the thread's pipe only while it runs.
- Requests and replies decode strictly: unknown keys, and keys the kind doesn't take, are
  errors at every level.

The server starts once playback is ready (after the first rows draw), so a request that plays
finds the engine. The tool starts the app with `NSWorkspace.openApplication`, passing its own
`--home` on, and from then has one 20 s deadline: each try's timeout is what's left of it, and
a connection the coming-up app closes unanswered counts as not ready yet. Anything refused on the socket is
logged.

**Commands, arguments and help come from the registry.** `Command` gains two properties, and
nothing else lists commands: `runsFromLinks`, and `argument`, the help for what a command
takes (only Play has one). A command's name is its ID or, when no other ID ends the same way
and it isn't `help` or `status`, its last part (`next`); any case. `status --json` is the
`ScriptStatus` shape below.

**The URL scheme runs playback and navigation only.** A link runs a command marked
`runsFromLinks` and refuses every other, with the reason in the status bar. The list, which
`onlyPlaybackAndNavigationRunFromLinks` pins: Play/Pause, Play, Pause, Play Selection, Play
Next, Next Track, Previous Track, Seek Forward, Seek Back, Volume Down, Stop, Shuffle, Repeat
Off, Repeat All, Repeat One, Back, Forward and Show Current Track. Volume Up isn't on it: a page
could open it in a loop and drive the owner's DAC to full volume (the owner's call,
2026-11-01). Links are also limited to 5 in any second, whatever they ask, refused ones
included; past that each is refused with the reason in the status bar and the log
(`LinkRate`). A link is
exactly `music-player://<command>[/][?q=<argument>]`: at most 2048 bytes, the host only ASCII
letters, digits and dots, no path, user, port, fragment or percent sign in it, one `q` key and
nothing else (a bare `?` is refused), decoded once (`+` stays a plus), and no control character in the argument. Links
that arrive before playback is ready wait, up to 16. `scripts/bundle` registers the scheme in
`CFBundleURLTypes`, reading the word from `toolName` in Swift, which is also the tool's name.

**Play's argument reuses the palette's keys.** `play "<text>"` is the search field's text over
the whole library, played from the top. Text starting with a pane's key prefix, `album:`,
`artist:` or `genre:`, as the palette keys its entries (`BrowserModel.Pane.keyPrefix`), shows
and plays that entry, matched ignoring case and accents, as the palette shows one. Two
entries of one name (two albums called "Greatest Hits") are refused, naming up to five
artists, rather than guessed between; a search of the name and the artist plays either. There
was no field syntax in the search box to reuse, and this adds none to it.

**The tool is a second executable in the bundle**, `Contents/MacOS/music-player`, built from
the App-tier target `ScriptTool`. It's signed with the hardened runtime before the app, whose
signature seals it, and `scripts/check-signature` checks every executable in `Contents/MacOS`.

**`status --json`** prints one line, keys sorted, every key always present:

```json
{"positionSeconds":65.2,"queueLength":2,"queuePosition":2,"repeat":"all","shuffle":true,
 "state":"playing","track":{"album":"Kind of Blue","albumArtist":null,"artist":"Miles Davis",
 "durationSeconds":562.5,"path":"/m/a.flac","title":"So What"}}
```

`state` is `stopped`, `playing` or `paused`; `track` is `null` when nothing is loaded, and its
tags are `null` for a file the library no longer holds; `positionSeconds` is `null` when
stopped; `queuePosition` is one-based in play order; `repeat` is `off`, `all` or `one`. Keys
are only ever added. There's no version field (pre-release, AGENTS.md).

## Alternatives considered

- **Apple events (`NSAppleScript` or `NSAppleEventDescriptor` from the tool).** Rejected. A
  hardened-runtime sender needs the `com.apple.security.automation.apple-events` entitlement
  and an `NSAppleEventsUsageDescription`, and the first send raises a TCC Automation prompt for
  whichever app ran the tool (Terminal, Raycast, Shortcuts), once per sender. The receiver
  can't tell which user or process sent an event without private API. A socket in a 0700 folder
  with a uid check needs no entitlement and no prompt, and its access rule is the file
  system's, which tests can drive with `--home`.
- **A confirmation sheet for other commands from links.** Rejected: any page can open links in
  a loop, and a sheet a page can raise trains the owner to click OK. Everything else stays on
  the command line, where only the owner's processes reach it; Shortcuts can run it with Run
  Shell Script.
- **`open -b <bundle ID>` to start the app.** Rejected: it starts whichever copy LaunchServices
  registered, not the one the tool is in, and passes `--home` only with more flags.
  `NSWorkspace.openApplication` starts the enclosing bundle.
- **A field syntax in the search box (`album:` there too).** Rejected for this phase: the
  palette already names entries this way, and the search box's FTS query stays as ADR 0025's
  row 15 audited it.

## Consequences

A command line that can run any command is as strong as the owner's account, which is the
model ADR 0025 already takes for the owner's own processes. A web page can play, pause, skip,
turn the volume down and move around the window, at most 5 times a second, and nothing else;
browsers ask before opening an app's link. A
second app started with another `--home` answers on its own socket; one started with the same
data folder is refused by the live-socket check and reports it in the status bar. A socket left
by a crash is replaced at the next launch. A data folder whose path leaves no room for the
socket's 104 bytes disables the command line with that reason in the status bar.
