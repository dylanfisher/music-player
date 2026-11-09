

### 61. Tagging preferences in Settings

- [x] **Editor:** the tagging preferences now set only in `config.json` (suffixes to drop,
      formats, the mappings) get an editor in Settings. Secrets stay out of it (AGENTS.md).

Implementation plan, phase 61 (ADR 0165):

What exists, found by search (map.md recipes): the tagger reads `discogs.mapping`,
`discogs.savedMappings`, `discogs.keepExistingValues`, `discogs.skipVideo`,
`discogs.fillSortArtist`, `discogs.artwork`, `discogs.dumpsFolder`, `discogs.catalogPath` and
`discogs.token` (`AppSettings`). All but the mapping's parts are shown somewhere: the tagger's
window and its Field Mapping sheet (`MappingSheet`, `MappingDraft`) show the four choices, each
field's mode, tags, join and template, and save and remove named mappings; the Discogs window
picks the dumps folder. What only `config.json` sets is each rule's `format` (`names`,
`suffixes`, `repeats`, `date`, `credits` per tag format) and a tag spelled per format or
numbered. The tie-break's preferred formats, edition and later-pressing words
(`Core/Discogs/TieBreak.swift`) are constants, not settings. `ConfigStore.set(key:json:)`
decodes and checks a value as the file's is, then patches only that key's text, written at mode
0600; an edit in the file reaches `SettingsWindowController.reload` through `changed`.

- 61.1 Core (`Settings`, `Discogs`): the modes' titles move from `TaggerTitles` to
  `DiscogsFieldRule.Mode`; `DiscogsFieldFormat` names what a part left out writes, which
  `MappedValue` and the date's render read; the format's choices are `CaseIterable`;
  `DiscogsTarget(names:numbered:)` reads a target's spellings as the file reads its string, and
  `MappingDraft` and the decoder use it.
- 61.2 `TaggingModel` (`Features/SettingsWindow`, no AppKit): the mapping in use as a draft, each
  field a key with its rule as the value; edits to the mode, the tags (add, remove, edit each
  format's spelling, numbered), join, template and each format part; the problem from
  `discogs.mapping`'s own `value(fromText:)`; Save through the model's `set`, Revert, and a
  reload that takes the file's value unless the draft is edited.
- 61.3 `TaggingPane` and `Pane.tagging`: a table of each field, by its title (`Discogs`'s
  `DiscogsField.title`) with its key as the tooltip, and its rule, the selected rule's form
  under it, the problem line, Revert and Save; `show(setting:)` opens it for the mapping;
  `--snapshot-of tagging`.
- 61.4 Tests: the model's edits and problems; the pane's table, form and Save; over a real
  `ConfigStore`, both secrets byte for byte after a save at mode 0600, and an edit in the file
  shown.

Order: 61.1, 61.2, 61.3, 61.4 with each, then the ADR.

Result, phase 61: shipped (ADR 0165). Settings has a Tagging pane, after Watched Folders, for
`discogs.mapping`, the mapping in use: each field by its title with its config.json key as the
tooltip, and the selected rule's mode, tags (one column per format's spelling, numbered or
not), join, template, and each format part (names, number suffixes, repeats, date, credits per
format) that before only config.json could set. A draft is checked by the setting's own reader
and saved through `ConfigStore.set(key:json:)`, which patches only the mapping at mode 0600; a
test keeps both fake tokens byte for byte. A blocked file keeps the draft and says so. The
tie-break's formats and edition words stay constants (ADR 0131), not settings. The Field
Mapping sheet and the pane share the rule edits, `PerTagFormat.isUniform` and
`DiscogsTarget.text`. Gate: one correctness and one simplify review, no correctness defects,
5 findings fixed in 7 commits; `theGlassHeadersAreFrosted` fails as in every agent session, and
`importColumnLayoutShowsAndSavesSwinsiansColumns` took 11 s under load and passed alone in
0.4 s. Cost: implementer about 330k tokens, 162 tool calls, 43 min; reviewers 151k tokens, 27
calls, 3 min.

Owner steps: Settings > Tagging, titles with the key as tooltip; on "artist" set Number Suffixes
to drop "(2)" and Save, then check config.json changed only in `discogs.mapping` and `stat -f
%Lp config.json` prints 600; clear Genres' join, see why Save is off, Revert; edit the mapping
in an editor with the pane open, then again over an edited draft and see the note; break
config.json and see the pane keep its draft; save with the tagger open and see it pick up the
change; the pane on mbp2015.


