# 0002. Declare the bundle identifier in Swift and write it into the bundle

- **Date:** 2026-10-30
- **Status:** accepted

## Context

Every `os.Logger` needs a subsystem, and the app should log under one: its bundle identifier.
That identifier lived in `Support/Info.plist`. Swift code can only see the plist at runtime
through `Bundle.main`, and under `swift test` and in the bare `Bench` and `GenerateFixtures`
executables `Bundle.main.bundleIdentifier` is nil.

## Decision

`bundleIdentifier` is a string literal in `Sources/Core/Log/ModuleLogger.swift`. `scripts/bundle`
reads that line and adds `CFBundleIdentifier` to the `.app`'s Info.plist, the same way it adds
`LSMinimumSystemVersion` from `Package.swift`. `Support/Info.plist` no longer holds it. A test in
`LogTests` fails if the line stops matching the script's pattern.

## Alternatives considered

- **Read `Bundle.main.bundleIdentifier`, and embed Info.plist in every executable with
  `-sectcreate __TEXT __info_plist`** — rejected: it's still nil in the test runner, so any code
  that logs would need a fallback subsystem there, which is the silent default AGENTS.md rules out.
- **Keep the identifier in both files, with a test that compares them** — rejected: two copies of
  one fact, even if checked.
- **Generate a Swift file from the plist with a SwiftPM build plugin** — rejected: a plugin target
  for one string.

## Consequences

Changing the bundle ID is a one-line Swift edit. The literal has to stay on one line in that
exact form, which the test enforces. Other Info.plist keys stay in `Support/Info.plist`.
