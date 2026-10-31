# 0015. The config file, `--home`, and what 0012 left open in phase 6

- **Date:** 2026-10-31
- **Status:** accepted
- **Amends:** [0003](0003-settings-schema.md), [0012](0012-searcher-conventions.md)

## Context

[0012](0012-searcher-conventions.md) takes Searcher's config file model: one JSON-with-comments
file at `~/.config/music-player/config.json` that is the settings, patched by the app, reloaded
on save, with a banner for errors. Building it raised questions 0012 doesn't answer, and the run
goes on without the owner, so this record decides them.

## Decision

- **Shape.** `ConfigText` blanks comments, trailing commas and a byte order mark to spaces,
  keeping every offset, so Foundation parses the text and errors keep the file's lines. A scan of
  the same text finds each key's value span and every key an object has twice, at any depth.
  `ConfigFile` reads and validates (unknown keys, bad values, duplicates, shortcut slots) and
  writes patches: a known key's value text is replaced, a new key goes in after the last one at
  its indent with its comment, a one-line object stays on one line, CRLF stays CRLF. A shortcut
  patch rewrites one command's object on one line, `{"alternate": "cmd+shift+o"}`, or takes the
  command out when it's back to its defaults.
- **Shortcut checks are injected.** Settings can't see the registry, so the app passes a
  `ShortcutCheck` built from `KeyBindings.problem`: an unknown command ID, a reserved chord, or a
  fixed chord elsewhere is an error on its line. An unknown ID is an error, not ignored, so a
  typo fails loudly, as an unknown setting key does.
- **`ConfigStore` runs on the main actor and writes synchronously.** The file is a few kilobytes
  on a local disk (or a symbolic link to one), so a read-modify-write costs well under a
  millisecond; Searcher's store actor and quit flush aren't needed. A failed write keeps its
  patches, shows in the banner, and retries after 1 s, doubling to 30 s. Before each write the
  file is read again; if it changed since the last read, that edit applies first and the patches
  go on top.
- **Reading.** FSEvents watches the file's folder, and a symbolic link's target folder. A file
  found empty or gone where it wasn't is read again 0.2 s later before it counts. Gone means the
  defaults; empty is an error. The app writes a new file with every default when there is none at
  launch; the command-line modes only read, and throw on any problem.
- **Live changes.** Shortcuts rebuild the key bindings and the menus' chords; appearance sets
  `NSApp.appearance`; watched folders, network readers and pausing rescans restart the watcher.
  The output settings (device, hog mode, digital volume) reopen the output, but only once
  playback is stopped, so a change never cuts a track; the log says it's waiting.
- **`--home <folder>`** keeps the config file, library, state file and device record in one
  folder, for tests, Bench and every run on the build Mac. `--settings <file>` names a config
  file only. The library and device record moved from "beside the settings file" to the data
  folder (`AppPaths`).
- **Edit items.** Undo, Redo, Cut, Copy and Paste have no commands yet, so their chords are
  reserved like Quit's. Select All is the one Edit item with a command, `edit.selectAll`, whose
  ⌘A is a fixed primary.
- **State before config.** The layout keys moved to `state.json` first, in the same commit that
  titled the settings, because a generated toggle for `window.queueVisible` would otherwise have
  duplicated Show Queue. `StateStore` discards a file that doesn't decode.

## Alternatives considered

- **Searcher's off-main store actor with a quit flush** — rejected: the file is small and local,
  and the actor's queue and flush deadline are most of its code.
- **Patching each shortcut slot separately** — rejected: rewriting one command's small object
  keeps the user's other text just as well with less scanning.
- **Ignoring shortcuts for unknown command IDs**, as Searcher's stored data does — rejected for
  the hand-edited file, where a typo would do nothing silently.
- **Reopening the output at once on a change** — rejected: it would stop the track playing.

## Consequences

A setting needs no config code: its summary and type make its comment, its decoder its check.
A new output setting must be added to the reopen list in `SettingsChanges.swift`. A config file
on a slow network share would block the main thread on writes; revisit if the owner keeps it
there.
