# 0017. The Settings window's generated rows and shortcut saves

- **Date:** 2026-10-31
- **Status:** accepted
- **Amends:** [0012](0012-searcher-conventions.md)

## Context

[0012](0012-searcher-conventions.md) says the General pane is generated from the settings schema,
so a new setting needs no UI code, and that the Shortcuts pane has Replace and Cancel for a
clash. Three details were left open.

## Decision

- **Every kind has a row.** A Boolean is a checkbox, a choice a pop-up, a whole or decimal number
  (optional or not) a number field, a string a text field, and the watched folders a list,
  added and removed in the sidebar. Any other kind shows its value as JSON with "edit in the
  config file", read-only. A new setting of a new kind still appears, and never traps.
- **A shortcut change is one write.** Replace changes two commands. `ConfigStore.setShortcuts`
  applies both overrides as one patch set and one change notice, so the bindings never pass
  through a state where the user's chord costs the other command a logged loss.
- **The panes' snapshots** are `--snapshot-of settings` and `--snapshot-of shortcuts`, beside
  `main` and `palette`, so each pane can be checked at 1440x900 without screen recording.

## Alternatives considered

- **Trap on a kind with no control** — rejected: adding a setting would then need UI code, which
  0012 rules out.
- **One write per changed command** — rejected: the first write leaves both commands claiming the
  chord until the second, and the dispatcher logs a loss nobody caused.

## Consequences

A list or structured setting gets an editor only when one is written for its kind; until then the
config file is where it's edited.
