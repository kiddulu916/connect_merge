# Implementation Spec: Engagement & Retention Engine - Phase 4

**Contract**: ./contract.md
**Estimated Effort**: M
**Prereq**: None — independent low-risk track, parallelizable with Phases 2 and 3.

## Technical Approach

Phase 4 closes the four UX gaps that quietly cap retention and reach: **no onboarding** (new players bounce before they understand the merge-anywhere rule), **no frustration relief** (one misdrag ends a scarce 30-move run), **no history** (nothing to look back on or feel proud of), and **color-only tiles** (excludes colorblind players and risks an accessibility rejection). None of these are flashy, but each removes a concrete reason players quit.

The work is deliberately low-risk and mostly additive. The **tutorial** is a first-run overlay gated by a `tutorialSeen` flag on `PlayerProfile`. **Undo** is the one piece needing care: it must rewind `BoardState`, the landing PRNG position, `dropIndex`, and the `moveLog` together so the run stays replay-consistent for Phase 2's server verification — so undo is implemented as a bounded history stack in `GameCubit` (not a guessed inverse). The **stats calendar** needs a small new persisted history log (today only one snapshot is kept). **Colorblind tiles** add always-on numerals + an optional pattern overlay driven by a profile setting, touching only the cell widget and palette.

Replay-fairness is the sharp edge: undo changes the move log, and the Phase 2 edge function replays the *final* `moveLog` against the regenerated board. As long as undo pops the trailing `MergeEvent` (and the drop it caused) so the persisted `moveLog` always equals the actual board history, verification stays valid. This invariant is the core thing the undo tests assert.

## Feedback Strategy

**Inner-loop command**: `flutter test test/application/game_cubit_undo_test.dart test/domain/`

**Playground**: Dart test suite for undo/history correctness; the running app for tutorial flow and colorblind rendering.

**Why this approach**: Undo's replay-consistency is the only real risk and it's pure cubit/engine state — unit tests catch desync instantly; tutorial and accessibility are visual and validated live.

## File Changes

### New Files

| File Path | Purpose |
| --------- | ------- |
| `lib/presentation/screens/tutorial_overlay.dart` | First-run interactive coachmarks (drag-to-merge-anywhere, 30 moves, deadlock). |
| `lib/domain/models/day_result.dart` | Immutable summary persisted per completed `(date, difficulty)` for history. |
| `lib/presentation/screens/stats_calendar_screen.dart` | Wordle-style month grid of past results. |
| `lib/presentation/widgets/tile_glyph.dart` | Renders the tier numeral + optional colorblind pattern over a tile. |
| `test/application/game_cubit_undo_test.dart` | Undo rewinds board + PRNG + dropIndex + moveLog consistently. |
| `test/infrastructure/history_log_test.dart` | Append/read/cap of the day-result history. |

### Modified Files

| File Path | Changes |
| --------- | ------- |
| `lib/infrastructure/storage_service.dart` | Add `bool tutorialSeen`, `bool colorblindMode`, and a `List<DayResult> history` accessor (`appendResult`, `loadHistory`) to the storage contract + both impls. |
| `lib/application/game_cubit.dart` | Maintain a bounded undo stack (prior `BoardState` + landing-PRNG step count); add `undo()` gated by `kFreeUndosPerDay` / rewarded ad; append `DayResult` on completion. |
| `lib/domain/constants.dart` | Add `kFreeUndosPerDay` (and reuse the rewarded-ad surface for extra undos). |
| `lib/presentation/widgets/grid_cell_widget.dart` | Compose `tile_glyph` (numeral always on; pattern when `colorblindMode`). |
| `lib/presentation/theme/tile_palette.dart` | Add a colorblind-safe pattern set keyed by tier. |
| `lib/presentation/screens/game_screen.dart` | Show the tutorial overlay on first run; add an Undo button; entry to the stats calendar. |
| `lib/main.dart` | Provide `tutorialSeen` gate at first launch. |

## Implementation Details

### Undo last merge (replay-consistent)

**Pattern to follow**: `lib/application/game_cubit.dart merge` (board + drop + moveLog + landing PRNG advance) — undo is its exact inverse.

**Overview**: Keep a small history stack of pre-merge states. `undo()` restores the previous `BoardState`, rewinds the landing PRNG to the saved position, and drops the trailing `MergeEvent` so `moveLog` stays equal to the real history.

```dart
// game_cubit.dart
final List<_UndoFrame> _undoStack = []; // {board, landingDrawsBefore}

Future<void> undo() async {
  if (_undoStack.isEmpty || _undosUsed >= kFreeUndosPerDay /* or ad */) return;
  final frame = _undoStack.removeLast();
  _landing = _rebuildLandingTo(frame.landingDrawsBefore); // deterministic rewind
  await storage.saveSnapshot(/* frame.board, completed:false */);
  emit(GamePlaying(board: frame.board, difficulty: _difficulty));
}
```

**Key decisions**:
- Rewind the landing PRNG by **rebuilding from seed and advancing N draws** (the codebase already does this on resume in `init`), rather than trying to reverse a PRNG — deterministic and proven.
- Undo pops the trailing `MergeEvent` so the persisted `moveLog` always matches the board ⇒ Phase 2 replay verification still passes.
- Bounded stack (e.g. depth 3) keeps memory trivial and prevents undo-to-start abuse.

**Implementation steps**:
1. Push a frame before each merge mutation.
2. Implement deterministic landing rewind helper.
3. `undo()` restores frame, decrements nothing on score beyond the popped merge, drops the trailing move-log entry.
4. Gate by `kFreeUndosPerDay`, then rewarded ad via `AdService`.

**Feedback loop**:
- **Playground**: `test/application/game_cubit_undo_test.dart` with a fake storage + injected dropTiers.
- **Experiment**: merge→undo→re-merge differently ⇒ board, dropIndex, and moveLog are self-consistent; replaying the final moveLog reproduces the final board.
- **Check command**: `flutter test test/application/game_cubit_undo_test.dart`

### First-run tutorial

**Overview**: A skippable coachmark overlay shown when `!tutorialSeen`, teaching merge-anywhere, the 30-move budget, and deadlock. Sets `tutorialSeen` on completion/skip.

**Key decisions**: Overlay (not a separate flow) so the player learns on the real board; gated purely by the profile flag (idempotent).

**Feedback loop**: Running app — fresh install shows it once; relaunch does not.

### Stats calendar (history)

**Pattern to follow**: `storage_service.dart` snapshot/stats accessors.

**Overview**: Persist a compact `DayResult` per completed `(date, difficulty)` and render a month grid (score/tier/win-state per cell), Wordle-stat style.

**Key decisions**: New append-only `history` list (capped, e.g. 366 days) — today's single snapshot isn't a history. Pure model; storage handles persistence.

**Feedback loop**:
- **Check command**: `flutter test test/infrastructure/history_log_test.dart`

### Colorblind-safe tiles

**Pattern to follow**: `lib/presentation/theme/tile_palette.dart` + `cosmetic.dart` color ramps.

**Overview**: Always render the tier value as a numeral; when `colorblindMode`, overlay a per-tier pattern so tiles are distinguishable without hue. Setting persisted on profile.

**Key decisions**: Numerals always-on (helps everyone); pattern is the opt-in accessibility layer. Works across all cosmetic ramps since it overlays, not replaces.

**Feedback loop**: Running app with `colorblindMode` on/off; verify adjacent tiers are distinguishable in grayscale.

## Data Model

### State Shape (PlayerProfile additions)

```dart
final bool tutorialSeen;   // default false
final bool colorblindMode; // default false
```

### Persisted history

```dart
class DayResult { final String date; final Difficulty difficulty;
  final int score; final int highestTier; final bool win; }
// storage: appendResult(DayResult), List<DayResult> loadHistory()
```

## Testing Requirements

### Unit Tests

| Test File | Coverage |
| --------- | -------- |
| `test/application/game_cubit_undo_test.dart` | Undo rewinds board/PRNG/dropIndex/moveLog; final moveLog replays to final board; per-day cap. |
| `test/infrastructure/history_log_test.dart` | Append, ordered read, cap, migration-free load. |

**Key test cases**:
- merge → undo → merge-different: dropIndex and moveLog stay consistent (no PRNG desync).
- Undo cap respected; rewarded undo path grants exactly one extra.
- History reloads with pre-Phase-4 profiles (empty list default).

### Manual Testing

- [ ] Fresh install shows tutorial once; relaunch skips it.
- [ ] Undo button reverts the last merge and the drop it caused; capped per day.
- [ ] Stats calendar shows past days correctly.
- [ ] With colorblind mode on, adjacent-tier tiles are distinguishable in grayscale.

## Error Handling

| Error Scenario | Handling Strategy |
| -------------- | ----------------- |
| Undo with empty stack | No-op (button disabled). |
| Undo after the run is locked | Disallowed — undo only in `GamePlaying`. |
| History grows unbounded | Cap to N days, drop oldest. |

## Failure Modes

| Component | Failure Mode | Trigger | Impact | Mitigation |
| --------- | ------------ | ------- | ------ | ---------- |
| Undo | PRNG desync | Landing stream not rewound with board | Wrong drops, corrupt run, replay rejection | Rebuild landing from seed + advance to saved draw count; assert moveLog↔board in test. |
| Undo | Move-log drift | Trailing event not popped | Phase 2 verification rejects a legit run | Pop trailing `MergeEvent` atomically with the board restore. |
| Tutorial | Shows every launch | Flag not persisted before dismiss | Annoyance | Persist `tutorialSeen` before closing overlay. |
| Colorblind | Pattern hides value | Overlay too dense | Unreadable tile | Keep numeral legible; pattern is subtle background. |

## Validation Commands

```bash
flutter analyze
flutter test test/application/game_cubit_undo_test.dart
flutter test test/infrastructure/history_log_test.dart
flutter test
```

## Rollout Considerations

- **Feature flag**: none; all additive + migration-free.
- **Monitoring**: tutorial completion rate; undo usage (free vs ad); colorblind-mode adoption.
- **Rollback plan**: additive; reverting undo leaves moveLog semantics unchanged.

## Open Items

- [ ] `kFreeUndosPerDay` value + undo stack depth (recommend 1 free/day, depth 3).
- [ ] History retention window (recommend 366 days).

---

_This spec is ready for implementation. Follow the patterns and validate at each step._
