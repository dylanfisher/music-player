# 0119. Analyze Library: files at once, the whole count, run again; Pause Scan

- **Date:** 2026-11-06
- **Status:** accepted
- **Amends:** [0116](0116-analyze-library.md) (one file at a time at background priority, the
  count of a run, the status, Library Health)

## Context

After the first runs of Analyze Library (ADR 0116) over a 43,000-file library on the NAS, the
owner asked for five changes: a faster pass; its progress in Library Health, with the file
under way and a Pause button; a count over the whole pass that a relaunch doesn't reset;
a way to run it again once every file is measured, where it now finds nothing and flashes
"0 of 0"; and a Pause button for a scan. The owner has already measured much of the library,
so whatever records a run must keep those measures.

## Decision

**Two to four files at once, at utility priority.** The pass keeps
`min(4, max(2, activeProcessorCount / 2))` files under way in a task group, two on the 2015
MacBook Pro, so one file's reads overlap another's FFTs. Files still start in path order, so a
share is read about a folder at a time. Each child task decodes its file at `.utility` and
stores its measures, with the three tries of ADR 0116; only the pass's actor counts and
reports. Pause cancels the run, and so every file under way; each is read again next run, and
no file is read twice in one run.

**The count is over the whole pass.** "1,240 of 43,368" counts every analyzable file, the
measured ones as done, so a run carried on after a pause or a relaunch goes on from the count
it stopped at. A run with nothing to do reports only its end.

**A run again, in a schema part of its own.** A new part, `analysisRun`, holds three tables:
`analysis_run` (one row: when the run going, or the last one, started, and whether it finished),
`measured_at` (when each measures row was stored, by path) and `analysis_failures` (the files the
run couldn't analyze or store, with their stamps, emptied as a run again starts). A file is done
for the pass when it has current measures stored at or after the run's start. A file that
failed as the index has it now counts as tried: a run carried on doesn't read it again, and
its count goes on from where it stopped; a run again reads it. Analyze Library
carries on from the last run's start; Analyze Library Again starts a run now, so every file
measured before it counts as not done. The measures it replaces stay until each file's new ones
are stored, so the columns and Library Health keep their values while it runs, and a quit
mid-way resumes it as any run.

The `measures` table doesn't change. Changing its SQL rebuilds it (pre-release, no
migrations), which would discard the owner's measures and cost another read of the library
on the NAS. A measures row with no `measured_at` row was stored before the part existed and
counts as made at 0, before any run, so those measures count as done. Rebuilding the new part
discards nothing a run can't make again, as for `measures`.

**Every file tried.** Analyze Library reads "Analyze Library Again…" in the menu, the palette
and Library Health once no run is unfinished and every file left is one the last run couldn't
analyze; it asks before it starts, since it reads every file again. Without the failures
table, one unreadable file would keep the library from ever counting as done. The app asks the
pass's standing at launch, after each run and after a scan changes the library. A pause
doesn't move a run's start, so its count survives a quit: after a relaunch with a run
unfinished, the status bar and Library Health say "Library analysis paused: 1,240 of 43,368".

**What the pass reports.** The newest file started, by name, and the count at most every
quarter of a second; a change of stage and the end go out at once. Library Health's header
shows a bar, "Analyzing library: 1,240 of 43,368 · name.flac" and Pause while it runs, and
Analyze Library (or Again) when it doesn't. The status bar gains a small pause button after
Analyze Library's text, and one after the scans'. Every button runs a command, so it does
what the menu and the palette do.

**Pause Scan.** `library.pauseScan` and `library.resumeScan` pause and resume the running scan
through its `ScanControl`. The user's pause is held in `WatchState`, which holds the running
scan while it's set, so the watcher's own `resume()` after playback stops doesn't undo it; it
ends with the scan, or with the watcher's stop, whose cancelled scan ends with `scanStopped`,
and doesn't outlast a quit. While it holds, other scans wait behind it as
for a scan paused by playback. The status bar says "Scan paused: …", and Analyze Library doesn't
wait for a paused scan, which reads nothing. Settings > Watched Folders shows no scan progress,
so the status bar is the only place with the button.

## Alternatives considered

- **A `measured_seconds` column in `measures`**: one table instead of two, but its rebuild
  discards every measure stored.
- **Deleting the measures for a run again**: the columns and Library Health would empty for
  the hours the run takes, and a pause would leave them empty.
- **More files at once on a fast Mac**: past four, the NAS's single link is the limit, and the
  window's searches and refreshes share the cores.
- **A title like "Analyze Library Again" kept apart from Analyze Library**: two items with one
  always disabled; the dispatcher's title hook changes one item's title instead.

## Consequences

- The first run after this build counts the owner's measured files as done.
- The 2015 MacBook Pro runs two files at once beside playback; the owner's checkpoint says
  whether playback or the window stutter.
- A store that keeps failing records a failure that may fail to store too; the file is then
  listed again, and only the Again title waits for it.
- A file that failed is read again only by Analyze Library Again, or once its file changes.
- A user's Pause Scan that's forgotten holds back other scans and sync pushes until Resume
  Scan, as a scan held for playback does.
- Resume Scan while playback holds a network scan leaves it held until playback stops.
