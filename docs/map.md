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
| a preference key | `rg '<key>' Sources/Core/` — preferences are read in one Core module only |
| a type | `rg '(struct\|enum\|class\|actor\|protocol\|typealias) <Name>' Sources/` |

If a search turns up something close but not identical, that's the second occurrence. Use it or
duplicate it — do not abstract yet (principle 3).

## Tiers

The default vocabulary below is a recommendation, not a mandate. **Rename these to whatever fits
the project** — `modules`, `services`, `packages`, `internal` are all fine. What must not change is
the dependency direction.

| Tier | Path | What belongs here | May import from |
|---|---|---|---|
| **primitives** | `Sources/Primitives` | Portable units with no knowledge of music or this app: ring buffer, SQLite wrapper, HTTP server, SSDP. No preference reads. | nothing in this table |
| **core** | `Sources/Core` | The domain: library index and scanner, tag reading, decoders, DSD/DoP, outputs (CoreAudio HAL device, UPnP renderer), preferences. | primitives, other core modules |
| **features** | `Sources/Features` | User-facing slices: library browser, now playing, preferences window, and later remote control. | core, primitives |
| **app** | `Sources/App` | The composition root: `main`, app delegate, menus. Wires features together; holds no logic of its own. | features, core, primitives |

Each SwiftPM target is one module at `Sources/<Tier>/<Name>`, and its tests are at
`Tests/<Name>Tests`. `Support/` holds bundle resources such as `Info.plist`, which
`scripts/bundle` copies into the `.app`.

**Dependency direction is one-way: app → features → core → primitives.** Never upward, never
sideways between features. Core modules may import each other; SwiftPM rejects cycles. If a
primitive needs something from core, it isn't a primitive.

`scripts/arch.swift` enforces this from `Package.swift`, and `./scripts/check` runs it. The
compiler already rejects any import a target hasn't declared, so checking the declared
dependencies covers every import. Its tier map has to match the table above.

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
- **Primitive grows a preference read or a domain type** → it was never a primitive; move it up.

A promotion is its own commit, separate from whatever work revealed it (principle 4).

<!-- paths: Sources/Primitives Sources/Core Sources/Features Sources/App -->
<!-- ↑ scripts/check verifies every path above exists. Keep it in sync with the Tiers table;
     a rename that misses this line fails the gate, which is the point. -->
