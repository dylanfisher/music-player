# 0152. Editing the Extras tab, and when Undo Tag Edit is on

- **Date:** 2026-11-08
- **Status:** accepted
- **See also:** [0129](0129-custom-tag-fields.md) (custom keys and `TagEdit.custom`),
  [0020](0020-tag-writing.md) (the undo journal), [0136](0136-asking-before-a-rescan-and-undoing-a-tagger-write.md)
  (Undo Tag Edit undoes the newest edit anywhere)

## Context

The info window's Extras tab (53.8) listed, read only, every key the reader found that no
field maps. The owner asked to change a value, delete a key and add one there. Undo Tag Edit
was on whenever the main window was open, so with nothing journaled it only beeped; the owner
asked for it to be off unless there's an edit to undo.

## Decision

### Extras

- **A table of key and value, with + and −,** in place of the text. A value is typed in as a
  field is: it goes into the window's model, a dot marks the edited key, Cancel drops it, and
  Save writes it with the fields through `TagEdit.custom`. A deleted key is written as empty
  text, which the writer reads as "remove". Keys another tab shows, as the Discogs ones, stay
  listed and editable: Extras is what the files hold.
- **Several files:** a key that differs, or that some files lack, shows "Mixed" and isn't in
  the edit unless typed in; then the value goes to every file, as for a field. A key deleted
  is removed from every writable file that holds it.
- **New keys are uppercased.** The reader gives every key back uppercased, and the writer
  replaces a key of the same name in any case, so keeping the typed case would only last until
  the window read the files again.
- **Names are checked on +, with why on the window's line:** `customKeyProblem`, which refuses
  what no format holds and a field's name (it would read back as that field), and a key
  already listed. An ID3-only key (`WXXX:`, `TIPL`) is refused while a writable file of another
  format is selected. `edit()` checks that again for an ID3-only key already in the files, as
  a `WXXX:` key changed or deleted with an MP3 and a FLAC selected: the writer refuses the
  whole FLAC file for it, even to remove a key the file doesn't hold, which would leave the
  batch half written.
- **Read-only files** show their keys but can't be typed in, added to or removed from, as
  their fields; in a mixed selection only the writable files are checked and written.
- **The Discogs tab stays read only.** It shows the local catalog's record of the release, not
  the file's tags.

### Undo Tag Edit

- **`TagEditing.canUndo`, read off the main thread.** Whether there's an edit to undo is a
  read of the journal folder, which can throw and, on a slow disk, stall; menu validation runs
  on the main thread whenever a menu opens. So the value is kept, and read on the writes queue
  at launch (after the recovery of an interrupted write) and after every write and undo
  finishes. The Discogs tagger's writes go through the same queue, so they count. The info
  windows' Undo Tag Edit buttons are refreshed when it's read; the menu item asks when shown.
- **A journal that can't be read leaves it on,** and the error is logged. Off would hide the
  problem behind a dead menu item; on, the click reads the journal again and shows the error.
  It's on until the first read for the same reason.

Rejected: reading the journal in the command's rule, which would list the folder on the main
thread at every menu open and key press.
