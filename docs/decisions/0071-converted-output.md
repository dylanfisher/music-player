# 0071. A device that can't take a track unchanged gets it converted to its best format

- **Date:** 2026-11-03
- **Status:** accepted
- **Amends:** [0011](0011-playback-engine-and-hal-output.md), [0035](0035-signal-path-panel.md),
  [0037](0037-device-profiles.md), [0064](0064-dsd-over-dop.md)

## Context

Phase 31. The owner's Bluetooth AirPods on the 2015 MacBook Pro offer 2 ch 32-bit float at
48 kHz, plus 16 kHz mono 16-bit for calls (the profile in that Mac's `state.json`). The output
sent only integer PCM at the track's own rate (0011), so every track failed with
`noBitPerfectFormat`, and after three failures playback stopped (0063). The owner wants the app
always to play to the chosen device, bit-perfect wherever the device allows it.

## Decision

**Bit-perfect first.** `bitPerfectFormat` is asked first, as before. Only when it finds nothing
for a PCM track does `convertedFormat` pick the device's best format, ranked in this order:

1. At least the track's channels, so none is dropped; else the format with the most.
2. The rate nearest the track's, at or above it before below it, and never below 44.1 kHz
   when the device has a rate at or above that. Without the floor a 22.05 kHz track would
   switch AirPods to their 16 kHz call format.
3. The track's own channel count, else the fewest above it. AudioConverter copies a mono track
   into both channels of a stereo format. A track with more channels than the device keeps the
   first ones, AudioConverter's default.
4. Float, which holds every integer source up to 24 bits exactly, then the widest.

`HALDevice.configure` and the null device fall back to it, and `DeviceFormat.isConverted` says
so. PCM tracks are no longer refused up front against the reported formats:
`DeviceOutputError.deviceCannotTake` is gone. A device with no PCM format at all to convert to,
or only non-mixable ones with hog mode off, throws `noPCMFormat` from `configure`, which fails
the output like any other device failure.

**Where conversion runs.** On the control thread, between the decoder and the ring buffer; the
IO proc and everything it reaches are unchanged. When the device's rate and channels match the
track's and only the sample type differs, as for a 48 kHz FLAC on AirPods, ExtAudioFile decodes
straight to the device's float format. Otherwise the decoder hands float at the file's rate to a
`RateConverter`: AudioConverter at maximum quality and normal complexity. Normal holds back about
a millisecond (54 frames at 48 kHz) and tracked an ideal sine to 1e-7; mastering held back ten
times as much and was no closer. It costs about 0.3% of an M1 core per channel for 44.1 to
48 kHz.

**Gapless.** A stream remembers the rate and channels it was configured for, and a next track
with the same ones plays on in it, as before. Its converter runs on across those tracks: at a
track's end the input callback returns a status of its own with no frames, which makes
AudioConverter return what it has made and keep the rest of the signal, so the next track's
frames follow in the same filter and the join is resampled as one signal. Resampling each track
on its own left a seam at the join, an error of 6% of full scale. The next track's first byte is
the output frame its first input frame lands on, `ceil(frames before it × device rate ÷ track
rate)` after the converter's start; the output is time-aligned with its input. The converter is
flushed only when the ring buffer holds less than half a second, because the engine can name the
next track after the last one has been decoded, and a flushed converter can't carry on. A next
track of another rate drains and reconfigures, as on a DAC: a converted stream doesn't take a
44.1 kHz and a 96 kHz track without a gap.

Two cases drop a little: replacing a next track already queued drops what the converter holds of
the current track's end (about a millisecond), and a next track named in the last half second
starts a new converter, with a seam.

**Position and seek.** A segment's start is kept in seconds of the file, from the frame decoding
started at and the track's own rate, and what has played since in frames at the device's rate.
A seek turns seconds into a frame at the track's rate, not the device's.

**What the panel says.** `TrackSignal.isConverted` marks a converted track, and the verdict puts
`SignalChange.converted(to:)` first, naming the format written to the device. The panel's badge
reads "Converted" rather than "Not bit-perfect", with the reasons after it; the decoder's
resampling or remixing follows as before. The now-playing line and `--play` say "converted for"
the device's format, and `--play` no longer calls full volume bit-perfect.

**Digital volume** applies to a converted stream as to any other: float samples are scaled by the
same IO proc gain. A converted path is already not bit-perfect, so the panel lists both.

**DSD isn't converted.** A DSD track on a device that can't carry DoP still fails before the
device is touched, with the reason (0064), and three in a row stop playback (0063). AudioToolbox
has no DSD decoder, so converting would mean writing a DSD-to-PCM decimation filter and checking
it against reference output: a phase of its own, for when the owner asks. The library's DSD
files are a watched folder of their own, so they're easy to leave out of a queue for AirPods.

## Consequences

- AirPods, the built-in output and any device without the track's format play every PCM track.
- The ranking is a guess at "best" for devices nobody here owns. A device with several rates and
  no 44.1 kHz family picks the nearest above, so a 44.1 kHz track goes to 48 kHz rather than 96.
- Tests run a null device that offers only 2 ch float at 48 kHz: a 44.1 kHz 16-bit and a 96 kHz
  24-bit two-track sine album play as one signal within 1e-3 across the join, a seek lands on
  the file's time, and the signal path names the conversion.
