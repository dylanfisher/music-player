# 0160. Get Info opens as it stays, resizes, and always has its Discogs tab

- **Date:** 2026-11-09
- **Status:** accepted
- **Amended by:** [0177](0177-art-viewer-settings-panes-get-info-steps.md): a window on one track steps to the previous and next
  track of its list in place, dropping what was typed, as a close does.
- **Amends:** [0103](0103-option-arrow-seeks-get-info-place-health-toggle.md) (where an info
  window opens), [0158](0158-every-window-keeps-its-frame.md) (Get Info joins it),
  [0153](0153-editing-extras-and-when-undo-is-on.md) (the Discogs tab was read only)
- **See also:** phase 53.11 in [plan-archive.md](../plan-archive.md), which showed the
  Discogs tab only for files with a release id

## Context

The owner, phase 57: the tabs resize themselves when an info window first opens; the window
should be resizable and keep its size and place as the other windows do; and every info window
should have the Discogs tab, so a release id can be set on files that have none.

Two things moved the window after it showed:

- **The tab bar.** Eleven tabs need 641 points and the tab view had 634, so it squeezed their
  labels. For files with no release id, `load` then took the Discogs tab out, and the ten left
  were laid out again at their full width.
- **The window's height.** The window took its size from its content's fitting size before
  the first tab's view was in the tab view: a view set on the tab already selected goes in at
  the first display, and the tab view sizes its views by frame, so their constraints don't
  reach the fitting size. The Info tab needs 22 points more than the tab view's 440, so the
  window grew as it was ordered front.

## Decision

- **Every tab, always.** The Discogs tab stays for files with no release id, saying how to add
  one. A Release ID field at its top edits `DISCOGS_RELEASE_ID`, through the model's Extras
  edit, so it saves with the other fields through `TagEdit.custom`, shows "Mixed" where the
  files differ, and Extras lists the same change. The tab reads the release typed from the
  catalog, a later read dropping an earlier one. `edit()` refuses an id that isn't a whole
  number above 0; empty removes the key. The release's text below stays read only.
- **Sized for its tallest tab and its tab bar.** The tab view's least height is 470, which
  Info, the tallest tab, fits, and its least width is the tab bar's `minimumSize`, so no label
  is squeezed. A test selects each tab and checks the window keeps its frame and its content
  fits the size it was given before it showed. The window is laid out before it's ordered
  front.
- **Resizable.** Its least size is its content's fitting size, which it opens at the first
  time. The tabs take the height past that, and the fields the width.
- **Its frame kept as "Get Info Window"** (its title is its files'), through
  `keepsFrame(as:)`, as Spectrum does: the first window open keeps it; one opened while
  another is open cascades from the last one open, at its size, and doesn't save its frame.
  `tagEditor.place`, which kept only the top left corner, is gone, with its own cascade past
  the corners of windows open.

## Alternatives considered

- **Hiding the window until its files are read:** Get Info opens at once by design (ADR
  0100), and the flash wasn't the read.
- **Building the first tab's view before it's added to the tab view:** the tab view still
  sized it by frame, so the fitting size didn't change.
- **Every window saving its frame under the name:** a window cascaded from another would save
  its cascaded frame, and the next would open another step down each time.

## Consequences

A `state.json` that holds `tagEditor.place` no longer matches and is discarded whole at the
first launch of this build (pre-release, one shape); deleting that line first keeps the rest.
A tab made taller than Info fails the test until `tabsHeight` grows with it.
