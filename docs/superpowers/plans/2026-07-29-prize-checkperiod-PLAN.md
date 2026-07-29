# Plan: Extract `_checkPeriod` — one prize-payout skeleton, not four copies
_Locked via grill — by Claude + kiddulu916_

## Goal
`prize_checking_mixin.dart`'s daily / weekly / monthly / challenge checks are four near-parallel methods that each re-implement the same subtle per-period skeleton: load profile → re-check the guard under the serialize-lock → best qualifying rank → coins → award → save → emit → reload guard → advance-or-break. A bug in that guard/advance/idempotency interaction currently has four places to hide. Extract the skeleton into ONE private `_checkPeriod`; reduce the four public methods to thin config (period keys + closures). Behavior-preserving; client-only (prize coins/crowns are walled off from `BoardState.score` and the move log, so nothing here is mirrored to the TS engine).

## Approach
1. Add a private method to `PrizeCheckingMixin`:
   ```dart
   Future<void> _checkPeriod({
     required List<String> periodKeys,
     required Future<Map<Difficulty, int>?> Function(String key) ranksFor, // null => break
     required String? Function(PlayerProfile) guardOf,
     required int Function(int rank) coinsFor,
     required PlayerProfile Function(
       PlayerProfile profile, String key, int coins, Map<Difficulty, int> ranks) award,
     required bool syncWeeklyPrizes, // weekly => true; the other three => false
   }) async {
     for (final key in periodKeys) {
       final ranks = await ranksFor(key);
       if (ranks == null) break;
       await serializedPrizeCommit(() async {
         final profile = storage.loadProfile();
         final storedGuard = guardOf(profile);
         if (storedGuard != null && storedGuard.compareTo(key) >= 0) return;
         final bestRank = _bestQualifyingRank(ranks, coinsFor);
         final coins = bestRank == null ? 0 : coinsFor(bestRank);
         final updated = award(profile, key, coins, ranks);
         await storage.saveProfile(updated);
         // Preserve each path's ORIGINAL emit exactly (Codex R1 #1: the
         // persisted profile's weeklyPrizes is NOT guaranteed == state's, so
         // always passing weeklyPrizes on the coins-only paths could fire an
         // extra emit or swap an equal list for a new instance).
         if (syncWeeklyPrizes) {
           if (updated.wallet.coins != state.coins ||
               !_sameWeeklyPrizes(updated.prizes.weeklyPrizes, state.weeklyPrizes)) {
             emit(state.copyWith(
               coins: updated.wallet.coins,
               weeklyPrizes: updated.prizes.weeklyPrizes,
             ));
           }
         } else {
           if (updated.wallet.coins != state.coins) {
             emit(state.copyWith(coins: updated.wallet.coins));
           }
         }
       });
       final committed = guardOf(storage.loadProfile());
       if (committed == null || committed.compareTo(key) < 0) break;
     }
   }
   ```
   The body is lifted VERBATIM from the current methods — same guard re-check (`storedGuard != null && >= key`), same emit condition, same advance-or-break (`committed == null || < key`).
2. Add three tiny filter/build helpers, lifted verbatim from the current inline code:
   - `Map<Difficulty, int> _nonChallengeRanks(Map<Difficulty, int>? inner)` — `{ for e in (inner ?? {}) where e.key != Difficulty.challenge }`.
   - `Map<Difficulty, int> _challengeOnlyRanks(Map<Difficulty, int>? inner)` — `inner?[Difficulty.challenge]` present → `{Difficulty.challenge: rank}`, else `{}`.
   - `List<WeeklyPrize> _weeklyCrowns(Map<Difficulty, int> ranks, String weekFrom)` — the current `ranks.entries.where(_weeklyCoinsFor > 0).map(WeeklyPrize(weekStart: weekFrom, tier, rank)).toList()`.
3. Rewrite `checkDailyPrizes` (thin): compute `yesterday`, `guard = ...lastDailyPrizeDate`, `dates = _boundedDateKeys(guard, yesterday, stepDays: 1, limit: 7)`; `if (dates.isEmpty) return;`; batch-fetch `ranksByDate` in a `try/catch → onErrorHook → return`; then
   `await _checkPeriod(periodKeys: dates, ranksFor: (d) async => _nonChallengeRanks(ranksByDate[d]), guardOf: (p) => p.prizes.lastDailyPrizeDate, coinsFor: _dailyCoinsFor, award: (p, k, c, _) => p.awardDailyPrize(k, awardCoins: c), syncWeeklyPrizes: false);`
   — daily's `ranksFor` NEVER returns null (an absent date yields an empty map → `_bestQualifyingRank` null → coins 0 → `awardDailyPrize` still stamps the guard, exactly as today). Only the upfront batch-fetch failure short-circuits, before `_checkPeriod`.
4. Rewrite `checkWeeklyPrizes` (thin): `latestWeek = _prevWeekMonday(...)`, `guard = ...lastWeeklyPrizeDate`, `weeks = _boundedDateKeys(guard, latestWeek, stepDays: 7, limit: 4)`; then
   `await _checkPeriod(periodKeys: weeks, ranksFor: (weekFrom) async { final weekTo = _weekSunday(weekFrom); final Map<Difficulty, int> fetched; try { fetched = await fetchRanks(from: weekFrom, to: weekTo); } catch (e, s) { onErrorHook?.call(e, s); return null; } return _nonChallengeRanks(fetched); }, guardOf: (p) => p.prizes.lastWeeklyPrizeDate, coinsFor: _weeklyCoinsFor, award: (p, k, c, ranks) => p.awardWeeklyPrize(k, awardCoins: c, crowns: _weeklyCrowns(ranks, k)), syncWeeklyPrizes: true);`
   — the `try` wraps ONLY `fetchRanks` (matching the current code); `_nonChallengeRanks` runs AFTER the catch so a filter-time throw propagates as today rather than being swallowed into a break (Codex R1 #2).
5. Rewrite `checkMonthlyPrizes` (thin): `latestMonth = _lastMonthKey(...)`, `guard = ...lastMonthlyPrizeMonth`, `months = _boundedMonthKeys(guard, latestMonth)`; then
   `await _checkPeriod(periodKeys: months, ranksFor: (monthKey) async { final Map<Difficulty, int> fetched; try { fetched = await fetchRanks(from: _firstOfMonth(monthKey), to: _lastOfMonth(monthKey)); } catch (e, s) { onErrorHook?.call(e, s); return null; } return _nonChallengeRanks(fetched); }, guardOf: (p) => p.prizes.lastMonthlyPrizeMonth, coinsFor: _monthlyCoinsFor, award: (p, k, c, _) => p.awardMonthlyPrize(k, awardCoins: c), syncWeeklyPrizes: false);`
   — same `try`-wraps-only-`fetchRanks` structure as weekly (Codex R1 #2).
6. Rewrite `checkChallengePayouts` (thin): like daily but challenge-only + `awardChallengeCheck`: `dates = _boundedDateKeys(guard(lastChallengeCheckDate), yesterday, 1, 7)`; `if (dates.isEmpty) return;`; batch-fetch `ranksByDate` `try/catch → onErrorHook → return`; then
   `await _checkPeriod(periodKeys: dates, ranksFor: (d) async => _challengeOnlyRanks(ranksByDate[d]), guardOf: (p) => p.prizes.lastChallengeCheckDate, coinsFor: _challengeCoinsFor, award: (p, k, c, _) => p.awardChallengeCheck(k, awardCoins: c), syncWeeklyPrizes: false);`
7. Delete the now-inlined loop bodies from the four methods; keep the `_bounded*Keys`, `_weekSunday`, `_prevWeekMonday`, `_lastMonthKey`, `_firstOfMonth`, `_lastOfMonth`, coin tables, `_bestQualifyingRank`, `_sameWeeklyPrizes`, and `serializedPrizeCommit` exactly as they are.
8. **Add absent-date coverage FIRST, against the CURRENT code (Codex R1 #3).** The existing daily/challenge tests use a date present with a NON-qualifying rank, not a date entirely absent from the batch map — so the "absent date still stamps the guard at coins 0 and advances" behavior this refactor relies on is currently UNPINNED. Add to `daily_prize_test.dart` and `challenge_payout_test.dart` a case where `fetchRanks` returns a batch map with the target date absent (e.g. `{}`), and assert: coins unchanged (zero award), the guard (`lastDailyPrizeDate` / `lastChallengeCheckDate`) is stamped to that date, and the loop advanced. Run these against the pre-refactor code so they pass first (they pin existing behavior).
9. Proof: `flutter test test/application/daily_prize_test.dart test/application/weekly_prize_test.dart test/application/monthly_prize_test.dart test/application/challenge_payout_test.dart test/application/engagement_test.dart`, then full `flutter test`. All green; behavior unchanged.
10. Commit.

## Key decisions & tradeoffs
- **Extract the skeleton; keep the four `award*` methods.** The skeleton (serialize-commit idempotency + advance-or-break + triple guard read) is the subtle, bug-prone part — deleting the four copies concentrates real complexity in one place (deletion test passes). The `award*` methods are four thin `copyWith` deltas over DISTINCT named `PrizeLedger` fields (`lastDailyPrizeDate` / `lastWeeklyPrizeDate` / `lastMonthlyPrizeMonth` / `lastChallengeCheckDate`); collapsing them needs field-name indirection Dart doesn't do cleanly and is tested separately (`profile_write_helpers_test`). Left untouched.
- **`ranksFor(key) -> Map?` closure, `null` = break — the seam that unifies TWO fetch shapes.** Daily/challenge batch-fetch once (fetch fails → do nothing) and their `ranksFor` just indexes the pre-fetched map (never null). Weekly/monthly fetch per-period inside `ranksFor` (fetch fails → return null → `_checkPeriod` breaks). Both failure semantics preserved exactly, because the fetch strategy stays in the callers.
- **Daily/challenge `ranksFor` never returns null.** An absent date → empty ranks map → coins 0 → the award STILL stamps the guard and the loop advances. This "stamp even empty days" behavior is load-bearing (it's how the daily/challenge guard walks forward past days with no qualifying finish) and is preserved by never returning null for a missing date.
- **Emit is NOT unified — each path keeps its exact original emit, selected by `syncWeeklyPrizes` (Codex R1 #1).** Weekly emits `copyWith(coins, weeklyPrizes)` under the coins-or-crowns check; the other three emit `copyWith(coins)` under the coins-only check. Always passing `weeklyPrizes` was rejected: `state.weeklyPrizes` is not guaranteed to equal the persisted profile's `weeklyPrizes` at a coins-only commit, so it could fire an extra emit or swap an equal list for a fresh Hive-deserialized instance. The `bool syncWeeklyPrizes` flag keeps the emit inside `_checkPeriod` while preserving both behaviors verbatim.
- **`try` wraps only `fetchRanks`, never the filter (Codex R1 #2).** Weekly/monthly assign the fetched map inside `try/catch` (catch → `onErrorHook` → `return null` → break) and call `_nonChallengeRanks` AFTER the catch, matching the current code where a filter-time throw propagates rather than being swallowed into a break.
- **Keep the three guard reads verbatim.** Consolidating four copies into one skeleton already cuts read-sites 12→3. Eliminating the post-commit reload would change the concurrency reasoning; not done here.

## Risks / open questions
- **Daily/challenge "empty/absent date still stamps guard and advances"** must survive — captured by `ranksFor` returning a non-null empty map (never break) + `awardDailyPrize`/`awardChallengeCheck` stamping on coins 0. This is currently UNPINNED (existing tests use a non-qualifying rank, not an absent date); Approach step 8 adds the pinning tests against the pre-refactor code first (Codex R1 #3).
- **Weekly/monthly break on the FIRST period fetch error** (vs daily's "batch fails → return nothing") — preserved by where the fetch lives (per-period closure returning null vs upfront pre-fetch returning early). `weekly_prize_test` pins the break.
- **`_checkPeriod` is private to the mixin** — no interface/API change; the four public method signatures are unchanged, so `main.dart:420-423` callers are untouched.
- The closure-per-call allocation (4 closures per invocation) is negligible vs the network fetch and storage I/O each check already does.

## Out of scope
- The four `award*` methods and `PrizeLedger` (untouched).
- Reducing the triple guard-read (optional follow-up).
- The `_bounded*Keys` and period-math helpers (unchanged).
- Server/edge; no TS mirror (cosmetic/economy is walled off from `BoardState.score` per CLAUDE.md).
