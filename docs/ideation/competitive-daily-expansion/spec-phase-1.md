# Implementation Spec: Competitive Daily Expansion - Phase 1

**Contract**: ./contract.md
**Estimated Effort**: M

## Technical Approach

Phase 1 is **client-only, no backend**. It does three things: (1) fixes the release-blocking iOS AdMob App ID, (2) turns the single daily puzzle into four difficulty tiers — each its own deterministic daily board, playable once per UTC day, and (3) switches seeding from the player's local date to the UTC date so a later global leaderboard is fair. It also adds **move-sequence recording**, which is unused in Phase 1 but is the required input for Phase 2's server-side replay verification — recording it now (and testing it now) means Phase 2 only has to consume an already-trusted log.

The guiding principle is to preserve the engine's purity. `GameEngine` and `DailySeeder` stay pure; difficulty enters as a parameter (`Difficulty`) threaded through seeding and constants, not as global mutable state. The seed key becomes `"$utcDate:${difficulty.name}"` hashed with the existing SHA256 path, so each tier is a fully independent deterministic stream that still reuses the proven `Prng` (Mulberry32). Snapshots and lifetime stats become keyed by `(date, difficulty)` instead of a single slot, which is the only storage-shape change.

Key decisions: tile-count is the **only** difficulty lever (move budget stays 30 for all tiers); difficulty is chosen on a new tier-select screen before play; the move log is an ordered event stream (merge events + ad-continue events) so a replay can reconstruct exactly how the run unfolded.

## Feedback Strategy

**Inner-loop command**: `flutter test test/domain/engine/daily_seeder_test.dart`

**Playground**: The existing `flutter test` suite. The game's logic is pure and already has strong test coverage (`test/domain/engine/*`), so tests are the tightest loop. The tier-select UI is verified with a widget test plus a manual `flutter run` pass.

**Why this approach**: Almost all Phase 1 changes are to pure seeding/engine/storage logic, which a scoped test runner validates in well under a second; only the tier-select screen needs a visual check.

> **Environment note**: This machine is analyze/test only (no Android/iOS device toolchain — see project memory). All logic is validated via `flutter test`/`flutter analyze`. The iOS App ID fix and on-device ad serving must be verified on a real build by the user.

## File Changes

### New Files

| File Path | Purpose |
| --------- | ------- |
| `lib/domain/models/difficulty.dart` | `Difficulty` enum (easy/medium/hard/legendary) with `startingFill` (10/8/6/4) and `label`. |
| `lib/domain/models/move.dart` | `MoveEvent` model: an ordered merge (`from`,`to`) or ad-continue marker, with `toJson`/`fromJson`. |
| `lib/presentation/screens/tier_select_screen.dart` | Tier picker shown before play; shows which tiers are already completed today + local reset countdown. |
| `test/domain/models/difficulty_test.dart` | Asserts tile counts 10/8/6/4 and label mapping. |
| `test/domain/models/move_test.dart` | Round-trip JSON for `MoveEvent`. |
| `test/presentation/tier_select_screen_test.dart` | Renders four tiers; tapping one routes to the game with that difficulty. |

### Modified Files

| File Path | Changes |
| --------- | ------- |
| `ios/Runner/Info.plist` | Replace test `GADApplicationIdentifier` (`ca-app-pub-3940256099942544~1458002511`) with the real iOS App ID. **Value must be supplied by the user (see Open Items).** |
| `lib/domain/constants.dart` | Remove the single `kStartingFill`; add `startingFillFor(Difficulty)` (or move onto the enum). Keep all other constants. |
| `lib/domain/engine/daily_seeder.dart` | `DailySeeder(date, difficulty)`; seed key = `"$date:${difficulty.name}"`; use `difficulty.startingFill` for placement count. |
| `lib/application/game_cubit.dart` | `init({required Difficulty difficulty})`; `_date` from **UTC** (`DateTime.now().toUtc()`); load/save snapshot + stats keyed by `(date, difficulty)`; block replay when today's `(date,difficulty)` is completed; append a `MoveEvent` to the log on each `merge` and `grantAdReward`. |
| `lib/application/game_state.dart` | Carry `difficulty` (and the move log if stored on state) through states for the result screen. |
| `lib/domain/models/board_state.dart` | Add `List<MoveEvent> moveLog` (default empty) + serialize it; `merge`/`applyDrop` unaffected, log appended in the cubit. |
| `lib/infrastructure/storage_service.dart` | Snapshot/stats APIs keyed by `(date, difficulty)`; `GameSnapshot` gains `difficulty`; `LifetimeStats` becomes per-tier (a map keyed by difficulty) OR add per-tier streak/best fields. |
| `lib/infrastructure/hive_storage_service.dart` | Implement the new keyed storage (Hive box key = `"$date:$difficulty"`). |
| `lib/main.dart` | Launch into `TierSelectScreen`; pass selected `Difficulty` into `GameCubit`. |
| `lib/presentation/screens/game_screen.dart` | Accept/display the active difficulty; show local reset countdown. |

## Implementation Details

### Difficulty model

**Overview**: A small enum that encodes the only difficulty lever (starting tile count).

```dart
enum Difficulty {
  easy(startingFill: 10, label: 'Easy'),
  medium(startingFill: 8, label: 'Medium'),
  hard(startingFill: 6, label: 'Hard'),
  legendary(startingFill: 4, label: 'Legendary');

  const Difficulty({required this.startingFill, required this.label});
  final int startingFill;
  final String label;
}
```

**Key decisions**:
- `startingFill` lives on the enum so seeding and UI share one source of truth.
- `name` (`easy`/`medium`/...) is the stable seed-key token — never localize it.

**Feedback loop**: skip (pure enum; covered by `difficulty_test.dart` + typecheck).

### UTC + per-tier deterministic seeding

**Pattern to follow**: existing `lib/domain/engine/daily_seeder.dart` (keep the two-stream A/B design).

**Overview**: The board + drop schedule become a function of `(utcDate, difficulty)`; the engine and PRNG are unchanged.

```dart
class DailySeeder {
  final String date;          // UTC YYYY-MM-DD
  final Difficulty difficulty;
  const DailySeeder(this.date, this.difficulty);

  static int seedForKey(String key) {
    final bytes = sha256.convert(utf8.encode(key)).bytes;
    return (bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24)) & 0xFFFFFFFF;
  }

  String get _key => '$date:${difficulty.name}';
  int get _seedA => seedForKey(_key);
  int get _seedB => seedForKey(_key) ^ 0x9E3779B9;

  DailyStart generate() {
    // identical to today, but place `difficulty.startingFill` tiles instead of kStartingFill
  }
}
```

**Key decisions**:
- Seed key is `"$date:$difficulty.name"`, NOT a numeric combo — string hashing keeps it readable and identical to the TS port in Phase 2.
- UTC: `_date` is derived from `DateTime.now().toUtc()`; `formatDate` stays but is fed a UTC `DateTime`.

**Implementation steps**:
1. Add `difficulty` to `DailySeeder`; rename `seedForDate` → `seedForKey` (keep a thin `seedForDate` alias only if other code needs it).
2. Replace `kStartingFill` usage with `difficulty.startingFill`.
3. In `GameCubit.init`, build `_date` from UTC and pass `difficulty`.

**Feedback loop**:
- **Playground**: extend `test/domain/engine/daily_seeder_test.dart`.
- **Experiment**: for a fixed date, assert each of the 4 tiers produces a board with the matching tile count (10/8/6/4) AND that two `DailySeeder(sameDate, sameTier)` instances produce identical boards + drop schedules; assert different tiers produce different boards.
- **Check command**: `flutter test test/domain/engine/daily_seeder_test.dart`

### Per-(date,tier) storage + once-per-day rule

**Pattern to follow**: `lib/infrastructure/storage_service.dart` (keep the abstract + in-memory fake structure for tests).

**Overview**: Snapshots and stats move from one slot to one-per-`(date,difficulty)`; a completed snapshot for today's tier blocks a second attempt.

```dart
abstract class StorageService {
  Future<void> init();
  GameSnapshot? loadSnapshot(String date, Difficulty difficulty);
  Future<void> saveSnapshot(GameSnapshot snapshot); // snapshot carries date+difficulty
  LifetimeStats loadStats(Difficulty difficulty);   // per-tier streak/best
  Future<void> saveStats(Difficulty difficulty, LifetimeStats stats);
}
```

**Key decisions**:
- Hive key = `"$date:${difficulty.name}"` for snapshots; stats keyed by `difficulty.name`.
- Streaks/best become **per tier** — a Hard streak is independent of an Easy streak (cleaner competition; matches per-tier leaderboards).

**Implementation steps**:
1. Add `difficulty` to `GameSnapshot` (+ JSON).
2. Rework `StorageService` signatures; update `InMemoryStorageService` and `HiveStorageService`.
3. In `GameCubit.init`, if `loadSnapshot(today, difficulty)?.completed == true`, emit a "come back tomorrow" / show-result state instead of a playable board.

**Feedback loop**:
- **Playground**: `test/infrastructure/in_memory_storage_test.dart` + `test/application/game_cubit_test.dart`.
- **Experiment**: save a completed snapshot for `(2026-06-07, hard)`; assert `init(difficulty: hard)` blocks replay but `init(difficulty: easy)` starts fresh; assert easy and hard streaks increment independently.
- **Check command**: `flutter test test/application/game_cubit_test.dart`

### Move-sequence recording

**Overview**: An ordered event log capturing each merge and each ad-continue, appended as the run progresses. Unused by Phase 1 UI; consumed by Phase 2's verifier.

```dart
sealed class MoveEvent {
  Map<String, dynamic> toJson();
}
class MergeEvent extends MoveEvent { final int from; final int to; }
class ContinueEvent extends MoveEvent {} // ad-continue granted (+kAdMoveReward)
```

**Key decisions**:
- The log is the **authoritative input** for Phase 2; record exactly the player inputs that change state, in order. Drops are NOT logged (the server regenerates them deterministically).
- Store the log inside `BoardState` (`moveLog`) so it persists/restores with the snapshot automatically.

**Implementation steps**:
1. Add `moveLog` to `BoardState` (default `const []`) + JSON round-trip.
2. In `GameCubit.merge`, append `MergeEvent(from,to)` before/after applying the merge (order: append the move that was accepted).
3. In `GameCubit.grantAdReward`, append `ContinueEvent()`.

**Feedback loop**:
- **Playground**: `test/application/game_cubit_test.dart`.
- **Experiment**: play a scripted 3-merge run + 1 ad-continue; assert `moveLog` equals `[Merge, Merge, Merge, Continue]` and survives a `toJson`→`fromJson` snapshot round-trip.
- **Check command**: `flutter test test/application/game_cubit_test.dart`

### iOS AdMob App ID fix

**Overview**: One-line plist value swap. Trivial, but release-blocking.

**Key decisions**: Unit IDs in `ad_config.dart` are already correct and `useTestAds=false`; only `Info.plist`'s `GADApplicationIdentifier` is wrong.

**Implementation steps**:
1. Obtain the real iOS App ID from AdMob (format `ca-app-pub-4807961095325796~XXXXXXXXXX`) — see Open Items.
2. Replace the test value in `ios/Runner/Info.plist`.
3. Verify on a real iOS build that ads serve (user task — not possible on this machine).

**Feedback loop**: skip (config value; `ad_config_test.dart` already guards unit IDs).

### Tier-select screen

**Pattern to follow**: `lib/presentation/screens/game_screen.dart` for scaffolding/theme; reuse `tile_palette.dart`.

**Overview**: Entry screen with four tier cards; each shows completed/locked state for today and the time until UTC reset.

**Implementation steps**:
1. Build four cards (Easy→Legendary) with tile-count hint + difficulty styling.
2. Mark a tier "Done today ✓" if `loadSnapshot(today, tier)?.completed`.
3. Show a live countdown to `00:00 UTC`.
4. Tap → push `GameScreen` with the chosen `Difficulty`.

**Feedback loop**:
- **Playground**: `flutter run` (manual) + `test/presentation/tier_select_screen_test.dart`.
- **Experiment**: render with `(easy completed, others open)`; assert easy card shows the done state and is non-tappable, others route correctly.
- **Check command**: `flutter test test/presentation/tier_select_screen_test.dart`

## Data Model

### State Shape (local, Hive)

```text
snapshot box key: "<utcDate>:<difficulty.name>"  -> GameSnapshot { date, difficulty, board(+moveLog), completed }
stats box key:    "stats:<difficulty.name>"      -> LifetimeStats { streak, lastCompletedDate, bestScore, bestTier }
```

## Testing Requirements

### Unit Tests

| Test File | Coverage |
| --------- | -------- |
| `test/domain/models/difficulty_test.dart` | Tile counts 10/8/6/4; labels. |
| `test/domain/models/move_test.dart` | `MoveEvent` JSON round-trip (merge + continue). |
| `test/domain/engine/daily_seeder_test.dart` (extend) | Per-tier determinism + correct tile counts; different tiers differ; same key identical. |
| `test/application/game_cubit_test.dart` (extend) | UTC date used; once-per-tier-per-day block; per-tier streaks; move log built correctly. |
| `test/infrastructure/in_memory_storage_test.dart` (extend) | Keyed snapshot/stats CRUD by `(date,difficulty)`. |

**Key test cases**:
- Same `(date,tier)` → identical board across two seeders.
- `legendary` board has exactly 4 starting tiles; `easy` has 10.
- Completing `hard` does not unlock a second `hard` run today but leaves `easy` playable.
- Move log records merges and continues in order and survives snapshot serialization.

### Manual Testing
- [ ] `flutter run`: pick each tier, confirm distinct boards and tile counts.
- [ ] Complete a tier, return to tier-select, confirm it shows "done today" and is locked.
- [ ] Real iOS build: confirm ads serve with the corrected App ID.

## Error Handling

| Error Scenario | Handling Strategy |
| -------------- | ----------------- |
| Corrupt/old snapshot JSON (pre-tier schema) | Treat as missing → start a fresh day for that tier (migration-free; pre-launch). |
| `moveLog` absent in old snapshot | Default to `[]`. |
| Device clock skew vs UTC | Seed from device UTC; Phase 2's server is the source of truth for scoring windows. |

## Failure Modes

| Component | Failure Mode | Trigger | Impact | Mitigation |
| --------- | ------------ | ------- | ------ | ---------- |
| Seeding | Tier collision | Two tiers accidentally share a seed | Identical boards across tiers (unfair) | Distinct string key `date:name`; test asserts tiers differ. |
| Storage keying | Cross-tier overwrite | Snapshot saved without difficulty in key | A run clobbers another tier's progress | Key includes difficulty; CRUD test covers it. |
| Once-per-day rule | Replay exploit | Snapshot `completed` not checked on init | Player re-rolls a tier for a better run | `init` blocks when today's `(date,tier)` is completed. |
| Move log | Desync with board | Log appended on rejected/illegal merges | Phase 2 replay mismatch | Append only after `canMerge` passes (same guard as state change). |
| UTC switch | Off-by-one day | Mixing local + UTC dates | Wrong board / double play near midnight | Single helper produces the UTC date string; used everywhere. |

## Validation Commands

```bash
flutter analyze
flutter test test/domain/engine/daily_seeder_test.dart
flutter test test/application/game_cubit_test.dart
flutter test
```

## Open Items

- [ ] **User must provide the real iOS AdMob App ID** (`ca-app-pub-4807961095325796~XXXXXXXXXX`) from the AdMob console — it is not derivable from the unit IDs and is not in the repo.
- [ ] Confirm per-tier streaks (decision: yes) vs a single global streak — spec assumes per-tier.
- [ ] Playtest legendary=4 to confirm it is "hard," not "instant-deadlock"; if unfair, revisit (out of Phase 1 scope, just flag).

---

_This spec is ready for implementation. Follow the patterns and validate at each step._
