

### 96. The web remote, denser and searchable

The owner (2026-11-22), on the web remote: the A–Z selector on the left, and the right side
"should support fine tune scrubbing if possible (e.g. scroll up/down to quickly go through whole
library, move finger left to change scrubbing speed to get fine tunes). if scrubbing is hard,
keep the default scroll"; "lists should have less vertical space so there are more items on
screen at once. keep font size as is"; Now Playing "should show the songs from that album below
it in track view, with a playing indicator on current track"; search "should support same cmd+p
commands, `a:dream` means album matching `dream`"; "a slider for volume"; and "use phosphor
icons https://phosphoricons.com/ for all icons/emojis currently in it". The owner asked for
Phosphor by name, so vendoring its SVGs (MIT) is the owner's go-ahead for that one asset set.

#### 96a. The page: icons, density, the scrubber and volume

- [x] **96a.1 The ADR (0219).** Phosphor's regular weight, the SVGs of only the icons the page
      uses, vendored into `Support/Remote` as one file served by `RemotePage.files` (inline
      SVG keeps the content policy as it is), with its MIT notice and the version they came
      from. It also records the scrubber's rule from 96a.3.
- [x] **96a.2 Icons and density.** Every glyph and emoji in `index.html`, `app.js` and
      `style.css` (transport, repeat one, shuffle, back, the ± and arrows, play state) becomes
      its Phosphor icon, coloured by `currentColor`, each button keeping its `aria-label`.
      List rows lose vertical padding so about 40% more fit on a phone screen, with the font
      sizes unchanged and each row still at least 36 px tall to tap.
- [x] **96a.3 A–Z on the left, the scrubber on the right.** The jump bar moves to the left
      edge. A strip on the right edge scrubs: a vertical drag moves through the whole list in
      proportion, and moving the finger left of the strip slows it (full speed on the strip,
      about a half, a quarter and an eighth at set distances to the left), the way iOS scrubs
      a seek bar, with a small label showing the row's letter or name under the finger. If it
      can't be made smooth on the owner's phone with long lists, the right side keeps the
      default scroll and the ADR says why. The speed rule is a pure function in `logic.js`
      with tests where `logic.js` is tested.
- [x] **96a.4 Receiver volume slider.** The app's slider already shows while Digital Volume is
      on. The receiver row gets a slider too, sending `receiver.setVolume` on release over the
      receiver's range from the state, showing the value while dragged, and the ± buttons stay.
      Tests where the state's receiver fields are tested.

96a implementation plan:

1. **Remote:** `RemoteState.Receiver` says its slider's range (`volumeFloorDecibels`,
   `volumeCeilingDecibels`), which the app passes from `SignalPathPanel.receiverRangeDecibels`
   as it passes the toolbar's for the app volume; tested beside its other fields in
   `RemoteServiceTests`.
2. **Page:** `Support/Remote/icons.js`, the Phosphor 2.1.1 path data and its MIT notice, served
   through `RemotePage.files`; app.js builds each icon with `createElementNS` from
   `data-icon` names, so no markup is parsed and the content policy is unchanged. Rows drop to
   40 px (`ROW` and `--row`).
3. **Scrubber:** the jump bar on the left, a strip on the right of Browse's lists; the speed
   rule (`scrubSpeed`, `scrubbed`) in logic.js, tested in `RemotePageTests` with JavaScriptCore,
   as is every icon's path data being path commands only.
4. **Receiver slider** sending `receiver.setVolume` on release. ADR 0219.

#### 96b. Now Playing's album and search prefixes

- [x] **96b.1 The ADR (0220).** The query grammar of ADR 0161 (`album:`/`a:`, `artist:`/`ar:`,
      `track:`/`t:`, `genre:`/`g:`, `playlist:`/`p:`) moves to a tier `Core/Remote` and
      `Features/Palette` both import, and the server parses `q`, so the page holds no copy.
      A kind the remote doesn't list answers an empty result rather than a 400; an unknown
      word before a colon is plain text, as in the palette.
- [x] **96b.2 Search prefixes.** `/api/search?q=a:dream` returns only albums matching `dream`,
      and the same for each kind the remote lists; the search field's placeholder names them.
      Tests in `RemoteLibraryTests` (each prefix, a short and a long name, case, an unknown
      word) and the palette's existing `PaletteQuery` tests still passing unchanged.
- [x] **96b.3 Now Playing's album.** Below the controls, Now Playing lists the playing track's
      album in track view, read through the routes the album view already uses, with a
      playing indicator (a Phosphor icon) on the current track that moves when the track
      changes, and a tap that plays from that track as the album view's does. A track with no
      album, or nothing playing, shows no list. It reads the album once per album, not once
      per state event.
96b implementation plan:

1. **Grammar:** `TypedQuery`, the `QueryKind` protocol and `SearchKind` (the library kinds and
   their short names) move to `Core/Settings`, the lowest module both `Remote` and `Palette`
   import; `PaletteQuery` becomes `TypedQuery<PaletteItem.Kind>` and the palette's kinds take
   their short names from `SearchKind`, its tests unchanged. A commit of its own.
2. **Search:** `TrackFilter.searchKind` narrows `search` to that kind's FTS columns;
   `RemoteLibrary.search` parses `q` into a `TypedQuery<SearchKind>`, lists only that kind, and
   answers genres and playlists empty. Placeholder from the page names the prefixes. Tests in
   `RemoteLibraryTests` and `LibraryTests`.
3. **Now Playing's album:** app.js reads `/api/tracks?album=…&sort=album` once per Mac and
   album, lists it below the controls with Phosphor's `speaker-high` on the playing track, and
   a tap plays from that track as the album view does. ADR 0220.

- [ ] **Hardware checkpoint (owner):** on the phone, with the library open: the icons, the
      denser lists, A–Z on the left, scrubbing on the right through Artists and Songs at each
      speed, the receiver slider against the Denon, `a:` and `ar:` searches, and Now Playing's
      album following a track change.

Result (2026-11-22): `329e6dfe..a3d9aa80`, 12 commits, in two parts on one branch. 96a: ten
Phosphor 2.1.1 icons, path data only with the MIT notice, in `Support/Remote/icons.js`, drawn
with `createElementNS`, play and pause in the fill weight; rows from 56 to 40 px with the font
sizes unchanged; the jump bar on the left and a 28 px scrub strip on the right of every Browse
list, at full speed on the strip and a half, a quarter and an eighth from 32, 96 and 160 px to
its left (`scrubSpeed`); a receiver slider over −80 to 0 dB from the state, sending
`receiver.setVolume` on release. 96b: the query grammar of ADR 0161 moved to `Core/Settings`
as `TypedQuery`, `PaletteQuery` its typealias with the palette's tests unchanged; the server
reads `q`'s prefix, a prefix matching only its kind's own fields through
`TrackFilter.searchField`, `g:` and `p:` an empty answer, and a query with no word to match
empty in a search and a 400 for a track list or Play List; Now Playing lists the playing album,
read once per Mac and album, with a speaker on the playing track. Both volume sliders share
one `SentSlider`, which holds a sent value only while the state still has the one it replaced.
Decided in ADRs 0219 and 0220. Cost: one Opus builder for 96a, 151k tokens, 69 tool calls,
about 18 minutes; one for 96b and every fix round, 187k, 78 + 36 calls, about 29 + 13 minutes;
Sonnet reviews of both parts, correctness 75k and security 56k, and a re-review, 62k. Security
found nothing real; correctness found the empty grid's scrub strip throwing, a prefix with no
words playing the whole library, a cancelled drag freezing a slider, a failed album read
retried on every event and an icon lookup reaching the prototype; the re-review found the
hold hiding a ± press and a lost receiver's last value. The full gate passed but for
`theGlassHeadersAreFrosted`, which fails on main too, with no screen recording here. The
hardware checkpoint is pending.

