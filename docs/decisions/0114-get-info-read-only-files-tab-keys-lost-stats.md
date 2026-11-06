# 0114. Get Info shows files it can't write; Back and Forward step its tabs; Lost Stats is off with none

- **Date:** 2026-11-06
- **Status:** accepted
- **Amends:** [0100](0100-get-info-windows-and-smb-temp-files.md) (the window opening before
  its files are read), [0026](0026-sync-identity-is-the-relative-path.md) (Resolve Lost Stats)

## Context

The owner's third round of feedback of 2026-11-05 (part 48a). Get Info opened on a small
"Reading tags…" view and swapped in the tabs once the files were read, so the window grew
and every field moved. ⌘[ and ⌘] are Back and Forward, which acted on the main window's
history even while an info window was key; the owner wanted them to switch tabs. Get Info on
a DSF file failed with "files can't be edited": the editor's read parses a `TagFile`, the
writer's structure, for the tag scheme and the fields holding several values, and `TagFile`
refuses DSF and DSDIFF. Resolve Lost Stats was always on, and with none to resolve it wrote a
line in the status bar the owner didn't see.

## Decision

- **The window opens at the size it keeps.** Its heading, tabs, the last tab's fields and the
  buttons row are made before it shows, the fields not yet editable, with a spinner and
  "Reading tags…" in the buttons row. Reading only fills in values. The row's line is one
  line, truncated, with the whole text in its tooltip, so no message makes the row taller.
- **Back and Forward step the key info window's tabs**, wrapping at the ends, and act on the
  main window otherwise. The app's Back and Forward handlers ask `TagEditing` first. The keys
  stay whatever Back and Forward are bound to. While a sheet is on an info window, the keys
  do nothing: they don't change the tabs behind it or the library.
- **The formats the writer refuses are one fact**, `FileFormat.tagWriteRefusal` in TagWriter
  ("Tags in DSF files can't be written yet"), which `TagFile` throws with. `editorTagFacts`
  checks it before parsing a `TagFile`, so a DSF or DSDIFF file is read by Metadata's reader
  alone; its tag shows as ID3v2, or "No tag", and no field counts as holding several values.
- **A read-only file shows its values.** The fields show every file in the window, but an
  edit is checked against, counted for and written to only the writable files. With none
  writable, the fields, the art buttons and Save are off. The line beside the buttons gives
  the reason, and in a mix how many files Save writes. A file that can't be read at all is
  still left out, and the alert says "can't be read".
- **Resolve Lost Stats is off once a health report finds no lost files**, and on before the
  first report, when nothing is known. If its sheet can't open (none found when it runs, or
  the read fails), an alert sheet on the window it was asked over says why.

## Alternatives considered

- **Catching ⌘[ and ⌘] in the info window**: rejected. It fixes the keys to those chords
  while Back and Forward can be rebound, and the menu would still show them as Back and
  Forward.
- **Leaving out the read-only files' values from the shared fields**: rejected. The window is
  for reading too, and a field would show one value while the files hold another.
- **Writing DSF and DSDIFF tags**: left for later. Their ID3v2 tag sits at the end of the
  file (DSF) or in a chunk (DSDIFF), each needing a layout and a read-back check of its own.
- **Keeping the status line for Lost Stats**, made louder: rejected. The user is looking at
  the menu they chose from; an off item says it before the click, and a sheet after.

## Consequences

Opening Get Info builds the first tab's fields before the window shows, which the bench row
for the window on screen measures. A selection of only DSF and DSDIFF files can be looked at
but not changed. The Lost Stats item can be off for a moment after a scan finds a lost file,
until the health report that follows ends.
