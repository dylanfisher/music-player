# 0098. A scan's new files by folder in the sync log, hog mode off by default, the ember icon

- **Date:** 2026-11-05
- **Status:** accepted
- **Amends:** [0037](0037-device-profiles.md) (hog mode for a device seen first),
  [0038](0038-sync-logs.md) (the `addedFiles` event), [0043](0043-app-icon.md) (the drawing)

## Context

The owner's feedback of 2026-11-05 (phase 42c). Three of its items change a decision recorded
earlier.

The owner's two sync logs, one from each Mac, were 16.7 MB each for a library of 43,382 files
with about a hundred plays. `added` lines were 86,750 and 86,644 of the 98,431 and 98,190 lines,
14.3 MB of each log, 165 bytes a line: every file twice, once from the first scan, with the
scan's time, and once from the Swinsian import, with Swinsian's earlier date. The import's
`counts` lines were 2.4 MB more. A scan line is mostly what every line repeats: `seq`, `ms`,
`n`, `"event":"added"`, the folder's path and a time that differs from the next line's by
microseconds. With 300,000 files that is 50 MB a Mac from the first scan alone, which every
other Mac reads at its first sync, over SMB.

`output.hogMode` defaulted to true, and since 0037's amendment a device seen for the first time
hogged when it was on USB, Thunderbolt, FireWire, PCI or AVB, whatever the setting said. The
owner wants hog mode off unless asked for.

The owner drew a new icon, "Ember", as an SVG.

## Decision

### A scan's new files go in the log by folder

- **`addedFiles`**, a new event: `folder` (a sync path), `names` (a list of 1 to 500 file names,
  none with a `/`; each `folder/name` is checked as a path is) and `at`. Each name's Date Added
  is `at`, merged as `added` is: the earliest any machine saw wins. Its cost toward a sync's
  batch is one per name.
- **A scan batch** (500 files) takes one time for all its new paths, which their rows get as
  Date Added, and logs one `addedFiles` event for each folder its new paths are in, in the order
  the folders came, split at 500 names. Grouping by folder keeps the event's paths short to
  write and to read; on the owner's logs it makes the first scan 2.2 MB instead of 7.1 MB, 51
  bytes a file instead of 165. A sync path with no folder, which a share always gives, would
  still go as `added`.
- **The import keeps `added`**, since each file has its own date, and `added` lines read as
  before. The owner's logs need nothing done: their lines all still decode, the outbox they
  are a prefix of carries on with new lines in the new form, and nothing reads them again.
- **A build from before this one** reading an `addedFiles` line reports it as an unknown event,
  among its 100 problems a log, and reads on, so that Mac keeps its own scan's dates for those
  files, so both Macs need this build.

### Hog mode is off by default

`output.hogMode` defaults to false. A device seen for the first time hogs only when
`output.hogMode` is on and its transport type doesn't say otherwise; a device whose type can't
be read takes the setting. So a DAC first seen with the setting off doesn't hog, and the
built-in output still doesn't hog with it on. A config that sets `output.hogMode` keeps its
value, and a device with a profile keeps its own.

### The ember icon

`Support/AppIcon.svg` is the owner's drawing, rendered as 0043 says. Its tile clip path is in
canvas coordinates, at 100, 100, with the group it clips outside the translate the rest of the
drawing sits in: `scripts/icon-mask.swift` reads that clip path as a rect in the 1024 px
canvas. The mask also cuts away the tile's drop shadow, since Quick Look draws it on an opaque
white square, where it can't stay see-through.

On 2026-11-05 the owner replaced the drawing with a pure red version of Ember. Its clip path was
renamed to `tile` so the mask finds it; nothing else in it changed.

## Alternatives considered

- **No `added` from a scan at all** — rejected: a Mac that scans a new album days after another
  would show its own later Date Added, and Recently Added would differ between the Macs.
- **Leaving `at` out of a scan's `added` line**, the clock's time standing in — rejected: it
  saves 23 of 165 bytes, and the folder, the clock and the event name would still repeat.
- **One `added` event for a whole batch, with full paths** — rejected: the folder still repeats
  on every path, about 76 bytes of the owner's 165.
- **Hog mode off only through the setting's default** — rejected: a USB DAC seen first would
  still hog, since its kind decided before the setting.
- **The owner's SVG unchanged, with `icon-mask.swift` taught the translate** — rejected: one
  attribute's place in the SVG is simpler to keep than a script that reads transforms.

## Consequences

A first scan logs about a third of what it did. Logs from before this build stay as they are. Hog
mode is off on every new device until the user turns it on. Editing the icon is still editing
the SVG; its tile clip path has to stay in canvas coordinates.
