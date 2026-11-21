# 0213. A time limit for each test target

- **Date:** 2026-11-19
- **Status:** accepted
- **Amends:** [0182](0182-test-targets-run-side-by-side.md) (how `scripts/test` runs each target)

## Context

In phase 91 one LibraryBrowserTests process waited for 90 minutes at 0% CPU in
`organizeSelectedFilesAsksWithTheCountThatWillMoveAndSkipsTheRest`, and the implementing
agent's `./scripts/check --changed main` waited with it, until the orchestrator found and
killed it. The test passed on the next two runs. Nothing put a bound on a target, so one test
that never returns stops the whole check, and an unattended run stops with it. The slowest
target takes about 28 s on a quiet machine, and a few times that under another session's load.

## Decision

**Each target's process is killed after `TEST_TARGET_SECONDS`, 600 by default,** about twenty
times the slowest target's time, so load alone doesn't reach it. A watcher beside the process
takes one second of `sample` stacks into `.build/test-logs/<target>.log.sample` and then sends
`SIGKILL`. The target fails with a line naming the tests its log shows started and never
finished, and the sample's path. A kill can leave some of the process's output unwritten, so
the list can be short or empty; the sample still shows the test function and line each thread
was in.

The watcher is a background subshell, not a wrapper such as perl's `alarm`, because
`/usr/bin/perl` is protected by SIP, which would drop the `DYLD_` variables the bundle needs, as
`/usr/bin/xargs` does.

## Consequences

- A hung test fails its target within ten minutes, and `./scripts/check test` reruns it alone,
  as for any failure.
- A target that legitimately grows past ten minutes fails too; raise the default then, with
  its reason here.
- The `./scripts/test <args>` form, which passes its arguments to `swift test`, has no limit.
