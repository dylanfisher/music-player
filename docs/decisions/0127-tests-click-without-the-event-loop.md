# 0127. Tests click buttons without `performClick`, and a test run without its summary fails

- **Date:** 2026-11-06
- **Status:** accepted
- **Amends:** [0122](0122-incremental-test-step.md) (what `scripts/test` counts as a pass)

## Context

LibraryBrowserTests stopped after about 100 of its 281 tests, printed no summary and exited
0, so `scripts/test` and `scripts/check` passed while most of the target never ran. Four
tests that fail were hidden this way.

A test process has no `NSApp.run`. Its main thread sits in the `CFRunLoopRun` of Swift's
async `main`, which calls `exit(0)` when that loop returns. `NSButton.performClick` waits on
window-server events through `nextEventMatchingMask`, which starts HIToolbox's event thread.
From then on, each event the window server sends makes that thread queue a `CFRunLoopStop`
on the main run loop, to wake an event wait. When no wait is under way, the stop lands on
the outer loop and the process exits. When that happens depends on the window server, so
each run stopped at a different test, and a test run alone passed. One `performClick` in
`dismissAllActsOnEveryRowSelectedOrNot` was enough.

## Decision

Tests click a button with `Fixtures.click(_:)`: when the button is enabled, it takes the
cell's next state and sends the action, which is what `performClick` does to a button's
state and target, with no event loop. Tests don't call `performClick`.

`scripts/test` fails when the number of `Test run started.` lines differs from the number of
`Test run with` summaries, so a process that exits partway through fails the step whatever
its exit status.

Rejected: disabling automatic termination for the test process. It wasn't the cause, and
the early exit continued with it off.
