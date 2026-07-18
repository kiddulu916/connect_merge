# Engagement Prize Check Deduplication — Design

Date: 2026-07-17
Status: Approved (frozen by root `PLAN.md` after four adversarial reviews)

## Summary

`EngagementCubit` has four prize checks with the same fetch, rank, guard,
profile-write, and emission shape. They currently differ in failure handling
and all retain a profile snapshot across network calls. This design keeps the
four public methods and their callback signatures unchanged, extracts only the
shared mechanics named by the frozen plan, and fixes the exposed correctness
defects without changing payout amounts or period definitions.

## Shared mechanics

`_myRankByTier` performs the per-tier leaderboard fetch loop and returns each
tier's player rank. Any fetch exception is reported through `_onError` and
returns `null`, aborting the period without stamping its guard. Daily, weekly,
and monthly pass the non-challenge difficulties; challenge passes only
`Difficulty.challenge`.

`_bestQualifyingRank` selects the lowest rank whose total payout function is
positive. Daily, weekly, and monthly map-backed payout functions return zero
outside their top-three tables. The challenge function returns zero for every
rank below 1 or above 10, closing the rank-zero defect while preserving the
150/100/50 ladder.

`_serializedPrizeCommit` is a future-chain mutex used only around the profile
commit. Network fetches remain concurrent. Every commit reloads the profile,
rechecks its period guard lexically with `stored >= periodKey`, derives one
updated profile, saves it once, and emits only if coins or weekly crowns differ
from cubit state. A caught commit error is reported and does not poison the
chain. The catch reloads storage and reconciles coins/crowns only when those
persisted values differ, covering storage implementations that write and then
throw without creating pre-write failure emissions.

The mutex guarantees prize-to-prize serialization inside one
`EngagementCubit`. It does not provide storage-wide atomicity against profile
writers in other cubits; that requires an infrastructure-level primitive and
is outside this change.

## Public prize checks

Each public check follows one order:

1. Compute the closed period and its guard key.
2. Read the current profile and return when its stored guard is lexically at or
   after the requested key.
3. Fetch ranks outside the mutex and return on `null`.
4. Enter `_serializedPrizeCommit`, reload the profile, and repeat the lexical
   guard check.
5. Compute the best payout and weekly crowns, build one `copyWith`, save once,
   and emit only changed coins/crowns.

Weekly crowns remain one record per qualifying non-challenge tier and append to
the existing history. Coins remain a single award based on the best qualifying
rank across tiers.

## UTC period construction

Date-only values are split into numeric year, month, and day components before
constructing `DateTime.utc`. `previousUtcDay`, weekly Monday/Sunday helpers,
and the previous-month helper never depend on local-midnight parsing. UTC date
normalization continues to handle year rollover, varying month lengths, and
leap days. This is a structural DST fix because Dart cannot inject a process
timezone per test.

## Proof strategy

Tests are added before production edits. Regression tests first demonstrate
weekly abort-and-retry, rank-zero rejection, concurrent lost updates,
write-failure recovery, write-then-throw reconciliation, lexical guard
hardening, and normalized no-emission behavior against the old implementation.
Coverage tests pin daily success/idempotency/fetch arguments, challenge fetch
arguments, multi-tier crown behavior, two-week crown retention, and UTC
calendar boundaries.

Focused application tests run after each implementation slice. Completion
requires a fresh full `flutter test` and `flutter analyze`, with zero failures
or analyzer issues.

## Out of scope

- `PlayerProfile`, Hive, or any other infrastructure/schema change.
- `main.dart`, Supabase, TypeScript replay code, or season changes.
- Payout amount or prize-period definition changes.
- Streak transition changes beyond the shared `previousUtcDay` construction.
- Cross-cubit storage-level atomicity.
- New dependencies or pubspec changes.

