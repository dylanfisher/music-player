# 0165. Tagging preferences in Settings

- **Date:** 2026-11-09
- **Status:** accepted
- **See also:** [0132](0132-discogs-field-mapping.md) (the field mapping and its sheet),
  [0015](0015-config-file.md) (the config file), [0082](0082-config-safety.md) (a file
  with problems refuses changes), [0137](0137-the-discogs-token.md) and
  [0144](0144-the-service-token.md) (the two secrets), [0159](0159-settings-the-menus-dont-list.md)
  (the tagger's choices beside its mappings)

## Context

The owner asked for a way to edit in the app the tagging preferences only `config.json` sets,
"like suffixes for drop, format", with a mapping editor. The Discogs tagger reads nine keys.
Seven are already shown: the tagger's window and its Field Mapping sheet show Keep Existing
Values, Skip Video, Fill Sort Artist and Artwork, each field's mode, tags, join and template,
and save, choose and remove named mappings; the Discogs window picks the dumps folder and the
file sets the catalog's path for a Mac short of space (ADR 0130). `discogs.token` is a secret.
What only the file set is inside `discogs.mapping`: each rule's `format` (`names`, `suffixes`,
`repeats`, `date`, `credits` per tag format), and a tag spelled per format or numbered, which
the sheet shows but won't edit.

## Decision

- **A Tagging pane of its own** in Settings, after Watched Folders. General's Library section
  was just shortened, and the mapping is a table, not a row.
- **It edits the mapping in use, every part of every rule.** A table lists each field by its
  key in the file, with its rule as the value. Under it, the selected rule: the mode, the tags
  as a list (add, remove, edit) with a column per format's spelling, `vorbis`, `mp4` and `id3`
  as the file names them, and a box for numbered keys, then the join, the template and a pop-up
  for each format part. A part left out shows what it writes (`DiscogsFieldFormat`'s
  `…Written`, which the writer reads too).
- **One check, the file's.** The draft is written as the file holds the setting and read back
  with the setting's own `value(fromText:)`, so the problem the pane shows is the file's word
  for word, and Save is off while there is one. Save goes through the settings' `set`, which
  checks again and patches only the mapping's text: every other key, the secrets included,
  stays byte for byte, at mode 0600.
- **Save and Revert, not a save per change.** A rule passes through states the check refuses,
  a tag added with no name yet or a join cleared before a new one is typed, so the draft is
  kept until Save, as the address rows' Save button keeps their text.
- **An edit in the file while the pane is open** replaces a draft with no changes; a draft with
  changes is kept, with a note that Revert shows the file's.
- **Left out:** the named mappings (the sheet saves, chooses and removes them; one is edited by
  choosing it there, editing it here and saving it there again); the tagger's four choices,
  shown in the tagger's window (ADR 0159); the dumps folder and catalog path (ADR 0130); the
  token. The tie-break's preferred formats and edition and later-pressing words
  (`TieBreak.swift`) are constants the owner approved in ADR 0131, not settings, so they stay
  in the code.

## Alternatives considered

- **Format columns in the Field Mapping sheet.** Seven more columns in a sheet already at its
  width, and the owner asked for the preferences in Settings.
- **A text view of the mapping's JSON.** The file already is one; the owner asked for an editor.
- **Field titles ("Album Artist") in the table.** They're `Discogs`'s, a module the Settings
  window doesn't import, and the keys are what the file holds.

## Consequences

The mapping has two editors that write the same setting. Each reloads on the other's change:
the tagger through `mappingChanged`, the pane through the window's reload. A draft edited in
both at once keeps the pane's until Save or Revert.
