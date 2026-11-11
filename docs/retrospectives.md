# Retrospectives

Where the time and tokens went over the last few phases, and what changed because of it. The
newest entry is first. [plan.md](plan.md#retrospective) says when to write one and what goes in
it.

## 2026-11-10: phases 78, 81 and 82

| Phase | Implementation | Reviews and bench | Fix rounds |
|---|---|---|---|
| 78 | 38 tool calls, 25 min | third review 3 min; the rest not recorded | 2 above low and 4 low, then 0 above low |
| 81 | 40 calls, 25 min | simplify 10 calls, bench 15 calls | 1 above low and 3 low, then 0 above low |
| 82 | 60 calls, 45 min | not recorded | round 1 fixed, then 0 above low (2 low) |

The three ran side by side in their own worktrees, 79 and 83 alongside, and landed one at a
time. Only the implementers' costs came through to the Result lines: the workflow reported
tool calls and minutes for the implement stage and left the review, fix, simplify and bench
stages empty, and no stage reported tokens, so where the gate's time went can't be read back
for this run. What the Result lines do show is load. With five phases' builds, tests and
benches on one Mac, the bench read rows over budget that weren't: Stats period change read
257 ms in 81 and 405 ms alone in 82 (budget 250 ms), and an A/B against main's binary gave the
branch 233 to 236 ms and main 263 to 270 ms; sync merge of 1M play events read 19.3 to 19.6 s
(budget 20 s, 6.45 to 7.8 s quiet in phase 73). In 82's first full run 15 rows errored with
SQLite's "disk I/O error" and 4 needed the app built; all passed rerun alone. Timing tests
(`aSearchTypedDuringARefreshDoesNotWaitForItsQueries`, `aRootWithATrailingSlashIndexesEachFileOnce`)
failed under the same load and passed rerun. Reviews found something real in each phase's
first round (a renderer stuck in TRANSITIONING keeping the Mac awake, a fallback widened to
ENOTSUP, focus mode losing an import's column layout) and nothing above low in the last.

Changes: the phase gate's performance audit now says a row that errors with SQLite's disk I/O
error while other phases run is rerun alone, like a miss, and that the bench's app is built
first. The Stats period change and sync merge rows are owner checks on a quiet machine in 78,
81 and 82's lines rather than misses. The workflow should pass every stage's tool calls,
minutes and tokens to the landing step, so the next entry can say where the gate's time went;
that's the workflow script's change, outside this repo. Cleanup: 78's and 81's worktrees were
removed as they landed, and 82's goes with this commit; `../music-player-p77`, `-p79` and `-p83`
belong to phases still running and stay; `../music-player-51gate` is still a leftover folder,
not a worktree, for the owner to delete.

## 2026-11-10: phases 73 to 76

| Phase | Implementation | Reviews and bench | Fix rounds |
|---|---|---|---|
| 73 | audit: 7 Sonnet auditors, 1.37M tokens, 9 to 30 min each side by side; 4 lanes, 808k tokens, 25 to 51 min side by side | 292k tokens, 50 calls, 6 min; 3 bench runs and an A/B of main | 1 defect and 4 simplify points, then 1 low |
| 74 | 253k tokens, 121 calls, 36 min | 139k tokens, 24 calls, 3 min | 0 above low; 3 small changes |
| 75 | 115k tokens, 48 calls, 11 min | 58k tokens, 5 calls, 1 min | 0 above low |
| 76 | 213k tokens, 112 calls, 33 min | 149k tokens, 26 calls, 2 min | 0 above low; 3 small changes |

The run took 3 hours 15 minutes: phase 73 2 hours 10 minutes, then 74 and 75 side by side and
76 started beside 74's gate, which saved about 30 minutes. Phase 73's time went to the audit
(30 minutes for the slowest auditor, B, then P's profiles) and to the lanes; triage was 10
minutes. The bench lock kept timed runs apart, but each full non-window bench run took about 15
minutes and three were needed (baseline, after, reruns), and two of the auditors' numbers
didn't hold up: D1's 17 s for a 3 MB body came from a harness reading on the main actor (7 ms
through the client), and the baseline's one miss and four "regressions" were load or the Mac's
drift, which only a rerun alone and an A/B against main's binary showed. Reviews were cheap
(1 to 3 minutes each) and the first ones found what mattered: a body copied on every chunk,
and a listing cache keeping two copies. Fixes sent back to the agent that wrote the code took 5
to 10 minutes each. No retrospective ran from phase 54 to 72, though the plan asks for one
every third phase; this entry covers only 73 to 76.

Changes: the phase gate's performance audit now says to A/B a row still slower alone against
main's binary before calling it a regression; the retrospective's cleanup says a worktree's
`.build` goes with it, so a Result line's evidence goes in the scratchpad first (phase 73's
baseline went that way). Cleanup: every phase worktree was removed as its branch merged; `git
worktree list` shows only main, and `../music-player-51gate` is a leftover folder, not a
worktree, for the owner to delete.

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
