# 0115. Spectrum and file analysis

- **Date:** 2026-11-06
- **Status:** accepted
- **Amends:** [0036](0036-scripting.md) (a command line command that takes
  paths), [0079](0079-thumbnails-in-the-caches-folder.md) (a second cache beside the thumbnails)

## Context

The owner asked on 2026-11-05 for a way to check that a file is what it says it is, a FLAC
that isn't a converted lossy file, a 24/96 that isn't 16/44.1 underneath, and to compare
files side by side (phase 45). The owner has no known-good or known-bad files, so the
thresholds come from generated fixtures and the published cutoffs of common lossy encoders,
and the owner's checkpoint compares flagged files with Spek. Part 45a builds the analysis, the
Spectrum window and the command line; 45b, the library pass, reads what it caches.

## Decision

**One pass over the decoded file** (`Analysis`, a Core module). `FileDecoder` is `package` so
Analysis reads files the way playback does. FLAC, ALAC and integer PCM are read as Int32, the
stored bits at the top of the word, so effective bits are exact: 32 less the trailing zeros of
every sample OR'd together. Lossy and float files are read as Float32 and have no effective
bits. Each 4096-frame hop feeds an 8192-point FFT per channel (Hann, 50% overlap, vDSP from
Accelerate, a system framework on macOS 12), its power averaged over the channels and scaled so
a full-scale sine is 0 dB. The spectrogram keeps each cell's maximum over the frames and bins
it covers, at most 1,000 columns × 512 rows, stored as 8 bits from -150 dB to 0 dB; the
average spectrum is the mean power per row. The same hops give identical channels (the first
two, sample by sample), clipped runs (3 or more samples at the largest code of the stored
depth, or at 32767/32768 for float), the sample peak, the true peak (a 4-phase, 48-tap
Hann-windowed sinc interpolator, as BS.1770 oversamples), and the DR meters' score (3-second
blocks, the second-highest block peak over the RMS of the loudest 20%, a sine's RMS taken as
its peak). The task is checked for cancellation at every hop, so at every FFT frame. DSD files
are refused with "DSD files aren't analyzed yet".

**A cutoff is a fall of at least 20 dB across 1 kHz** of the average spectrum: the mean level
of the 500 Hz above a frequency against the 500 Hz below, looked for from 5 kHz up, the
highest one found. Music's own roll-off doesn't come close (12 dB an octave is under 1 dB
across a kilohertz at 16 kHz); an encoder's low-pass and a resampler's anti-alias filter do.
Its steepness is that fall over the 500 Hz between the halves' centers, in dB per kHz.

**Verdicts**, every threshold in `AnalysisRules`:

| Verdict | Rule |
|---|---|
| Suspect lossy origin | FLAC, ALAC or PCM; a cutoff at or under 20.5 kHz; Nyquist 22.05 kHz or more |
| Suspect upsampled | a rate over 48 kHz and a cutoff at or under 24 kHz |
| Padded bits | effective bits under the stored bits |
| Fake stereo | the first two channels identical, and not silent |
| Clipped | 10 or more clipped runs |

A lossy file gets measures but no lossy-origin verdict. Each verdict has one line naming its
numbers: "Cutoff at 16.0 kHz: suspect conversion from a lossy file".

**Caches.** Measures go in the index, in a `measures` table that is a schema part of its own,
keyed by path, with the file's size and modification time as the directory walk reads them, so
45b can find changed files against `files` without touching the NAS. A row whose stamp doesn't
match is ignored and replaced; a rebuild of the part reports no discarded stats, as it's a
cache. The table holds the format as decoded, so the verdicts can be worked out from a row
alone when the rules change. Spectrograms go in `Caches/MusicPlayer/Spectrograms`, one file
each (columns, Nyquist, length, the 8-bit cells and the 512 average levels; about 0.5 MB for
1,000 columns) named by a hash of the path and stamp, and the least recently used are removed
past 100 MB, after launch and every 10 MB written, as the thumbnails are (ADR 0079).
`FileAnalyzer` puts both in front of the analysis, which runs at utility priority on a task
cancelled with the one awaiting it.

**Show Spectrum** (`track.analyze`) is in the track menu and the File menu after Get Info, and
so in the palette. It opens a window on 1 to 8 selected tracks; more is refused in the status
bar. Two files are analyzed at once. Each file shows its progress, then its format line,
spectrogram and verdicts, stacked on one frequency axis to the highest Nyquist, with dotted
lines at 16, 19, 20, 22.05 and 24 kHz; beside them every average spectrum on one chart, a color
per file, a legend and the dB scale; one file also lists its measures. The line at the bottom
reads time, frequency and level under the pointer. Closing the window cancels its work.

**`music-player analyze [<path>…] [--json]`** runs the same registry entry. `Command` gains
`takesPaths`: the tool makes the words after the name absolute against its own folder and sends
them in a `paths` key of a report request, which the router refuses for any other command; a
path must be absolute and pass the argument checks, and the request must still fit 4 KiB. With
no paths it's the selection. It prints each file's path, format line, measures and verdicts,
or a JSON array with every key and null for what doesn't apply, and opens no window, so a
script can run it over files. The tool waits up to 600 s for it (`ScriptLimits
.fileReplySeconds`), against 10 s for other commands: a few long hi-res files on the NAS take
minutes on the 2015 MacBook Pro.

## Alternatives considered

- **Reading every file as float** — rejected: a 24-bit file padded from 16 bits would show 24
  effective bits wherever the conversion rounds, and the padded verdict is meant to be exact.
- **A cutoff as the frequency the level drops a fixed amount under a reference band** —
  rejected: quiet or dark music would show a "cutoff" wherever its highs fade, and a steep fall
  is what tells an encoder from the music.
- **The command line opening the window, as `stats` shows Listening Stats** — rejected: a
  script over many files would pile up windows; the menu and palette open it.
- **The command line analyzing the files itself** — rejected: with no paths it needs the app's
  selection, and the app has the index the measures are cached in; one path through the app
  keeps one cache.
- **Spectrograms in the index** — rejected for the reasons ADR 0079 gives for thumbnails: size,
  backups, and the writer's connection.

## Consequences

- On the slow simulated NAS a 5-minute 24/96 file takes about four times as long as from the
  page cache, as the reads wait in turn; 45b's library pass reads each file once.
- The thresholds are a first guess until the owner compares flagged files with Spek.
- A live visualizer is still in Later; nothing here runs on the real-time audio thread.
