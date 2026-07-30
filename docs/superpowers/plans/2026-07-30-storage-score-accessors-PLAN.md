# Plan: `StorageService.scoreFor` / `isCompletedFor` — stop the UI reaching into GameSnapshot
_Locked via grill — by Claude + kiddulu916_

## Goal
`TierSelectScreen` dereferences `storage.loadSnapshot(date, tier)?.board.score` (3×: `:297`, `:453`, `:608`) and `?.completed` (`:341`), making `GameSnapshot`'s internal shape load-bearing in the presentation layer, and reading "my score for a tier today" in three places. Add two concrete accessors on `StorageService` so the widget asks for a score / completion, not a snapshot shape. Behavior-preserving; client-only.

## Approach
1. **First make concrete inheritance possible (Codex R1 blocker):** both `HiveStorageService` (`hive_storage_service.dart:12`) and `InMemoryStorageService` (`storage_service.dart:236`) currently declare `implements StorageService`, which inherits NO concrete bodies. Change BOTH to `extends StorageService`. This is safe: neither has another superclass or a conflicting constructor, `StorageService` is an abstract class with only abstract members (so an implicit default super-constructor), both already define every abstract member (those become overrides), and they are the ONLY implementers (test fakes `extends InMemoryStorageService`). Behavior-preserving — they simply now ALSO inherit the two new concrete accessors.
2. Add two CONCRETE methods to the abstract `StorageService` class (`lib/infrastructure/storage_service.dart`, near the `loadSnapshot` declaration ~`:204`). They delegate to the abstract `loadSnapshot`, so they are written ONCE and (after step 1) inherited by both implementations — no per-impl duplication:
   ```dart
   /// Score in the persisted snapshot for [date]/[difficulty], or null if there
   /// is no snapshot yet. Callers apply their own default (some want 0, some
   /// need to distinguish "not played" from a real score of 0).
   int? scoreFor(String date, Difficulty difficulty) =>
       loadSnapshot(date, difficulty)?.board.score;

   /// Whether the run for [date]/[difficulty] is completed (false if no snapshot).
   bool isCompletedFor(String date, Difficulty difficulty) =>
       loadSnapshot(date, difficulty)?.completed ?? false;
   ```
3. Replace the four reads in `lib/presentation/screens/tier_select_screen.dart`, preserving each caller's existing default EXACTLY:
   - `:297` `...loadSnapshot(widget.today(), tier)?.board.score ?? 0` → `widget.storage.scoreFor(widget.today(), tier) ?? 0`.
   - `:453` `final score = ...loadSnapshot(today, difficulty)?.board.score;` → `final score = widget.storage.scoreFor(today, difficulty);` (stays `int?`; the following `if (score == null) return;` is unchanged — this is WHY `scoreFor` returns nullable, not 0).
   - `:608` `...loadSnapshot(widget.today(), tier)?.board.score ?? 0` → `widget.storage.scoreFor(widget.today(), tier) ?? 0`.
   - `:341` `_isCompleted` body `return widget.storage.loadSnapshot(today, d)?.completed ?? false;` → `return widget.storage.isCompletedFor(today, d);`.
4. Leave every OTHER `loadSnapshot` caller alone — `game_cubit.dart:244` reads the full snapshot for game resume (a legitimate whole-snapshot use, not a shape leak); `redeem_coordinator` uses an unrelated snapshot.
5. Tests: add to `test/infrastructure/in_memory_storage_test.dart` (or `storage_ownership_test.dart`) — save a `GameSnapshot` with a known `board.score` and `completed`, assert `scoreFor` returns that score and `isCompletedFor` returns the flag; for an absent `(date, difficulty)` assert `scoreFor == null` and `isCompletedFor == false`. Existing `tier_select_screen_test.dart` (rival nudge, duel settle) is the behavior-preserving guard for the widget.
6. Proof: `flutter test test/infrastructure/in_memory_storage_test.dart test/infrastructure/storage_ownership_test.dart test/presentation/tier_select_screen_test.dart`, then `flutter test test/infrastructure/ test/presentation/`. All green.
7. Commit.

## Key decisions & tradeoffs
- **Accessors are concrete on the abstract `StorageService` class, not new abstract methods — which requires the impls to `extends` (not `implements`) it (Codex R1 blocker).** `implements` inherits no bodies; switching both impls to `extends` (safe — see step 1) lets them inherit the two concrete accessors, so the logic exists once and there is no interface-surface growth a subclass must reimplement, and no Hive/InMemory duplication.
- **`scoreFor` returns `int?`, not `int`.** Caller `:453` distinguishes "no snapshot" (`null` → return, no duel settle) from a real score of 0; returning 0 for absent would silently settle a duel against an unplayed run. Callers `:297`/`:608` keep their `?? 0`.
- **Scope is the accessor extraction only.** The rival-overtake / duel-settle ORCHESTRATION stays in the widget's lifecycle handlers (it is triggered by app-open / tier-complete, a reasonable place); moving it into an application coordinator was considered and deferred as speculative.
- **Behavior-preserving.** Each call site keeps its exact default/null handling; the accessors are pure delegations to `loadSnapshot`. Existing `tier_select_screen_test` pins the widget flows.

## Risks / open questions
- The only behavior-sensitive site is `:453` (null vs 0) — preserved by the nullable return + unchanged `if (score == null) return`.
- No `StorageService` interface (abstract-method) change → no impact on the `InMemoryStorageService` fake beyond inheriting the concrete accessors; test constructs remain valid.

## Out of scope
- The rival/duel orchestration coordinator (deferred, speculative).
- `game_cubit`'s full-snapshot `loadSnapshot` read (legitimate).
- Any change to `GameSnapshot`, `BoardState`, or `loadSnapshot` itself.
- Server/edge; no TS mirror.
