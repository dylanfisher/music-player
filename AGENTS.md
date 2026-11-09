# AGENTS.md

Instructions for AI coding agents working in this repo. Humans: see [README.md](README.md).
**Keep this file under ~50 lines.** Anything longer lives in `docs/` and is linked from here.

## Stack

- **Language:** Swift 6 language mode, strict concurrency; toolchain from the Xcode in `.xcode-version`. C for the real-time audio core.
- **Platform:** macOS 12+ (`Package.swift`); it must run on a 2015 MacBook Pro. Guard newer APIs with `#available`.
- **Package manager:** SwiftPM only — no `.xcodeproj`. `scripts/bundle` builds the `.app`.
- **Frameworks:** AppKit, CoreAudio (HAL), MediaPlayer (media keys, Now Playing), system SQLite, Network.framework (UPnP/DLNA, from phase 9), Accelerate (vDSP, for the analysis's FFTs). Tests: Swift Testing.
- **Layout:** `Sources/<Tier>/<Module>`, tests in `Tests/<Module>Tests` — tiers and search recipes: [docs/map.md](docs/map.md)

## Commands

| Task | Command |
|---|---|
| Install / bootstrap | `./scripts/setup` |
| Run locally | `./scripts/dev` |
| Run tests | `./scripts/test` (only what changed since its last pass) |
| Run the tests for what you changed | `./scripts/test --changed [ref]` |
| **Full gate** (see Definition of done) | `./scripts/check` |

Iterate with `./scripts/test --changed`; run `check` once, at the end. **Run a check only when it can fail on your diff:** name the steps that read what you changed (the list heads `scripts/check`) and run only those, `./scripts/check <step>…`; if none does, skip it and say so. The full gate, no steps named, is for a change to the scripts or when asked.

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

- **Music files are written only by `Sources/Core/TagWriter`, for a tag edit the user confirmed in the UI** (one confirmation covers a reviewed Discogs match set, [ADR 0133](docs/decisions/0133-one-confirmation-for-a-match-set.md); a download staged for review is written once, unasked, after a clean match, and only inside the staging folder, [ADR 0146](docs/decisions/0146-staged-tag-writes.md)). Besides it, only Remove and Move to Trash moves them: it passes the files the user confirmed to `NSWorkspace.recycle` ([ADR 0050](docs/decisions/0050-remove-from-library.md)). A drop of files with Copy Added Files on creates new copies in the library folder, reading the originals only, and removes only a copy of its own that failed ([ADR 0124](docs/decisions/0124-drop-files-and-the-library-folder.md)). Approve in the Downloads window renames the staged files into the library folder, never over a file, and for an upgrade then passes the files it replaces to the same Trash call, which on a share with no Trash deletes them ([ADR 0147](docs/decisions/0147-moving-downloads-into-the-library.md)); an old file replaced at its own path is first renamed beside itself to a hidden name ([ADR 0156](docs/decisions/0156-replacing-an-album-at-its-own-paths.md)); with Keep Files Organized on, a tag edit or undo the user asked for, and Organize Selected Files after its confirmation, rename files inside the library folder to its layout the same way, skipping a taken name and removing only folders left empty ([ADR 0164](docs/decisions/0164-keep-files-organized.md)). A drag of rows out of the app offers a copy only and writes nothing ([ADR 0141](docs/decisions/0141-copy-only-drag-out-of-the-app.md)). Nothing else writes, renames, moves or deletes them, and no test or tool touches a real library or the NAS, except `scripts/smb-copy-probe.swift`, which only the owner runs, on a scratch folder, making and removing a subfolder of its own ([ADR 0108](docs/decisions/0108-faster-tag-writes.md)), and the Discogs tagger's agent runs that read the watched folders and the dumps folder, read only, reporting under `.build/` ([ADR 0128](docs/decisions/0128-discogs-survey.md)): tag tests write to generated fixtures or to clones of the reference corpus ([ADR 0020](docs/decisions/0020-tag-writing.md)). App state lives in the SQLite index and the files beside it, and its snapshots in the snapshot folder, a local one outside every watched folder and the sync folder ([ADR 0142](docs/decisions/0142-library-snapshots.md)). Besides those, the app appends its own `<machine id>.log`, and writes nothing else, in the sync folder the user chose, which must be outside every watched folder; tests use a temporary folder ([ADR 0038](docs/decisions/0038-sync-logs.md)).
- **The real-time audio thread is C-only.** Nothing reachable from the CoreAudio IO proc allocates, locks, logs, or calls Swift/ObjC; it goes through `Sources/Primitives/RingBuffer`.
- **Version:** semver, `CFBundleShortVersionString` in `Support/Info.plist`. A branch bumps it once, in the commit that lands it on main: minor if it has a `feat`, patch if only `fix`, none for docs, tests or chores. Pre-1.0, so a breaking change is minor.
- **Commit locally; never push.** No `git push`, no `gh`. The owner pushes. Once a worktree's commits are on main, remove it and its branch (`git worktree remove`, `git branch -D`).
- **Pre-release:** breaking changes are fine. Stored data has one shape — no version fields, migrations, or compatibility shims; data that doesn't match is discarded. Delete this line at the first production release.
- **Two secrets: the Discogs token** (optional) **and music-recommender's service token**, each kept only in `config.json` at mode 0600 ([ADR 0137](docs/decisions/0137-the-discogs-token.md), [ADR 0144](docs/decisions/0144-the-service-token.md)). Never log, print, copy or commit either, and never put one in a test or fixture; `DiscogsToken` and `ServiceToken` redact themselves. No test or tool calls the Discogs API or the real service: tests use written responses through a stand-in transport. Any other secret: stop and ask first.

## Definition of done

- `./scripts/check` passes clean, when the change touches anything it reads.
- New behavior has a test that fails without the change.
- No new dependencies, no new files outside the agreed layout, no TODOs left behind.
- If a decision was non-obvious, record it in `docs/decisions/`.
- Comments, docs, and commit messages follow [docs/writing.md](docs/writing.md).
