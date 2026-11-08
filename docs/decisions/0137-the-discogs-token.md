# 0137. The Discogs token

- **Date:** 2026-11-08
- **Status:** accepted
- **Amends:** [0025](0025-threat-model.md) (rows 58 and 59), [0015](0015-config-file.md) (every
  write is mode 0600)
- **See also:** [0082](0082-config-safety.md) (problems that don't block the file),
  [0130](0130-discogs-catalog.md) (settings edited in the file only)

## Context

Phase 52 adds the Discogs API to the tagger. Discogs's database search needs a personal access
token, and with one the API allows 60 requests a minute instead of 25 and serves release
images. The token is the app's first secret: until now AGENTS.md said the app had none and to
stop and ask before adding any. The owner decided on 2026-11-07 that the token goes in
`config.json`, and has already put it there under `"discogs.token"`.

## Decision

- **Where it lives.** One optional setting, `discogs.token`, a `DiscogsToken` in the config
  file and nowhere else: not in `state.json`, the index, the Discogs cache, a sync log, the
  log, an error or a test. The settings window has no row for it (`SettingKind.secret`, hidden
  in `GeneralModel.isShown`), so it is edited in the file, as the dumps folder is. The app
  reads it only through `fileValue(\.discogsToken)`, and builds the one `Authorization`
  header from it, for `api.discogs.com` alone (ADR 0138).
- **Redaction by type.** `DiscogsToken`'s `description`, `debugDescription` and mirror all
  give `<Discogs token>`, so interpolation, `String(reflecting:)`, `dump` and a failed
  `#expect` can't print the value. A value that isn't a token (empty, a space, a line break,
  anything outside printable ASCII, a number) is a problem naming the key, never quoting the
  value. A header value can't carry a line break, so the last check also keeps the header
  well formed.
- **Mode 0600 on every write.** `ConfigStore` writes through `writeConfigFile`: a temp file
  beside the config, created with `O_CREAT | O_EXCL` and `fchmod` to 0600 (the umask can't
  loosen it), written, synced and renamed over the file the path resolves to. Every write is
  0600, token or not: one rule with no branch on what the file holds. `Data.write(.atomic)`
  made its temp file with the umask's mode, so a file the app wrote was 0644. The temp file
  keeps Foundation's `.sb-` name, so the leftover cleanup at launch still removes one a killed
  process left.
- **A loose file fails closed.** When a group or other permission bit is set on the file (or
  the mode can't be read), a secret it sets isn't used, and a warning says
  `"discogs.token" isn't used while other users can read the file; run chmod 600 on it`. The
  rest of the file applies: a warning is a `ConfigProblem` with `isWarning`, which doesn't
  block, like an unknown key, but has no Remove button. The app never changes the mode on a
  read. Its next write makes the file 0600 anyway, so the token is used from then on. A
  `chmod` that changes no text is noticed by the next read too.
- **AGENTS.md.** The "no secrets" line is replaced by one naming the token, its one place,
  what never happens to it, and that any other secret still needs the owner first. A line says
  no test or tool calls the Discogs API.

## Alternatives considered

- **The Keychain.** Rejected by the owner: the ad-hoc-signed app's identity changes with each
  build, so each of three Macs would ask to allow access again after every install, and the
  config file is already what the owner copies between Macs by hand.
- **A file of its own for the token.** Rejected: a second file to sync and keep at 0600, with
  no gain over the config file once that is 0600 itself.
- **Fixing the mode on read.** Rejected: ADR 0025 row 21 says the app never writes over the
  config file because of a problem, and a mode change the owner didn't ask for is a write.

## Consequences

`config.json` is `-rw-------` after the app's first write. A token in a file another user can
read does nothing until it is chmod'ed or the app writes the file. A command-line mode reads
the config strictly, so a loose file with a token stops it with the warning, as an unknown
key does. The tests use a made-up token, `fakeTOKENfor3tests0nly`.
