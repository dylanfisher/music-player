# 0103. Option-arrow seeks; Get Info opens where it was moved; Show Library Health toggles

- **Date:** 2026-11-05
- **Status:** accepted
- **Amends:** [0096](0096-one-focus-order-and-control-arrow-seeks.md) (the seek chords and
  the longer step), [0099](0099-library-health-panel.md) (the tiles' width, the command),
  [0100](0100-get-info-windows-and-smb-temp-files.md) (where an info window opens)

## Context

The owner's second round of feedback of 2026-11-05 (part 44a). macOS gives ⌃→ and ⌃← to
moving between Spaces by default, so the Control-arrow seeks of ADR 0096 did nothing until
the owner turned that off; the owner asked for ⌥→ and ⌥← instead, and ⌥⇧→ and ⌥⇧← for the
longer seek. Its 5% was 10 s on a 200 s track, no longer than the short seek, so it should
move 5% of the track or 30 s, whichever is longer.

Info windows opened a step down and to the right of the last one opened, starting near the
main window's top left at every launch; the owner wanted each to open where the last one was
moved, across launches. Library Health's tiles, 180 points or more, cut off nine of the
thirteen descriptions. Show Library Health only showed the panel; with it showing, the owner
wanted the command to hide it and show the track table at the playing track.

## Decision

- **⌥→ and ⌥←** are Seek Forward's and Seek Back's second chords, in place of ⌃→ and ⌃←; the
  menu still shows ⌥⌘→ and ⌥⌘←. **⌥⇧→ and ⌥⇧←** replace ⌃⇧→ and ⌃⇧← for the longer seeks.
  A field being edited takes all four first to move by word or select by word
  (`KeyChord.isTextEditing`), so the search field and Get Info's fields keep them. No other
  command had them; → and ← alone stay Next and Previous Track.
- **The longer step** is `max(5% of the duration, 30 s)`, `AppCommands.seekStepPercent` and
  `seekStepMinimumSeconds`. With no duration known it moves 30 s rather than nothing, so the
  key always does something. The commands are titled "Seek Forward 5% or 30 s" and "Seek Back 5% or 30 s"; their
  IDs (`playback.seekForwardPercent`, `playback.seekBackPercent`) don't change, so a saved
  shortcut holds.
- **Get Info's place** is an added optional state key, `tagEditor.place`: the top left corner,
  in screen points, of the info window the user last moved. Null, as in every state file
  from before, opens near the main window's top left as before. The corner rather than the
  frame, since a window grows once its files are read. A new window opens at the corner, a
  step down and to the right for each open info window already there, so it doesn't hide
  behind one; a corner on no screen, after a display is unplugged, falls back to the main
  window's top left. Only moves after the window shows are saved: placing it, and its growth
  from the reading view (which keeps the top left corner), aren't the user's. The save is
  coalesced with the other layout saves.
- **Health tiles** are 330 points or more: ten descriptions show whole; the three longest
  (370 to 470 points) are cut, and whole in the tooltip.
- **Show Library Health** (`library.checkHealth`) shows the panel, or, with it showing, hides
  it and shows the track Show Current Track would find: in what the window showed when its
  play started, else in the library. A play started from a check, or nothing playing, shows
  the whole library; going back to the check would leave the panel up. The menu item is
  checked while the panel shows, as the other view toggles are. Settings' Show Library
  Health button only brings the main window forward when the panel already shows.

## Alternatives considered

- **Keeping ⌃→ beside ⌥→**: rejected. The owner asked for a replacement, and with Spaces'
  shortcuts on, a chord that does nothing is noise in Settings ▸ Shortcuts.
- **Doing nothing when the duration is unknown**, as before: rejected; the step has a floor
  now, and 30 s is what the key would do on any track up to ten minutes.
- **Saving the frame, or a share of the screen as the palette does (`palette.place`)**:
  rejected. An info window's height changes with what it shows, and the owner puts it at a
  spot, not a proportion; a top left corner is what a move sets.
- **Two lines for a tile's description**: rejected. Taller tiles show fewer rows in the
  columns' height, and the owner asked for wider ones.
- **Going Back** (the step history) to hide Library Health: rejected. The step before may be
  anything, a search or another check, and the owner asked for the playing track.

## Consequences

A config file whose shortcuts give ⌥→, ⌥←, ⌥⇧→ or ⌥⇧← to another command keeps that binding,
and the seek loses its chord, as for any override that takes a default's chord; none of them
was bound before. One state key was added, `tagEditor.place`; no config key changed, and the
owner's current `state.json` and `config.json` decode unchanged (checked against copies). The
health panel fits three columns from about 1,030 points wide; a narrower panel shows fewer
columns and more rows to scroll.
