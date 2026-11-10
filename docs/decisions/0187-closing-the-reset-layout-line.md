# 0187. Closing the reset-layout line

- **Date:** 2026-11-10
- **Status:** accepted
- **See also:** [0166](0166-a-stale-state-key-drops-only-itself.md) (a stale state key drops
  only itself)

## Context

Since ADR 0166 a key in `state.json` that doesn't match this build is dropped and the banner
says so, as "the saved window layout was reset: …" followed by the key's error. The line had
no close button, and the key stayed in the file until another layout change saved state, so
the line came back at each launch. It also named the whole layout when only one setting was
lost.

## Decision

- **A line per dropped key, named by its setting's title.** `StateStore.discarded` holds
  "the saved Discogs Tagger Sheets setting was reset: …" for a key the schema has, using
  `Setting.title`, declared beside the key in `AppState`; "the saved setting "window.old" was
  dropped: unknown setting" for one it doesn't; and "the saved window layout was reset: …"
  only for a file that isn't a JSON object. "setting" keeps the verb singular whatever the
  title.
- **Closing saves the file at once.** The close button shows while there's a reset line,
  even under a config problem that blocks the file, which stays. Closing calls
  `StateStore.forgetDiscarded()`, which writes the values in effect, so the stale keys are
  gone from the file, then clears the lines.
- **Through `LayoutSaver`, as a pending write.** A failed rewrite is reported as
  "couldn't save the window layout: state.json: …" and retried with the next flush, as any
  failed layout write; the reset lines stay until it succeeds.

## Alternatives considered

- **A lowercase phrase for each state setting** ("the Discogs tagger's sheet sizes", as the
  owner's example reads). It reads better, but it's a second name for each of the 27 state
  settings, kept in step with the title by hand.
- **Hiding the line in the banner only**, as closed config problems are. The key would stay in
  the file and the line would come back at the next launch.

## Consequences

- Removing or reshaping a state key shows one closable line naming that setting, and closing it
  is the end of it.
