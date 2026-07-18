# Streak Rule and UTC Calendar Helpers — Design

Date: 2026-07-18
Status: Approved (frozen by root `PLAN.md` after five adversarial reviews)

## Summary

Per-tier completion bookkeeping delegates its streak transition to the existing
pure `nextStreak` function with `hasFreeze: false`. This removes the duplicate
yesterday/increment/reset rule while preserving the product policy: freeze
tokens can protect only the headline daily-active streak, never a per-tier
streak.

Canonical date-only parsing and calendar arithmetic live in
`lib/domain/date_utils.dart`. `parseUtcDate`, `previousUtcDay`, and
`mondayOfWeek` construct UTC dates from parsed `YYYY-MM-DD` components. This
removes local-time `Duration` arithmetic from per-tier streak completion and
weekly leaderboard ranges, including their Africa/Cairo spring-forward bugs.

## Domain API

`lib/domain/date_utils.dart` exposes exactly these additional helpers:

```dart
DateTime parseUtcDate(String yyyyMmDd);
String previousUtcDay(String date);
String mondayOfWeek(String date);
```

`previousUtcDay` moves from `domain/models/streak.dart`; there is no re-export
shim. `streak.dart` imports it for `nextStreak` without otherwise changing
`nextStreak` or `StreakResult`. No validation API, general date arithmetic API,
or period-range abstraction is added.

## Consumers and preserved behavior

`GameCubit._recordCompletion` keeps its same-day guard, best-score and
best-tier folds, persistence, and analytics payload. Its transition becomes
`nextStreak(prev: prev.streak, last: prev.lastCompletedDate, today: _date,
hasFreeze: false)`, while genuine-gap analytics compares against
`previousUtcDay(_date)`.

`EngagementCubit._thisWeekMonday` delegates to `mondayOfWeek`, and all former
`_parseUtcDate` calls use `parseUtcDate`. The cubit imports `formatDate`,
`utcToday`, `parseUtcDate`, `previousUtcDay`, and `mondayOfWeek` directly and
selectively from `date_utils.dart`. Prize-specific period helpers remain
private.

`LeaderboardPeriod.range` documents its canonical `YYYY-MM-DD` input contract
and uses `mondayOfWeek` for the weekly branch. The current leaderboard week
(Monday through today) and the previous completed prize week (Monday through
Sunday) remain different periods that share only the Monday sub-rule. Monthly
and all-time branches do not change.

The `LifetimeStats.streakFreezeTokens` comment states that tokens are banked in
per-tier records but consumed only for the headline streak. Storage behavior
does not change.

## DST regression proof

IANA tzdb's `Africa/Cairo` rule starts DST at 00:00 on the last Friday of
April. In 2025 that transition was Friday 2025-04-25, advancing local time from
23:59:59 Thursday to 01:00 Friday. Tests therefore pin:

- `previousUtcDay('2025-04-26') == '2025-04-25'` and per-tier completions on
  2025-04-25 then 2025-04-26 producing streak 2;
- `mondayOfWeek('2025-04-26') == '2025-04-21'` and the weekly leaderboard
  range for that Saturday starting on 2025-04-21.

On Ubuntu with `TZ=Africa/Cairo`, parsing the Saturday at local midnight and
subtracting a fixed duration crosses the one-hour offset change: one day lands
at 23:00 Thursday and five days lands at 23:00 Sunday. UTC component
construction produces the intended calendar dates. Windows ignores this `TZ`
override, so CI reruns the three focused suites under Cairo.

## Proof

New behavior is specified red-first in domain, application, and presentation
tests. CI adds one focused Cairo step after the main Flutter test step. Final
proof is a clean `flutter analyze`, a green full `flutter test`, and green
focused runs for date utilities, leaderboard periods, and per-tier streaks.

## Out of scope

- Freeze-policy, token-consumption, achievement, or economy changes.
- Changes to `nextStreak`, `StreakResult`, game replay, Supabase, the TypeScript
  mirror, golden vectors, or leaderboard season.
- Moving prize-specific period helpers out of `EngagementCubit`.
- Local-time notification scheduling.

