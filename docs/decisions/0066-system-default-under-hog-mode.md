# 0066. System Default is read as if this app held no hog mode

- **Date:** 2026-11-02
- **Status:** accepted

## Context

On the 2015 MacBook Pro the owner played on the built-in output, which hogs there, then picked
System Default and got "macOS has no default output device". While a process hogs a device,
macOS moves the default output off it, and with the built-in output the only output left, there
is no default at all. With a second device connected the default moves to it, so System Default
picked that device instead of the one the owner had set in System Preferences. The owner asked
whether System Default should go, since the built-in output looked like the default anyway.

## Decision

- **Keep System Default.** It is what a fresh config (`output.deviceUID` null) plays on, and it
  follows the default when the owner changes it in System Preferences between switches.
- **Resolve it as macOS would without this app's hog mode** (`systemDefaultUID`). For each device
  this process hogs, the snapshot taken before it first changed the device names the default
  from before the hog, which wins while that device is connected. Otherwise the default macOS
  reports wins. With no default and a device hogged, the hog is why there is none, so the hogged
  device is the default. With no default and nothing hogged it still fails.

## Alternatives considered

- **Removing System Default** — rejected: null still has to mean something in the config, and
  the picker would have nothing to check for it.
- **Releasing hog mode before resolving** — rejected: macOS doesn't move the default back when
  hog mode ends, so the answer would still be wrong, and the switch would close the old device
  before it knows the new one.

## Consequences

- A default changed in System Preferences while a device is hogged is overridden by the
  snapshot's default when that is connected. macOS reports the move it made for the hog the
  same way as a change the owner made, so the two can't be told apart.
