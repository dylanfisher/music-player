# 0144. The music-recommender token, the app's first secret, and the staging folder setting

- **Date:** 2026-11-08
- **Status:** Proposed — awaiting owner approval
- **Amends:** [0082](0082-config-safety.md) (how the config file is written)
- **See also:** [0028](0028-network-folders-by-share.md) (folders by share),
  [0038](0038-sync-logs.md) (the sync folder, kept outside the watched folders),
  [0039](0039-network-control.md) (addresses as IP literals),
  [0146](0146-staged-tag-writes.md) and [0147](0147-moving-downloads-into-the-library.md)
  (what the staging folder is for)

## Context

Phase 54 has the player talk to music-recommender, the service on mbp2021 that downloads albums
from Soulseek and stages them on the NAS for review. The service's API takes a bearer token, so
the player has to hold one. AGENTS.md says the app has no secrets, and to stop and ask before
adding any secret handling. The owner settled the shape on 2026-11-08: the player takes the
service's address and port and the token in Settings, with no Bonjour for now, and keeps the
token in the config file. The slskd API key stays in the service and never reaches the player.
The owner asked for the feature in these words: "if the album is new from soulseek we can
automatically write the tags", and "nothing should be imported into the real full music
tracklist until manually reviewed and approved". Phase 52.1 planned a Discogs token as the first
secret; this one lands first, and 52.1 follows the same rule.

The player also needs to know where the staged albums are. The service names each album's
folder relative to its staging folder, and the player Macs see that folder at
`/Volumes/music/staging`, beside `library` on the same share.

## Decision

**Four settings**, in a Downloads box in the General pane:

- `recommender.address`: an IP literal, never a host name, as `receiver.address` is (ADR 0039).
  Both use `IPAddressSetting`. Null is no service.
- `recommender.port`: 1 to 65535, default 7878, the service's default.
- `recommender.token`: a `ServiceToken`, 1 to 1024 visible ASCII characters. It prints as `***`
  wherever it is interpolated, so a log line or an error that names the value can't show it, and
  its problem text never quotes it. The window's field is a secure text field.
- `import.stagingFolder`: a `StagingFolder`, a path or a share and the path inside it, chosen with
  Choose… and stored by share when it's on one, as a watched folder is (ADR 0028).

**The token is kept in `config.json` only, readable by its owner alone.** While the token has a
value, `ConfigStore` makes the file mode 0600 before each write, creating it empty at 0600 when
there is none, so the atomic write that follows, which keeps the file's mode, never puts the
token in a file others can read. A file read with a token and wider permissions, as after the
owner types it in an editor, is set to 0600 at once and the change logged. The token is never
copied elsewhere: not to the index, the state file, a sync log or the pasteboard. Without a
token the file keeps the mode the system gives it.

**The staging folder is apart from every folder the app reads or writes.** A staging folder in
or around a watched folder, the library folder or the sync folder is a conflict (`conflicts` in
`AppSettings`): a watched folder inside it would scan downloads, and a library or sync folder
inside it would sit where the service deletes and where Approve takes files from. The schema's
conflicts run on every change to any setting and on every read of the file, so changing the
watched, library or sync folder to overlap it is refused, and a file edited that way is blocked
until fixed (ADR 0082). A folder stored by share and one stored by path can't be compared until
both are found; the code that uses the staging folder (54.3 on) checks the found paths again, as
the sync does.

## Alternatives considered

- **The Keychain.** Rejected for now: the owner chose the config file, the service keeps its own
  token in a 0600 file the same way, and the config file is already the one place settings live.
  The Keychain is the move if a secret ever needs more than file permissions.
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
token. An editor that saves by writing a new file can widen the mode; the next read sets it back.
The client (54.2, ADR 0145) adds the token's row to the threat model (ADR 0025).

## Proposed AGENTS.md change

The last bullet of Boundaries, "The app has no secrets. If one appears, stop and ask before
adding any secret handling.", becomes one line, with the link's `docs/decisions/` prefix as the
other links in that section have it:

> - The app's one secret is music-recommender's token, kept only in `config.json` at mode 0600, never logged or copied ([ADR 0144](0144-the-service-token.md)). If another appears, stop and ask before adding any secret handling.

The line count stays the same, and the detail stays here.
