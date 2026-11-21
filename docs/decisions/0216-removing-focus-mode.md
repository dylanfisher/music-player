# 0216. Removing Focus Mode

- **Date:** 2026-11-20
- **Status:** accepted
- **Supersedes:** [0204](0204-focus-mode.md)
- **See also:** [0072](0072-window-chrome-and-status-bar.md) (Distraction-Free Mode),
  [0082](0082-config-safety.md) (unknown keys in `config.json`)

## Context

Phase 82 added Focus Mode (ADR 0204): View > Enter Focus Mode, ⌥⌘F, showed the track table
alone, full screen and dark, in Title, Artist and Album at `appearance.focusFontSize`. On
2026-11-20 the owner asked for it, and all the code that served only it, to be removed.

## Decision

- **Removed:** the `view.focusMode` command and its ⌥⌘F, its View menu item and its title and
  enabling; the main window's section, with its injected full-screen toggle, the separator it
  kept a reference to and the Esc callback only it set, so Esc in the window does nothing again;
  the browser's and track table's focus columns, saved layout, rows and branches in column
  reporting; the `appearance.focusFontSize` setting and its row in Settings; and the tests that
  exercised only it.
- **Kept:** a reload of every row, as a row height change makes, keeps the selection, cursor and
  anchor, which `NSTableView.reloadData` drops. Phase 82 found that for every reload, so it
  stays, with a test of its own in place of the deleted Focus Mode test that covered it. The
  View toggles go back to needing only an open window. Distraction-Free Mode and the `focus.*`
  commands, which move the keys, are separate features and stay.
- **A config that still sets the key:** stored data has one shape, so there's no migration. The
  key is an unknown setting like any other: skipped, shown as a problem, and taken out by Remove
  Obsolete Setting. A shortcut override for `view.focusMode` is a problem like one for any
  command that doesn't exist, which keeps the file from applying until it's taken out.
- **It can't come back by halves:** a test checks that ⌥⌘F is unbound and no command is named
  for Focus Mode, and another that no setting is and the old key is skipped as unknown.

## Alternatives considered

- **Keeping the setting and command, hidden.** Rejected: the owner asked for all of it to go,
  and a setting no code reads would be a default that masks nothing.
- **A message naming the old key as removed.** Rejected: the config check already reports an
  unknown key with a way to remove it, and a list of removed keys would be a compatibility shim.

## Consequences

- ⌥⌘F is free for another command.
- `TrackTableController` is back under 1,000 lines and off the size allowlist.
