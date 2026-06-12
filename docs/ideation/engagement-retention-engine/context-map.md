# Context Map: engagement-retention-engine

**Phase**: 2
**Scout Confidence**: 90/100
**Verdict**: GO

## Dimensions

| Dimension            | Score | Notes                                                                                                   |
| -------------------- | ----- | ------------------------------------------------------------------------------------------------------- |
| Scope clarity        | 18/20 | All new/modified files identified; constants (prices, kXpPerLevelBase, thresholds) are open tuning items. |
| Pattern familiarity  | 19/20 | Cosmetic unlock predicate, EngagementCubit grant→persist→emit, Achievement badge predicate all read.    |
| Dependency awareness | 18/20 | EngagementState/Cubit consumed by cosmetics_screen + tier_select_screen; PlayerProfile round-trips Hive. |
| Edge case coverage   | 18/20 | Overspend, double-purchase idempotency, XP monotonicity, migration-free load, double-count guard.        |
| Test strategy        | 17/20 | InMemoryStorageService + cubit test pattern established; pure-function tests for level/almanac.          |

## Key Patterns

- `lib/domain/models/cosmetic.dart` — pure `isUnlocked` switch over `CosmeticUnlock`; `unlockedCosmetics()` aggregator threads `adUnlocked`. Add `purchase` case + `price`, thread a `purchased` set.
- `lib/application/engagement_cubit.dart` — `grantAdCosmetic` shows grant→loadProfile→saveProfile(copyWith)→emit. `purchaseCosmetic` mirrors it with a balance+idempotency guard. `_buildProgress` folds per-tier stats (almanac fold model).
- `lib/domain/models/achievement.dart` — `Achievement` enum carries a pure `isUnlocked(PlayerProgress)` predicate; `unlockedFor`/`newlyUnlocked` aggregate. Almanac mastery badges follow this shape (pure threshold over counts).
- `lib/application/game_cubit.dart` — `onCoinsEarned(int)` decoupled callback (golden coins, never score); `onTierCompleted()` fired once per locked day. Extend the completion path to pass run summary (score/highestTier).
- `lib/application/loot_cubit.dart` — read-check-write inside one loadProfile→saveProfile guards against double-credit; matches the economy debit pattern.

## Dependencies

- `lib/infrastructure/storage_service.dart` PlayerProfile — round-tripped by `hive_storage_service.dart:67-80` via toJson/fromJson. New fields MUST be in toJson + copyWith + fromJson (migration-free defaults).
- `lib/application/engagement_cubit.dart` EngagementState — consumed by `cosmetics_screen.dart` (unlockedCosmetics, selectedCosmetic) and `tier_select_screen.dart` (state.unlocked, selectedCosmetic).
- `lib/application/game_cubit.dart` GameCubit ctor — constructed in `tier_select_screen.dart:238` with onTierCompleted/onCoinsEarned. Adding optional named params is backward compatible.
- `cosmetic.dart` `unlockedCosmetics()` — called in engagement_cubit `load`, `onTierCompleted`. Signature change (add `purchased`) must update both call sites.

## Conventions

- **Naming**: snake_case files; enum `name` is the stable storage token (never localized); `kXxx` constants in `domain/constants.dart`.
- **Imports**: relative within lib; tests import via `package:merge_count/...`.
- **Error handling**: completion/coins hooks are best-effort (try/catch swallow in game_cubit); economy guards return `bool` (false on reject), never throw.
- **Types**: pure domain models are flutter-free (colors stored as int ARGB). Cubits wire domain→storage→emit.
- **Testing**: `test/{domain,application}/...`; `InMemoryStorageService` fake; pure functions tested directly; cubits via `make()..load()` + `todayProvider` injection.

## Risks

- HARD INVARIANT: coins/XP/almanac are client-side only — must never touch `BoardState.score` or `moveLog`. XP derives from already-recorded cumulative score (tamper-irrelevant).
- Economy value leak: guard `balance < price` (overspend) AND `purchasedCosmetics.contains` (idempotency) inside one read-check-write.
- XP curve must be monotonic non-decreasing (rounding dip would make level appear to drop) — assert in test.
- Almanac double-count: completion hook can fire twice; reuse the once-per-day completion guard (lastCompletedDate / GameCubit `_completionFired`).
- Migration-free: new PlayerProfile fields default empty/0 in fromJson; pre-Phase-2 profiles must load cleanly.
- `unlockedCosmetics()` signature change touches 2 call sites in engagement_cubit — keep them in sync.
