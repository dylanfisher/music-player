# Code map

Where things live, and how to find one before you build a second. Read this before creating any
new file.

This file describes **shape, not contents** — conventions and search commands, never an inventory.
An inventory would be a second copy of facts the code already holds, it would rot within a week,
and it would have no error message when it diverged. If you catch yourself listing what exists
here, stop: the grep is the list.

## Find before you create

The single rule that matters. AGENTS.md principles 1–3 (single source of truth, match the
surrounding code, DRY on the third occurrence) all depend on it — none of them can be followed
against a codebase you haven't searched.

| Before adding… | Run |
|---|---|
| any named thing | `rg -i '<name>' --type swift --type c` |
| a module | `ls Sources/*/` — or `swift package describe` |
| a primitive | `ls Sources/Primitives/` |
| a helper / extension | `rg '^(public )?(func\|extension) ' Sources/` |
| a setting key | `rg '<key>' Sources/Core/Settings/` — settings are read in one Core module only |
| a type | `rg '(struct\|enum\|class\|actor\|protocol\|typealias) <Name>' Sources/` |

If a search turns up something close but not identical, that's the second occurrence. Use it or
duplicate it — do not abstract yet (principle 3).

`scripts/dupes.swift`, in `./scripts/check`, catches what a search missed: a string literal in
two files under `Sources`, or a third copy of a block. A fact two modules need lives in the
lowest module both import. A repeat that isn't one fact goes in `scripts/dupes-allow.txt` with
its reason ([ADR 0024](decisions/0024-single-source-check.md)).

## Tiers

The default vocabulary below is a recommendation, not a mandate. **Rename these to whatever fits
the project** — `modules`, `services`, `packages`, `internal` are all fine. What must not change is
the dependency direction.

| Tier | Path | What belongs here | May import from |
|---|---|---|---|
| **primitives** | `Sources/Primitives` | Portable units with no knowledge of music or this app: ring buffer, SQLite wrapper, HTTP server, SSDP, key chords, window placement. No settings reads. System frameworks are fine, AppKit included, in a file of its own (`<Type>+AppKit.swift`) so the rest of the unit stays testable without a window. | nothing in this table |
| **core** | `Sources/Core` | The domain: library index and scanner, tag reading, decoders, audio analysis, DSD/DoP, outputs (CoreAudio HAL device, UPnP renderer), settings, logging, and views two features lay out from a setting (AppKit, in a module of their own). | primitives, other core modules |
| **features** | `Sources/Features` | User-facing slices: library browser, now playing, settings window, and later remote control. | core, primitives |
| **app** | `Sources/App` | The composition root: `main`, app delegate, menus. Wires features together; holds no logic of its own. A second executable here, the `music-player` command line, ships in the bundle beside the app. | features, core, primitives |
| **tools** | `Sources/Tools` | Development tooling that never ships in the app: the fixture generator, test stand-ins such as a null audio device, and benchmarks. | tools, features, core, primitives |

Each SwiftPM target is one module at `Sources/<Tier>/<Name>`, and its tests are at
`Tests/<Name>Tests`. `Support/` holds bundle resources such as `Info.plist`, which
`scripts/bundle` copies into the `.app`.

**Dependency direction is one-way: app → features → core → primitives.** Never upward, never
sideways between features. Core modules may import each other; SwiftPM rejects cycles. If a
primitive needs something from core, it isn't a primitive.

A feature puts its logic in a view model or data source with no AppKit in it, which its tests
drive, and keeps its AppKit views thin. It reports what the user does through closures, and the
app wires them to other features and to core.

Tools sit beside app: they may import any tier but app, and nothing outside tools imports them, so
test-only code can't end up in the shipped binary.

When one module has to walk another's internals, as the tag writer walks the tag reader's atoms
and frames, mark those internals `package` rather than `public`, so the public API stays what
features and the app call, and the shared code stays one copy.

A declaration is `public` or `package` only when another module under `Sources` calls it; tests
reach the rest through `@testable import`. `scripts/surface.swift`, in `./scripts/check`, fails
on any other ([ADR 0030](decisions/0030-public-surface-check.md)).

`scripts/arch.swift` enforces this from `Package.swift`, and `./scripts/check` runs it. The
compiler already rejects any import a target hasn't declared, so checking the declared
dependencies covers every import. Its tier map has to match the table above.

It also fails a `fileURLWithPath:` call without `isDirectory:`, which makes Foundation stat the
path. Track paths take `false`, folders `true`. Nothing on the main actor touches the file system
for a track path; that work goes through a detached task or the index.

## Naming

- One thing per file; the filename is the thing's name.
- Tier directories plural, module directories singular and UpperCamelCase: `Core/Library`, not
  `core/libraries`. The module name equals its directory name.
- Tests mirror the modules: `Tests/<Module>Tests/<Thing>Tests.swift`, using Swift Testing.
- C APIs in primitives take a `<Module>` prefix (`RingBufferWrite`), because C has no namespaces.
- Units go in names wherever they're ambiguous: `sampleRateHz`, `bufferFrames`, `latencyMs`.

## Promotion

Things move between tiers deliberately, never by accident:

- **Third occurrence** → extract to the lowest tier that all three callers can reach (principle 3).
- **Core module loses its domain knowledge** → it's a primitive now; move it down.
- **Primitive grows a settings read or a domain type** → it was never a primitive; move it up.

A promotion is its own commit, separate from whatever work revealed it (principle 4).

<!-- paths: Sources/Primitives Sources/Core Sources/Features Sources/App Sources/Tools -->
<!-- ↑ scripts/check verifies every path above exists. Keep it in sync with the Tiers table;
     a rename that misses this line fails the gate, which is the point. -->
