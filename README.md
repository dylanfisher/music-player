# music-player

A native macOS player for large local hi-res and DSD libraries. It plays bit-perfect to a local
DAC, switching sample rate and bit depth per track, and streams at full quality to UPnP/DLNA
renderers such as a Denon AVR.

Runs on macOS 12 and later, so a 2015 MacBook Pro is the oldest supported machine.

## Develop

Needs the Xcode version in `.xcode-version`, selected with `sudo xcode-select -s`.

| Task | Command |
|---|---|
| Install / bootstrap | `./scripts/setup` |
| Run the app | `./scripts/dev` |
| Run tests | `./scripts/test` |
| Build the `.app` | `./scripts/bundle [debug\|release]` |
| Update a second Mac's clone, then run the app | `./scripts/pull` |
| Everything CI runs | `./scripts/check` |

`./scripts/check` runs every step even after one fails, so one run lists every problem.

## Where to read next

| Path | Purpose |
|---|---|
| `AGENTS.md` | Rules for AI coding agents, and the definition of done. Kept under ~50 lines. |
| [docs/plan.md](docs/plan.md) | The build plan: phases, the gate between them, and performance budgets. |
| [docs/map.md](docs/map.md) | Tiers, where code lives, and how to find something before writing a second one. |
| [docs/writing.md](docs/writing.md) | Comment voice and commit message format. |
| [docs/principles.md](docs/principles.md) | Why the principles in AGENTS.md are what they are. |
| [docs/decisions/](docs/decisions/) | Architecture decision records. |

## License

None yet; all rights reserved.
