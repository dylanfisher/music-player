# 0209. Filtering threads

- **Date:** 2026-11-14
- **Status:** accepted
- **See also:** [0208](0208-threads.md) (the Threads source this filters); music-recommender's
  ADR 0036 (the seed artist's albums in `artist` threads only)

## Context

The owner (2026-11-14): "often times the threads just lists a bunch of other albums by that
same artist. how can we make threads more interesting by giving it some filters like only
other artists". Asked for all three of the options offered: the service keeps the seed
artist's albums out of every thread but `artist` (its phase 11, ADR 0036), a toggle for
other artists only, and filters on what the reply already carries: the thread's kind, the
album's plays and its year.

## Decision

- **A filter row in the Threads card, above All:** an Other Artists Only checkbox, a Kinds
  pull-down, a Played pop-up and a Years pop-up, in that order.
- **Other Artists Only** hides every `artist` thread and leaves out of All the albums in no
  other thread. With the service's ADR 0036 an album in an `artist` thread is in no other, so
  this is "every album not by the seed's artist". Off by default.
- **Kinds** is a pull-down of the four other kinds, Credits, Related Artists, Labels and
  Styles, each checked or not, all checked by default; its title names the unchecked ones
  ("Kinds: no Styles") or says "All Kinds". The `artist` kind is the checkbox's, not a fifth
  item, so one control says it.
- **Played:** Any Time (default), Never Played (`plays` 0), Not in a Year (never played, or
  `last_played` more than 365 days before now).
- **Years:** Any Year (default), Within 5 Years, Within 10 Years of the seed's `year`; an
  album without a year is left out once one is chosen. Disabled, Any Year, while the seed has
  no year.
- **What a filter changes:** an album the filters leave out is in no thread's count, in All
  and in the table; a thread of a hidden kind isn't listed; a thread none of whose albums pass
  is dimmed and can't be chosen, as a thread of none of this library's albums is (ADR 0208).
  A chosen thread that is hidden or emptied goes back to All. Why This Album lists the
  selected album's threads of the shown kinds.
- **Not part of the place.** The filters are the panel's, not the seed's, so Back and Forward
  don't step through them and every seed shows with the same filters. They are kept across
  launches in the settings, `library.threadsOtherArtistsOnly`, `library.threadsHiddenKinds`,
  `library.threadsPlayed` and `library.threadsYears`, set from the panel and not listed in the
  Settings window.
- **No new request.** Each filter is applied to the reply held; changing one reads nothing.
- **Built (2026-11-14).** The rule is `AlbumThreads.shown(by:now:)` in Recommender, beside
  the reply it reads: the threads of the kinds shown, each with its albums that pass, and
  All's albums, those that pass in a thread shown. All also keeps an album in no thread,
  which the contract doesn't send, and leaves out one whose every thread is hidden, whatever
  its kind. Not in a Year takes an album with plays but a `null` last play, whose plays the
  player never saw, as not played in the year, and one last played exactly 365 days ago as
  played in it; Within 5 and 10 Years take an album exactly that many years from the seed's.
  The index checks every album of a reply, to count those it lacks, but lists only those
  the filters pass, so a left-out album never shows in the table; a filter changed while a
  reply is listed lists it again under the new filters. The keys hold `true` or `false`, a list
  of `credit`, `related`, `label` and `styles`, `anyTime`, `neverPlayed` or `notInAYear`,
  and `anyYear`, `within5Years` or `within10Years`. They're kept out of the Settings window
  as the Discogs tagger's choices are, set beside their own window (ADR 0132); as every bool
  and choice setting does, they give the palette Turn On Other Artists Only in Threads,
  Never Played Thread Albums, Not in a Year Thread Albums and Within 5 Years of the Seed in
  Threads, among others.

## Alternatives considered

- **Other Artists Only in the player alone.** Rejected: the caps, 60 albums a thread and 25 a
  style's, fill with the seed artist's albums before the player sees the reply, so a filter
  can only remove albums, not find the ones the caps dropped. The service's ADR 0036 fixes
  that; the toggle then only hides the artist threads.
- **Other Artists Only on by default.** Rejected: walking an artist's records is a thread the
  owner follows, and with ADR 0036 the other artists' threads come first in the list anyway.
- **The filters as part of the place,** so Back restores them. Rejected: a filter is how the
  owner likes to read threads, not where they are.
- **Asking the service to filter.** Rejected: every filter here reads fields the reply has, and
  a request field per filter would make each change a round trip.

## Consequences

- Filters can leave every thread dimmed; All then lists nothing and the table is empty, with
  the filter row still there to undo it.
- Never Played and Not in a Year read the plays and last play the profile sent, so a play
  since the last profile counts once the profile is sent again.
