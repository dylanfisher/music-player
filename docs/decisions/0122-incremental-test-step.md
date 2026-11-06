# 0122. The gate's test step reruns only what changed since its last pass

- **Date:** 2026-11-06
- **Status:** accepted

## Context

`./scripts/check` ran the whole test suite every time, about 90 s on Apple Silicon, whatever
changed. Agents ran it after every commit and again after each review fix, so a one-line ADR
edit or a fix to one module's test cost a full run. AGENTS.md asked for a clean gate with no
condition, and docs/plan.md asked for one on every commit. The ambient-studio project had the
same problem and solved it with a rule ("run a check only when it can fail on your diff"), a
`--changed` mode, and a stamp that skips a full run whose inputs match the last pass.

## Decision

**A rule.** AGENTS.md says to run a check only when it can fail on the diff, and to name the
step that reads what changed. The head of `scripts/check` lists what each step reads.

**One list of test inputs and one test graph.** `scripts/affected.swift` reads the target graph
from `swift package dump-package`. Given changed paths, it prints every test target that
depends on a changed target, directly or through other targets. It prints `all` for a shared
input (Package.swift, `.xcode-version`, and the two test scripts), and no targets for a path
outside Sources and Tests. The one exception is a file a test reads from outside them, listed
in its `readByTests`: `docs/plan.md`, read by BenchTests. `--inputs` prints the paths a test
can read.

**A stamp.** After a passing run, plain `./scripts/test` writes `.build/test-pass`: the
toolchain's `swift --version`, then the hash of every input file. The next plain run diffs the
hashes against the stamp and runs only the test targets `affected.swift` picks for the paths
that differ. With no difference it runs nothing. A failed run leaves the stamp alone, so the
next run covers the same paths again. A new toolchain, a missing stamp, or `--fresh` runs
everything.

**`--changed [ref]`** runs the targets affected by the files changed since a commit,
uncommitted and untracked files included, and leaves the stamp alone. A builder iterates with
it, and a reviewer runs it against the commit a branch sits on.

`scripts/affected-test` runs the script on paths whose answers are known from the real
Package.swift, and `./scripts/check` runs it.

## Alternatives considered

- **Skip only when nothing changed** (ambient-studio's stamp). `docs/plan.md` is a test input
  and changes in every phase, so most reruns would still run all 90 s.
- **Infer test inputs from `#filePath` reads.** Every other test that reads the repo through
  `#filePath` reads its own folder, its own target's sources or `.build`, so one listed
  exception was simpler than a scanner.

## Consequences

- The suite's tests have to be deterministic and independent of each other, as
  [ADR 0023](0023-failure-table.md) already has them: a target is trusted to pass again on
  unchanged inputs, whatever else runs beside it. A test that passes alone but fails at full parallelism can hide until the next
  `--fresh`. Run `--fresh` at each retrospective (docs/plan.md), before a release, and when a
  race is suspected.
- A new test that reads a file outside Sources and Tests needs an entry in `readByTests`, or an
  edit to that file won't rerun it.
- A file under Sources or Tests outside every target's folder fails the step, since Package.swift
  and the tree disagree.
