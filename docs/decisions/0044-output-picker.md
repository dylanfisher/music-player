# 0044. The output is picked from the devices and renderers found

- **Date:** 2026-11-01
- **Status:** accepted

## Context

The owner asked how to set the audio output. The only way was typing a Core Audio UID into
`output.deviceUID`, in the config file or a text field in the Settings window, and a renderer's
UDN into `output.renderer`. The owner rejected the text field: the picker should list the
outputs already found. The switch itself already follows the config ([0037](0037-device-profiles.md),
[0041](0041-upnp-output.md)).

## Decision

- **One list, three places.** `outputOptions` in Settings lists System Default (null) first,
  then each output device by name, then each renderer by name. Controls ▸ Output, a ⌘K row per
  entry ("Output: <name>") and the Settings window's Output Device popup all show it, the one in
  use checked or selected. A renderer, when set, is the one in use, since it plays instead of the
  device. The Network Renderer row isn't drawn on its own; the Output Device popup picks it.
- **A pick writes the config's settings, and nothing else.** A device sets `output.deviceUID`
  and clears `output.renderer`; System Default clears both. A renderer sets `output.renderer`
  and keeps `output.deviceUID`, which plays again when the renderer is cleared: clearing it
  would switch the device output to the system default while the track still plays on the
  device, before the renderer is found. So only one entry is ever checked, and the existing
  change handlers do the switching. The device is written before the renderer, so leaving a
  renderer moves the idle device output first.
- **A configured output that isn't there stays listed** by its UID, "(not connected)", or its
  UDN, "(not found)", so a setting isn't silently lost from view.
- **Devices are followed, renderers are searched for.** The app lists the output devices at
  launch and again whenever the HAL's device list changes (`DeviceListWatch`), and the menu, the
  palette and the open Settings window show the change. Renderers come from one SSDP search
  (about 3 s) started when Controls ▸ Output or the Output Device popup opens, unless one is
  running; the open menu fills in when it ends. ⌘K lists the renderers the last search found,
  so it opens at once and doesn't search the network on every keystroke-driven open.
- **The menu is a live submenu.** `MenuEntry.live(title)` is a submenu the app fills each time
  it opens, since the outputs aren't commands with fixed IDs. It has no shortcuts.

## Alternatives considered

- **A command per device** — rejected: commands are registered once with fixed IDs and
  shortcuts, and devices come and go.
- **Clearing `output.deviceUID` when a renderer is picked** — rejected for the switch it would
  make on the device mid-track, described above.
- **Searching for renderers at launch or on a timer** — rejected: it sends multicast on every
  launch whether or not the owner wants a renderer, and a timer needs a clock in Core for little
  gain over searching when the picker opens.

## Consequences

- The Settings window's schema-driven rows have two key-specific controls, the output popup and
  the hidden renderer row; other settings still need no UI code.
- A renderer that only answers a second search shows after the picker is opened again.
