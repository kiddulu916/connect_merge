# Plan: Collapse the four prize checks into one shared engine

_Locked via grill — by Claude + kiddulu916. Revised after Codex round 1._

## Goal

`EngagementCubit` carries four near-duplicate methods — `checkDailyPrizes`, `checkWeeklyPrizes`, `checkMonthlyPrizes`, `checkChallengePayouts` (~250 lines, `lib/application/engagement_cubit.dart:329-594`) — that all do: compute a closed period, short-circuit on a once-per-period guard, fetch leaderboard entries per tier, find the player's best rank, convert rank → coins, stamp the guard, save, emit. Deduplicate them behind small shared helpers (not a config framework — per Codex round 1), keep the four public names and signatures, and fix the real defects the dedup exposes: weekly's stamp-guard-despite-failure quirk, the concurrent lost-update race between the four startup checks, local-time date parsing in the period helpers, and challenge's payout for rank ≤ 0. Pure client-side economy code — no TS mirror, no season bump, no storage schema change.

## Approach

0. **Repo planning workflow first**: create the dated design doc under `docs/superpowers/specs/` and the task-by-task implementation plan under `docs/superpowers/plans/` (each task = failing test → implementation → passing test → commit), per CLAUDE.md/AGENTS.md — same as candidates #1 and #2.
1. **Failing tests first** (extend existing suites):
   - `weekly_prize_test.dart`: one tier's `fetchPeriod` throws → `lastWeeklyPrizeDate` NOT stamped, no coins, no crowns; healthy re-run pays out. (Pins normalized abort-and-retry.)
   - `weekly_prize_test.dart`: two consecutive weeks both top-3 → `weeklyPrizes` retains both crowns (persisted + emitted). (Coverage Codex showed was missing.)
   - `weekly_prize_test.dart` or `engagement_test.dart`: mixed ranks across tiers (e.g. hard=1, medium=3) → best (lowest) rank pays, every qualifying tier gets a crown.
   - New `test/application/daily_prize_test.dart`: success payout, guard idempotency, and fetch-args assertions for daily (currently only an onError test exists).
   - `challenge_payout_test.dart`: rank 0 and rank 11 pay nothing; rank 1 pays 150. (Pins the `rank < 1` guard.)
   - Concurrency: all four checks fired concurrently (daily save delayed via a completer-backed fake) → no guard/coins lost-update; every stamp and payout survives.
   - Persistence failure: `saveProfile` throws before writing → `_onError` fired, no emit, and the NEXT check (same or different period) still runs — the mutex chain is not poisoned by a failed link. Completed-write-then-throw variant: guard idempotency makes the retry a no-op (no duplicate payment), AND the catch path reconciles cubit state from storage so the credited coins/crowns are emitted rather than left stale behind the stamped guard — asserted on both storage and state.
   - Emission: zero-payout weekly/challenge check → listener sees NO emit (pins the emit-iff-changed normalization).
   - `challenge_payout_test.dart`: the fake captures fetch arguments → assert `Difficulty.challenge` + yesterday's date (currently unasserted).
2. **Shared helpers** in `engagement_cubit.dart` (the dedup, Codex-round-1 shape):
   - `_serializedPrizeCommit(Future<void> Function() body)` — a future-chain mutex all four checks run their COMMIT through (network fetches happen outside it, so the four checks' fetches stay concurrent). What it guarantees: prize-to-prize serialization — the four checks can no longer erase each other's stamps/coins. What it does not: atomicity against other profile writers (other cubits don't share the mutex; the commit window no longer spans network fetches, which narrows but does not close that pre-existing repo-wide race). Each link runs `body` in try/catch → `_onError`, so a throwing `saveProfile` in an `unawaited` startup future is reported, the check stays retryable, and a failed link can never poison the chain; if the failure happened after the write landed (guard stamped), the catch reconciles cubit state from storage so credited coins/crowns aren't stranded unemitted.
   - `_myRankByTier(List<Difficulty> tiers, Future<List<LeaderboardEntry>> Function(Difficulty) fetch)` → `Map<Difficulty, int>?` — the per-tier fetch loop; returns null after `_onError` on ANY fetch failure (unified abort-and-retry rule, per grill), so no partial-result stamping is possible for any period.
   - `_bestQualifyingRank(Map<Difficulty, int> ranks, int Function(int) coinsForRank)` → best (lowest) rank whose payout is positive.
   - Payout tables become total functions (`_dailyCoinsFor(rank)` etc.); the map-backed ones already return 0 for any non-winning rank, so only the challenge ladder gains an explicit `rank < 1 → 0` guard (it currently pays 100 for rank ≤ 0).
3. **Rewrite the four public methods** as short explicit blocks (each ~15 lines) with ONE ordering used everywhere: compute period → cheap guard pre-check on the current profile (skip without fetching) → `_myRankByTier` OUTSIDE the mutex → null ⇒ return → `_serializedPrizeCommit`: reload profile → re-check guard against the reload (lexical ≥; authoritative under the mutex) → compute coins (+ crowns for weekly) → single `copyWith`/`saveProfile` → emit only when coins or crowns actually changed.
   - Guard skip hardened from `==` to "stored ≥ periodKey" (lexical compare; each guard field's format is internally consistent — ISO dates or `YYYY-MM` — so lexical order = chronological order). A clock rollback can no longer re-pay an old period. One regression test.
4. **Fix the period helpers to be actually UTC** (root-cause, shared): `previousUtcDay` (`lib/domain/models/streak.dart:27`) and the weekly/monthly statics parse date-only strings as LOCAL midnight, so day arithmetic across a DST transition can yield the wrong calendar day. Fix by constructing UTC dates explicitly (`DateTime.utc(y, m, d ± n)` after parsing components); add boundary tests (year rollover, month lengths, leap day). Honest limitation: the DST regression itself cannot be pinned deterministically in-process (Dart offers no per-test timezone injection, and on a UTC machine local == UTC), so the guarantee is structural — every date construction in these helpers goes through `DateTime.utc`, reviewed at the diff — while the boundary tests pin the values. Behavior is byte-identical outside the DST edge; `previousUtcDay` is shared with streak logic, which gets the same latent fix for free. No TS-side change (server already runs in UTC).
5. **Prove**: full `flutter test` (engagement, weekly, monthly, challenge suites + the new tests) + `flutter analyze` clean. No golden-vector involvement — this code never touches `BoardState`/replay.

## Key decisions & tradeoffs

- **Weekly error handling normalized, not preserved** (grill decision): any fetch failure aborts the whole check before stamping, retrying next launch. A transient error can no longer permanently forfeit a crown. Failure-path-only behavior change; pinned by the new test.
- **Shared helpers over a config record** (Codex round 1, accepted): a 6-field config with `readGuard`/`stampGuard` closures was a mini-framework — more indirection than the duplication it removed. Three small helpers + four explicit methods keep each check readable at a glance while deduplicating the parts that are actually identical (mutex, fetch loop, rank fold, payout-fn shape).
- **Serialization covers the commit only, not the fetches** (Codex round 2, accepted; claim scoped in round 3): the guarantee is prize-to-prize serialization. Against OTHER profile writers (run completion, purchases, golden-tile credits) there is no atomicity — the mutex merely stops holding a stale snapshot across slow network fetches, narrowing that pre-existing repo-wide race without closing it. Closing it properly means a storage-level read-modify-write primitive — out of scope here, noted for a future candidate.
- **Emit only on change** (modification of Codex's "preserve emission policy per period"): Codex was right that my always-emit claim was backwards (no `==` override ⇒ every emit rebuilds listeners). Instead of preserving the four inconsistent policies behind a flag, all four emit iff coins or crowns changed — never a spurious rebuild, no per-period flag. Daily/monthly keep their exact behavior; weekly/challenge stop emitting value-identical states, which no test or widget observes.
- **Guard comparison hardened to ≥** (Codex, accepted): one-line change; client-side coins are tamper-able anyway, but refusing obvious clock-rollback replays is free.
- **Guard fields stay four separate profile fields** — collapsing them into a map is a `PlayerProfile`/Hive migration for zero user-visible gain (candidate #5's territory).

## Risks / open questions

- The commit-time reload changes when the profile snapshot is taken (after fetches complete, not before). All tests drive checks sequentially except the new concurrency test, so ordering assumptions in existing tests are unaffected; full suite is the backstop.
- `saveProfile` throwing AFTER the write has landed cannot be distinguished from a clean failure by the caller; the guard's idempotency is what makes the retry safe either way (re-skip if stamped, re-pay-nothing-twice never possible) — pinned by the completed-write-then-throw test.
- Lexical `≥` on `lastWeeklyPrizeDate` compares Mondays to Mondays (always stamped with `weekFrom`) — consistent. `lastDailyPrizeDate`/`lastChallengeCheckDate` are dates, `lastMonthlyPrizeMonth` is `YYYY-MM` — each field only ever compares against its own format.
- `previousUtcDay` is also used by streak-gap analytics (`engagement_cubit.dart:207`); the UTC fix can shift behavior only for users whose local clock crossed DST at the exact boundary — the direction of the change is "correct calendar day," and streak tests pin the honest paths.

## Out of scope

- No storage/`PlayerProfile` schema changes (candidate #5).
- No TS mirror, no season bump — prize economy is client-only and walled off from replay (`lib/domain/constants.dart`).
- No change to payout amounts or period definitions (only the local→UTC correctness fix to their date math).
- No change to `main.dart` call sites or public signatures.
- Streak transition rules themselves (candidate #6) — only the shared `previousUtcDay` helper is touched.
