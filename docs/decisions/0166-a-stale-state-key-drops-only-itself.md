# 0166. A stale state key drops only itself

- **Date:** 2026-11-09
- **Status:** accepted
- **See also:** [0015](0015-config-file.md) (the state file), [0023](0023-failure-table.md)
  (failure table, row "State file corrupt"), [0160](0160-get-info-opens-as-it-stays.md) (the
  removed `tagEditor.place`), [0187](0187-closing-the-reset-layout-line.md) (closing the
  banner's line rewrites the file)

## Context

`StateStore` discarded the whole of `state.json` when any key didn't match the schema. Phase 60
removed `tagEditor.place`; the owner launched the build without deleting the line by hand, as
the release notes asked, and lost every window frame, panel size, column and toolbar item. The
pre-release rule (stored data has one shape, no migrations) is about not carrying old shapes
forward. It doesn't need one stale key to cost the rest of the layout, which is only where the
user left things.

## Decision

- **Each key is decoded on its own.** A key the schema doesn't have, or whose value doesn't
  decode or validate, is dropped; the keys that match are kept. The banner and the log name the
  dropped keys, as they named the discarded file.
- **A file that isn't a JSON object is still discarded whole**: there are no keys to keep.
- **The next save writes over what was dropped**, as before. Nothing reads an old shape.
- **Within a key, decoding stays strict.** A layout value with an unknown field is dropped
  whole, not repaired: a key holds one value, and a half-read one is a guess.

## Consequences

- Removing or reshaping a state key no longer needs release notes asking the owner to edit
  the file.
- `config.json` is unchanged: the user edits it, and a problem there is shown for a fix rather
  than dropped (ADR 0082).
