# 0004. A tools tier for code that never ships

- **Date:** 2026-10-30
- **Status:** accepted

## Context

Phase 1 adds a fixture generator and a benchmark runner. Both are executables, both hold real
logic (tag writers, a library planner, a timing harness), and the fixture code has to be a library
so tests and benchmarks can call it. None of it may end up in the app: the fixture tag writers in
particular must never be mistaken for the phase 11 tag writer, which is the only code allowed to
write music files.

## Decision

Add a fifth tier, `Sources/Tools`. Tools may import every tier except app, and other tools.
Nothing outside tools imports them. `scripts/arch.swift` enforces both, so an app or core target
that depends on a tool fails `./scripts/check`. `Fixtures` (library), `GenerateFixtures` and
`Bench` (executables) live there.

## Alternatives considered

- **App tier** — rejected: app is the composition root and holds no logic, and the arch check
  could not stop `MusicPlayer` from importing the fixture tag writers.
- **Core tier for the fixture library** — rejected: anything in core can be imported by app and
  features, so the check wouldn't keep it out of the shipped binary.
- **A separate Swift package under `Tools/`** — rejected: a second manifest, a second build
  directory, and the tools could no longer import the app's modules to benchmark them.

## Consequences

Benchmarks can import any core or feature module directly. A tool that turns out to be needed by
the app has to move to another tier, in its own commit, like any promotion.
