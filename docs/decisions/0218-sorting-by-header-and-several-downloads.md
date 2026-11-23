# 0218. Sorting a discography by its headers, and acting on several downloads

- **Date:** 2026-11-22
- **Status:** accepted
- **See also:** [0205](0205-recommendations-in-the-player.md) (the Recommendations window),
  [0217](0217-an-artists-discography.md) (an artist's discography), phase 95 of the plan

## Context

The owner (2026-11-22) asked for the Recommendations window to "sort by the table headers if
possible, at least where the table is somewhat finite, like recommended discography", and for
the Downloads window to "select multiple items at once … to be able to retry or remove/cancel
etc multiple at once". Every Recommendations list is paged by the service, 100 rows a page, a
discography too; the window reads the next page as it scrolls to the last row.

## Decision

- **Only a discography's headers sort.** It is the one list that is finite by nature, so the
  window holds it whole: once a header sorts it, the model reads every page not read yet, and
  every later read of it (a refresh as its values come in, Try Again, a read after a mark)
  reads every page too. A page with no rows that says more follow ends the read, said as the
  list's problem, since asking again would get the same page. The scored lists keep the service's order and their headers have no
  sort, since a sort of the rows read so far would look like the whole list's.
- **What each column sorts by.** Year, Have, Want, For Sale, Lowest Price, Rank, Albums and
  Score as numbers; Rating by its average, so a release without values or votes is empty; In Library
  as had or not; every other column by its text, as the Finder orders names (numbers in a
  title as numbers). Empty values go last both ways, and equal values keep the list's own
  order, which the Sort pop-up sets. Download doesn't sort: its states change as the jobs
  run, and the rows would move under the pointer.
- **A sort is kept per list** (by its seed) while the app runs, and isn't stored: leaving a
  discography and coming back restores it. A click on the sorted header again reverses it.
  Choosing an order from the Sort pop-up clears the header sort, so the order chosen is the
  one shown. The selection follows its albums through a sort, scrolled to the first.
- **The Downloads table takes multiple selection** (shift and command click, Select All). A
  button or menu item is enabled while its action applies to any of the rows it would act
  on, and acts on each of them it applies to, skipping the others; an action on one row takes
  the clicked row when it applies. The context menu acts on
  the clicked row, or on the selection when the clicked row is in it, as the Recommendations
  window does. The selection is kept by job id as the rows are replaced.
- **Approve, Resume Here and Open in Tagger act on the first row** they apply to: each opens
  one review, a sheet or the tagger, which the owner finishes before the next. Approve Safe
  Matches Automatically is the way to approve many.
- **Retry, Reject and Cancel on several rows ask once**, naming the count, then send each job
  in turn, as it is by then, skipping one the action no longer applies to, and say together
  which failed. Retry on several doesn't ask for a format: each job
  searches again in the format it asked for, and a staged copy that isn't clean is requeued
  as Retry does for one. Reveal in Finder shows every staged folder in one Finder window.
  One row works as before, a Retry that searches again asking for its format.

## Alternatives considered

- **Sorting any list once every page is read.** Rejected: a scored list's headers would start
  sorting partway through a scroll, and a filter change would turn them off again.
- **Sorting the loaded rows of a paged list.** Rejected: the first 100 rows by rating look
  like the list's best-rated albums and aren't.
- **Approving several in a row, one sheet after another.** Rejected for now: each sheet asks
  its own questions, and a cancelled one would leave the owner unsure which were approved.
- **A format question for a Retry of several.** Rejected: the jobs may differ in what they
  asked for, and an upgrade takes only lossless formats; one row still asks.

## Consequences

- A header click on a large discography reads all of it, a page at a time, before the sort
  covers every row; the spinner shows meanwhile and the rows read are sorted as they are.
- A Retry of several that includes a job needing another format takes two steps: Retry the
  set, then Retry that job alone with its new format.
