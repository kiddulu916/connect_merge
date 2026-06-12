# Implementation Spec: Engagement & Retention Engine - Phase 1

**Contract**: ./contract.md
**Estimated Effort**: L

## Technical Approach

Phase 1 installs the three foundations every later phase depends on: a **soft-currency wallet**, a **deterministic variable-reward Daily Loot Chest**, and **deterministic golden tiles** — plus the **staggered return moments** and **near-miss framing** that fix the one-and-done retention leak. Nothing here touches the leaderboard/replay path: coins are a purely client-side economy and must never affect `BoardState.score`, the `moveLog`, or anything the Supabase edge function replays. This keeps Phase 2's cheat-resistance fully intact.

The keystone is that **all variable rewards are derived from the daily seed**, mirroring the existing `DailySeeder` design. The loot amount for a given UTC date is `SHA-256("$date:loot")` folded through the existing `DailySeeder.seedForKey` + `Prng` — so it is identical for every player, cheat-proof, and costs $0. Golden tiles are likewise a seed-derived property of specific drop indices, computed in the seeder and carried on the `Tile`. Because the reward variance comes from the seed (not from `Random()`), it slots cleanly into the project's determinism pillar.

Follow the established layering exactly: pure domain logic (loot computation, golden-drop selection, near-miss evaluation) lives in `lib/domain` with zero Flutter imports and is unit-tested directly; cubits wire it to `StorageService` and the UI; `AdService.showRewarded` provides the "double it" surface. The wallet is a new field on the existing `PlayerProfile` record (migration-free default `0`, exactly like `streakFreezeTokens` was added).

## Feedback Strategy

**Inner-loop command**: `flutter test test/domain/`

**Playground**: The Dart test suite — loot/golden/near-miss logic is pure and seed-driven, so a fast `flutter test` against fixed dates is the tightest possible loop. UI (chest open animation, golden tile shimmer) is validated in the running app.

**Why this approach**: Most of the risk is in the determinism + economy math, which is pure domain logic; the existing `test/domain` pattern (feed a fixed date, assert byte-identical output) covers it in milliseconds.

## File Changes

### New Files

| File Path | Purpose |
| --------- | ------- |
| `lib/domain/engine/daily_loot.dart` | Pure: derive the day's loot reward (coins + optional cosmetic shard) from `"$date:loot"` via `seedForKey`. |
| `lib/domain/models/loot_reward.dart` | Immutable value: `{ coins, shardCosmetic? , doubled }`. |
| `lib/domain/engine/near_miss.dart` | Pure: given a finished `BoardState`, return a "1 merge from tier N" message (or null). |
| `lib/application/loot_cubit.dart` | Orchestrates: is today's chest claimable, claim it, double via ad, credit the wallet. |
| `lib/application/loot_state.dart` | `LootSealed \| LootReady \| LootClaimed(reward)`. |
| `lib/presentation/screens/loot_chest_screen.dart` | The chest-open UX (tap to open, reveal, optional "watch ad to double"). |
| `lib/presentation/widgets/coin_balance.dart` | Small wallet-balance pill reused across screens. |
| `test/domain/daily_loot_test.dart` | Determinism + distribution tests for loot. |
| `test/domain/near_miss_test.dart` | Near-miss message correctness + null cases. |
| `test/application/loot_cubit_test.dart` | Claim-once-per-day, double-via-ad, wallet crediting. |

### Modified Files

| File Path | Changes |
| --------- | ------- |
| `lib/infrastructure/storage_service.dart` | Add `int coins` and `String? lastLootClaimDate` to `PlayerProfile` (+ `toJson`/`fromJson`/`copyWith`, migration-free defaults `0`/`null`). |
| `lib/domain/models/tile.dart` | Add `bool golden` (default `false`); update `toJson`/`fromJson` (absent ⇒ false, migration-free). |
| `lib/domain/engine/daily_seeder.dart` | Compute a deterministic `Set<int> goldenDropIndices` from a `"$date:gold"` sub-stream; mark `applyDrop`'d tiles golden when their drop index is in the set. |
| `lib/domain/engine/game_engine.dart` | In `applyDrop`, set `golden: true` when the drop index is golden. Add a pure `int goldenBonusFor(BoardState before, int fromIndex, int toIndex)` helper (coins to credit when a golden tile is consumed in a merge). **Do not** change `score`. |
| `lib/application/game_cubit.dart` | After a successful `merge`, if a golden tile was consumed, credit the wallet via a new `onCoinsEarned(int)` callback (decoupled, like `onTierCompleted`). Pass golden-drop set from the seeder. |
| `lib/infrastructure/notification_service.dart` | Extend `planFor` with two new staggered notifications: **chest-ready** (`kLootReadyId`) and a **midday nudge** (`kMiddayId`), each suppressed once consumed/all-done. |
| `lib/presentation/screens/tier_select_screen.dart` | Surface the Daily Loot Chest entry point + coin balance. |
| `lib/presentation/screens/score_share_screen.dart` | Show the near-miss line on out-of-moves/deadlock. |

## Implementation Details

### Daily Loot Chest (deterministic variable reward)

**Pattern to follow**: `lib/domain/engine/daily_seeder.dart` (seed derivation), `lib/application/engagement_cubit.dart` (cubit↔storage wiring).

**Overview**: Once per UTC day the player opens a chest for a variable coin reward derived from the seed. An optional rewarded ad doubles it. Claim state is a date stamp on `PlayerProfile`.

```dart
// lib/domain/engine/daily_loot.dart
class DailyLoot {
  static LootReward forDate(String date) {
    final p = Prng(DailySeeder.seedForKey('$date:loot'));
    // Variable band: weighted so small rewards are common, jackpots rare.
    final roll = p.nextInt(100);
    final coins = roll < 70 ? 10 + p.nextInt(15)   // common
                : roll < 95 ? 30 + p.nextInt(30)   // uncommon
                            : 100 + p.nextInt(50);  // rare jackpot
    final shard = roll >= 97 ? _shardFor(p) : null; // rare cosmetic shard
    return LootReward(coins: coins, shardCosmetic: shard, doubled: false);
  }
}
```

**Key decisions**:
- Seed-derived, not `Random()` — keeps the determinism pillar and makes it cheat-proof at $0.
- Weighted bands deliver the variable-reward dopamine (mostly small, occasional jackpot) — the psychological core.
- Claim idempotency via `profile.lastLootClaimDate == today` guard (mirrors `_recordCompletion`'s `lastCompletedDate` guard).

**Implementation steps**:
1. Add `LootReward` value object.
2. Implement `DailyLoot.forDate`.
3. `LootCubit.load()` → emit `LootReady` if `lastLootClaimDate != today`, else `LootSealed`.
4. `claim()` → compute reward, set `lastLootClaimDate`, `coins += reward.coins`, persist, emit `LootClaimed`.
5. `doubleWithAd()` → call after `AdService.showRewarded` grants; `coins += reward.coins` again, emit doubled.

**Feedback loop**:
- **Playground**: `test/domain/daily_loot_test.dart` with fixed dates.
- **Experiment**: assert `forDate('2026-06-11')` is byte-identical across 1000 calls; assert reward bands appear at expected frequencies over many dates; assert jackpot is rare.
- **Check command**: `flutter test test/domain/daily_loot_test.dart`

### Golden tiles (in-loop variable reward)

**Pattern to follow**: `lib/domain/engine/game_engine.dart applyDrop` + the two-stream seeding in `daily_seeder.dart`.

**Overview**: A deterministic subset of the day's drops are "golden." Merging a golden tile credits bonus coins. Score and move log are untouched (fairness preserved).

```dart
// daily_seeder.dart — golden indices from an independent sub-stream
Set<int> goldenDropIndices() {
  final g = Prng(seedForKey('$_key:gold'));
  final out = <int>{};
  for (var n = 0; n < kMaxDrops; n++) {
    if (g.nextInt(100) < kGoldenDropPercent) out.add(n); // ~8%
  }
  return out;
}
```

**Key decisions**:
- Golden is a **visual/economy** property on `Tile`, never a scoring property — replay verification (Phase 2) only ever sees tiers + moves, so golden can't be forged for leaderboard gain.
- Bonus credited in the cubit (not the engine) so the pure engine stays side-effect-free; the engine only exposes `goldenBonusFor`.

**Implementation steps**:
1. Add `golden` to `Tile` (+ JSON, default false).
2. Seeder computes `goldenDropIndices`; `applyDrop` stamps golden on matching drop index.
3. `goldenBonusFor` returns coins if `from`/`to` was golden.
4. `GameCubit.merge` calls `onCoinsEarned(goldenBonusFor(...))`.
5. `grid_cell_widget.dart` renders a shimmer/sparkle on golden tiles.

**Feedback loop**:
- **Playground**: `test/domain/daily_seeder_test.dart` (extend existing).
- **Experiment**: same date ⇒ identical golden index set; merging a golden tile yields the expected bonus; `score` unchanged vs. a non-golden control.
- **Check command**: `flutter test test/domain/`

### Staggered return moments (local notifications)

**Pattern to follow**: `lib/infrastructure/notification_service.dart planFor` (pure planning + injectable seams).

**Overview**: Add two staggered nudges to the existing pure `planFor`: a midday "your boards are waiting" and a "loot chest ready" once the chest unlock time passes and is unclaimed. All local, $0.

**Key decisions**:
- Extend the existing pure `planFor` signature with `lootUnclaimed` + a `middayMinutes` slot; keep cancel/replace id discipline (`kLootReadyId`, `kMiddayId`).
- Suppress each when its content is consumed (`allTiersDoneToday`, `lootUnclaimed == false`) — honest nudges, the wholesome-tone requirement.

**Implementation steps**:
1. Add the two ids + entries to `planFor`.
2. Thread `lootUnclaimed` from `LootCubit` into the `reschedule` caller.
3. Unit-test the new suppression rules.

**Feedback loop**:
- **Playground**: `test/infrastructure/notification_service_test.dart` (extend).
- **Experiment**: chest claimed ⇒ no loot-ready notification; all tiers done ⇒ no midday nudge.
- **Check command**: `flutter test test/infrastructure/notification_service_test.dart`

### Near-miss framing

**Overview**: On a finished board, compute the most motivating "so close" line. Pure function over `BoardState`.

```dart
// near_miss.dart
String? nearMissMessage(BoardState s) {
  // e.g. two tier-8s left unmerged at deadlock -> "1 merge from tier 512!"
  // or highest tile one tier below a personal best -> "32 points from your best".
}
```

**Key decisions**: Pure + null when no compelling near-miss exists (don't fabricate pressure — wholesome tone).

**Feedback loop**:
- **Check command**: `flutter test test/domain/near_miss_test.dart`

## Data Model

### State Shape (PlayerProfile additions)

```dart
final int coins;               // default 0, migration-free
final String? lastLootClaimDate; // UTC date of last chest claim
```

`Tile` gains `final bool golden; // default false`.

## Testing Requirements

### Unit Tests

| Test File | Coverage |
| --------- | -------- |
| `test/domain/daily_loot_test.dart` | Determinism, reward bands, jackpot rarity, shard rarity. |
| `test/domain/near_miss_test.dart` | Correct message per board shape; null when none. |
| `test/domain/daily_seeder_test.dart` (extend) | Golden index determinism; golden never alters score. |
| `test/application/loot_cubit_test.dart` | Claim-once-per-day; double-via-ad; wallet credit; resume same day = sealed. |

**Key test cases**:
- Same date ⇒ identical loot + golden set across runs (the determinism acceptance criterion).
- Claiming twice in one UTC day credits once.
- Golden merge credits coins but leaves `score` and `moveLog` identical to a non-golden control.

### Manual Testing

- [ ] Open chest, see reward, watch ad to double, balance updates.
- [ ] Golden tile visibly shimmers; merging it pops a coin gain.
- [ ] Near-miss line appears on a deadlock that was one merge short.

## Error Handling

| Error Scenario | Handling Strategy |
| -------------- | ----------------- |
| Rewarded ad unavailable on "double it" | `onUnavailable` ⇒ keep the single reward, no error surfaced. |
| Profile lacks new fields (pre-Phase-1 install) | `fromJson` defaults `coins=0`, `lastLootClaimDate=null` (migration-free). |
| Clock skew / timezone near UTC midnight | All claim/seed keys use `utcToday()` — never local date. |

## Failure Modes

| Component | Failure Mode | Trigger | Impact | Mitigation |
| --------- | ------------ | ------- | ------ | ---------- |
| LootCubit | Double-claim | App killed mid-claim before persist | Player re-claims same day | Persist `lastLootClaimDate` BEFORE emitting `LootClaimed`; guard on load. |
| DailyLoot | Cross-platform seed drift | Different SHA/fold across SDKs | Players see different loot | Reuse the already-tested `seedForKey`; cover with determinism test. |
| Golden tiles | Fairness leak | Golden mistakenly added to score | Cheaters forge coins → leaderboard | Golden never touches `score`/`moveLog`; assert in test. |
| Notifications | Nudge spam | Reschedule loop re-adds claimed chest | Annoyed user, review backlash | Suppress on `lootUnclaimed == false`; stable ids cancel+replace. |

## Validation Commands

```bash
flutter analyze
flutter test test/domain/
flutter test test/application/loot_cubit_test.dart
flutter test
```

## Rollout Considerations

- **Feature flag**: none needed; additive and migration-free.
- **Monitoring**: watch ad fill rate on the "double it" surface; chest claim rate as the mid-day return proxy.
- **Rollback plan**: features are additive; reverting leaves profiles intact (extra fields ignored).

## Open Items

- [ ] Final loot band weights + `kGoldenDropPercent` — tune in playtest (expose both as constants in `constants.dart`).
- [ ] Exact midday notification time (default 12:00 local, reuse `reminderMinutes` style).

---

_This spec is ready for implementation. Follow the patterns and validate at each step._
