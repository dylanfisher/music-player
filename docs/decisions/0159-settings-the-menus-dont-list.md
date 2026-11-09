# 0159. Settings the menus don't list

- **Date:** 2026-11-09
- **Status:** accepted
- **Amends:** [0143](0143-separate-releases.md) (Separate Releases was in the File menu too)
- **See also:** [0053](0053-track-table-appearance.md) (a command for each Boolean and choice
  setting), [0132](0132-discogs-field-mapping.md) (the tagger's choices beside its
  mappings)

## Context

Every Boolean and choice setting is a command, and a test held every command to a menu item,
so each new setting of either kind went into a menu. The File menu had grown to 12 of them: the
tagger's four choices, the five watched folders options, Group by Album Artist, Separate
Releases and File Viewer, all of which the Settings window, the tagger's window or its Field
Mapping sheet already shows. The owner found the menu too long, and asked for Separate
Releases to be a setting only.

## Decision

- **A setting command needn't be in a menu.** Those no menu lists are listed by the Shortcuts
  pane and the palette under a section of their own, Settings, after the menus. They're still
  commands: the palette runs them, the command line and links reach them as before, and a
  shortcut given to one in the Shortcuts pane works, through a hidden item at the end of the
  app menu, as a command's alternate chord already does.
- **The File menu drops the 12.** Settings that act on what's in view, the appearance, the track
  table's lines, Hog Mode, Digital Volume and the receiver, stay in the View and Controls
  menus.
- **Rarely used commands go into two submenus** of the File menu: Import from Other Players
  (Swinsian, iTunes) and Moved and Removed Files (Resolve Lost Stats, Restore Removed Tracks,
  Import Moves). They stay commands with menu items, so nothing changes for the palette or
  their shortcuts.
- **Track commands stay** in the File menu. Phase 56 moves the menus' track and keyboard work.

## Alternatives considered

- **Submenus for the settings too:** keeps the old rule, but a menu of settings repeats the
  Settings window, which is where the owner looks for them.
- **No command for a setting the window shows:** drops the palette's and the Shortcuts pane's
  way to them, which the generated commands exist for.

## Consequences

A new Boolean or choice setting no longer has to be placed in a menu; it's in the Settings
section until one lists it. The test that every command is in a menu now allows exactly the
Settings section's commands, and checks a shortcut given to one has a hidden item.
