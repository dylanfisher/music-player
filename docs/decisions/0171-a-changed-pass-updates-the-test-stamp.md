# 0171. A passing `--changed` run updates the test stamp

- **Date:** 2026-11-09
- **Status:** accepted

## Context

Agents ran the full `./scripts/check` 621 times between 2026-10-30 and 2026-11-09, about 11
hours of waiting, with a median of 3 runs a session and up to 73. Nearly all of that time is the
test step (about 160 s) and `typecheck` (about 40 s). The other steps take about 25 s together,
and `agents.md`, `map`, `residue` and the script self-tests never failed once. A full gate that
followed a passing `./scripts/test --changed`, with no edit between them, failed 6 times in 21,
almost always on `format` or `dupes`: steps the agent should have named, not steps a targeted
run can't reach.

The test step reran targets that a `--changed` pass had just run, because `--changed` left the
stamp alone ([ADR 0122](0122-incremental-test-step.md)).

## Decision

**`--changed` writes the stamp when its pass covers what the stamp says is stale.** Before it
runs, it works out the targets the plain form would run against the stamp. If the targets it
ran include all of those, or it ran `all`, a pass writes the stamp with the inputs hashed before
the run, the same as a plain pass does. Otherwise it leaves the stamp alone, so the gate still
runs what `--changed` skipped.

**AGENTS.md names the steps for a change to Sources**, says to rerun only the failed steps after
a failure, and keeps the full gate for once before a branch lands on main, a change to the
scripts, or when asked.

## Alternatives considered

- **Drop the steps that never fail from the full gate.** They take about 25 s together. That's
  too little to be worth losing them.
- **Have `--changed` always write the stamp.** Its diff is against a commit, not against the
  last pass, so it can miss an edit the stamp would catch, such as one committed since the
  stamp was written.

## Consequences

- `--changed` now hashes the test inputs before it runs, as the plain form does.
- A failed `--changed` run leaves the stamp alone, so the next plain run covers the same paths.
