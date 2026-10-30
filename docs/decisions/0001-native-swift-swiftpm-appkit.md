# 0001. Native Swift with SwiftPM, AppKit, CoreAudio HAL, and a C real-time core

- **Date:** 2026-10-30
- **Status:** accepted

## Context

The app plays a 43k-file, 1 TB library from a NAS, including hi-res PCM and DSD, and has to be
bit-perfect: it sets the DAC's sample rate and bit depth per track and can take exclusive (hog
mode) access. It must also stream at full quality to a Denon AVR-X1800H, a UPnP/DLNA renderer
through HEOS, and later be controllable from other devices. It has to run on a 2015 MacBook Pro,
whose last supported OS is macOS 12. It starts as a personal app and goes public later.
Dependencies stay at a minimum.

## Decision

Swift 6 in strict-concurrency mode, macOS 12 deployment target, SwiftPM only (no `.xcodeproj`),
with a script that bundles and signs the `.app`. AppKit for UI, the CoreAudio HAL for output,
system `libsqlite3` for the library index, and Network.framework for UPnP. The real-time render
path and its ring buffer are C. Tests use Swift Testing.

## Alternatives considered

- **AVAudioEngine / AVPlayer** — rejected: they can't set the hardware's nominal rate or physical
  format, can't enter hog mode, and don't play DSD.
- **SwiftUI** — rejected for the main UI: `Table` on macOS 12 is slow and limited at 43k rows,
  where `NSTableView` is not.
- **An `.xcodeproj` app target** — rejected: the pbxproj can't be reviewed or safely edited as
  text. SwiftPM plus `scripts/bundle` covers what the app needs. Revisit if entitlements, extensions,
  or App Store distribution outgrow the script.
- **Core Data** — rejected: harder to query directly, weaker full-text search than SQLite FTS5,
  and the schema is easier to share with remote clients as plain SQL.
- **Real-time callback in Swift** — rejected: the compiler can insert retains or allocations on
  the audio thread that don't show in the source, which surface as rare dropouts.
- **AirPlay to the receiver** — rejected as the main path: limited to 16-bit/44.1 kHz. UPnP lets
  the receiver pull the original file.

## Consequences

Full Xcode is required (Swift Testing doesn't build with the Command Line Tools alone), pinned
in `.xcode-version`. Everything newer than macOS 12 needs an `#available` check. DSD
(`.dsf`/`.dff`) parsing and DoP packing are written here, since Apple doesn't decode DSD. Formats
outside AudioToolbox (APE, WavPack) would each need a dependency, so they're out of scope until
asked for.
