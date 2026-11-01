# 0012. Commands, shortcuts, palette and config follow Searcher; the window follows Swinsian

- **Date:** 2026-10-30
- **Status:** accepted
- **Amended by:** [0015](0015-config-file.md): what this left open in phase 6, including which
  Edit items have commands.
- **Amends:** [0003](0003-settings-schema.md) (where the file lives, what it holds, export and
  import)

## Context

Searcher (`~/projects/searcher`) is the owner's other native macOS app, with the same stack and
the same AGENTS.md rules. The owner wants this app's command registry, shortcuts, ⌘K palette,
config file and settings window (phase 6), and the controls of the main window (phase 5), to work
the way Searcher's do. We port Searcher's decisions, rewritten for this repo's tiers and naming.
We don't copy its code.

The owner's answers, 2026-10-30: "appkit is good, shortcuts will obviously need to be changed the
majority to match the music player, but a few can be consistent. config file model: choose which
model seems best - only choose searcher's if it seems better. we want to look less like music.app
and more like swinsian. palette budge can be different." The run should go on without waiting on
the owner, so this record decides each difference itself. A wrong call is a later amendment, not
a blocker.

Searcher's records are the source of truth for what is ported, not this summary. What counts in
each is its `## Decision` section and its dated amendments, which quote the owner. Before
building a part, read its records in `~/projects/searcher/docs/decisions/`:

| Topic | Searcher records | Searcher code |
|---|---|---|
| Commands are data, one spelling per chord, clashes throw | 0010 | `Sources/Browser/Command.swift`, `CommandRegistry.swift`, `KeyChord.swift`, `CommandID.swift` |
| Keys reach commands only through the registry; a menu item for every command | 0027, 0060 | `Sources/Interface/MainMenuBuilder.swift`, `KeyChord+NSEvent.swift` |
| Primary and alternate chords, overrides, reserved and fixed chords, the recorder | 0106 | `Sources/Browser/KeyBindings.swift`, `ShortcutOverride.swift`, `Sources/Interface/ShortcutRecorderField.swift`, `ShortcutsSettingsView.swift` |
| The config file is the settings | 0123, 0126, 0130; 0120 and 0122 are superseded but explain the banner and shortcut errors | `Sources/Browser/Settings.swift`, `Settings+Preference.swift`, `ConfigFile.swift`, `ConfigText.swift`, `ConfigStore.swift`, `ConfigPatch.swift`, `Sources/Interface/ConfigErrorBanner.swift`, `GeneralSettingsView.swift` |
| ⌘K palette: panel, keys, ranking, frecency | 0087, 0085, 0079, 0101 | `Sources/Browser/Palette*.swift`, `Sources/Base/FuzzyMatch*.swift`, `Sources/Interface/Palette*.swift` |
| Row movement, type-to-select, type-to-filter | 0029, 0034, 0037 | `Sources/Browser/SelectionCommands.swift`, `TypeSelect.swift`, `NameFilter.swift` |
| Hover, pressed, focused and disabled states | 0110 | `Sources/Interface/HoverButton.swift` |
| Dialogs, appearance | 0076, 0100 | `Sources/Interface/` |

Searcher's chrome records (0128, 0133, 0136, 0139, 0131) copy Finder's window. This app copies
Swinsian's layout instead, so they're useful only for how Searcher builds a bar with AppKit
before macOS 26.

## Decision

### Commands and keys (0010, 0027, 0060, 0106)

- Every user action is a registered `Command`: an ID such as `selection.tenRowsDown`, a title
  and up to two default chords, the primary and then the alternate. The menus, the key handling,
  the palette, the Shortcuts pane, the config file and the remote API (phase 10) all read the
  registry. Nothing else turns a key into an action.
- A chord has one spelling. `KeyChord.init` traps on an uppercase letter (write `"k"` plus
  Shift) and on whitespace or control characters, which are named keys (`.space`, `.tab`,
  `.return`, `.escape`, `.delete`). The stored form is the modifiers in the order ctrl, opt,
  cmd, shift, then the key, joined by `+`: `cmd+shift+k`, `cmd++`, `f5`, `pageup`.
  `KeyChord(stored:)` accepts only that spelling.
- Two defaults on one chord throw at registration, and a test fails. The user's chord beats a
  default: the other command loses it, and the loss is logged and shown under that command in
  the Shortcuts pane. Stored data never makes the app throw.
- Every command has a main menu item, and a test fails, naming the command, when one has none.
  The item's key equivalent is the command's first chord that can be one (it has ⌘, ⌃ or ⌥, or
  is an F-key). A hidden item beside it (`isHidden`, `allowsKeyEquivalentWhenHidden`) carries
  the second. Plain keys (Space, Return, the arrows, a plain letter) never become key
  equivalents, so text fields keep them; they reach their command from the focused view's
  `keyDown`. The row-movement submenu shows no chords. Changes show in the menus at once.
- Reserved chords (Quit, Hide, Hide Others, Minimize, Settings… on ⌘,) can't be bound to a
  command. The six Edit items keep their chords (⌘Z, ⇧⌘Z, ⌘X, ⌘C, ⌘V, ⌘A), so text fields
  always have them: Select All's ⌘A is its command's fixed primary, and the other five, which
  have no commands, are reserved (0015). A command's alternate stays editable.
- An unbound chord with ⌘, ⌃ or ⌥ beeps instead of reaching `NSTableView`'s own key bindings.
  Unbound plain and Shift-only printable keys go to type-to-select.
- Type-to-select (0034), in the track table and each browser pane: plain letters select the
  first row whose sort column starts with what was typed. A pause of 1 s, any command, or a
  change of list starts a new query. A repeated letter doesn't cycle. Space while a query is
  being typed joins the query, ahead of Play/Pause.
- The Shortcuts pane has a recorder for each slot, with Reset per command and Reset All. A chord
  another command has says "⇧⌘P is used by Go to Item." with Replace and Cancel. Recording never
  runs the command (0106's amendment of 2026-10-26).
- **Which settings are commands.** The registry generates a command from the schema for each
  Boolean setting (a toggle titled with what it would do, such as "Turn On Hog Mode") and one
  for each value of a choice setting (as Searcher's three Appearance items). Numbers, lists and
  folders aren't commands: the palette lists them as settings, and choosing one opens the
  Settings window at its row.

### Default shortcuts

Most defaults follow music players. A few keep Searcher's, where the job is the same. Every
default can be changed in the Shortcuts pane or the config file, so a poor default costs one
line. Swinsian isn't installed on the build Mac, so its menus weren't checked: the player
defaults below are the ones Mac players share (iTunes, Music.app and Swinsian alike, from
memory). The owner can correct any of them later; the run doesn't wait for that.

Kept from Searcher, the same job on the same key:

| Action | Default |
|---|---|
| Command palette | ⌘K, alternate ⇧⌘P. Pressing it again or ⌘W closes it |
| Go to Item in the current list | ⌘P, alternate ⇧⌘K |
| Next / previous row, extend the selection | ↓ / ↑, ⇧↓ / ⇧↑ |
| Move 10 rows | ⌥↓ / ⌥↑, alternate ⌃⇧↓ / ⌃⇧↑ |
| First / last row | Home / End, alternate ⌘⌥↑ / ⌘⌥↓ |
| Page down / up | Page Down / Page Up |
| Select All | ⌘A |
| Search | ⌘F focuses the search field. Esc clears it and gives the keys back to the list; ↑/↓ in the field move the list |
| Sort by Title, Artist, Album, Date Added / reverse | ⌃⌥1–4 / ⇧⌥⌘P |
| Toggle sidebar / focus sidebar | ⌃⌘S / ⌘0 |
| Toggle status bar | ⌘/ |
| Edit Tags… (Searcher's Get Info) / Reveal in Finder / Copy Path | ⌘I / ⇧⌘R (as Music and Swinsian), alternate ⌥⌘R / ⌥⌘C |
| Back / forward through sidebar sources | ⌘[ / ⌘] |
| Settings | ⌘, (reserved) |
| Open Config File, Copy Default Config | no chord; app menu and palette |

The player's own:

| Action | Default | Note |
|---|---|---|
| Play/Pause | Space | |
| Play the selection | Return, alternate ⌘↓ | ⌘↓ is Searcher's Open |
| Play Next | ⌥Return | |
| Next / Previous Track | ⌘→ / ⌘← | A field being edited takes ⌘ or ⌥ with ←, → or ⌫ (± ⇧) before the menu, in every window, as Searcher's filter field takes its own keys (0037). A test checks it |
| Seek Forward / Back | ⌥⌘→ / ⌥⌘← | |
| Volume Up / Down | ⌃⌘↑ / ⌃⌘↓ | Enabled only while digital volume is on |
| Show Current Track | ⌘L | |
| Show Queue | ⌥⌘U | |
| Show Signal Path | ⌥⌘S | phase 20 |
| New Playlist / New Smart Playlist | ⌘N / ⌥⌘N | phase 7 |
| Add Watched Folder… | ⌘O | |
| Remove from Queue or Playlist | ⌘⌫ | Never touches files (AGENTS.md) |
| Focus the next or previous browser pane | → / ← | Genre, artist, album, then the track table |
| Next focus area | Tab | Sidebar, panes, track table, queue |
| Close Window | ⌘W | The standard item |
| Stop, Shuffle, Repeat | none | The palette and the Controls menu run them |

Volume takes ⌃⌘↑ / ⌃⌘↓, not the players' ⌘↑ / ⌘↓, because ⌘↓ plays the selection, as Open in
Searcher. Its commands are off unless digital volume is on, since the default output is
bit-perfect with no volume. No tabs, so none of Searcher's tab or window
keys (⌘T, ⇧⌘W, ⇧⌘[ / ⇧⌘]) are bound, and ⌘1 / ⌘3 (view modes) are free.

### Config file

We take Searcher's model, without the configurable location. Each part was weighed against
0003's model (only changed values, export and import):

- **The file is the settings.** One JSON-with-comments file,
  `~/.config/music-player/config.json`, holds every preference and the user's shortcut
  overrides. The app reads and writes it; there is no second copy. Better than 0003's because
  the owner edits settings by hand, as in Sublime Text, and a file that lists every option with
  what it takes can be edited without the docs. 0003's file of changed values shows nothing to
  edit.
- **Location: fixed.** Searcher's Change… button, its location in `UserDefaults` and its handling
  of moves and missing volumes are left out. A symbolic link at that path (to Dropbox, or a
  dotfiles repo) is read and written through, as in Searcher, which covers the same need with
  less code. `~/.config` rather than Application Support, so dotfile tools find it. The library
  database and the device restore record stay in Application Support. `--settings <file>` points
  at a config file only; `--db` names the library.
- **Format.** `//` and `/* */` comments, a trailing comma and a UTF-8 BOM are allowed; nothing
  else from JSON5 is (0126). Keys keep this repo's spelling (`output.hogMode`), which matches the
  command IDs under `"shortcuts"`, rather than Searcher's dashed keys.
- **A new file** lists every preference at its default, in schema order, each with a comment
  above it: the summary from `Setting`, then what it takes, from `SettingKind`. It ends with
  `"shortcuts": {}` and its own comment. Copy Default Config puts the same text on the
  pasteboard.
- **Writes are patches.** Each change in the app rewrites one key's text, read-modify-write and
  atomic, keeping the user's comments, spacing and key order (0123, 0126).
- **Live reload.** The file is watched and reloaded on save, so settings become observable. A
  deleted file means the defaults.
- **Errors.** An unknown key, a bad value or a duplicate key is an error naming its line and key.
  A file with any error applies nothing, the last good settings stay (the defaults at launch),
  and a banner across the window names the error, with Open Config File. Changes made meanwhile
  wait and are written on top of the fix; a broken file is never written over. The CLI commands,
  with no window, still fail loudly on a bad file.
- **Shortcuts:** `"shortcuts": {"window.showPalette": {"alternate": "cmd+shift+o"}}`. A slot left
  out keeps its default, `""` removes it, and a slot equal to its default is dropped at the next
  write. A reserved or fixed chord in the file is an error; two slots given one chord isn't.
- **Export and import go.** The file is the export. Copy Default Config gives the defaults, and
  copying a config file into place is the import.
- **App state isn't config.** Window frame, splits, column widths, the sort, pane selections, the
  palette's place and frecency are where the user left things, not choices. They go to
  `~/Library/Application Support/MusicPlayer/state.json`, decoded with the same `Setting<Value>`
  schema and discarded whole on a mismatch (pre-release boundary), and saved through
  `StateStore`.

### Palette (0087, 0085, 0079, 0101)

- A borderless panel that is its own window: it opens on the screen of the window that opened
  it, centred across, its top a fifth of the way down. It's dragged by its background, and the
  dragged place is remembered as app state. It closes when it loses the keys.
- A field with a magnifying glass on top, then rows: the kind's icon, the title with matched
  letters bold, the detail in secondary text, and a command's effective primary chord
  right-aligned as a menu draws it (⌃⌥⇧⌘). The selection uses the accent colour. Long titles
  wrap.
- ↑, ↓, Page Up and Page Down move; Return runs; Esc closes and gives the keys back to whatever
  had them. The opening chords and ⌘W close it; the other palette's chords switch to it. An off
  command is listed greyed, and Return beeps on it.
- **⌘K** lists commands, settings, artists, albums, genres and playlists, a few thousand items.
  **⌘P** (Go to Item) lists the rows of the current track list, prepared off the main actor as
  0101 does, and selects the chosen row, centred. Tracks aren't in ⌘K: the search field (FTS5)
  and ⌘P cover them, and 43k titles would crowd out the rest.
- Matching follows 0079 and ranking 0085: word-start, component-start and initials bonuses, the
  prefix rule from three letters, a kind bonus, and frecency with zoxide's weights (4 within the
  hour, 2 the day, 1/2 the week, 1/4 before), counted from palette choices and plays. Ranking runs
  off the main actor and the latest query wins.
- The budget is this repo's own: < 30 ms per keystroke on Apple Silicon and < 80 ms on the old
  Mac, for either palette over 43k rows, measured in Bench.
- The matcher has no knowledge of music, so it is a primitive: `Sources/Primitives/FuzzyMatch`.

### Settings window

AppKit, as the owner chose. One window with a toolbar of panes. General is generated from the
schema in an `NSGridView`, one row per setting, so a new setting appears with no UI code, under
a header with Open Config File, Reveal in Finder and Copy Default Config. Shortcuts is laid out
as Searcher's: a search field, the commands in sections as the menus list them, two recorders
and Reset per row, Reset All in the footer.

### Look and feel

- The layout follows Swinsian, not Music.app: a source list sidebar, the genre, artist and album
  column browser above the track table, a toolbar with transport, the now-playing track and the
  search field, and a status bar with the list's track count, total time and size. When a
  behaviour question comes up, do what Swinsian does.
- Native AppKit controls. Nothing is hand-drawn where the system has a control. System label
  colours and materials, so light and dark both follow the appearance. An `appearance` setting
  of auto, light or dark sets `NSApp.appearance`, at launch and on each change (0100).
- Every interactive control has distinct hover, pressed, focused and disabled looks (0110). Bezel
  controls have them already. Borderless ones use a `HoverButton`: a rounded
  `quaternaryLabelColor` fill on hover, `tertiaryLabelColor` while pressed, the focus ring around
  the same rounded shape, and AppKit's dimmed symbol while disabled.
- Dialogs go through one path and are `NSAlert` sheets on the window they're about (0076).
- macOS 12 on the 2015 MacBook Pro is the baseline. Anything from macOS 26 (`NSGlassEffectView`,
  split-view accessory bars) sits behind `#available`, with the pre-26 path as the default: the
  palette's backdrop is an `NSVisualEffectView` with the `.popover` material, `.behindWindow`,
  state `.active`, clipped to a 20 pt rounded rectangle with a hairline edge (0087's updates).
  Bars hang from the content view's safe area (0133, "Before macOS 26").

## Alternatives considered

- **Share Searcher's code as a package** — rejected: a new dependency (AGENTS.md principle 7),
  and the tiers differ. Searcher's `Browser` mixes what is core and features here.
- **Keep 0003's model: changed values only, export and import** — rejected: the file shows none
  of the options, so editing it by hand needs the docs, and export and import are two commands
  for what copying one file does.
- **Searcher's configurable location** — rejected for now: a symbolic link covers keeping the
  file in Dropbox, and the location code (moves, missing volumes, a path kept outside the file)
  is most of what 0123's store does beyond the patches.
- **Searcher's shortcuts throughout** — rejected: a file browser's Return renames and its Space
  previews, and a player's users expect Return and Space to play.
- **Searcher's hidden-until-⌘F filter bar** — rejected: Swinsian keeps its search field in the
  toolbar, and search is the main way into a 43k-track library.
- **Tracks in ⌘K** — rejected: 43k titles would bury commands and albums, and the search field
  already finds tracks.
- **SwiftUI settings panes, as Searcher has** — rejected by the owner: AppKit.

## Consequences

Phase 5 went on as planned. Phase 6 moved the layout keys out of `AppSettings` into the state
file (`StateStore`), made the config file (`ConfigStore`) the settings in place of
`SettingsStore`, and removed `--export-settings` and `--import-settings`. The player defaults
weren't checked against Swinsian's menus; correcting one later is a one-line change in its
command set and this record's table.
