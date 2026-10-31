# AGENTS.md

Instructions for AI coding agents working in this repo. Humans: see [README.md](README.md).
**Keep this file under ~50 lines.** Anything longer lives in `docs/` and is linked from here.

## Stack

- **Language:** Swift 6 language mode, strict concurrency; toolchain from the Xcode in `.xcode-version`. C for the real-time audio core.
- **Platform:** macOS 12+ (`Package.swift`); it must run on a 2015 MacBook Pro. Guard newer APIs with `#available`.
- **Package manager:** SwiftPM only — no `.xcodeproj`. `scripts/bundle` builds the `.app`.
- **Frameworks:** AppKit, CoreAudio (HAL), system SQLite, Network.framework (UPnP/DLNA). Tests: Swift Testing.
- **Layout:** `Sources/<Tier>/<Module>`, tests in `Tests/<Module>Tests` — tiers and search recipes: [docs/map.md](docs/map.md)

## Commands

| Task | Command |
|---|---|
| Install / bootstrap | `./scripts/setup` |
| Run locally | `./scripts/dev` |
| Run tests | `./scripts/test` |
| **Full gate** (see Definition of done) | `./scripts/check` |

## Principles

Non-negotiable, regardless of stack. Rationale: [docs/principles.md](docs/principles.md).

1. **Single source of truth.** Every fact — a constant, type, config value, copy string — is defined once and imported. Never re-declare, never re-derive. **Search before you create** — [docs/map.md](docs/map.md) has the recipes.
2. **Match the surrounding code.** Consistency beats personal preference. Read a neighboring file before writing a new one; map.md says which one is the neighbor.
3. **DRY on the third occurrence, not the second.** Premature abstraction costs more than duplication.
4. **Smallest change that solves the problem.** No drive-by refactors, renames, or reformatting outside the task.
5. **Fail loudly.** No empty catches, no silent fallbacks, no defaults that mask a missing value.
6. **Delete, don't comment out.** Git remembers.
7. **No new dependencies without asking first.** Say what it's for and what it replaces.
8. **Style is the formatter's job.** If a tool enforces it, it does not belong in this file or in review.

## Boundaries

- **Music files are read-only.** Never write, retag, rename, move, or delete anything in the user's library or on the NAS. App state lives in the SQLite index.
- **The real-time audio thread is C-only.** Nothing reachable from the CoreAudio IO proc allocates, locks, logs, or calls Swift/ObjC; it goes through `Sources/Primitives/RingBuffer`.
- **Commit locally; never push.** No `git push`, no `gh`. The owner pushes.
- **Pre-release:** breaking changes are fine. Stored data has one shape — no version fields, migrations, or compatibility shims; data that doesn't match is discarded. Delete this line at the first production release.
- The app has no secrets. If one appears, stop and ask before adding any secret handling.

## Definition of done

- `./scripts/check` passes clean.
- New behavior has a test that fails without the change.
- No new dependencies, no new files outside the agreed layout, no TODOs left behind.
- If a decision was non-obvious, record it in `docs/decisions/`.
- Comments, docs, and commit messages follow [docs/writing.md](docs/writing.md).
