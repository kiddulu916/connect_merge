# Implementation Spec: Engagement & Retention Engine - Phase 5 (GATED)

**Contract**: ./contract.md
**Estimated Effort**: XL
**Prereq**: Phases 1, 2, 3 shipped AND the Phase-5 decision gate passed.

> ## ⚠️ Decision Gate — do not build until cleared
> Endless Climb is the one feature that risks diluting the clean daily-ritual identity, and it is the largest build here. **Build it only if Phase 1–3 daily-retention metrics justify an always-available second loop.** Concretely, clear the gate only if, after Phases 1–3 are live for ~2–4 weeks:
> - D1/D7 retention improved but **session frequency is still ~once/day** (i.e. players want more but the daily content is exhausted), AND
> - the coin economy has healthy demand (cosmetics being bought, ad-doubles taken) — proving a sink exists for an endless-mode faucet.
>
> If instead retention is flat, fix the daily loop first. If players already return multiple times/day, you may not need this. This spec exists so that, *if* the gate clears, execution is immediate.

## Technical Approach

Endless Climb is the **always-available loop**: a non-daily, replayable roguelike-flavored mode the player can open anytime to chase a personal endless high score and **earn coins** for the Phase 2 economy. It answers "there's nothing left to do today" without touching the daily competitive integrity — endless runs are explicitly **off the global leaderboard** and never feed replay-verified scores.

It reuses the entire pure engine (`GameEngine.merge/applyDrop/evaluateStatus`) unchanged; only the *seeding* and *progression* differ. Where the daily mode seeds from `"$date:difficulty"`, endless seeds each run from a fresh per-run key (the existing `practice_seeder.dart` is the starting point), and instead of a fixed 30-move budget it uses an escalating structure (e.g. move refills on reaching tier milestones, gradually widening drop caps) so a skilled run lasts longer. A run ends on deadlock or exhausted budget; the player banks coins proportional to depth reached.

The meta-progression sink is the key design constraint: endless must **earn** coins (a faucet) without **inflating** the economy — so the coin yield curve is tuned against Phase 2 prices, and endless grants **no** leaderboard/XP-for-rank advantages. It is a pure time-sink + cosmetic-funding loop, deliberately walled off from the competitive systems.

## Feedback Strategy

**Inner-loop command**: `flutter test test/application/endless_cubit_test.dart`

**Playground**: Dart test suite for run lifecycle + coin-yield math; the running app for the endless-mode feel (escalation pacing).

**Why this approach**: The economy-balance risk (coin faucet vs Phase 2 sink) is pure math and must be pinned before tuning feel in-app.

## File Changes

### New Files

| File Path | Purpose |
| --------- | ------- |
| `lib/domain/engine/endless_seeder.dart` | Per-run seeding + escalating drop-cap / move-refill schedule (built on `practice_seeder.dart`). |
| `lib/domain/engine/endless_rules.dart` | Pure: milestone move-refills, run-end conditions, coin yield for a finished run. |
| `lib/application/endless_cubit.dart` | Run lifecycle: start, merge (reuse `GameEngine`), bank coins on end, track personal best. |
| `lib/application/endless_state.dart` | `EndlessIdle \| EndlessPlaying \| EndlessOver(depth, coins)`. |
| `lib/presentation/screens/endless_screen.dart` | The endless-mode board + depth/score HUD + "bank & exit". |
| `test/domain/endless_rules_test.dart` | Refill thresholds, end conditions, coin-yield curve. |
| `test/application/endless_cubit_test.dart` | Run lifecycle, best-score persistence, coin banking, off-leaderboard guarantee. |

### Modified Files

| File Path | Changes |
| --------- | ------- |
| `lib/infrastructure/storage_service.dart` | `PlayerProfile`: add `int endlessBestDepth`, `int endlessBestScore` (migration-free). |
| `lib/domain/constants.dart` | Add endless constants: `kEndlessStartMoves`, refill schedule, `kEndlessCoinPerTier`. |
| `lib/presentation/screens/tier_select_screen.dart` | Add the Endless Climb entry point + personal best. |

## Implementation Details

### Endless seeding + escalation

**Pattern to follow**: `lib/infrastructure/practice_seeder.dart` and `lib/domain/engine/daily_seeder.dart` (PRNG streams), `lib/domain/engine/game_engine.dart` (reused unchanged).

**Overview**: Each run gets a fresh seed; drop caps widen and moves refill at tier milestones so the run self-extends with skill. The board engine is the existing pure one.

```dart
// endless_rules.dart
int movesAfterMilestone(int reachedTier) => /* +k moves each new milestone */;
bool isRunOver(BoardState s) => s.movesRemaining <= 0 || !GameEngine.hasMergeAvailable(s);
int coinYield(int depthTier, int score) => /* tuned vs Phase 2 prices */;
```

**Key decisions**:
- Reuse `GameEngine` verbatim — endless differs only in seeding + budget rules, not merge mechanics.
- Coin yield curve is the economy lever; keep it conservative so endless funds cosmetics over many runs, not in one (anti-inflation).
- Endless writes **only** to `endlessBest*` + coins — never to `LifetimeStats`, the leaderboard, or XP-for-rank.

**Feedback loop**:
- **Playground**: `test/domain/endless_rules_test.dart`.
- **Experiment**: same run seed ⇒ identical board sequence; coin yield is monotonic in depth; a deep run can't out-earn N daily completions (balance check).
- **Check command**: `flutter test test/domain/endless_rules_test.dart`

### Endless cubit

**Pattern to follow**: `lib/application/game_cubit.dart` (engine orchestration), `lib/application/loot_cubit.dart` (coin crediting from Phase 1).

**Overview**: Start a run, drive merges through `GameEngine`, on end bank coins via the wallet and update personal best.

**Key decisions**: No `onSubmitRun`/`onTierCompleted` wiring — endless is intentionally disconnected from the competitive + streak systems.

**Feedback loop**:
- **Experiment**: finishing a run credits exactly `coinYield`; best score only increases; restarting mid-run forfeits unbanked coins as designed.
- **Check command**: `flutter test test/application/endless_cubit_test.dart`

## Data Model

### State Shape (PlayerProfile additions)

```dart
final int endlessBestDepth; // default 0
final int endlessBestScore; // default 0
```

## Testing Requirements

### Unit Tests

| Test File | Coverage |
| --------- | -------- |
| `test/domain/endless_rules_test.dart` | Refill thresholds, end conditions, coin-yield monotonicity + balance ceiling. |
| `test/application/endless_cubit_test.dart` | Lifecycle, best persistence, coin banking, NO leaderboard/streak writes. |

**Key test cases**:
- Endless never calls submit/leaderboard/streak hooks (assert via spy fakes).
- Coin yield for a max realistic run stays within the anti-inflation ceiling.
- Personal best is monotonic.

### Manual Testing

- [ ] Endless run feels escalating and ends fairly on deadlock/budget.
- [ ] Banked coins appear in the wallet and can buy cosmetics.
- [ ] Endless does not appear on any global leaderboard.

## Error Handling

| Error Scenario | Handling Strategy |
| -------------- | ----------------- |
| App killed mid-run | Unbanked run is forfeited (by design); no partial coins. |
| Coin overflow | Clamp yield to the per-run ceiling constant. |

## Failure Modes

| Component | Failure Mode | Trigger | Impact | Mitigation |
| --------- | ------------ | ------- | ------ | ---------- |
| Economy | Coin inflation | Yield curve too generous | Cosmetics trivially bought, economy dead | Tune `kEndlessCoinPerTier` against Phase 2 prices; ceiling + balance test. |
| Identity | Daily dilution | Endless overshadows daily ritual | Brand erosion | Keep endless off leaderboards/streaks; position as a secondary, optional loop. |
| Engine reuse | Budget rule leak | Endless rules mutate shared constants | Daily mode affected | Endless constants are separate; engine functions stay pure/unchanged. |

## Validation Commands

```bash
flutter analyze
flutter test test/domain/endless_rules_test.dart
flutter test test/application/endless_cubit_test.dart
flutter test
```

## Rollout Considerations

- **Feature flag**: ship behind a flag so it can be enabled only after the gate clears and A/B'd against daily-only.
- **Monitoring**: endless session count vs daily; coin faucet/sink ratio; effect on daily completion rate (must NOT drop).
- **Rollback plan**: flag off; profile fields ignored.

## Open Items

- [ ] Full escalation schedule + `kEndlessCoinPerTier` (tune only after the gate clears, against live Phase 2 economy data).
- [ ] Whether endless gets its own cosmetic unlocks or shares the daily pool (recommend shared, to reinforce one economy).

---

_This spec is GATED. Do not begin until Phase 1–3 metrics clear the decision gate above._
