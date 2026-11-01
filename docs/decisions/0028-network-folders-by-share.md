# 0028. A network folder is stored by its share, not its mount path

- **Date:** 2026-11-01
- **Status:** accepted
- **Amends:** [0022](0022-stable-track-identity-and-play-timeline.md),
  [0026](0026-sync-identity-is-the-relative-path.md)

## Context

A watched folder is stored as a mount path, such as `/Volumes/music/library`. macOS mounts an SMB
share at `/Volumes/music-1` when a stale `/Volumes/music` folder is left behind, and two Macs can
mount the same share at different paths. The folder then looks missing, and pointing the app at
the new path gives every file a new `paths` row (0022), so its stats stay behind.

## Decision

A watched folder on a network volume is stored as its share's URL (`smb://nas/music`, from the
volume's remount URL) and the path inside the share (`library`). The app finds the share's
current mount point. Mounting stays the user's job.

- **Finding it:** at launch, before each scan, on wake and on a network change, the app looks
  for a mounted volume whose remount URL has the same host and share. When none does and exactly
  one mounted share has the same share name, that one is used, so `nas.local` and the NAS's IP
  address reach the same library. Two candidates, and the folder is offline with both named.
- **A new mount point** (`/Volumes/music` became `/Volumes/music-1`): one transaction rewrites the
  prefix of every `paths` row under the old one, so IDs, Date Added and stats stay, then the scan
  runs.
- **A share that isn't mounted** leaves the folder offline, as now.
- **Settings** show each network folder's share and its current mount point.
- **Sync** (0026): the library root is the watched folder, stored the same way, so it's the same
  value on every machine and isn't set per machine. The sync folder is stored the same way.
- A local folder is stored by path, as now.

## Alternatives considered

- **Keep mount paths** — rejected: a remount at `-1` takes the library offline, and repointing
  it loses its stats.
- **Match on the volume's UUID** — rejected: SMB volumes don't report a stable one.
- **Mounting the share when it's missing** — not now: the owner didn't ask for it. NetFS
  (`NetFSMountURLAsync`) with the Keychain's password and no UI would do it if wanted later.

## Consequences

The library follows the share wherever macOS mounts it. A new or renamed NAS doesn't match the
stored share, so the user picks the folder again once, and the same prefix rewrite keeps the
stats.
