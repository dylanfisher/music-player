# music-player

A native macOS player for large local hi-res and DSD libraries. It plays bit-perfect to a local
DAC, switching sample rate and bit depth per track, converts for a device that can't take a track
unchanged, such as Bluetooth headphones, and streams at full quality to UPnP/DLNA renderers such
as a Denon AVR.

Runs on macOS 12 and later, so a 2015 MacBook Pro is the oldest supported machine.

## Use

- **Settings** live in `~/.config/music-player/config.json`, a JSON file with comments that
  lists every setting at its default with what it takes. Edit it in any editor and the app picks
  the change up on save; a mistake shows in a banner across the window and nothing in the file
  applies until it's fixed. The Settings window (⌘,) edits the same file, with a General pane
  for the settings in titled boxes, a Playback pane for the output and play counts, an
  Appearance pane for light or dark and the track table's lines, rows and album art, a Watched
  Folders pane with the network folders' settings, and a Shortcuts pane for every command's two chords. Network Scan Readers, and File Viewer without
  Searcher, are set in the file only. What each browser column groups by, picked by
  right-clicking its header, is saved in the file too, as `browser.columnGroupings`; the same
  menu adds a column (up to six) or removes one.
- **⌘K** opens the command palette: every command, setting, output, playlist and genre, ranked
  by how well they match and how often and recently you chose or played them.
- **Controls ▸ Output** picks the output device or a UPnP renderer on the network, by name;
  the Settings window's Output Device popup and ⌘K's "Output:" rows pick from the same list.
- **⌘P** is Go to Item: the artists, then the albums, then every track in the library. A kind
  and a colon search that kind alone: `album: dream`, `track: windowlicker`, `artist:`, or
  the short `a:`, `ar:`, `t:`, `g:` and `p:`.
- **Playlists** (⌘N, or ⇧⌘N from the selection) take tracks dragged onto them in the sidebar,
  and reorder by dragging while sorted by Order. **Smart playlists** (⌥⌘N) pick tracks by rules
  and follow the library as it changes. Click a selected playlist's name, or press Return, to
  rename it in place; its context menu also duplicates and deletes it. Plays, skips, ratings and History are kept in the
  library database, never in the music files; a play counts once 75% of the track has played (Count as
  Played At in Settings), or 4 minutes when its length isn't known.
  History lists each track played once; **Timeline** lists every play, newest first.
- **Import Playlist…** reads M3U, M3U8 and PLS files, also dropped on the sidebar, as new
  playlists, and lists the entries the library doesn't hold. **Export Playlist…** writes the
  playlist shown as M3U8, in the table's order, with absolute or relative paths.
- **Import from Swinsian…** and **Import iTunes Library…** bring play counts, last played,
  date added, ratings, loved tracks and playlists across, matched by path, after a preview of
  what each would change. Running one again adds only the plays since.
- **Watched folders** are listed in Settings ▸ Library, which adds and removes them;
  ⌘O adds one too. A folder on a network share is stored by the share, so the library follows it when
  macOS mounts it somewhere else, such as `/Volumes/music-1`. A network folder already in the
  library isn't rescanned at launch: it's checked every `pollIntervalMinutes` (60 by default,
  up to 1440), or with Never (`null`) only when asked; **Rescan All** checks every folder at
  once, and **Rescan** the ones selected.
  A renamed or moved file keeps its plays, rating and playlist entries. **Library Health** lists files that couldn't be read,
  playlist entries whose file left, likely duplicates, albums with gaps, several album artists
  or mixed sample rates, tracks missing art, an album or an album artist, and Lost Stats: files
  with stats that left without a match, which **Resolve Lost Stats…** gives to a track or
  dismisses. **Import Moves…** applies a list of moved files' old and new paths, a tab
  between them, one file a line, so a conversion script's moves keep their stats exactly.
  **Show Library Health** (File menu, or the button in Settings ▸ Library)
  shows a tile per check with its count over the track table, in the browser columns' place;
  a tile lists its tracks below. It runs after a scan and on Show Library Health. ⌘R reveals the selected tracks
  in Searcher, or in Finder when Searcher isn't installed or the File Viewer setting says so.
- **Sync Folder** (Settings): Macs that play the same library on a share share their plays,
  ratings, loved tracks, playlists and Date Added through a folder outside the music, where
  each writes only its own log. They sync at launch, after each rescan and on wake; a Mac
  away from the share keeps its changes and sends them when it's back.
- **`music-player`**, in `Music Player.app/Contents/MacOS`, runs any command in the app and
  starts it if it isn't running: `music-player next`, `music-player play "album:Kind of Blue"`,
  `music-player status --json`. `music-player help` lists the commands. Links run playback and
  moving around the window only: `music-player://next`, `music-player://play?q=miles`
  ([ADR 0036](docs/decisions/0036-scripting.md)).

## Develop

Needs the Xcode version in `.xcode-version`, selected with `sudo xcode-select -s`.

| Task | Command |
|---|---|
| Install / bootstrap | `./scripts/setup` |
| Run the app | `./scripts/dev` (`--home <folder>` keeps the config file, library and state in one folder; `--settings <file>` names another config file) |
| Check a window's layout | `./scripts/dev --home <folder> --snapshot <file.png> [--snapshot-of main\|palette\|playlist\|tags\|settings\|playback\|appearance\|toolbar\|library\|shortcuts\|statusBar\|headerStatus\|toolbarSheet\|downloads]` |
| Run tests: only the targets edited since the last pass (`--fresh` for all), or those changed since a commit | `./scripts/test [--fresh]`, `./scripts/test --changed [ref]` |
| Build the `.app`, signed ad hoc with the hardened runtime (debug also lets lldb attach) | `./scripts/bundle [debug\|release]` |
| Build the release `.app` and replace the copy in `/Applications`, quitting it first | `./scripts/install` |
| Check a release bundle's signature and entitlements, and that it launches hardened (not in `check`) | `./scripts/check-signature "<Music Player.app>" [--launch]` |
| Update a second Mac's clone, then run the app | `./scripts/pull` |
| Build the fixture library (43k tagged files) | `./scripts/fixtures [--count N]` |
| Survey the tag corpus, or edit and undo every file on clones of it (not in `check`) | `./scripts/tag-corpus [<folder> \| --round-trip]` |
| Run the benchmarks against their budgets | `./scripts/bench [--soak <seconds>] [name]` |
| Kill the app's writes at random points, or fill the disk under them, and check what's left (not in `check`) | `./scripts/kill-test [--kills N] [--seed N]`, `./scripts/full-disk` |
| Fuzz a parser or the tag writer, or every target at once, with coverage (not in `check`) | `./scripts/fuzz <target>\|all <seconds> [--seed N]` |
| Run the tests under ASan, TSan and UBSan with 1,000 property cases (not in `check`) | `./scripts/sanitize [--thread-runs N] [address] [thread] [undefined]` |
| Mutate the core state machines and list the mutants the tests miss (not in `check`) | `./scripts/mutate [--jobs N] [<part of a path>]` |
| Everything CI runs | `./scripts/check` |

`./scripts/check` runs every step even after one fails, so one run lists every problem.

## Where to read next

| Path | Purpose |
|---|---|
| `AGENTS.md` | Rules for AI coding agents, and the definition of done. Kept under ~50 lines. |
| [docs/plan.md](docs/plan.md) | The build plan: phases still to build, the gate between them, and performance budgets. |
| [docs/plan-archive.md](docs/plan-archive.md) | Finished phases, with their plans and results. |
| [docs/map.md](docs/map.md) | Tiers, where code lives, and how to find something before writing a second one. |
| [docs/writing.md](docs/writing.md) | Comment voice and commit message format. |
| [docs/principles.md](docs/principles.md) | Why the principles in AGENTS.md are what they are. |
| [docs/decisions/](docs/decisions/) | Architecture decision records. |

## License

None yet; all rights reserved.
