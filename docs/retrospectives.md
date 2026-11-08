# Retrospectives

Where the time and tokens went over the last few phases, and what changed because of it. The
newest entry is first. [plan.md](plan.md#retrospective) says when to write one and what goes in
it.

## 2026-11-08: phases 51h, 52 and 53

| Phase | Implementation | Reviews and bench | Fix rounds |
|---|---|---|---|
| 51h | 920k tokens, 427 tool calls, 69 min | 405k tokens, 88 calls, 63 min | 14 findings, then 1 |
| 52 | 1.12M tokens, 437 calls, 83 min | 368k tokens, 87 calls, 18 min | 11, then 1 |
| 53 (a, b, c) | 818 calls, 249 min, a and b side by side | 656k tokens, 100 calls, 25 min | 31, then 2 |

Planning was cheap: about 130k tokens and 5 minutes a phase, all three written at the start,
with 53c's rewritten once 51h's types existed. The time went to implementation, then to the
first full bench: 55 of 51h's 63 review minutes were 11 window rows each waiting out a 300 s
timeout, because the app hangs in `terminate:` in an agent session, main's binary too. With
those rows left out, 52's bench took 8 minutes and 53's 12. The first review of every part
found real defects (a restore that overwrote its own source, a flag that skipped every rescan
question, a token-free cover path that wrote nothing and said nothing); every second review
found nothing above low. Running 53a and 53b side by side saved about 95 minutes, at the cost
of one AGENTS.md conflict resolved in the rebase. Fixes sent to the agent that wrote the code,
with its context, took 13 to 25 minutes a round.

Changes: the phase gate now says to leave out the window rows in an agent session and to
rerun a missing row alone (53's metadata parse missed once at 5.29 s and ran 4.9 s alone), and
that `theGlassHeadersAreFrosted` fails in agent sessions. Reviews' briefs say "strictly read
only", since one architecture audit edited files. Cleanup: every phase worktree was removed as
its branch merged; `git worktree list` shows only main.
