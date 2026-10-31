# 0003. Settings are typed properties of a schema struct, found by reflection

- **Date:** 2026-10-30
- **Status:** accepted
- **Amended by:** [0015](0015-config-file.md): the settings are now a config file that lists
  every setting, and the window layout moved to a state file that holds only changed values.
  Both are decoded with this schema. Export and import are gone.

## Context

Every later phase adds settings, and the settings window and command palette (phase 6) are
generated from the list of them. Adding a setting has to be one declaration, or the list and the
typed accessors drift apart. Reads have to be typed, so code can't ask for the wrong kind of
value. A file read with it must fail loudly, naming the key, when it doesn't match.

## Decision

A setting is a `Setting<Value>` stored property of a `SettingsSchema` struct (`AppSettings`),
holding its key, default, summary and optional range. `SettingsSchema.settings` lists the
properties with `Mirror`, in declaration order. Code reads and writes through key paths:
`store[\.hogMode]`, `store.set(\.hogMode, to: false)`. Values are `Codable` types conforming to
`SettingValue`, which says how to describe them in errors and the settings window. The JSON file
is decoded key by key, and every bad key is reported in one error.

## Alternatives considered

- **Static settings plus a hand-written `all` array** — rejected: two edits per setting, and
  forgetting the second hides the setting from the config file and the settings window with no
  error.
- **String keys with `Any` values, like `UserDefaults`** — rejected: no type checking at the read
  site, and defaults end up repeated at each read.
- **Decoding the whole file as one `Codable` struct** — rejected: it needs every key present (or
  optionals everywhere), and its errors name the first problem only, as a coding path.
- **A macro to generate the list** — rejected: a macro target pulls in swift-syntax, a dependency.

## Consequences

`Mirror` only sees stored properties, so a setting declared as a computed property is invisible;
`schemaListsSettingsInDeclarationOrder` and the app-settings test catch a missing or duplicated
key. Reflection runs once per store, not per read. A new structured value type needs a
`SettingKind` case so the settings window knows how to show it.
