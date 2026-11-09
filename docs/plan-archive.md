

### 57. Get Info

- [x] **No flashing:** the window opens at its final layout; its tabs don't resize after it
      shows.
- [x] **Resizable,** and it remembers its size and position (phase 55).
- [x] **Discogs tab always shown,** so a release id can be set where none is; the earlier
      choice to hide it without one is reversed.
- [x] **Play count** field, editable, for the count phase 56 lets the user set.

Implementation plan, phase 57 (ADRs 0160, 0162):

What exists, found by search (map.md recipes):

- `TagEditorWindow` makes its layout in `init` at a fixed width (660) and tab height (440),
  then `load` fills it in. With no release id, `showDiscogs` takes the Discogs tab out
  (`removeDiscogsTab`, from 53.11, a plan choice with no ADR). Eleven tabs don't fit in
  660 points, so the tab bar squeezes them, and taking one out after the window shows lays
  the rest out again: the owner's "tabs resize themselves". The window isn't resizable and
  keeps only its top left corner, in `tagEditor.place` (`InfoWindowPlace`), its own
  cascade past open windows, `start(place:parent:screens:)` and `moved`.
- `window.keepsFrame(as:)` (ADR 0158); Spectrum keeps the first window's frame and cascades
  the rest from the last one open.
- The Discogs tab reads the first release id the files hold, through `release`, and shows the
  catalog's text. The release id is the custom key `DiscogsKey.releaseID`, which Extras
  edits through `TagEditorModel.setExtra`.
- Play counts are app state: `plays.play_count`, which `recordPlay`, imports (`totals`) and
  sync add to; nothing writes a play count to a file. Sync (ADR 0038) unions plays and keeps
  each player's highest import total; ratings and the like are last-writer-wins through
  `sync_items` (`SyncField`). The stats parts are rebuilt by their SQL text, so a new table
  goes in a part of its own.

Parts, in order, each its own commit:

1. **Discogs tab always shown** (ADR 0160). `removeDiscogsTab` goes; with no release id the
   tab says so. A Release ID field at its top edits `DiscogsKey.releaseID` through the
   model's Extras edit, so it saves through `TagEdit.custom` with the other fields, shows
   "Mixed" for files that differ, and reads the typed release from the catalog. `edit()`
   refuses an id that isn't a whole number above 0. Tests: the tab with no id, typing an id
   reads it and saves it, a bad id is refused.
2. **No flash** (ADR 0160). The cause is the tab taken out after the window shows, fixed by
   part 1; also the tab view's minimum size, so the tab bar never squeezes, and a layout pass
   before the window first shows. Test: the tab bar and window frame are the same before and
   after `load`, for files with and without a release id.
3. **Resizable, keeps its frame** (ADR 0160). `.resizable`, a minimum size from the content
   at its fitting size; the tabs take the extra height and the fields the extra width. The
   first window open keeps its frame as "Get Info Window"; one opened while another is open
   cascades from the last, at its size. `tagEditor.place`, `InfoWindowPlace`, `moved`,
   `start` and the cascade-past-taken-corners code go. Tests: the window resizes, its frame
   is kept under the name, and a second window cascades.
4. **Play count, stored and synced** (ADR 0162). `LibraryIndex.setPlayCount(_:paths:)`
   stores each track's hand-set count as an offset over its counted plays (a part of its own,
   `playCounts`), changing `plays.play_count` by the difference, and logs a `playCount`
   event with the offset, last writer wins through `sync_items`. Merging applies the
   offset over the plays that machine counts, so plays made elsewhere add on top and two
   machines' sets don't add up. Moves carry the offset; rebuilding the imports or the part
   takes it out first. Tests: set, set again, sync to a second index, plays after the set
   add on, a lower set, a move, the line's round trip.
5. **Play count field** in Get Info's File tab ("Plays"): "Mixed" where the tracks differ,
   typing sets every track that has a row in the index, Save stores it through the app (not
   the tag writer), also for read-only files. Tests: the model's shared value and edit, and
   `TagEditing` handing a save's count on, with no write for a count alone.

Result, phase 57: shipped all four items (ADRs 0160 and 0162; 0038 and 0158 amended). Get Info
opens at its final layout: the tab bar now gets the 641 points its eleven tabs need and the
Discogs tab is never removed, and the least height of 470 fits Info, the tallest tab. It is
resizable and keeps its frame as "Get Info Window"; a second one cascades, through the same
`keepsFrame(as:cascadedFrom:)` Spectrum now uses. The Discogs tab always shows, with a Release
ID field. Plays is set by hand on the File tab, stored as an offset over the counted plays and
synced as a latest-wins `playCount` event, so later plays on any Mac add on top. Gate: one
correctness and one simplify review, 8 findings fixed in 10 commits, each correctness fix with
a test seen failing first; `theGlassHeadersAreFrosted` fails as in every agent session, and
`watcherEventsArriveInTheOrderSent` missed its 10 s deadline once under load and passed alone.
No bench row covers Get Info. Cost: implementer about 330k tokens plus the fixes, 163 tool calls,
38 min before the fixes; reviewers 182k tokens, 33 calls, 4 min.

Owner steps: before the first launch, delete the `"tagEditor.place"` line from `state.json`, or
the state file is discarded once; Get Info on files with and without a release id, nothing
jumping and every tab label whole; resize, close, reopen and relaunch, and a second window
cascading; a release id typed on an untagged album, saved, shown in Extras; one deleted in
Extras then typed on the Discogs tab, saved, the new one written; Plays on one track and a mixed
selection, the table updating, and with sync on the count and a later play reaching the other
Mac.


