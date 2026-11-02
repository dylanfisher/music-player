# 0048. ⌘R reveals the selection, in Searcher or in Finder

- **Date:** 2026-11-02
- **Status:** accepted
- **Amends:** [0012](0012-searcher-conventions.md), [0034](0034-folders-and-library-health.md)

## Context

The owner, 2026-11-02: ⌘R should reveal the track, in Searcher (`~/projects/searcher`, the
owner's file browser) when it's installed, else in Finder, with a setting that picks Finder or
Searcher. Reveal in Finder had ⇧⌘R, as in Music and Swinsian, and Searcher's ⌥⌘R as the
alternate (0034). ⌘R had no command.

Searcher's bundle ID is `com.dylanfisher.searcher`, from its `Info.plist`. Its 0137 records how
reveals reach a file viewer: `activateFileViewerSelecting` goes to the app the global
`NSFileViewer` key names, so with Searcher set as the system's file viewer, a reveal meant for
Finder would open Searcher. Searcher takes an open-documents event naming files as a reveal: it
shows each file selected in its folder.

## Decision

- **⌘R is Reveal in Finder's primary, ⇧⌘R its alternate.** ⌘R was free. A command has two
  default chords, so Searcher's ⌥⌘R is no longer a default; the Shortcuts pane or the config
  file can bind it again.
- **The title stays Reveal in Finder** when Searcher shows the files. Menu titles are fixed, and
  macOS calls a reveal "Show in Finder" in every app whatever the file viewer is, which is how
  Searcher's own 0137 is used.
- **The setting `library.fileViewer`** (File Viewer, in the Library section and the File menu)
  is Searcher or Finder, Searcher by default. Searcher reveals by opening the files with the
  app Launch Services finds for Searcher's bundle ID, which sends that event. When no app has
  the ID, the reveal goes to Finder, as the owner asked, and the setting's summary says so.
- **Finder means Finder.** Before a reveal in Finder, the app puts `NSFileViewer =
  com.apple.finder` in its own argument domain, in memory only, as Searcher's 0137 does, so a
  global `NSFileViewer` naming Searcher or another app doesn't take the reveal.

## Alternatives considered

- **Telling Finder to reveal over Apple events** — rejected: it needs the Automation
  permission, and the argument domain does the same with none.
- **Opening the files with Finder's app URL** — rejected: Finder opens the files in their
  default app, which would play them, rather than revealing them.
- **A title that follows the setting** ("Reveal in Searcher") — rejected: no command title
  changes with a setting, and the palette and the Shortcuts pane list the command by one title.
