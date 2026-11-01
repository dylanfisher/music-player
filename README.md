# music-player

A native macOS player for large local hi-res and DSD libraries. It plays bit-perfect to a local
DAC, switching sample rate and bit depth per track, and streams at full quality to UPnP/DLNA
renderers such as a Denon AVR.

Runs on macOS 12 and later, so a 2015 MacBook Pro is the oldest supported machine.

## Use

- **Settings** live in `~/.config/music-player/config.json`, a JSON file with comments that
  lists every setting at its default with what it takes. Edit it in any editor and the app picks
  the change up on save; a mistake shows in a banner across the window and nothing in the file
  applies until it's fixed. The Settings window (⌘,) edits the same file, with a General pane
  for the settings and a Shortcuts pane for every command's two chords.
- **⌘K** opens the command palette: every command, setting, playlist, genre, artist and album,
  ranked by how well they match and how often and recently you chose or played them.
- **⌘P** is Go to Item: the tracks of the current list, by title.
- **Playlists** (⌘N, or ⇧⌘N from the selection) take tracks dragged onto them in the sidebar,
  and reorder by dragging while sorted by Order. **Smart playlists** (⌥⌘N) pick tracks by rules
  and follow the library as it changes. Plays, skips, ratings and History are kept in the
  library database, never in the music files; a play counts after half the track or 4 minutes.
  History lists each track played once; **Timeline** lists every play, newest first.

## Develop

Needs the Xcode version in `.xcode-version`, selected with `sudo xcode-select -s`.

| Task | Command |
|---|---|
| Install / bootstrap | `./scripts/setup` |
| Run the app | `./scripts/dev` (`--home <folder>` keeps the config file, library and state in one folder; `--settings <file>` names another config file) |
| Check a window's layout | `./scripts/dev --home <folder> --snapshot <file.png> [--snapshot-of main\|palette\|playlist\|tags\|settings\|shortcuts]` |
| Run tests | `./scripts/test` |
| Build the `.app`, signed ad hoc with the hardened runtime | `./scripts/bundle [debug\|release]` |
| Check a bundle's signature and entitlements, and that it launches hardened (not in `check`) | `./scripts/check-signature <MusicPlayer.app> [--launch]` |
| Update a second Mac's clone, then run the app | `./scripts/pull` |
| Build the fixture library (43k tagged files) | `./scripts/fixtures [--count N]` |
| Survey the tag corpus, or edit and undo every file on clones of it (not in `check`) | `./scripts/tag-corpus [<folder> \| --round-trip]` |
| Run the benchmarks against their budgets | `./scripts/bench [--soak <seconds>] [name]` |
| Kill the app's writes at random points, or fill the disk under them, and check what's left (not in `check`) | `./scripts/kill-test [--kills N] [--seed N]`, `./scripts/full-disk` |
| Everything CI runs | `./scripts/check` |

`./scripts/check` runs every step even after one fails, so one run lists every problem.

## Where to read next

| Path | Purpose |
|---|---|
| `AGENTS.md` | Rules for AI coding agents, and the definition of done. Kept under ~50 lines. |
| [docs/plan.md](docs/plan.md) | The build plan: phases, the gate between them, and performance budgets. |
| [docs/map.md](docs/map.md) | Tiers, where code lives, and how to find something before writing a second one. |
| [docs/writing.md](docs/writing.md) | Comment voice and commit message format. |
| [docs/principles.md](docs/principles.md) | Why the principles in AGENTS.md are what they are. |
| [docs/decisions/](docs/decisions/) | Architecture decision records. |

## License

None yet; all rights reserved.
