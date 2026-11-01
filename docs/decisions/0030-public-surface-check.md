# 0030. A check that each public declaration has a caller outside its module

- **Date:** 2026-11-01
- **Status:** accepted

## Context

Phase 14f asks that each module exposes only what other modules call, and that a check in
`./scripts/check` keeps it that way. Every module is in one package and the app has no outside
clients, so `public` and `package` mean the same thing in practice; what matters is that a
declaration another module doesn't call is internal, so a reader can tell a module's API from its
internals. Phases had made things `public` for a test, a bench or a caller that later went away.

## Decision

`scripts/surface.swift`, Foundation only and run by `./scripts/check` as `scripts/dupes.swift`
is. It lexes each Swift file under `Sources` (comments and string text dropped, interpolations
kept), lists each `public`, `package` and `open` declaration, and reports each one that no other
module uses. It takes under a second on the whole tree.

**Used** means the declaration's name appears in a file of a module that imports its module,
directly or through another module (members are visible through a module that's imported
transitively), or in the signature of another public declaration in its own module: a parameter
or return type, a default argument, a superclass or an enum case's payload, which the compiler
requires to be public. An initializer is used when another module constructs its type
(`Name(`, a trailing closure `Name {`, or `Name.init`).

**Not checked:** enum cases, overrides, `required` initializers, operators, and the members a
standard protocol requires a public type to make public (`description`, `hash`, `id`,
`init(rawValue:)`, `init(from:)` and the like), since the compiler calls them, not another
module.

**Also a finding:** an access level on a member of an internal type, since it changes nothing
and reads as API, and `public extension`, so each member states its own level.

**Who counts as a caller:** any module under `Sources`, Tools included: the benches, the fuzz
targets, the failure drill and the tag corpus call the API they measure or attack, and the plan
names each. Tests don't count. They use `@testable import`, which reaches internal declarations,
so a declaration only a test calls is internal.

**The allowlist,** `scripts/surface-allow.txt`, holds what must be public for a reason no caller
shows: the optional requirements of an AppKit delegate protocol on a public type
(`numberOfRows(in:)`, `controlTextDidChange(_:)`), which the compiler requires to be public. One
entry per line, `<Type>.<member> | <reason>`. An entry that matches nothing fails, so the list
can't outlive its members.

`scripts/surface-test` runs the script on a tree it must pass and on one with each finding and
each bad allowlist entry planted, and `./scripts/check` runs both.

## What the first run found

154 of 1,648 declarations, and more in later rounds as narrowing took away the signatures that
had kept a type or an initializer public, and as members of the narrowed types lost their access
levels. All but the 11 allowlisted were narrowed to internal and the build stayed green; 1,402
remain, each with a caller outside its module. One, `KeyBindings.menuChord(of:)`, had no caller in `Sources` at all, only tests
(the menu builds its chords itself), and was deleted. The test-only helpers in Fixtures (the
null device's plug and session counters, the simulated NAS's drop and reconnect, the property
case runner) are internal now; tests reach them with `@testable import`.

## Alternatives considered

- **`swift-symbolgraph-extract`:** lists declarations with their access level, but not their
  callers, so it needs the same name search on top, and a full build first.
- **The index store** (`swift build` with indexing, read by `IndexStoreDB`): exact callers, but
  it's a dependency, and the build and the index take minutes.
- **Matching against importers only:** a file sees the members of modules it reaches through
  another import without importing them, so it reported members the App calls as unused.

## Consequences

- A name shared with a member of another type hides an unused declaration, so the check misses
  some. Besides the framework witnesses, it would wrongly report the initializer of an `open`
  class that only a subclass in another module calls; there are no `open` classes.
- A new public declaration needs a caller in another module in the same commit, or it's a
  finding.
- A test reaching a narrowed declaration switches to `@testable import`, which the debug builds
  that run tests allow.
