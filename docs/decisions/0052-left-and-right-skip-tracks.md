# 0052. ← and → skip tracks, except in the browser panes

- **Date:** 2026-11-02
- **Status:** accepted
- **Amends:** [0012](0012-searcher-conventions.md), [0046](0046-go-to-item-goes-or-filters.md)

## Context

The owner wants → to play the next track and ← to go back, as the transport's back button does
(restart, or the previous track within the first 3 seconds), while the track table, the browser
panes or the sidebar has the keys and no field is being edited. → and ← were Focus Next and
Previous Pane's, from the track table and the sidebar too, and the registry gives a chord one
command in the app.

## Decision

- **Next Track and Previous Track take → and ← as their alternates**, after ⌘→ and ⌘←. A plain
  arrow can't be a menu key equivalent, so only a list that sends its keys to the registry runs
  them: the track table, the timeline, the sidebar and the queue. A field being edited keeps its
  arrows.
- **The genre, artist and album panes take → and ← themselves**, before the registry, to move
  between panes as they did, and as Swinsian's do. A pane lists genres, artists or albums, not
  tracks, so there is no track there for the keys to skip, and the panes had no other key to
  move between them. → from the album pane still goes to the track table; ← from there now goes
  to the previous track, and Tab or a click goes back to the panes.
- **Focus Next and Previous Pane have no default chord.** They stay in the View menu and ⌘K, and
  a chord set in Shortcuts runs them from anywhere.

## Alternatives considered

- **A pane scope in the registry, as the palette has** — rejected: Shortcuts, the clash rules and
  the config file would all need a third scope for two commands whose keys only the panes use.
- **Focus Next Pane playing the next track unless a pane has the keys** — rejected: the View
  menu's Focus Next Pane would skip a track.

## Consequences

The panes' arrows can't be rebound. Unbinding → from Next Track leaves → in the track table
unbound. The queue skips tracks on ← and → as the track table does.
