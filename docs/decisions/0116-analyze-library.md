# 0116. Analyze Library

- **Date:** 2026-11-06
- **Status:** accepted
- **Amends:** [0115](0115-spectrum-and-file-analysis.md) (the measures table, read by the
  library pass, the columns and Library Health)
- **Amended by:** [0119](0119-analyze-library-at-once-again-and-pause-scan.md): two to four
  files at once at utility priority, the count over the whole pass, Analyze Library Again, the
  file under way in Library Health, and Pause Scan

## Context

Part 45b of phase 45 runs the analysis of ADR 0115 over the whole library. The owner asked
that it run only when the user starts it, never at launch, after a scan or on a schedule; that
it show its progress, can be paused, pauses while a scan runs and carries on after a relaunch;
and that on the NAS, where reading is the cost, each file is read once. Its results show as
Library Health tiles and as track table columns and smart playlist fields.

## Decision

**A pass, started by hand.** `LibraryAnalysis`, an actor in Analysis, runs on Analyze Library
(`library.analyzeLibrary`), from the File menu after Show Library Health, the palette and the
command line, and stops on Pause Library Analysis (`library.pauseAnalysis`). Neither runs from
links: a page could keep the NAS busy. Each run asks the index for every track's file with no
measures made from it as indexed (`filesToAnalyze`), in path order so a share is read a folder
at a time, DSD left out as analysis refuses it. Nothing is kept about a run: a run started
later, after a pause or a relaunch, lists what's left from the index.

**One file at a time, read once.** Each file is decoded at background priority on a task of
its own, its measures stored with the size and modification time the index holds for it, not
a new stat: the pass touches the share only to read, and its row joins the files row it was
made for. A file changed since the scan is measured as it is now and stored against the old
stamp; the next scan's new stamp makes it pending again. No read-ahead: the fixture files'
cost is the open, and a real file's reads are already the SMB client's large requests.

**No spectrograms.** The pass keeps the measures only. The spectrogram cache holds about 200
files (100 MB); writing one per file of the library would replace it over and over for nothing.
Show Spectrum makes one when asked.

**Waiting for scans.** Before each file the pass asks whether a scan runs, as the status bar
shows it, and while one does waits a second at a time, saying so in the status bar. A scan
that starts during a file waits for nothing; the file finishes. Every scan the watcher runs
ends with `.scanned` or `.scanFailed`, retries that fail the same way included, so the status
bar never shows a scan that stopped.

**Pause stops at once.** Pausing cancels the file under way at its next FFT frame; the next
run reads it again. A file that fails is logged, counted, and listed again next run; nothing
is stored for it. A store that fails, as when a scan holds the index past SQLite's timeout,
is tried three times a second apart before the file counts as not stored, so a busy index
doesn't cost another read.

**Status.** "Analyzing library: 40 of 1,200" follows the scans and a tag save in the status
bar, with its bar filling when neither runs; "Library analysis paused: 40 of 1,200" stays
until the next run. While the pass runs, the table refreshes as during a scan; when it stops,
the table refreshes and Library Health runs again. A run with failures says how many in the
status bar.

**Library Health.** Five checks, one per verdict: Lossy Origin, Upsampled, Padded Bits, Fake
Stereo and Clipped, over the tracks with current measures. Library can't import Analysis, so
`healthReport(measuredChecks:)` takes the verdict rules as a function, and every threshold
stays in `AnalysisRules`. Each of those tiles says how many files its count is over.

**Columns and fields.** Cutoff, Effective Bits, Dynamic Range and True Peak, read through a
join of `measures` on path, size and modification time, defined once for the columns, the
pending list and the report. A cutoff compares in hertz, as a sample rate does. A true peak
compares unrounded and may be negative: rounded to a whole decibel, "is more than 0" would
miss an over of 0.4 dB.

## Alternatives considered

- **A stat of each file before reading it**, as Show Spectrum's analyzer does: a round trip per
  file on the NAS for a stamp the index already has.
- **Finishing the file under way on pause**: a long hi-res file on the old Mac takes tens of
  seconds, and Pause should mean now.
- **Watching the watcher's events for scans in the pass**: the status bar already tracks them,
  and what it shows is what the user sees the pass wait for.
- **Verdicts in Library, or stored with the measures**: Library sits below Analysis, and stored
  verdicts would go stale when a threshold changes, which ADR 0115 keeps the format for.

## Consequences

- A library of 43,000 files on the NAS is read once in full; the owner's checkpoint times it.
- A scan that runs while the pass is mid-file shares the NAS with that one file.
- The thresholds are still the first guess of ADR 0115 until the owner's Spek check.
