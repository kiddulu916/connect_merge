# Implementation Spec: Competitive Daily Expansion - Phase 4

**Contract**: ./contract.md
**Estimated Effort**: XL
**Prerequisites**: Phase 2 (identity + backend) merged. (Streaks, notifications, practice mode, and cosmetics are client-only and need only Phase 1; achievements + extended leaderboards need Phase 2.)
**Parallelizable with**: Phase 3. Coordinate on shared files (`lib/main.dart`, `pubspec.yaml`, Supabase migrations, shared leaderboard widgets).

## Technical Approach

Phase 4 is the retention layer that turns four daily puzzles into a daily habit. It bundles (Stretch scope, all in): **streak system** (surface the already-tracked streak + milestones + a rewarded-ad streak freeze), **local daily-reminder notifications** ($0, no backend push), **achievements/badges**, **extended leaderboards** (weekly/monthly/all-time), **practice/unlimited mode** (off-leaderboard endless play for extra ad impressions), and **extra rewarded-ad placements** (hint / reveal-next-drop) plus **cosmetic tile themes**.

Most of this is client-side and offline-friendly. Streaks/achievements/cosmetics live in Hive (extending Phase 1's per-tier stats); local notifications use `flutter_local_notifications` scheduled at a user-chosen time and recomputed on each app open / day completion. Only two pieces touch the backend: extended leaderboards (SQL aggregation over the existing `scores` table — no new writes, just new read RPCs) and achievement definitions that depend on rank (e.g., "top-10 finish") which read from `scores`.

Reuse-first: rewarded ads go through the existing `AdService.showRewarded`; hint/reveal-next-drop are new reward callbacks, not new ad plumbing. Cosmetics extend the existing `tile_palette.dart`. The streak-freeze and hint placements must respect determinism — a hint reveals information already fixed by the seed (the next drop tier) and does **not** alter the board, so it can't affect leaderboard fairness; practice mode is explicitly off-leaderboard so unlimited play can't pollute rankings.

## Feedback Strategy

**Inner-loop command**: `flutter test test/application/engagement_test.dart`

**Playground**: `flutter test` for streak/achievement/cosmetic logic (pure, fast); a notification test harness for scheduling logic; `flutter run` for the notification permission prompt and practice mode; local Supabase stack for the extended-leaderboard RPCs.

**Why this approach**: The retention logic (streak transitions, achievement triggers, reward effects) is pure state computation best pinned by unit tests; only OS notifications and ad-reward UX need a device pass.

> **Environment note**: Notification delivery, the notification permission prompt, and rewarded-ad display require a real device (user-verified). Streak/achievement/cosmetic/leaderboard-aggregation logic is tested headlessly here.

## File Changes

### New Files

| File Path | Purpose |
| --------- | ------- |
| `supabase/migrations/0003_extended_leaderboards.sql` | Read RPCs for weekly/monthly/all-time aggregation (no new writes). |
| `lib/application/engagement_cubit.dart` | Streak transitions, achievement unlocks, cosmetic selection. |
| `lib/domain/models/achievement.dart` | Achievement definitions + unlock predicates. |
| `lib/domain/models/cosmetic.dart` | Tile-theme definitions + unlock source. |
| `lib/infrastructure/notification_service.dart` | Schedule/cancel local daily + streak-expiry notifications. |
| `lib/infrastructure/practice_seeder.dart` | Random (non-daily) boards for practice mode. |
| `lib/presentation/screens/achievements_screen.dart` | Badge grid (locked/unlocked). |
| `lib/presentation/screens/practice_screen.dart` | Endless off-leaderboard play. |
| `lib/presentation/widgets/streak_banner.dart` | Streak display + freeze CTA. |
| `lib/presentation/widgets/hint_button.dart` | Rewarded reveal-next-drop. |
| `test/application/engagement_test.dart` | Streak transitions + achievement triggers. |
| `test/infrastructure/notification_service_test.dart` | Scheduling/cancel logic (mocked plugin). |
| `test/domain/models/achievement_test.dart` | Unlock predicate truth tables. |

### Modified Files

| File Path | Changes |
| --------- | ------- |
| `pubspec.yaml` | Add `flutter_local_notifications`, `timezone`. |
| `lib/main.dart` | Init notifications + timezone; request permission lazily; wire `EngagementCubit`. |
| `lib/application/game_cubit.dart` | On completion, emit a hook for streak/achievement evaluation; add hint (reveal next drop tier from `_dropTiers`) and streak-freeze reward paths. |
| `lib/infrastructure/storage_service.dart` | Extend stats: per-tier streak (Phase 1) + `streakFreezeTokens`, unlocked achievements, selected cosmetic. |
| `lib/presentation/theme/tile_palette.dart` | Support multiple selectable palettes (cosmetics). |
| `lib/presentation/screens/game_screen.dart` | Show streak banner + hint button. |
| `lib/presentation/screens/score_share_screen.dart` | Surface newly unlocked achievements. |
| `lib/presentation/screens/leaderboard_screen.dart` | Add Daily / Weekly / Monthly / All-time period tabs. |

## Implementation Details

### Streak system + freeze

**Pattern to follow**: existing streak logic in `GameCubit._recordCompletion` (extend, don't duplicate).

**Overview**: Surface the per-tier streak; consecutive-UTC-day completion increments, a gap resets — unless a freeze token covers the missed day.

```dart
// streak transition (pure)
StreakResult nextStreak({required int prev, required String? last,
    required String today, required bool hasFreeze}) {
  // last == yesterday -> prev+1; last == today -> unchanged;
  // gap & hasFreeze -> consume token, keep streak; else -> reset to 1
}
```

**Key decisions**:
- Streak is **per tier** (matches Phase 1) — but also expose a "any tier today" daily-active streak for the headline number (decide at impl).
- Freeze tokens earned at milestones (e.g., 7-day) or via rewarded ad; capped to prevent infinite shielding.

**Feedback loop**:
- **Playground**: `engagement_test.dart`.
- **Experiment**: last=yesterday → +1; last=today → unchanged; gap, no freeze → reset to 1; gap, 1 freeze → keep + token consumed.
- **Check command**: `flutter test test/application/engagement_test.dart`

### Local notifications

**Overview**: Schedule a daily reminder at a chosen local time + a streak-expiry warning; reschedule on completion/app open.

**Key decisions**:
- Local scheduled notifications only (no FCM, $0). Use `timezone` for correct local firing.
- Don't notify if all tiers already completed today; warn when a streak will lapse before next reset.

**Implementation steps**:
1. Init plugin + timezone in `main.dart`; request permission at a sensible moment (not cold first-launch).
2. On day completion / app open, cancel + reschedule the next reminder.

**Feedback loop**:
- **Playground**: `notification_service_test.dart` with a mocked plugin.
- **Experiment**: all tiers done → no reminder scheduled; streak at risk → expiry warning scheduled at the right time.
- **Check command**: `flutter test test/infrastructure/notification_service_test.dart`

### Achievements / badges

**Overview**: Declarative achievements with pure unlock predicates evaluated on completion (and on rank fetch for rank-based ones).

```dart
enum Achievement { firstLegendaryClear, sevenDayStreak, topTenFinish, tierMaster, ... }
bool isUnlocked(Achievement a, PlayerProgress p); // pure
```

**Key decisions**:
- Local-first (stored in Hive); rank-based achievements (`topTenFinish`) read from the Phase 2 `scores`/leaderboard.
- Newly unlocked → celebrate on the result screen; shareable via Phase 3 cards.

**Feedback loop**:
- **Playground**: `achievement_test.dart`.
- **Experiment**: truth table — each achievement unlocks exactly at its trigger and not before.
- **Check command**: `flutter test test/domain/models/achievement_test.dart`

### Extended leaderboards

**Overview**: New read-only SQL RPCs aggregating the existing `scores` table by week/month/all-time (sum or best — decide), per tier.

```sql
create function leaderboard_period(p_diff text, p_from date, p_to date)
returns table(rank bigint, display_name text, total int, is_me boolean)
language sql stable as $$
  select rank() over (order by sum(s.score) desc), p.display_name,
         sum(s.score)::int as total, bool_or(s.player_id = auth.uid())
  from scores s join players p on p.id = s.player_id
  where s.difficulty = p_diff and s.utc_date between p_from and p_to
  group by p.id, p.display_name order by total desc;
$$;
```

**Key decisions**:
- No new writes — pure aggregation over existing rows (free-tier friendly).
- Period = sum of daily bests (rewards consistency); client passes the date range for week/month.

**Feedback loop**:
- **Playground**: local Supabase stack.
- **Experiment**: seed 3 days of scores; weekly total = sum of dailies; all-time spans full range; ranks correct.
- **Check command**: `curl -s ... /rpc/leaderboard_period ... | jq .`

### Practice mode + extra rewarded-ad spots

**Overview**: Off-leaderboard endless play (random seed each round) + rewarded hint (reveal next drop tier) and reveal-next placements.

**Key decisions**:
- Practice uses `practice_seeder.dart` with a random seed — **never** submitted to any leaderboard (no determinism guarantee, no fairness concern).
- Hint reveals only seed-fixed information (the upcoming drop tier from `_dropTiers`) and does **not** change the board → leaderboard fairness preserved. Gate behind a rewarded ad with a per-day cap.

**Feedback loop**:
- **Playground**: `flutter test` (practice seeder produces valid boards) + manual ad flow.
- **Experiment**: practice round generates a playable board; completing it touches no `scores` write; hint returns the correct next-drop tier and leaves the board unchanged.
- **Check command**: `flutter test test/infrastructure` (practice seeder test)

### Cosmetic tile themes

**Pattern to follow**: `lib/presentation/theme/tile_palette.dart`.

**Overview**: Multiple selectable palettes unlocked by streaks/achievements or a rewarded ad; selection persisted.

**Feedback loop**: skip core logic (selection is a stored enum); verify rendering via a widget test that swaps palettes.

## Data Model

### Local (Hive) — extend stats

```text
stats:<difficulty.name> -> { streak, lastCompletedDate, bestScore, bestTier,
                             streakFreezeTokens }
profile                 -> { unlockedAchievements:Set, selectedCosmetic, dailyActiveStreak }
notif                   -> { reminderTimeLocal, enabled }
```

### Server — read-only RPCs only

`leaderboard_period(p_diff, p_from, p_to)` (+ thin wrappers for weekly/monthly/all-time). No new tables, no new writes.

## API Design

| Method | Path | Description |
| ------ | ---- | ----------- |
| `RPC` | `leaderboard_period` | Aggregated ranking over a date range per tier (read-only). |

## Testing Requirements

### Unit Tests

| Test File | Coverage |
| --------- | -------- |
| `test/application/engagement_test.dart` | Streak transitions incl. freeze consumption; completion hook. |
| `test/domain/models/achievement_test.dart` | Per-achievement unlock truth tables. |
| `test/infrastructure/notification_service_test.dart` | Schedule/cancel/reschedule, suppress-when-done. |
| practice seeder test | Random boards are valid + never marked for submission. |

### Integration Tests (local stack)
- `leaderboard_period` weekly total equals sum of daily bests; ranks correct; `is_me` set.

### Manual Testing
- [ ] Reminder fires at the configured time; no reminder when all tiers done.
- [ ] Streak increments across days; freeze saves a missed day.
- [ ] Rewarded hint reveals next drop, board unchanged; daily cap enforced.
- [ ] Practice round never appears on any leaderboard.
- [ ] Switching cosmetic re-themes tiles; persists across restart.

## Error Handling

| Error Scenario | Handling Strategy |
| -------------- | ----------------- |
| Notification permission denied | Feature degrades silently; in-app reminders only; don't nag. |
| Timezone/DST shift | Use `timezone` package; reschedule on app open. |
| Rank-based achievement before scores load | Evaluate lazily after leaderboard fetch; never block result screen. |
| Freeze token abuse | Cap tokens; one freeze covers one missed day; consumption is logged. |
| Practice run accidentally submitted | Practice path has no submit call; assert in tests. |

## Failure Modes

| Component | Failure Mode | Trigger | Impact | Mitigation |
| --------- | ------------ | ------- | ------ | ---------- |
| Streak logic | Off-by-one day | Local vs UTC date mismatch | Wrong streak break | Use the same UTC date helper as Phase 1; tested transitions. |
| Notifications | Silent failure | Permission denied / channel missing | No reminders, lower DAU | Detect permission state; in-app fallback. |
| Hint | Fairness break | Hint alters board or reveals beyond seed | Leaderboard unfair | Hint is read-only on seed-fixed data; board state untouched; tested. |
| Practice mode | Leaderboard pollution | Practice score submitted | Corrupt rankings | No submit path in practice; explicit test. |
| Extended LB | Free-tier load | Heavy aggregation queries | Slow/over quota | Read-only RPCs, indexed by `(utc_date,difficulty,score)`; cache client-side; paginate. |
| Cosmetics | Unlock bypass | Selecting a locked palette | Minor exploit | Gate selection on unlocked set; harmless if missed. |

## Validation Commands

```bash
flutter analyze
flutter test test/application/engagement_test.dart
flutter test test/domain/models/achievement_test.dart
flutter test test/infrastructure/notification_service_test.dart
flutter test
# server
supabase start && psql ... -f supabase/migrations/0003_extended_leaderboards.sql
```

## Rollout Considerations

- **Permissions**: notifications requested contextually (after first completion), not at cold launch.
- **Monitoring**: notification opt-in rate; extended-LB query latency; rewarded-ad fill for new placements.
- **Rollback**: each feature behind its own flag (streak banner, notifications, achievements, practice, cosmetics, extended LB) — independently disablable without touching core play.

## Open Items

- [ ] Headline streak: per-tier vs a single "daily active" streak (spec supports both; pick the hero number).
- [ ] Period aggregation: sum-of-daily-bests vs single best (spec assumes sum).
- [ ] Daily caps for rewarded hint / streak-freeze.
- [ ] Initial cosmetic set + unlock thresholds.

---

_This spec is ready for implementation. Follow the patterns and validate at each step._
