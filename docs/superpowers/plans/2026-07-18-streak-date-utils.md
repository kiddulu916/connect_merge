# Streak Rule and UTC Calendar Helpers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:test-driven-development` while implementing this plan task by
> task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route per-tier streak transitions through `nextStreak(hasFreeze:
false)`, single-source duplicated UTC date-only arithmetic, and prove the two
local-time DST regressions under `TZ=Africa/Cairo`.

**Architecture:** Three pure calendar helpers live in
`lib/domain/date_utils.dart`; application and presentation consumers import
only what they use. Existing policy and all non-boundary behavior remain
unchanged.

**Tech stack:** Dart/Flutter, flutter_bloc, Flutter test, GitHub Actions.

## Global constraints

- Follow frozen root `PLAN.md` exactly; this document records rather than
  redesigns it.
- Do not run Git-mutating commands. The reviewer owns all Git state changes.
- Every new behavior begins with a focused failing test.
- Do not add dependencies or touch `supabase/**`, `notification_service.dart`,
  `tier_select_screen.dart`, or `main.dart`.
- Do not change freeze policy, `nextStreak`, `StreakResult`, achievements,
  economy, replay rules, the TypeScript mirror, golden vectors, or season.

---

### Task 1: Specify shared UTC date helpers first

**Files:**

- Create: `test/domain/date_utils_test.dart`
- Modify: `test/application/engagement_test.dart`

- [ ] Add `parseUtcDate` tests proving component parsing yields UTC values.
- [ ] Relocate the existing year-boundary and leap-day `previousUtcDay` cases
  verbatim from `engagement_test.dart`.
- [ ] Add the Cairo-sensitive
  `previousUtcDay('2025-04-26') == '2025-04-25'` case.
- [ ] Add `mondayOfWeek` cases for all seven weekdays, month and year
  boundaries, and Cairo-sensitive Saturday 2025-04-26.
- [ ] Run the new suite and verify it fails because the APIs do not yet exist:

```powershell
flutter test test/domain/date_utils_test.dart
```

### Task 2: Implement the shared UTC date helpers

**Files:**

- Modify: `lib/domain/date_utils.dart`
- Modify: `lib/domain/models/streak.dart`

- [ ] Implement `parseUtcDate` from split integer components and
  `DateTime.utc`.
- [ ] Move `previousUtcDay` from `streak.dart`, using UTC component calendar
  construction; import it back into `streak.dart` without re-exporting it.
- [ ] Implement `mondayOfWeek` with UTC component calendar construction.
- [ ] Leave `nextStreak` and `StreakResult` otherwise untouched.
- [ ] Run `flutter test test/domain/date_utils_test.dart` and require green.

### Task 3: Specify per-tier policy and DST behavior first

**Files:**

- Modify: `test/application/game_cubit_test.dart`

- [ ] Add an explicit reset-to-1 assertion to the existing genuine-gap test.
- [ ] Add a gap with banked freeze tokens that resets the per-tier streak to 1
  and leaves the token count unchanged.
- [ ] Add consecutive completions on 2025-04-25 and 2025-04-26 that expect
  streak 2; this is load-bearing under `TZ=Africa/Cairo` on Ubuntu.
- [ ] Run the focused named tests and verify the new behavior fails against the
  old inline local-time implementation where the Windows environment permits;
  retain the correct test when Windows ignores `TZ`.

### Task 4: Specify weekly range boundary behavior first

**Files:**

- Modify: `test/presentation/leaderboard_period_range_test.dart`

- [ ] Add a weekly year-boundary case.
- [ ] Add the Cairo-sensitive Saturday 2025-04-26 weekly case expecting
  Monday 2025-04-21 through Saturday 2025-04-26.
- [ ] Run the focused suite; Windows may pass because Dart ignores `TZ`, while
  the unchanged old code is expected to fail in the later Ubuntu Cairo step.

### Task 5: Consume the helpers and correct documentation

**Files:**

- Modify: `lib/application/game_cubit.dart`
- Modify: `lib/application/engagement_cubit.dart`
- Modify: `lib/presentation/screens/leaderboard_screen.dart`
- Modify: `lib/infrastructure/storage_service.dart`

- [ ] In `_recordCompletion`, preserve the same-day guard and replace only the
  inline transition with `nextStreak(... hasFreeze: false)`; use
  `previousUtcDay` for genuine-gap analytics.
- [ ] Delegate `_thisWeekMonday` to `mondayOfWeek`, replace `_parseUtcDate` with
  `parseUtcDate`, remove the private parser, and use direct selective imports.
- [ ] Use `mondayOfWeek` in only the weekly leaderboard branch; document the
  canonical input contract and correct the false prize-period equivalence
  comment.
- [ ] Correct only the `streakFreezeTokens` doc comment in storage.
- [ ] Run the three focused suites and the existing engagement prize-boundary
  tests required by root `PLAN.md`.

### Task 6: Add Cairo CI proof

**Files:**

- Modify: `.github/workflows/test.yml`

- [ ] Add one step after the main `flutter test` step with
  `TZ: Africa/Cairo`.
- [ ] Run exactly `test/domain/date_utils_test.dart`,
  `test/presentation/leaderboard_period_range_test.dart`, and
  `test/application/game_cubit_test.dart` in that step.
- [ ] Preserve all pinned actions, permissions, jobs, and other workflow lines.

### Task 7: Format, verify, and audit the frozen plan

- [ ] Format only changed Dart files.
- [ ] Run each of the three CI-step suites individually without `TZ` on
  Windows and capture their tails.
- [ ] Run fresh `flutter analyze` and capture its full tail.
- [ ] Run fresh full `flutter test` and capture its full tail.
- [ ] Re-read root `PLAN.md` line by line and audit the read-only diff for every
  required behavior, forbidden path, and out-of-scope decision.
- [ ] Run `git diff --check` and inspect `git status --short`; do not stage,
  commit, branch, checkout, or stash.

