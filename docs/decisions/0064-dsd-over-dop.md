# 0064. DSD plays as DoP, packed on the decode thread, at unity

- **Date:** 2026-11-02
- **Status:** accepted
- **Amends:** [0006](0006-tag-reader.md), [0011](0011-playback-engine-and-hal-output.md),
  [0035](0035-signal-path-panel.md), [0041](0041-upnp-output.md), [0059](0059-problems-window-actions.md)

## Context

Phase 12. The owner keeps a watched `dsd` folder of DSF files, DSD64 and DSD128, which the
scanner skipped, so a Swinsian import listed them as a format this app doesn't read yet (0059).
The DAC, an RME ADI-2, takes DSD as DoP (DSD over PCM, v1.1): each PCM frame carries 16 DSD bits
per channel under an 8-bit marker that alternates 0x05 and 0xFA, at a sixteenth of the DSD rate.
It offers 2 ch 32-bit integer at 176.4, 352.8 and 705.6 kHz, non-mixable under hog mode. Any
change to a sample, a gain below unity included, breaks the markers, and the DAC then plays
the frames as loud PCM noise.

## Decision

**Reading.** DSF and DSDIFF parsers sit beside AIFF and WAV in Metadata and share a
`DSDStream`: the rate, the channels, where the bits start, how many are present, block
(DSF, 4096 bytes per channel) or byte (DSDIFF) interleaving, and the bit order (DSF stores each
byte's oldest bit lowest). DSF's ID3v2 tag is read at the header's metadata pointer, and a
DSDIFF `ID3 ` chunk, which taggers add, the same way; DSDIFF's `DIIN` title and artist aren't
read. A file cut short reads what it holds, with a truncation warning, as WAV and AIFF do. A DSF
metadata pointer inside the header or the audio, or at bytes that aren't a readable ID3v2
tag, is an `unreadableField` warning: the tags are dropped and the audio kept, since the tag
sits apart from it.
DST compression, a rate that isn't 64, 128, 256 or 512 times 44.1 or 48 kHz, more than 6
channels and a DSF format other than raw DSD are typed `unsupported` errors, so the scan lists
them as problems instead of dropping them. The tag writer refuses both formats.

**One label.** `sampleRateText` (Metadata) names a rate DSD64, DSD128 or DSD256 by its multiple
of the base rate, and any other in kHz. The library stores a DSD track's bit rate as its sample
rate and 1 as its depth, so the rate column, the now-playing line and `--play`'s list all go
through it, and a smart rule on the rate still compares numbers.

**Packing.** `DSDReader`, a sibling of `FileDecoder` behind the `TrackDecoder` protocol the
output decodes through, reads the bits and packs them on the decode thread into the device's
own integer format: 24-bit packed, or 32-bit with the 24 DoP bits aligned high and zero below.
The oldest bit is the word's highest, below the marker. A last frame with one byte gets the
idle pattern 0x69 for the other. The IO proc still copies bytes and knows nothing of DoP.

**Continuous markers.** A frame's marker is set by its place in the track: 0x05 on even
frames, 0xFA on odd. The reader rounds a track's length up to a pair of frames with DoP silence
(0x69 under the markers), seeks only to even frames, and the ring buffer takes DoP in pairs of
frames, so every track starts on an even frame of the ring and every discard skips an even
number. A gapless DSD to DSD change and a next track replaced while queued then never put two
frames with the same marker side by side, and neither does a seek, given that the IO proc takes
an even number of frames each cycle, as every HAL buffer size is in practice. A seek while
playing can still leave the IO proc a cycle with nothing new to play, which it pads with zeros,
as it does for PCM; the DAC drops out of DoP for those few milliseconds, and the markers carry
on alternating across them.

**Unity.** A DSD stream's render state is created with `HALRenderSamplesOpaque`, a sample
kind the IO proc never scales, and the control thread never sets a gain on it. The kind is
fixed with the stream when the track loads, so the volume can't reach DoP by any path. A
volume change while DSD plays only updates the gain the next PCM track gets. The signal path
panel's Volume row says "digital bypassed for DoP", and the path reports unity, so the
verdict stays bit-perfect when everything else is.

**Carrier and refusal.** DSD64 plays at 176.4 kHz, DSD128 at 352.8 and DSD256 at 705.6 (and
the 48 kHz family at 192, 384, 768), in a 24- or 32-bit integer format; the device is asked
for at least 24 bits. A device whose reported rates or formats lack either is refused before
it's touched, through `refuseUntakeable`, with one message: "ADI-2 can't play DSD128: it has no
352.8 kHz rate for DoP". Nothing converts DSD to PCM. A refused track fails like any other, so
a DSD album on such a device stops after `PlaybackEngine.failureLimit` tracks (0063).

**Signal path.** A DSD file's `SignalFormat` has the code `DSD ` at its bit rate, and what the
reader hands on has `DoP ` at the carrier rate and 24 bits; the verdict judges the device
against the DoP words. The panel shows "DSD128, 2 ch" for the file and "DoP at 352.8 kHz" for
the decoder, and the now-playing line names the output "DoP at 352.8 kHz on" the device's
format.

**UPnP.** A DSF or DSDIFF file goes to a renderer unchanged under the first of its own type,
its `x-` form, `audio/dsd` and `audio/x-dsd` that the renderer's sink lists; the Denon lists all
six. A renderer that lists none refuses it the way it refuses any other container.

**Fixtures.** The generator writes DSF and DSDIFF at DSD64, 128 and 256: 14,112 bytes a channel
(40 ms of DSD64) of a 1-bit sine from a first-order modulator, with ID3 tags of the versions
MP3s get, and DSF albums untagged three times in ten. Every 12th album is DSD, the six kinds in
turn, so every other album's random picks stay as they were. They're short so the bench library keeps
its generator and scan budgets, and long enough that the audio ends past the reader's first
16 KiB read, as a real file's does.

## Alternatives considered

- **Native DSD through the HAL.** macOS has no public DSD format for an output stream; DoP is
  what the ADI-2 and most USB DACs take on a Mac.
- **Packing in the IO proc.** It would put file layout and bit reversal on the real-time
  thread, which stays a byte copy.
- **The marker from the ring buffer's frame count.** The reader would need the ring's count for
  every chunk and every decode ahead of a switch; pairs of frames keep it ignorant of the ring.
- **A frame of DoP silence written before each track that starts on an odd frame.** The ring is
  often full when a track is queued or a seek posts its discard, so there may be no room to
  write it then.
- **Turning the volume command off while DSD plays.** The gain is the output's setting, not the
  track's, and a held key would stop working mid-album; it's kept for the next PCM track and
  the panel says it's bypassed.
- **Converting DSD to PCM for a device without the carrier.** That's a resampler and a
  low-pass filter in the app, and the output would no longer be the file's bits.

## Consequences

DST-compressed DSDIFF, which SACD rips sometimes are, is listed as unsupported and doesn't
play. Tags can't be edited in DSD files. The ADI-2's DSD indicator, at the hardware checkpoint,
is the proof that the whole path is bit-perfect.
