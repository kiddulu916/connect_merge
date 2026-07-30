# ADR 0001: EngagementCubit's mixin split is intentional, not a false seam

**Status:** Accepted (2026-07-30)
**Context:** Architecture-review candidate #4 ("merge the engagement mixins back")

## Decision

Keep `EngagementCubit` split across three files via mixins —
`engagement_cubit.dart` (core: load, `onTierCompleted`, streaks/XP/achievements),
`engagement/prize_checking_mixin.dart` (period payouts), and
`engagement/cosmetics_wallet_mixin.dart` (freeze tokens, purchases). **Do not
merge them into a single class.**

## Why

The 2026-07 architecture review flagged the split as a "class cut in three for
line count" — a false seam whose deletion test says "merge." That framing was
conditional on `prize_checking_mixin` shrinking enough (after the `_checkPeriod`
extraction, candidate #3 / PR #8) that the split lost its justification.

It did not. Post-#3 the files are ~379 + 448 + 185 = **~1012 lines**; merging
them (minus ~40 lines of cross-mixin glue) yields a **~970-line
`engagement_cubit.dart`**. That trades three focused, separately-navigable files
for one unwieldy one — net-negative for the AI-navigability and testability the
review optimizes for.

The three files also map to three plausibly-distinct responsibilities (core
engagement / period payouts / cosmetics-wallet), so the split is defensible
decomposition, not purely line-count. The only real cost is ~40 lines of
"privacy workaround" (a few members forced non-private to cross the mixin
boundary, documented inline).

## Consequences

- Future architecture reviews should NOT re-suggest merging these mixins.
- If the privacy-workaround coupling ever becomes painful, the genuine
  deepening is to extract prize-checking and cosmetics-wallet into **composed
  collaborator objects** (injected, with real interfaces — no forced-public
  members), NOT to merge into one class. That is a larger, currently-unwarranted
  refactor.
