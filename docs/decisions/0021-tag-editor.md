# 0021. The tag editor reads the files, shows mixed values, and writes only on Save

- **Date:** 2026-10-31
- **Status:** accepted

## Context

Phase 11's editor edits one track or many, shows where a selection differs, and replaces or
removes art. Every action is a registry command (phase 6), and the App tier only wires.

## Decision

- **Features/TagEditor.** `TagEditorModel` (no AppKit) holds the tracks, each field's shared
  value or "mixed", what the user typed, and the art; `edit()` keeps only fields typed
  differently from what they showed and checks every value against every track before anything
  is written. `TagEditorSheet` is the AppKit sheet; `TagEditing` reads the files off the main
  thread (an earlier open's read is dropped by a session number), writes one edit at a time off
  the main thread, reports failures in an alert, and passes the changed files on so the app
  rescans their folders.
- **The editor reads the files**, not the index, so it starts from what is written there,
  including comment and composer, which the index doesn't keep. A file that can't be read is
  reported and the rest open.
- **Mixed fields** show "Mixed" as a placeholder and stay untouched unless typed in; typing
  then clearing one clears it in every file. The compilation box starts in the mixed state and
  a click sets it for all.
- **Commands:** Edit Tags… (⌘I, Searcher's Get Info), Undo Tag Edit, Replace Artwork… and Remove
  Artwork, in the File menu. The sheet's art buttons run the last two through the dispatcher.
  Save writes one file directly; more than one asks first ("Change the tags of 12 files?").
- **After a write**, `LibraryWatcher.rescan(directories:)` queues the edited folders, network
  ones too, since FSEvents reports nothing there; a network rescan waits for playback as polls
  do.

## Alternatives considered

- **Edit from the index's values.** Rejected: the index lacks fields and can be stale; writing
  from it could undo a change made in another app.
- **Write a field the user didn't touch with the value shown.** Rejected: in a batch it would
  overwrite each file's own value with the first's.
- **Undo through ⌘Z.** Rejected for now: text fields own ⌘Z, and a file write isn't the kind of
  change the Edit menu's Undo reverts silently.

## Consequences

Opening the editor on a large selection reads every file first (a few seconds on the NAS for
an album, longer for thousands). Art the user picks is written as chosen, at full size.
