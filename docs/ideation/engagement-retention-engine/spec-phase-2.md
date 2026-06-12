# Implementation Spec: Engagement & Retention Engine - Phase 2

**Contract**: ./contract.md
**Estimated Effort**: L
**Prereq**: Phase 1 (soft-currency wallet + `coins` on `PlayerProfile`).

## Technical Approach

Phase 2 turns the Phase-1 wallet into a **meta-progression economy**: coins become *spendable* on cosmetics, and two new accumulation systems — a **Merge Almanac** (collection) and a **player level/XP** — give the player a visible sense of "I am building something" across days. This is the accumulation half of the addiction model; Phase 1 supplied the variance half.

The work leans almost entirely on patterns that already exist. Cosmetics already have a clean `CosmeticUnlock` enum + a pure `isUnlocked` predicate + `unlockedCosmetics()` aggregator and an `EngagementCubit` that wires them to `PlayerProfile`. We add one new unlock mode (`purchase`, with a `price`) and a `purchaseCosmetic` method that debits the wallet. The Almanac and level systems are pure derivations over data the game already records (per-tier `bestTier`, cumulative score), persisted as small additions to `PlayerProfile`.

Critically, **none of this touches the leaderboard/replay path** — coins, XP, and collection are all client-side. Extra rewarded-ad surfaces (double-coins-on-completion) reuse `AdService.showRewarded` and the existing hint/freeze surfaces, so no new ad plumbing is required.

## Feedback Strategy

**Inner-loop command**: `flutter test test/domain/ test/application/engagement_cubit_test.dart`

**Playground**: Dart test suite — cosmetics pricing, XP curve, and almanac unlocks are pure functions; the existing `engagement_cubit_test` pattern covers the wiring.

**Why this approach**: The economy correctness (can't overspend, idempotent grants, monotonic XP) is pure logic best pinned by fast unit tests before any UI work.

## File Changes

### New Files

| File Path | Purpose |
| --------- | ------- |
| `lib/domain/models/player_level.dart` | Pure: `levelForXp(int)`, `xpForNextLevel(int)`; XP = cumulative score / k. |
| `lib/domain/models/almanac.dart` | Pure: collection model — per-tier highest reached + mastery badges with progress. |
| `lib/domain/engine/almanac_progress.dart` | Pure: fold per-tier stats + a run into updated almanac entries. |
| `lib/presentation/screens/almanac_screen.dart` | The fillable "book" UI with progress bars. |
| `lib/presentation/widgets/level_badge.dart` | Player level chip (shown on profile + leaderboard rows). |
| `lib/presentation/widgets/price_tag.dart` | Coin price + buy button for cosmetic cards. |
| `test/domain/player_level_test.dart` | XP curve monotonicity + thresholds. |
| `test/domain/almanac_test.dart` | Collection fill + badge unlock logic. |
| `test/application/economy_test.dart` | Purchase debits, overspend rejection, idempotency. |

### Modified Files

| File Path | Changes |
| --------- | ------- |
| `lib/domain/models/cosmetic.dart` | Add `CosmeticUnlock.purchase` + `int price`; extend `isUnlocked` to check a `purchased` set; add 2–3 purchasable themes. |
| `lib/infrastructure/storage_service.dart` | `PlayerProfile`: add `Set<String> purchasedCosmetics`, `int lifetimeXp`, `Map<String,int> almanacCounts` (all migration-free defaults). |
| `lib/application/engagement_cubit.dart` | Add `purchaseCosmetic(Cosmetic)` (debit wallet, record purchase); fold XP + almanac in `onTierCompleted`; expose `level`, `almanac` in state. |
| `lib/application/game_cubit.dart` | On completion, pass run summary (score, highestTier) to the engagement hook for XP + almanac; add optional `onCoinsEarned` for a "double coins" completion reward. |
| `lib/presentation/screens/cosmetics_screen.dart` | Render price tags + buy flow for `purchase` cosmetics; "watch ad to unlock" stays for `rewardedAd` ones. |
| `lib/presentation/screens/score_share_screen.dart` | Show XP gained + level-up celebration; "double coins" rewarded button. |

## Implementation Details

### Earned cosmetics economy

**Pattern to follow**: `lib/domain/models/cosmetic.dart` (pure unlock predicate), `engagement_cubit.dart grantAdCosmetic` (grant→persist→emit).

**Overview**: Add a purchasable unlock mode priced in coins; `purchaseCosmetic` debits the wallet via the profile and records the purchase, then recomputes `unlockedCosmetics`.

```dart
// cosmetic.dart
case CosmeticUnlock.purchase:
  return purchased.contains(this);

// engagement_cubit.dart
Future<bool> purchaseCosmetic(Cosmetic c) async {
  if (c.unlock != CosmeticUnlock.purchase) return false;
  final profile = storage.loadProfile();
  if (profile.coins < c.price) return false;          // can't overspend
  if (profile.purchasedCosmetics.contains(c.name)) return false; // idempotent
  await storage.saveProfile(profile.copyWith(
    coins: profile.coins - c.price,
    purchasedCosmetics: {...profile.purchasedCosmetics, c.name},
  ));
  emit(state.copyWith(unlockedCosmetics: {...state.unlockedCosmetics, c}));
  return true;
}
```

**Key decisions**:
- Purchase is a wallet debit guarded by balance + idempotency — the two ways an economy leaks value.
- Reuse the existing `unlockedCosmetics()` aggregator by threading a `purchased` set through it (mirrors `adUnlocked`).

**Feedback loop**:
- **Playground**: `test/application/economy_test.dart`.
- **Experiment**: buy with exact balance (ok), 1 coin short (reject), buy twice (debited once).
- **Check command**: `flutter test test/application/economy_test.dart`

### Player level / XP

**Overview**: XP accrues from cumulative score; `levelForXp` is a pure curve. Level surfaces on profile + leaderboard rows as flair.

```dart
// player_level.dart
int levelForXp(int xp) { /* e.g. floor(sqrt(xp / kXpPerLevelBase)) */ }
```

**Key decisions**: Derived from already-recorded score so it's tamper-irrelevant (client-side flair only). Monotonic non-decreasing.

**Feedback loop**:
- **Check command**: `flutter test test/domain/player_level_test.dart`

### Merge Almanac (collection)

**Pattern to follow**: `engagement_cubit.dart _buildProgress` (folding per-tier stats).

**Overview**: A book of "highest tile reached, N times" entries with mastery badges (e.g. "reach 2048 five times"). Fills visibly; the completion itch.

**Key decisions**: `almanacCounts` keyed by tier; pure `almanac_progress` folds a finished run into new counts; badges are pure thresholds (same shape as `Achievement.isUnlocked`).

**Feedback loop**:
- **Experiment**: reaching tier 9 thrice flips the tier-9 mastery badge; counts are monotonic.
- **Check command**: `flutter test test/domain/almanac_test.dart`

### Extra rewarded-ad surface: double coins on completion

**Pattern to follow**: `game_cubit.dart grantAdReward` + `ad_service.dart showRewarded`.

**Overview**: On the result screen, offer a rewarded ad to double the coins earned that run (golden + completion coins). Pure bookkeeping; never affects score.

## Data Model

### State Shape (PlayerProfile additions)

```dart
final Set<String> purchasedCosmetics; // default {}
final int lifetimeXp;                 // default 0
final Map<String,int> almanacCounts;  // tier -> times reached, default {}
```

## Testing Requirements

### Unit Tests

| Test File | Coverage |
| --------- | -------- |
| `test/application/economy_test.dart` | Purchase debit, overspend rejection, double-purchase idempotency, double-coins grant. |
| `test/domain/player_level_test.dart` | XP→level monotonicity + thresholds. |
| `test/domain/almanac_test.dart` | Count folding + badge unlocks + migration-free load. |

**Key test cases**:
- Spend more than balance ⇒ rejected, balance unchanged.
- Cumulative score increase never lowers level.
- Almanac counts persist and reload with pre-Phase-2 profiles defaulting cleanly.

### Manual Testing

- [ ] Earn coins, buy a theme, see it selectable; balance debits once.
- [ ] Complete a run, watch ad, coins double; level-up celebration fires at a threshold.
- [ ] Almanac page fills and a mastery badge unlocks.

## Error Handling

| Error Scenario | Handling Strategy |
| -------------- | ----------------- |
| Overspend attempt | `purchaseCosmetic` returns false, no debit, UI shows "not enough coins". |
| Concurrent purchase taps | Idempotency guard on `purchasedCosmetics` prevents double-debit. |
| Pre-Phase-2 profile | New fields default empty/0 in `fromJson`. |

## Failure Modes

| Component | Failure Mode | Trigger | Impact | Mitigation |
| --------- | ------------ | ------- | ------ | ---------- |
| Economy | Negative balance | Race between balance read and debit | Corrupt wallet | Read-check-write inside one `loadProfile`→`saveProfile`; guard `< price`. |
| Almanac | Double-count | Completion hook fires twice | Inflated collection | Reuse the once-per-day completion guard (`lastCompletedDate`). |
| Player level | Non-monotonic | XP curve with rounding dip | Level appears to drop | Curve must be non-decreasing; assert in test. |

## Validation Commands

```bash
flutter analyze
flutter test test/domain/ test/application/
flutter test
```

## Rollout Considerations

- **Feature flag**: none; additive + migration-free.
- **Monitoring**: cosmetic purchase rate, coin sink/earn ratio (watch for runaway inflation).
- **Rollback plan**: additive; reverting leaves profiles readable.

## Open Items

- [ ] Cosmetic prices + `kXpPerLevelBase` + mastery thresholds — tune in playtest (constants).
- [ ] Whether level grants any functional perk or stays pure cosmetic flair (recommend flair-only to protect fairness).

---

_This spec is ready for implementation. Follow the patterns and validate at each step._
