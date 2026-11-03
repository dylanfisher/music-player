# 0077. The tag editor reads its files a few at once, off the cooperative pool

- **Date:** 2026-11-03
- **Status:** accepted

## Context

Get Info reads every selected file before the editor opens: its tags, its art and the fields
holding several values, each from a fresh open. It read one file after another in a detached
task, so on the NAS each file's round trips added up: 200 fixture files, each costing what three
art reads cost on the slow simulated NAS (ADR 0073), took 27.6 s before the sheet opened. The
detached task also held a thread of Swift's cooperative pool for the whole read, one of 4 on the
2015 MacBook Pro.

## Decision

`readEditableTracks` reads `filesReadAtOnce` files at once (ADR 0074's rule, now defined in
Metadata: one short of the active processors, at least 2), and keeps the order of the
selection. `TagEditing` runs it on a global dispatch queue instead of a detached task. The same
200 files now take 3.2 s on the build Mac, 9 at once; the old Mac reads 3 at once.

## Alternatives considered

- **One open per file** — not done: the three reads parse different structures (the reader's
  tags, the writer's frames), and sharing one descriptor needs a new entry point in both
  modules. The bench charges every open the same, a disk wait included, so it can't tell what
  the second and third opens of a file cost on the real NAS; the checkpoint can. Reading files
  at once already cut the wait ninefold here.
- **The scanner's network reader count (16 to start)** — rejected: the editor reads a selection
  once, not a library, and the orchestrator's rule is that limits scale with the Mac.

## Consequences

- A large selection on a fast disk parses several files at once, so opening the editor uses
  more CPU for a moment than before.
- A read that hangs on a dropped share holds a dispatch thread, not a pool thread.
