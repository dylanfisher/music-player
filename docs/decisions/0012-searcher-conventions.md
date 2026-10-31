# 0012. Commands, shortcuts, palette, config and chrome follow Searcher

- **Date:** 2026-10-30
- **Status:** proposed. Nothing below is built until the owner answers each question in
  [Open questions](#open-questions).

## Context

Searcher (`~/projects/searcher`) is the owner's other native macOS app, with the same stack and
the same AGENTS.md rules. The owner wants phase 6 (command registry, shortcuts, ⌘K palette,
settings window) and the main window of phase 5 to feel like Searcher: the same keys doing the
same jobs, and the same defaults, config file, palette and chrome. We port Searcher's decisions,
rewritten for this repo's tiers and naming. We don't copy its code.

Searcher's records are the source of truth, not this summary. What counts in each is its
`## Decision` section and its dated amendments, which quote the owner. Before building a part,
read its records in `~/projects/searcher/docs/decisions/`:

| Topic | Searcher records | Searcher code |
|---|---|---|
| Commands are data, one spelling per chord, clashes throw | 0010 | `Sources/Browser/Command.swift`, `CommandRegistry.swift`, `KeyChord.swift`, `CommandID.swift` |
| Keys reach commands only through the registry; a menu item for every command | 0027, 0060 | `Sources/Interface/MainMenuBuilder.swift`, `KeyChord+NSEvent.swift` |
| Primary and alternate chords, overrides, reserved and fixed chords, the recorder | 0106 | `Sources/Browser/KeyBindings.swift`, `ShortcutOverride.swift`, `Sources/Interface/ShortcutRecorderField.swift`, `ShortcutsSettingsView.swift` |
| The config file is the settings | 0123, 0126, 0130; 0120 and 0122 are superseded but explain the banner and shortcut errors | `Sources/Browser/Settings.swift`, `Settings+Preference.swift`, `ConfigFile.swift`, `ConfigText.swift`, `ConfigStore.swift`, `ConfigPatch.swift`, `Sources/Interface/ConfigErrorBanner.swift`, `GeneralSettingsView.swift` |
| ⌘K palette: panel, keys, ranking, frecency | 0087, 0085, 0079, 0101 | `Sources/Browser/Palette*.swift`, `Sources/Base/FuzzyMatch*.swift`, `Sources/Interface/Palette*.swift` |
| Row movement, type-to-select, type-to-filter | 0029, 0034, 0037 | `Sources/Browser/SelectionCommands.swift`, `TypeSelect.swift`, `NameFilter.swift` |
| Hover, pressed, focused and disabled states | 0110 | `Sources/Interface/HoverButton.swift` |
| Native chrome, translucent bars, dialogs, appearance, status bar | 0128, 0133, 0136, 0139, 0076, 0100, 0131 | `Sources/Interface/` |

This record does two things. It says what carries over as Searcher has it. Then it lists each
place where Searcher's choice and this repo's existing choice or domain differ, with a
recommendation, for the owner to decide.

## Decision

Once the open questions are answered, these carry over from Searcher. They are checked against
the records and code above as of 2026-10-30.

### Commands and keys (0010, 0027, 0060, 0106)

- Every user action is a registered `Command`: an ID such as `selection.tenRowsDown`, a title
  and up to two default chords, the primary and then the alternate. The menus, the key handling,
  the palette, the Shortcuts pane and the config file all read the registry. Nothing else turns
  a key into an action.
- A chord has one spelling. `KeyChord.init` traps on an uppercase letter (write `"k"` plus
  Shift) and on whitespace or control characters, which are named keys (`.space`, `.tab`,
  `.return`, `.escape`, `.delete`). The stored form is the modifiers in the order ctrl, opt,
  cmd, shift, then the key, joined by `+`: `cmd+shift+k`, `cmd++`, `f5`, `pageup`.
  `KeyChord(stored:)` accepts only that spelling.
- Two defaults on one chord throw at registration, and a test fails. A clash that stored data
  makes is settled for the user's chord: the other command loses it, and the loss is logged,
  never thrown.
- Every command has a main menu item, and a test fails, naming the command, when one has none.
  The item's key equivalent is the command's first chord that can be one (it has ⌘, ⌃ or ⌥, or
  is an F-key). A hidden item beside it (`isHidden`, `allowsKeyEquivalentWhenHidden`) carries
  the second. Plain keys (Space, Return, the arrows, a plain letter) never become key
  equivalents, so text fields keep them; they reach their command from the focused view's
  `keyDown`. The row-movement submenu shows no chords. Changes show in the menus at once.
- Reserved chords (Quit, Hide, Hide Others, Minimize, Settings… on ⌘,) can't be bound to a
  command. The six Edit items keep their chords (⌘Z, ⇧⌘Z, ⌘X, ⌘C, ⌘V, ⌘A) as their commands'
  fixed primaries, so text fields always have them; a command's alternate stays editable.
- An unbound chord with ⌘, ⌃ or ⌥ beeps instead of reaching `NSTableView`'s own key bindings.
  Unbound plain and Shift-only printable keys go to type-to-select.
- Type-to-select (0034): plain letters select the first row starting with what was typed. A
  pause of 1 s, any command, or a change of list starts a new query. A repeated letter doesn't
  cycle. Space while a query is being typed joins the query, ahead of the command on Space.
- The Shortcuts pane has a recorder for each slot, with Reset per command and Reset All. A chord
  another command has says "⇧⌘P is used by Go to Item." with Replace and Cancel. Recording never
  runs the command (0106's amendment of 2026-10-26).

### Config file (0123, 0126, 0130)

- One JSON-with-comments file holds every preference and the user's shortcut overrides. `//` and
  `/* */` comments, a trailing comma and a UTF-8 BOM are allowed; nothing else from JSON5 is.
- A new file lists every preference at its default, in schema order, each with a comment above
  it: the summary, then what it takes. It ends with `"shortcuts": {}` and its own comment. This
  is the only time the app writes the whole file. Copy Default Config puts the same text on the
  pasteboard.
- Each change in the app is a patch to one key's text, read-modify-write and atomic. The user's
  comments, spacing, key order and line endings stay. The file is watched and reloaded live. A
  deleted file means the defaults.
- An unknown key, a bad value or a duplicate key is an error naming its line and key. A file
  with any error applies nothing, the last good settings stay, and a banner across the window
  says what's wrong, with Open Config File. A broken file is never written over: changes made
  meanwhile wait in a queue and are written on top of the user's fix.
- Shortcut overrides: `"shortcuts": {"window.showPalette": {"alternate": "cmd+shift+o"}}`. A
  slot left out keeps its default, `""` removes it, and a slot equal to its default is dropped
  from the next write. A reserved or fixed chord in the file is an error. Two slots given one
  chord isn't: the first command keeps it and the other loss is logged.
- App state (window frame, splits, column widths, the palette's place, the queue) is not config
  and stays out of the file.
- Open Config File and Copy Default Config are commands with no chord, in the app menu and the
  palette.

### Palette (0087, 0085, 0079, 0101)

- A borderless panel that is its own window: it opens on the screen of the window that opened
  it, centered across, its top a fifth of the way down. It's dragged by its background, and the
  dragged place is remembered across relaunches as app state. It closes when it loses the keys.
- A field with a magnifying glass on top, then rows: the kind's icon, the title with matched
  letters bold, the detail in secondary text, and a command's effective primary chord
  right-aligned as a menu draws it (⌃⌥⇧⌘). The selection uses the accent colour. Long titles
  wrap.
- ↑, ↓, Page Up and Page Down move; Return runs; Esc closes and gives the keys back to whatever
  had them. The opening chords and ⌘W close it; the other palette's chords switch to it. An off
  command is listed greyed, and Return beeps on it.
- Matching follows 0079: word-start, component-start and initials bonuses, the prefix rule from
  three letters, best alignment by dynamic program, folded bytes. Ranking follows 0085: kind
  bonus and a frecency bonus (zoxide weights: 4 within the hour, 2 the day, 1/2 the week, 1/4
  before), top-k per bucket. Ranking runs off the main actor and the latest query wins. Our
  budget is < 30 ms per keystroke at 43k tracks; Searcher's is 50 ms.
- The matcher has no knowledge of music, so it is a primitive here: `Sources/Primitives/FuzzyMatch`.

### Look and feel (0110, 0128, 0133, 0136, 0076, 0100)

- Native AppKit chrome. Nothing is hand-drawn where the system has a control. System label
  colours and materials, so light and dark both follow the appearance. An `appearance` setting
  of auto, light or dark sets `NSApp.appearance`, at launch and on each change. Translucent bars.
  When a behaviour question comes up, match Music.app (where Searcher matches Finder).
- Every interactive control has distinct hover, pressed, focused and disabled looks. Bezel
  controls have them already. Borderless ones use a `HoverButton`: a rounded
  `quaternaryLabelColor` fill on hover, `tertiaryLabelColor` while pressed, the focus ring around
  the same rounded shape, and AppKit's dimmed symbol while disabled.
- Dialogs go through one path and are `NSAlert` sheets on the window they're about (0076).
- macOS 12 on the 2015 MacBook Pro is the baseline. Searcher's macOS 26 parts (`NSGlassEffectView`,
  split-view accessory bars) sit behind `#available` with the pre-26 path as the default: the
  palette's backdrop is an `NSVisualEffectView` with the `.popover` material, `.behindWindow`,
  state `.active`, clipped to a 20 pt rounded rectangle with a hairline edge (0087's updates).
  Bars hang from the content view's safe area (0133, "Before macOS 26").

## Open questions

Each question names Searcher's choice, this repo's, and a recommendation. The owner answers;
the answers become this record's Decision and amend the records they touch.

### Q1. Window layout in Settings, which phase 5 is building now

Phase 5 step 2 saves the window frame, split positions, queue panel, track table columns and
sort, sidebar source and pane selections as `window.*` and `browser.*` settings, and that code is
on `phase/5-main-window` now. Searcher keeps all of this out of the config file, because it's
where the user left things, not a choice (0123). Under Q2 these keys would be written into the
user's commented file on every drag.

**Recommend:** keep the layout out of the config file. Store it as app state in
`~/Library/Application Support/MusicPlayer/state.json`, decoded with the same strict
`Setting<Value>` schema and discarded whole on a mismatch (pre-release boundary). Phase 5 can
finish on `SettingsStore` and move the keys in phase 6, or move them now. Decide before phase 5
merges.

### Q2. Move the settings to Searcher's config file model?

ADR 0003 and phase 1 store only the changed values at
`~/Library/Application Support/MusicPlayer/settings.json`, with `--export-settings` and
`--import-settings`. The `Setting<Value>` schema on `AppSettings` maps onto Searcher's
`Settings.preferences`: the summary becomes the comment's first line, and `SettingKind` gives
the "takes" line and the error words.

**Recommend:** yes, move to Searcher's model, with these parts:

- **Q2a. Location.** `~/.config/music-player/config.json`, changeable in Settings, with the
  chosen path the one thing kept outside the file (in `UserDefaults`). The library database and
  the device restore record stay in Application Support. Phase 5's `--settings <file>` then
  points at a config file only, and the library gets its own `--db` instead of "the library
  beside it".
- **Q2b. Export and import.** Remove both CLI flags. The file is already the export. Copy
  Default Config replaces exporting the defaults, and choosing another file's location replaces
  import.
- **Q2c. Key spelling.** Keep ours (`output.hogMode`), not Searcher's dashed keys (`show-hidden`).
  Ours match the command IDs that `"shortcuts"` already uses, so the file names things one way.
  Searcher's 0122 had to accept two spellings for this reason.
- **Q2d. A bad file at launch.** Today `SettingsStore.init` throws and the app stops. In
  Searcher the app starts on the defaults (or the last good settings), shows the banner, and
  doesn't write over the file. Take Searcher's for the window app. The CLI commands, which have
  no window, keep failing loudly.
- **Q2e. Live reload.** Phase 5 reads settings once at launch and passes them in. Live reload
  needs settings that can be observed. Add that in phase 6 and leave phase 5 as planned.

### Q3. Shortcut conflicts

Phase 6 says conflicts "are reported by name, not silently overridden". Searcher's user chord
wins over a default, and the loser is only logged. The Shortcuts pane names the other command
when you record a chord it has.

**Recommend:** Searcher's. The recorder reports a clash by name before anything changes. A clash
in the config file that a later default creates goes to the log and, so that it's not only in
the log, a line in the Shortcuts pane under the command that lost its chord.

### Q4. "Every setting is a command"

Phase 6 makes changing each setting a command. Searcher registers commands only for settings
that read as menu items (Show Status Bar, the three Appearance items). The rest are edited in
Settings or the config file.

**Recommend:** generate commands from the schema for Boolean settings (a toggle titled with what
it would do) and choice settings (one command per value, as Searcher's Appearance items). Other
kinds (numbers, lists, folders) get a palette item of a "setting" kind that opens the Settings
window at that row, not a command.

### Q5. The settings window

Phase 6 generates the window from the schema, with no UI code per setting. Searcher's General
pane is written by hand, and its panes are SwiftUI. AGENTS.md lists AppKit, not SwiftUI, and
SwiftUI on macOS 12 lacks parts Searcher uses.

**Recommend:** keep ours: one generated General pane in AppKit (`NSGridView` rows from the
schema), plus Searcher's config file buttons (Change…, Open in Editor, Reveal in Finder, Use
Default, Copy Default Config) above it. The Shortcuts pane is AppKit too, laid out as Searcher's.
Using SwiftUI would be a stack change, so it's the owner's call.

### Q6. What the palette searches

Phase 6 puts commands, settings, tracks, albums, artists and playlists in ⌘K. Searcher's ⌘K
(Open Quickly) has commands and places. Its ⌘P (Go to Item) searches only the rows of the
current list and jumps to the chosen row, centred.

**Recommend:** ⌘K lists commands, settings, artists, albums, genres and playlists, a few
thousand items. Tracks go through ⌘P, over the rows of the current track list (up to 43k,
prepared off the main actor as Searcher's 0101 does), and through the search field (FTS5).
Frecency counts plays (phase 7's stats) and palette choices, with zoxide's weights. Frecency is
app state, not config. The 30 ms budget applies to both palettes, measured in Bench at 43k rows.

### Q7. Keys where Searcher's job and a player's differ

Checked against `~/projects/searcher/Sources/Browser/*Commands.swift`. Music.app's chords marked
"unverified" are from memory and need checking in its menus before they're used.

| Key | Searcher | Recommend here |
|---|---|---|
| Return | Rename | Play the selection, as Music.app and Swinsian do |
| Space | Quick Look | Play/pause. Space while type-to-select is typing still joins the query |
| ← / → | To parent column / into folder | Move focus between the genre, artist and album panes and the track table |
| Tab | Focus the other pane | Same idea: the next of sidebar, panes, track table and queue |
| ⌘↓ / ⌘↑ | Open / go to parent | Same keys: play the selection or go into the pane's selection / back up a pane. Music.app uses them for volume (unverified), so volume goes elsewhere (Q8) |
| ⌘N | New Window | New Playlist (phase 7), as Music.app does (unverified). One main window, so no New Window |
| ⌘T, ⇧⌘W, ⇧⌘[ / ⇧⌘] | Tabs | Not used: no tabs |
| ⌘W | Close Pane | Close Window, the standard item |
| ⌘⌫ | Move to Trash | Never touches files (AGENTS.md). Remove from queue or playlist |
| ⌘F | Show the filter bar, Esc hides it | Focus the search field, which is always in the toolbar as in Music.app. Esc clears it and gives the keys to the table; ↑/↓ in it move the table |
| ⌘1, ⌘3 | List / column view | No view modes; unbound |
| ⌃⌥1–4, ⌥⌘P, ⇧⌥⌘P | Sort by a column / next column / reverse | Same keys. ⌃⌥1–4 sort by Title, Artist, Album and Date Added (fixed, since a command's title is fixed) |
| ⌥⌘R | Reveal in Finder | Same. Music.app's Show in Finder is ⇧⌘R (unverified); same key, same job wins |
| ⌘I, ⌥⌘C | Get Info, Copy Path | Same: track info (read-only until phase 11), copy the file's path |
| ⌘/ | Status bar | Same: a status bar with the list's track count, total time and size, as Swinsian has |

The rest of the handoff's table carries over unchanged: ↓/↑, ⇧↓/⇧↑, ⌥↓/⌥↑ with ⌃⇧↓/⌃⇧↑ for 10
rows, Home/End with ⌘⌥↑/⌘⌥↓, Page Down/Page Up, ⌘A, ⌘U/⇧⌘U, ⌘[/⌘], ⌃⌘S, ⌘0, ⌘K with ⇧⌘P, ⌘P
with ⇧⌘K, and ⌘,.

### Q8. Defaults for player-only commands

None of these collides with Q7 or the registry above.

| Command | Proposed default | Why |
|---|---|---|
| Play/Pause | Space | Music.app and Swinsian |
| Next / Previous Track | ⌘→ / ⌘← | Music.app's Controls menu. As key equivalents these take ⌘←/⌘→ from the search field's caret. A test checks the field still moves its caret, or the field takes them before the menu, as Searcher's filter field takes its own keys (0037) |
| Seek Forward / Back | ⌥⌘→ / ⌥⌘← | Searcher leaves these free. No Music.app default known |
| Volume Up / Down | ⌃⌘↑ / ⌃⌘↓ | Music.app's ⌘↑/⌘↓ are Open/Go Up here (Q7). Only enabled while digital volume is on |
| Play Next | ⌥Return | Next to Return's Play. No Music.app default known |
| Go to Current Track | ⌘L | Music.app (unverified) |
| Show Queue | ⌥⌘U | Music.app's Playing Next (unverified) |
| Stop, Shuffle, Repeat | none | Rarely keyed. The palette and the Controls menu run them |

### Q9. Window chrome

Phase 5 plans a now-playing bar. Music.app puts transport, art and the progress display in a
unified toolbar, with the search field at the toolbar's trailing end.

**Recommend:** Music.app's arrangement: transport and now-playing in an `NSToolbar` with
`.fullSizeContentView` and the unified style, the sidebar running full height, and the search
field as a toolbar item. The config error banner hangs from the content's safe area under the
toolbar (0133's pre-26 path). The status bar is a plain view along the bottom (0131's pre-26
path). No tab strip.

## Alternatives considered

- **Share Searcher's code as a package** — rejected: a new dependency (AGENTS.md principle 7),
  and the two apps' tiers differ. Searcher's `Browser` mixes what is core and features here.
- **Port Searcher's choices as they are, without the question list** — rejected: this repo
  already decided settings storage (ADR 0003), the settings window and the conflict rule
  differently, and a player has jobs a file browser doesn't.
- **Keep this repo's settings model and add only the commands and palette** — rejected in the
  recommendation (Q2): the owner asked for the same config file, and Searcher's 0123 explains
  why an app copy over the file confused the owner there.

## Consequences

Phase 6 can't start until this record is accepted. The phase 5 layout keys (Q1) may move in phase
6, which changes `AppSettings` and the window's save path. If Q2 is accepted, ADR 0003 gets an
amendment: the schema stays, but "the file holds only changed values" and export/import go. Some
Music.app chords in Q7 and Q8 are unverified and need checking on a Mac with Music.app before
they ship.
