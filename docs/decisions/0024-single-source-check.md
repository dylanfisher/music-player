# 0024. A check for facts defined twice and code copied three times

- **Date:** 2026-10-31
- **Status:** accepted

## Context

Phase 14b asks that each fact is defined once (AGENTS.md principle 1) and that code is shared
at its third copy, not its second (principle 3), and that a script in `./scripts/check` keeps it
that way. Reviews had found repeated literals by hand, phase after phase. A search before
writing (docs/map.md) only helps when the author thinks to search, and nothing caught the
second spelling of a frame ID, a setting key or a button title once it was in.

The first run over `Sources` (261 files) found 160 string literals in more than one file and
one block with three copies.

## Decision

`scripts/dupes.swift`, Foundation only and run by `./scripts/check` as
`swift scripts/dupes.swift`, as `scripts/arch.swift` is. It lexes each `.swift`, `.c` and `.h`
file under `Sources`, so comments, raw and multi-line strings, and literals inside
interpolations are read as the compiler reads them. A multi-line string loses its closing
delimiter's indentation, as Swift reads it, so the same SQL at two indents matches, and a
backslash at a line's end, in a string or a C preprocessor line, still counts the line. It takes
under a second on the whole tree.

**A literal worth flagging** is any string literal with 4 or more characters of its own in more
than one file under `Sources`: user-facing text, identifiers (setting keys, command IDs, table
and column names, atom, frame and chunk IDs, SF Symbol names, file names, paths, flags) and SQL.
A literal's own characters are what's left once interpolations and printf specifiers are taken
out, with each escape counted as one character, so a format string such as `"\(a): \(b)"` or
`"%02d:%02d"` isn't flagged, and neither is `"\u{1B}"`. Under 4 characters a literal is too
generic to be a fact (`"ASC"`, `"#"`, `", "`), while 4 keeps every four-character code.

Not compared:

- **Tests.** They may repeat literals freely, since a test that types the value it expects
  catches a wrong constant that a test importing it would not. A test that asserts a string the
  code exposes by name, such as a command's title or a setting's type name, reads that name.
- **Programmer-error messages:** the message of `fatalError`, `preconditionFailure` and
  `assertionFailure`, and the argument after the condition of `precondition` and `assert`. Each
  describes a programmer error at its own site, is never shown in a window and is never
  compared, as the `required init?(coder:)` message in eleven views is. A literal in the
  condition, or in a `file:` argument, still counts.
- **What an oracle shares with the modules it checks.** A Tools module listed as
  `oracle <dir> | checks <dir>…` re-types those modules' format facts on purpose: the fixture
  generator writes each tag format from its spec, so a wrong ID in Metadata fails a test instead
  of agreeing with itself. Its literal is hidden only where a checked module (Metadata or
  TagWriter) spells it too; anything else it shares, such as a file extension with the scanner,
  is compared like any other. The tag corpus was an oracle in the first draft, but hides nothing
  under this rule, so it's compared in full.
- Log categories, which come from `#fileID`, so they're never literals.

Within one file a repeat is left to review: it's in front of the reader, and the plan's
contract is "more than one file".

**A near-duplicate block** is 8 consecutive lines that aren't only punctuation or an import,
compared with every identifier, number and literal replaced by a placeholder, so a copy with
renamed variables still matches. A window with fewer than 6 distinct lines is skipped: a run of
`case .x: "y"` lines or stored properties is the code's shape, not a copy. A block fails at its
third copy. A second copy of 20 lines or more prints as advisory and doesn't fail.

**The allowlist,** `scripts/dupes-allow.txt`, holds one entry per line,
`<key> | <scope> | <reason>`, and the script prints each finding's key and scope:

- `literal "<as written>" | files <file>…`: that literal in exactly those files. A new file
  that reuses the spelling changes the file list, so it fails.
- `block <fingerprint> x<copies> | files <file>…`: that block, by an FNV-1a hash of its first
  window, that many times, in exactly those files. A fourth copy, or a different block in the
  same files, fails.
- `oracle <dir> | checks <dir>…`, as above.

An entry with no reason or no scope fails, as do a repeated entry, an unknown kind and an entry
that no longer matches anything: an oracle fails when nothing it hides would otherwise be
reported. So the list can't outlive what it excused. `scripts/dupes-test`, also in
`./scripts/check`, runs the script on a tree it must pass and a tree that plants each kind of
duplicate (in an interpolation, in a condition, at two indents of a multi-line string, with
`\"` escapes, in a `##` raw string, in C, beside an oracle in a directory named like it) and
each kind of bad entry, and checks each `file:line`.

**Where a shared fact lives:** in the lowest module every user imports, as docs/map.md says.

## What the first run found, and what became of it

| Category | Found | Fixed | Allowlisted |
|---|---|---|---|
| Tag format IDs: ID3 frames, Vorbis keys, MP4 atoms and items, AIFF and WAV chunks | 44 | 44 | |
| Error details the tag reader and writer both write | 9 | 9 | |
| The app's command-line flags | 9 | 9 | |
| Database file names, suffixes and SQL in Bench | 5 | 5 | |
| Setting keys in the menus | 4 | 4 | |
| Titles: fields, commands, settings, "None", a type name | 17 | 17 | |
| Formats: a bit depth, a bench note | 2 | 2 | |
| The same spelling for different things | 21 | | 21 |
| Standard AppKit button titles ("Cancel", "Save") | 2 | | 2 |
| App flags and keys Bench and FailureDrill use from outside | 4 | | 4 |
| Separate executables' own messages | 5 | | 5 |
| Second copies of behavior | 2 | | 2 |
| Format IDs re-typed only by an oracle | 36 | | 1 oracle entry |
| Blocks with three copies: the strict-decoding shape | 1 | | 1 |

After the sweep the script reported nothing outside 37 allowlist entries. Review then
scoped the oracles, which brought back 10 literals the tag corpus and the fixture generator
share with the app or other tools (their own messages, file extensions, a fixture word that is
also an appearance's title); all 10 are allowlisted with reasons, and the fixture generator's
oracle entry now hides 64 format IDs it shares with Metadata. The check runs clean with 46
entries. The fixes:

- Metadata names each ID once as a `package` constant beside `MP4Type` (`ID3FrameID`,
  `VorbisKey`, `MP4ItemType`, the audio chunk IDs, `FileFailure`), and TagWriter uses them.
- `Database.walSuffix` and `shmSuffix`, `libraryFileURL(in:)`, `insertHistorySQL` and
  `LibraryIndex.checkpoint()` replace Bench's own spellings.
- The menus read setting keys from `AppSettings`, the view toggles' titles come from the
  `AppState` entries they show, and `AppCommands.title(of:)` gives buttons their command's
  title.
- The smart field titles move from the rule editor to Library, where the tag editor and the
  browser panes read them with the column titles.
- `bitDepth(_:)` joins `kilohertz(_:)` in DisplayText, and the app's flags are one `Flag` enum.

## Alternatives considered

- **A grep for repeated quoted strings** — rejected: it can't tell a string from a comment,
  reads `#"…"#` and `"""` wrong, and misses literals inside interpolations.
- **SwiftSyntax** — rejected: a package dependency, and parsing 261 files would cost more than
  the 5 s the check has.
- **Flagging literals on their third occurrence**, like code — rejected: principle 1 outranks
  principle 3 (docs/principles.md). Two spellings of one fact already disagree the day one
  changes; two copies of behavior are only annoying.
- **Comparing blocks with identifiers kept** — rejected: it misses the copy whose variables
  were renamed, which is the usual copy. Normalizing them finds the strict-decoding shape, which
  is allowlisted.
- **Excluding all of `Sources/Tools`** — rejected: Bench and FailureDrill read the library's
  file name and the SQLite suffixes, and those must follow the app. Only the fixture generator is
  an oracle, and only for what it shares with Metadata and TagWriter.
- **Excluding log messages** — rejected: the owner reads them in Console, so they're user-facing
  text. The one repeated log line is allowlisted as a second copy of behavior.
- **Moving the strict-key check to a primitive** so HALOutput and Settings share it — deferred:
  it's the second copy, so it stays until a third.

## Consequences

A fact a second module needs makes the check fail until it's imported or allowlisted with a
reason, and the allowlist shrinks as duplicates are fixed, since a stale entry fails too.
Because each entry names its files, a file that edits its way into or out of an allowlisted
duplicate makes its entry fail, and the entry is rewritten from the key the script prints.

What it doesn't check:

- **Repeats within one file**, of literals or of blocks: they're in front of the reader.
- **Numeric constants:** budgets have BenchTests, and a number such as `1024` or `1000` repeats
  across unrelated code too often to flag.

The block comparison's limits:

- **Structure over-matches.** With identifiers normalized, unrelated code of the same shape
  matches, as the strict-decoding types do; those go in the allowlist.
- **One inserted line breaks a window.** A copy with a line added every 7 lines has no 8-line
  window in common with the original, so heavily edited copies go unseen.
- **Keywords are kept, so a variable named like one differs.** A word in the keyword list
  (`get`, `set`, `open`, `some`…) stays as itself, so a copy that renames `set` to `put` doesn't
  match, and a C file's types are read as identifiers unless listed.
