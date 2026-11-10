# 0191. Quitting with work in progress

- **Date:** 2026-11-10
- **Status:** accepted
- **Amends:** [0167](0167-quitting-with-tag-writes-queued.md) (the tag writes' question is
  asked alone only while nothing else runs)
- **See also:** [0172](0172-every-picture-and-bulk-covers.md) and
  [0189](0189-discogs-covers-kept-on-disk.md) (Get Artwork),
  [0147](0147-moving-downloads-into-the-library.md) (Approve's import),
  [0164](0164-keep-files-organized.md) (organizing), [0124](0124-drop-files-and-the-library-folder.md)
  (a drop's copy), [0190](0190-an-unfinished-analyze-resumes.md) (Analyze resumes)

## Context

The owner asked, on 2026-11-10, that quitting warn while work runs in the background:
"organizing files, downloading artwork, tags in progress, downloads in progress, etc." Only
the tag editor's queue asked (ADR 0167); every other job stopped at ⌘Q with nothing said.

## Decision

- **One question for everything.** `applicationShouldTerminate` gathers a line from each part
  of the app already made, and while any part outside the tag editor's queue has one, returns
  `.terminateLater` and asks, app-modal, after returning: "Quit with work in progress?", the
  lines as a list, and "Quitting stops them where they are. What they have finished stays
  done." The buttons are Cancel, the default, and Quit Anyway. Quit Anyway saves the play state
  and quits as before (ADR 0095); Cancel replies no. The reply is
  `reply(toApplicationShouldTerminate:)`, so a logout or restart waits on the answer the way
  AppKit lets it, and never on the work itself.
- **The tag queue's own question stays** for when it is the only work: "N tag writes haven't
  finished" with Wait and Quit (ADR 0167). When other work runs too, the queue's lines go at
  the top of the one question, which has no Wait and Quit, since the other work has no end to
  wait for here.
- **Each part says its own lines,** from state it already keeps, and the app only joins them:
  - `TagEditing.unfinishedWork`: "Saving tags: 3 of 20" while a write has files left (the
    status bar's count), "Organizing 12 files" while Keep Files Organized or Organize
    Selected Files has files left, else "2 tag writes queued" for an undo or a step that
    hasn't reported. The Discogs tagger's Apply and Get Artwork's write go through this queue.
  - `LibraryBrowser.unfinishedWork`: a drop's copy into the library folder, by the status
    bar's line, "Copying into the library folder: 3 of 20".
  - `DiscogsTagger.unfinishedWork`, for the library's tagger and a staged download's:
    "Discogs tagger: analyzing 40 of 200 albums", "Discogs tagger: reading 3 of 20 files"
    (before Apply to All), "Importing the Discogs catalog", and Get Artwork's fetch, "Getting
    covers: 3 of 20".
  - `Downloads.unfinishedWork`: "Moving Artist - Title (2001) into the library" while
    Approve or Resume Here runs its import.
- **`QuitQuestion` (DisplayText)** holds the wording and the rule that work the tag queue's
  question covers is asked about only beside other work. It knows only strings, so it is a
  primitive, with its alert in a file of its own.

### Left out, and why

The rule: a job is listed when quitting stops it and nothing starts it again by itself, or
when it leaves files part done. These carry on without anyone asking, and lose nothing:

- **Scans:** the watcher scans every folder again at launch.
- **Analyze Library:** a run quit mid-way resumes at the next launch (ADR 0119).
- **The downloads themselves:** music-recommender searches and downloads on its own Mac; the
  player only polls it, so quitting the player stops none of them.
- **A download's auto-tag:** its write goes through the staged journal, put right at the next
  launch (ADR 0146), and its 10-minute lease runs out, so the next poll tags the job again.
- **The daily snapshot,** written between scans, asked for again the next hour.
- **Library Health's check and the player imports:** the check only reads, and an import is
  one transaction.

Analyze in the tagger, the catalog import and Get Artwork's fetch keep what they fetched
(ADRs 0190, 0134, 0189), but are listed anyway: each runs for hours and starts again only when
the owner starts it.

## Alternatives considered

- **A busy flag per feature, with the app writing the words.** Rejected: the features already
  word their progress for the status bar and their windows, and the app holds no logic.
- **Wait and Quit for everything.** Rejected: a fetch of 4,000 covers or an Analyze takes
  hours, and only the tag queue can tell when it is empty.
- **Two questions in a row,** the general one then the tag queue's. Rejected: one quit, one
  question.

## Consequences

- A quit while a Discogs Analyze runs now asks, where it used to stop the run at once.
- The tag queue's question no longer comes up when other work runs; the tag writes are listed
  in the one question instead, without Wait and Quit.
