# 0183. Several albums selected in the tagger

- **Date:** 2026-11-09
- **Status:** accepted
- **Amends:** [0133](0133-one-confirmation-for-a-match-set.md) (Apply to All, and Reject per
  album)

## Context

The owner asked, on 2026-11-09, to select several albums in the tagger's album list, to apply
to only some of a tab's albums at a time, or to reject several at once. Until now the list
selected one album: Reject acted on it alone, and Apply to All wrote every album of the tab
that wasn't rejected or written. Applying to part of a tab meant rejecting the rest one by one,
then accepting them again.

## Decision

- **The list selects several albums,** as any list in the app does: Shift and Command extend
  the selection. The model keeps the selected albums' ids beside `selectedID`, the album the
  detail shows, which is the row selected last. Setting `selectedID` selects that album alone,
  so a tab change, an Analyze and the tests' selections go on as before.
- **Reject acts on every album selected in the tab shown.** Its title counts them when there
  are several, "Reject 3 Albums". When they're all rejected it reads Accept and takes the
  rejections back, each album getting back the release chosen for it. The rejections are saved
  in one call to the index, and taking them back in one call per review they return to.
- **Apply writes the selected albums when there are several,** and its title says so, "Apply
  to 3 Selected…", counting the albums selected. It still leaves out those rejected or written
  already, and asks once, with the counts, as before. With one album selected it is Apply to
  All in the tab.
- **The other review buttons act on the detail's album:** Other Releases, Look Up, View
  Changes and Open on Discogs, and leaving a file out. Each is about one release.

## Alternatives considered

- **A separate Apply to Selected button.** One more button beside Apply to All, off whenever
  one album is selected, which is most of the time. The title change says the same thing in
  the place the user already looks.
- **A tick box per album.** A second selection beside the list's own, which the user would
  have to clear by hand after each Apply.
- **An empty detail while several are selected.** The detail is how the user checks an album
  before adding it to the selection, so it keeps showing the last one clicked.

## Consequences

- With several selected, an album taken out of the tab by a new match, as choosing a release
  can do, leaves the selection without being shown; Reject and Apply count only the albums
  the tab lists.
