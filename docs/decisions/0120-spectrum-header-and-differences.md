# 0120. The Spectrum window's header and differences

- **Date:** 2026-11-06
- **Status:** accepted
- **Amends:** [0115](0115-spectrum-and-file-analysis.md) (the header, the legend, and a
  Differences box when files are compared)

## Context

The owner compared a 16-bit WAV ("PCM · 44.1 kHz · 16-bit stored, 16 effective") and a 24-bit
FLAC ("FLAC · 44.1 kHz · 24-bit stored, 24 effective") of one song on 2026-11-06. The
spectrograms looked the same, both had a band above 16 kHz that was lower in the intro, and
the WAV's average spectrum was a little higher above 16 kHz. They don't read spectra, and
asked for the window to say in plain words how files differ, above all a remaster from its
original, and to show each file's album and size (part 50d of phase 50).

## Decision

**Header.** Show Spectrum opens the window with the `TrackRow` it already looks each title up
in. A file's header reads "Title — Album", and its format line ends with the size from the
index, as the track table's Size column shows it (`fileSizeText`, now in `DisplayText`). A
file the index doesn't have is named by its file and shows no size.

**Names.** The legend and the sentences call each file by its title; where titles repeat, by
its file type ("the FLAC", and the header adds "(FLAC)"); where that repeats too, by its place
("file 2"). The legend shows these names in the files' colors instead of the format lines
the headers already show, which leaves the right column room for the differences.

**Differences.** With two files or more, a Differences box under the legend and the dB scale
shares the column's height with the chart, scrolling. Once every file has finished, it holds a
paragraph for each later file analyzed, against the first one analyzed, a sentence a line.
`differences(_:from:)` in Analysis builds them from the measures and the average spectra, with
no new reads, each threshold in `AnalysisRules`:

| Sentence | When | What it says it means |
|---|---|---|
| Cutoff | one stops at a cutoff 1 kHz or more under the other's top | made from an MP3 or AAC, from a lower rate, its encoder's, or filtered, by its verdicts |
| Level | 1 dB or more | turn it down to compare fairly |
| DR | 2 or more apart | more compressed, typical of a loud remaster |
| True peak | one over 0 dBTP, the other not | may distort in some players |
| Clipping | one with the clipped verdict's 10 runs, the other not | peaks cut off to make it louder |
| Bass, treble | 20–250 Hz or 4–16 kHz differs from 250 Hz–4 kHz by 1 dB or more | a different EQ |
| Above 16 kHz | the same, from 16 kHz to where both stop | noise-shaped dither when the one with more has fewer effective bits, else air or noise |
| Length | 2 s or more | a different edit, fade or silence |
| Rate | the rates differ | adds only what's above the lower Nyquist, or upsampled when its content stops there |
| Bits | effective or stored bits differ | padded, made from a copy with fewer, or detail too quiet to hear |
| Format | the codecs differ | every sample kept either way, or a lossy one at best the same |
| Size | both lossless and 5% or more apart | follows format, bits and rate, not the sound |

The first nine are how the files would sound different (but the dither one). When none of
them passes its threshold, the paragraph ends: "The FLAC and the WAV sound the same as far as
these measures can tell: only comparing their samples could prove the audio identical".
Matching measures can't prove identical samples, so it never says the files are the same.

**Level is an estimate.** No loudness is measured: the analysis has no K-weighting or gating
(BS.1770's LUFS). The level is the power summed over the average spectrum from 20 Hz up to
where both files stop (the lower Nyquist, or a cutoff less the 500 Hz its fall is measured
over), so a cutoff isn't read as a level difference. Every row of the average spectrum holds
the same 8 FFT bins whatever the rate, so the power of a band is each row's power times the
share of the row inside it, and files at different rates compare by frequency, not row. It's
unweighted, so the bass counts for most of it, and the sentence says "about". Bands are
measured against the midrange, not the overall level, so a louder file isn't read as having
more bass.

**Thresholds.** 1 dB is about the smallest level change a listener hears; DR scores one apart
are the meters' rounding; 2 s covers a gap or a trimmed fade; 5% of size covers tags and art.
Like 0115's, they're a first guess until the owner compares files they know.

## Alternatives considered

- **Measuring loudness (LUFS) in the pass** — rejected for now: it would change the
  `measures` table, and the owner has measured much of a 43,000-file library that a shape
  change would discard. The spectrum estimate needs nothing new stored.
- **Comparing every pair of files** — rejected: 8 files make 28 pairs. Against the first,
  the top one in the window, they make 7.
- **The sentences in the Spectrum feature** — rejected: Analysis has the measures and the
  rules, and its tests build results without a window.

## Consequences

- The `measures` table and `FileMeasures` don't change.
- The sentences name a cause only as "probably" or "typical"; a difference past its
  threshold can still be harmless, and one under it can still be heard.
