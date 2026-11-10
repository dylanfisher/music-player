# 0182. Test targets run side by side, with their windows clear

- **Date:** 2026-11-09
- **Status:** accepted
- **Amends:** [0122](0122-incremental-test-step.md) (how `scripts/test` runs what it picks),
  [0127](0127-tests-click-without-the-event-loop.md) (where the summary check runs)

## Context

A full `./scripts/test` took 142 s after the build, and each UI test's window flashed on the
screen. The toolchain's build system makes one `.xctest` bundle per test target, and
`swift test` runs the 43 of them one after another, so the targets' run times add up: 133 of
the 142 s. Each process runs its own tests in parallel, but most UI tests run on the main
actor and take turns on its one thread. One core was busy for most of the run. Two
`swift test` processes can't share the build folder, because SwiftPM locks it.

SettingsWindowTests took 22 s by itself. Its panes looked up the section of each row, and each
lookup built the settings schema once per section, checking every setting's default each time.
That was 86% of its main thread, and it slowed opening Settings in the app too.

## Decision

**`scripts/test` runs each picked target's bundle itself**, with the Swift Testing helper
`swift test` uses (`swiftpm-testing-helper`), `TEST_JOBS` at a time. The default is the number
of performance cores. On an 18-core Mac with 6 of them, a full run took 35 s with 4 jobs, 27 s
with 6, and 25 s with 9 or 18, and more jobs failed more of the tests that time a sleep. It
builds with `swift build --build-tests` first. Targets start longest first, by their
times in the last run (`.build/test-durations`). Each target's output goes to
`.build/test-logs/<target>.log`, and the script prints one line per target and then each
failing target's issues. The ADR 0127 check runs per target: a target fails if its process
fails or if it started a run without printing the summary. The `./scripts/test <args>` form
still passes its arguments to `swift test`.

**Every window is clear.** `scripts/test` builds `scripts/clear-windows.m` into a dylib and
loads it into each bundle with `DYLD_INSERT_LIBRARIES`. It sets `alphaValue = 0` in
`NSWindow`'s designated initializer, which every window, panel, sheet and alert goes through.
A clear window still orders in, lays out, becomes key and takes sheets. The window server
draws nothing for it, materials included, so `theGlassHeadersAreFrosted`, which reads them
back from the screen, sets its window's alpha to 0.01 before it does: the window server draws
the materials, and the window is too faint to see. A watcher polling the window list through a
full run found no other test window with an alpha above 0.

**Each section's key prefixes are computed once**, in `GeneralModel.Section`. That brought
SettingsWindowTests from 22 s to 4 s.

**Waits use `Fixtures.waitLimit`, 60 s.** With other targets running alongside,
LibraryBrowserTests' 10 s waits ran out on every run, and TagEditorTests' 5 s ones and
DownloadsTests' `eventually`, which gave up after 20,000 yields, on some. They guard against a
hang, not slowness, so a long limit costs a passing run nothing.
`MainWindowFixture.layout` compares the window's size, not its origin: the window opens on
the main screen, which can change between two fixtures when the Mac has a second display.

A full run takes 27 to 31 s, the build included, against 142 s before plus the build.

## Alternatives considered

- **Several `swift test --filter` processes at once.** They wait on each other's build-folder
  lock.
- **The native build system's single test bundle.** Every target's main-actor tests would take
  turns on one main thread in one process. Not measured.
- **Windows moved offscreen.** AppKit moves a titled window back onto a screen when it orders
  in.
- **Hiding each window in the test that opens it.** The code under test shows about 30 windows
  and sheets of its own.

## Consequences

- `scripts/test` depends on the helper's command line, which isn't documented. A toolchain
  that moves or changes it fails the test step, which names the helper's path.
- It runs Swift Testing tests only, and it fails if any file under `Tests` imports XCTest.
- Targets in separate processes share the loopback addresses. During this change, one run
  each failed on "address in use" in UPnPOutputTests and LocalNetworkTests, and neither has
  recurred.
- Other short waits in UI targets (PaletteTests, SettingsWindowTests, MusicPlayerTests) haven't
  failed yet. Each can use `waitLimit` if it does.
- Tests that sleep a fixed time and then check what happened can still fail under load. Two
  each failed once in the runs that measured the job counts:
  `cancellingDuringARateLimitWaitStopsTheRun` (DiscogsTests) and
  `filesAreReadAFewAtOnceAndKeepTheirOrder` (TagEditorTests).
