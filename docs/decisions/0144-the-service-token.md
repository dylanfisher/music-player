# 0144. The music-recommender token, the app's second secret, and the staging folder setting

- **Date:** 2026-11-08
- **Status:** accepted
- **Amends:** [0025](0025-threat-model.md) (row 65, with [0145](0145-the-recommender-client.md))
- **See also:** [0137](0137-the-discogs-token.md) (the rule this token follows),
  [0028](0028-network-folders-by-share.md) (folders by share),
  [0038](0038-sync-logs.md) (the sync folder, kept outside the watched folders),
  [0039](0039-network-control.md) (addresses as IP literals),
  [0082](0082-config-safety.md) (a conflict blocks the file),
  [0142](0142-library-snapshots.md) (the snapshot folder),
  [0146](0146-staged-tag-writes.md) and [0147](0147-moving-downloads-into-the-library.md)
  (what the staging folder is for)

## Context

Phase 54 has the player talk to music-recommender, the service on mbp2021 that downloads albums
from Soulseek and stages them on the NAS for review. The service's API takes a bearer token, so
the player has to hold one. It is the app's second secret, after the Discogs token (ADR 0137),
and AGENTS.md's rule for secrets covers both. The owner settled the shape on 2026-11-08: the
player takes the service's address and port in Settings, with no Bonjour for now, and the token
in the config file only, with no field for it in Settings. The slskd API key stays in the
service and never reaches the player. The owner asked for the feature in these words: "if the
album is new from soulseek we can automatically write the tags", and "nothing should be
imported into the real full music tracklist until manually reviewed and approved".

The player also needs to know where the staged albums are. The service names each album's
folder relative to its staging folder, and the player Macs see that folder at
`/Volumes/music/staging`, beside `library` on the same share.

## Decision

**Four settings.** Three are in a Downloads box in the General pane, and the token is not:

- `recommender.address`: an IP literal, never a host name, as `receiver.address` is (ADR 0039).
  Both use `IPAddressSetting`. Null is no service.
- `recommender.port`: 1 to 65535, default 7878, the service's default.
- `recommender.token`: a `ServiceToken`, 1 to 1024 visible ASCII characters, edited in the
  config file only. The Settings window has no row for it (`SettingKind.secret`, as for the
  Discogs token), and the Downloads window's not-set message says where it goes.
- `import.stagingFolder`: a `StagingFolder`, a path or a share and the path inside it, chosen with
  Choose… and stored by share when it's on one, as a watched folder is (ADR 0028).

**The token is kept as the Discogs token is** ([0137](0137-the-discogs-token.md)). It lives in
`config.json` and nowhere else: not in the state file, the index, a sync log, the log, an error,
the pasteboard or a test. Every config write is mode 0600 through `writeConfigFile`, token or
not. A token in a file with a group or other permission bit set isn't used, with a warning
naming the key, until the owner runs chmod 600 or the app next writes the file; the app never
changes the mode on a read. `ServiceToken`'s `description`, `debugDescription` and mirror give
`<service token>`, so interpolation, `String(reflecting:)` and `dump` can't print the value, and
a bad value's problem names the key and never quotes it. The app reads the value only to build
the one `Authorization` header (ADR 0145).

**The staging folder is apart from every folder the app reads or writes.** A staging folder in
or around a watched folder, the library folder, the sync folder or the snapshot folder is a
conflict (`conflicts` in `AppSettings`): a watched folder inside it would scan downloads, a
library or sync folder inside it would sit where the service deletes and where Approve takes
files from, and the service's deletes could take snapshots with them. The schema's conflicts run
on every change to any setting and on every read of the file, so changing one of those folders
to overlap it is refused, and a file edited that way is blocked until fixed (ADR 0082). A folder
stored by share and one stored by path can't be compared until both are found; the code that
uses the staging folder checks the found paths again, as the sync does.

## Alternatives considered

- **The Keychain.** Rejected, as for the Discogs token (ADR 0137): the ad-hoc-signed app's
  identity changes with each build, and the config file is the one place settings live.
- **A field for the token in Settings.** Rejected by the owner: the Discogs token has none, and a
  secret typed into a window is one more place it can show.
- **A token in the state file.** Rejected: the state file is for what the app saves as it runs,
  not for what the owner types.
- **Host names, or Bonjour.** Rejected for now by the owner: the client takes IP literals only
  (ADR 0039), and discovery is a later item.
- **Checking the staging folder only when it's used.** Rejected: a watched folder that comes to
  hold the staging folder would scan downloads before anything used it.
- **Leaving the staging folder to the config file.** Rejected: its share URL is easy to get wrong
  by hand, and Choose… stores it the way Add Watched Folder… does.

## Consequences

Anyone who can read the owner's files can read the token, as with the service's config. A
backup or a dotfiles repository that copies `~/.config/music-player/config.json` copies the
token. A token in a file others can read does nothing until the mode is fixed or the app writes
the file. The threat model's row 65 (ADR 0145) covers the client's use of it.

AGENTS.md's secrets bullet names both tokens and the one rule: config file only, mode 0600,
never logged, printed, copied or committed. Any other secret still needs the owner first.
