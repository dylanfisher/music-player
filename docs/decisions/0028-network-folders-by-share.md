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
  host and share. Hosts are the same when they differ only in case, a trailing dot, `.local`
  or a Bonjour service label (`nas._smb._tcp.local`); share names ignore case, as SMB's do,
  and the user name in the URL is dropped. Without such a match, a share with the same name is
  used only when one of the two hosts is an IP address and no other mounted share has that
  name, so the NAS reached by its address is found. A second server with a share of the same
  name is never used: with the NAS off and `smb://backup/music` mounted, retargeting would
  have the next scan remove the library and scramble its stats. That case, and two candidates,
  leave the folder offline with the mount points in the log. The share mounted twice on its
  host (`/Volumes/music` and `/Volumes/music-1`, which macOS makes when it reconnects while the
  old mount lingers) is one share, so the first mount point in order is used. No DNS lookup decides it: it's a
  network call that can hang.
- **Listing the shares** reads the kernel's mount table with `getmntinfo(MNT_NOWAIT)`: the
  mount point and the source (`//user@nas/music` on `smbfs`, `nas:/export` on `nfs`), which
  give the share's URL without asking any volume. `volumeURLForRemountingKey` asks each one,
  and a hung SMB mount would block it, and with it the watcher's queue that quit waits on.
- **When:** the watcher finds the folders when it starts (at launch and after a settings
  change); after a trigger, which the app sends on wake, on a volume mount and on a network
  change (`NWPathMonitor`); and when a scan is about to start, comparing each share's lookup
  with the last and rewriting only when one changed. Not on every FSEvents batch, playback
  change or timer. If finding them fails at start (the listing or the index), the local
  folders are watched anyway, share folders stay where their paths were, files outside the
  folders aren't removed that launch, and the next trigger or scan tries again. The window
  shows where the folders' paths were last until the watcher reports.
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
