

### 56. Browsing and the keyboard

- [x] **Shift with Option-Up/Down:** extends the selection over the rows it jumps.
- [x] **Next and previous album:** Control-Down and Control-Up move the selection to the first
      track of the next or previous album, a rebindable command; with Shift they extend it.
- [x] **Typed palette search:** in the Command-P palette, `album: dream` searches albums only
      and `song: windowlicker` songs only; also `artist:`, and any other kind the palette
      lists.
- [x] **Edit menu:** Copy, Paste and Delete enabled. Copy puts text only on the pasteboard
      (one "Artist – Title" line per track); Paste and Delete work in playlists and the queue
      only, never on the library.
- [x] **Browse columns:** more than three columns in browse mode.
- [x] **Play count:** set by hand (Get Info, phase 57, holds the field).

Plan:

1. **Shift with Option-Up/Down:** two commands in `AppCommands`, Extend Selection Down and Up
   10 Rows (`selection.extendTenRowsDown`/`Up`, ⇧⌥↓/⇧⌥↑), in `RowMove.commands` as the ten-row
   moves with `extending`, and in Edit ▸ Selection. `ListSelection.moved` already extends any
   move; a test drives it through the dispatcher's key routing.
2. **Next and previous album:** `RowMove` gains `nextAlbum` and `previousAlbum`, which
   `ListSelection.moved` resolves from an album ID per row, the one the art column and the
   album lines group by (ADR 0088). Four commands: Select Next and Previous Album (⌃↓/⌃↑) and
   Extend Selection to Next and Previous Album (⌃⇧↓/⌃⇧↑). Move 10 Rows drops its ⌃⇧ alternate
   for them. The track table passes its rows' album IDs; the timeline, the queue and the panes
   have none, so the album moves leave their selection alone. Mission Control's ⌃↑/⌃↓ take the
   chords first while they're on: an ADR says so. Tests on `ListSelection`.
3. **Typed palette search:** `PaletteQuery` in the Palette module reads a leading
   `<kind>:` (`artist:`, `album:`, `song:` or `track:`, `genre:`, `playlist:`, `command:`,
   `setting:`, `output:`) and `rankPalette` ranks only that kind on the rest of the text. A word
   that isn't a kind's leaves the query as typed. Tests on `rankPalette`.
4. **Edit menu:** Copy, Paste and a new Delete item stay standard items (⌘C and ⌘V are the
   field editor's in a text field); the app delegate answers `copy:`, `paste:` and `delete:`
   and validates them. Copy, in the track table, the timeline or the queue, writes one
   "Artist – Title" line per track (`CopiedTrack`, Core/Library) as plain text only, and the
   app keeps the copied files' paths with the pasteboard's change count. Paste, while the
   pasteboard still holds that copy, adds them to the manual playlist shown (placed after the
   selection when the playlist is in its own order) or to the queue (as Add to Playback Queue
   does); nowhere else. Delete runs Remove from Queue or Playlist. Tests on the copied text, the
   clipboard, the paste target and the browser's paste into a playlist.
5. **Browse columns:** `BrowserColumn.counts` is 1 to 6; the config check, the state check and
   `BrowserColumn.restored` take any count in it. `BrowserModel` sizes its entries from the
   columns, and `PanesController` rebuilds its tables when the count changes. The header menu
   gets Add Column (to the right, with the first grouping not shown) and Remove Column, through
   `groupingsChosen` as a grouping choice goes. Tests on the model and the menu.
6. **Play count:** not here. Phase 57, running at the same time, owns the field and its storage.
7. ADR 0161 records the album moves' rules, the chords and Mission Control, the clipboard, and
   the column limits.

Result, phase 56: shipped five items (ADR 0161); the play count went to phase 57. Shift-Option
extends over ten rows. Control-Down and Control-Up move to the next or previous album's first
track, and with Shift extend; the track table reads album ids from the index 500 rows at a
time off the main actor, and a failed read moves nothing. macOS's Mission Control takes
Control-Up and Control-Down by default, so the owner turns those off or rebinds. The palette
takes `artist:`, `album:`, `song:` or `track:`, `genre:`, `playlist:`, and in Command-K
`command:`, `setting:` and `output:`. Edit's Copy writes text only; Paste and Delete reach the
queue and manual playlists only, with the main window key, and a paste keeps the copied order.
Browse mode takes one to six columns. Gate: one correctness and one simplify review, 8
findings fixed in 8 commits; `theGlassHeadersAreFrosted` fails as in every agent session, and
`HTTPClientTests` failed once under load and passed alone. Nothing in playback changed, so no
bench run. Cost: implementer about 290k tokens plus the fixes, 165 tool calls, 31 min before the
fixes; reviewers 166k tokens, 30 calls, 3 min.

Owner steps: Shift-Option-Down and Up in the track table; with Mission Control's Control-Up and
Down off, the album jumps and their Shift forms; Command-P `album: dream`, `song: windowlicker`,
`artist:`; Command-C into TextEdit, and a paste in Finder makes no file; Command-V into a manual
playlist and the queue, greyed in the library and smart playlists; Edit > Delete with Downloads
key does nothing; Add Column to six and back to one, glass on and off, kept over a relaunch;
six columns on the 2015 MacBook Pro.


