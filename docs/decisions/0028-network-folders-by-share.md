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
volume's remount URL) and the path inside the share (`library`): in the config file,
`"share": "smb://nas/music", "path": "library"`, kind `network`. A folder picked on a network
volume is stored that way when a mounted share holds it; one on a volume without a remount URL,
and every local folder, is stored by path, as now. Mounting stays the user's job.

- **Finding it:** the app looks for a mounted volume whose remount URL has the same scheme,
  host and share. When none does and exactly one mounted share has the same scheme and share
  name, that one is used, so `nas.local` and the NAS's IP address reach the same library.
  Hosts are compared lowercased without a trailing dot, share names ignoring case (SMB names
  do), and the user name in a remount URL is dropped. No DNS lookup decides it: resolving a
  name is a network call that can hang, and the share name already tells two NASes apart in
  this library. Two candidates, and the folder is offline, with both mount points in the log.
- **When:** the watcher finds the folders when it starts (at launch and after a settings
  change), and before each scan: whenever it's idle and about to start one, it lists the
  mounted shares, which costs no NAS round trip, and finds the folders again only when a
  share's lookup changed. The app also wakes it on wake, on a volume mount and on a network
  change (`NWPathMonitor`). The window shows where the folders' paths were last until then.
- **Where the paths were** is kept per folder (share and path inside it) in a stats table,
  `share_roots`, which index rebuilds keep.
- **A new mount point** (`/Volumes/music` became `/Volumes/music-1`): one transaction rewrites
  the prefix of every `files` and `paths` row under the old one, so IDs, Date Added and stats
  stay and the scan that follows reads nothing. A file the index already held under the new
  root is dropped for that scan to read again. A path under both roots gives way where it has
  no stats; with stats on both, the old one stays where it was and shows in Lost Stats (0026).
  A new root inside the old one, or the old inside the new, is refused with an error.
- **A share that isn't mounted** leaves the folder offline, as now: the folder keeps the root
  its paths had, and its scans report it missing or empty. A folder never found has no root;
  its URL stands in for the path, which no scan finds as a directory.
- **Settings** list a share folder as "library on smb://nas/music"; the sidebar's tooltip for
  the folder shows where it's mounted now.
- **Sync** (0026): the library root is the watched folder, stored the same way, so it's the same
  value on every machine and isn't set per machine. The sync folder is stored the same way.

## Alternatives considered

- **Keep mount paths** — rejected: a remount at `-1` takes the library offline, and repointing
  it loses its stats.
- **Match on the volume's UUID** — rejected: SMB volumes don't report a stable one.
- **Mounting the share when it's missing** — not now: the owner didn't ask for it. NetFS
  (`NetFSMountURLAsync`) with the Keychain's password and no UI would do it if wanted later.

## Consequences

The library follows the share wherever macOS mounts it. A folder stored by path before this
change stays that way until it's removed and added again. A new or renamed NAS doesn't match
the stored share, so the user picks the folder again once; the new folder has no stored root,
so its scan finds every file at a new path, and move matching (0026) keeps the stats of each
one whose length is unique.
