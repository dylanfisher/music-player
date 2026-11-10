# 0180. `./scripts/check --changed` picks its own steps

- **Date:** 2026-11-09
- **Status:** accepted

## Context

[ADR 0171](0171-a-changed-pass-updates-the-test-stamp.md) left choosing the gate's steps to
the agent, which read a table at the top of `scripts/check` and named them. From 2026-11-06
to 2026-11-09 agents still ran the full gate 376 times (a median of 69 s each, 7.5 hours in
all), against 168 runs with named steps. A run came out wrong in two ways. An agent missed a
step and fell back to the full gate: a new helper script with a README row ran every test,
though only `links` reads either file. Or it named every step every time: the gate subagents
named nine steps on each commit.

Landing also ran the gate twice. The gate subagent ran nearly every step in the worktree, then
the orchestrator ran the full gate there again with no edit in between, because
`docs/plan.md` asked for the gate in step 3 and again in the phase-gate list. The test stamp
didn't follow the branch either. Each checkout keeps its own `.build/test-pass`, so after main
was fast-forwarded to a phase, the next gate in main reran tests the worktree had just passed.
The README commit above ran 64 of them.

## Decision

**`./scripts/check --changed [ref]` picks the steps.** It lists the files changed since ref
the way `./scripts/test --changed` does, and `steps` in `scripts/check` maps each path to the
steps that read it. That function replaces the table, so the mapping is written once, as code.
A deleted path also picks `map` and `links`, `scripts/check` itself or `.xcode-version` picks
the full gate, and the test step becomes `./scripts/test --changed ref`, which skips itself
when no test reads what changed. Format's script list and residue's file list moved into
arrays that both the steps and the picker read. `--which` prints the picked steps for paths on
standard input, and `scripts/check-test` checks planted cases.

**The full gate runs once per branch,** run by whoever lands the branch, just before it lands.
AGENTS.md and `docs/plan.md` say so, and every other run is `--changed`.

**A post-merge hook carries the stamp.** `scripts/post-merge`, linked by `./scripts/setup`,
copies another worktree's stamp into this checkout when the merge leaves it at the commit that
worktree has checked out. The stamp hashes every input, so a copied stamp still reruns
whatever differs. `scripts/post-merge-test` checks it in a scratch repository.

## Alternatives considered

- **A clearer rule in AGENTS.md.** ADR 0122 and ADR 0171 both made the rule clearer, and
  agents still picked wrong, both ways.
- **One stamp in the git directory, shared by every worktree.** Parallel phase worktrees would
  keep overwriting it, so each would rerun the others' changes.

## Consequences

- A new step or input needs a line in `steps` and a case in `scripts/check-test`, or
  `--changed` won't pick it.
- An agent running in the background still has to wait for the result, so AGENTS.md now says
  to run in the foreground, with no polling loop.
