# Game Session Factory and Root Cubit Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:test-driven-development` while implementing this plan task by
> task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move production game-session composition into one application-layer
factory, root-own loot state, and refresh every profile-backed root cubit after
account deletion without changing existing widget tests.

**Architecture:** `GameSessionFactory` synchronously creates and starts a
`GameCubit` while owning the application bridges formerly embedded in the tier
screen. `main.dart` owns the factory and `LootCubit`; `TierSelectScreen` keeps
only UI callbacks, navigation, and its existing test-only cubit fallbacks.

**Tech stack:** Dart/Flutter, flutter_bloc Cubit/BlocProvider, existing storage
and leaderboard services, Flutter test.

## Global constraints

- Follow frozen root `PLAN.md` exactly; this document records rather than
  redesigns it.
- Do not run Git-mutating commands. The reviewer owns all Git state changes.
- Do not modify existing widget tests.
- Do not change `GameCubit`, `LootCubit`, `EngagementCubit`, `RivalryCubit`, or
  `DuelCubit`; change only their construction and wiring.
- Do not touch `supabase/**`, `lib/domain/**`, `lib/infrastructure/**`, other
  screens' service threading, or `PracticeScreen`.
- Add no dependency and no AppScope, InheritedWidget, service locator, factory
  interface, or fallback factory.
- Preserve the exact completion, coin, submission, observability, duel,
  notification, and navigation behavior described in root `PLAN.md`.
- `_ConnectMergeAppState.dispose()` closes only the hoisted `LootCubit`.
- Every new behavior begins with a focused failing test.

---

### Task 1: Record the frozen design and execution plan

**Files:**

- Create: `docs/superpowers/specs/2026-07-18-game-session-factory-design.md`
- Create: `docs/superpowers/plans/2026-07-18-game-session-factory.md`

**Interfaces:**

- Consumes: frozen root `PLAN.md` and the current source tree.
- Produces: the exact ownership boundary, factory API, red-green order, and
  final proof checklist used by later tasks.

- [ ] Write both dated documents before changing tests or production code.
- [ ] Confirm the screen's current production composition is confined to
  `_startTier`, `_onTierCompleted`, `_creditCoins`, and `_submitRun`:

```powershell
rg -n "GameCubit\(|_onTierCompleted|_creditCoins|_submitRun" lib/presentation/screens/tier_select_screen.dart
```

- [ ] Confirm existing widget tests use `onTierSelected` and do not require a
  fallback factory:

```powershell
rg -n "TierSelectScreen\(|onTierSelected" test/presentation --glob "*.dart"
```

### Task 2: Specify the factory contract first

**Files:**

- Create: `test/application/game_session_factory_test.dart`

**Interfaces:**

- Consumes: existing `GameCubit` callback fields, `StorageService`,
  `EngagementCubit`, `LootCubit`, and `LeaderboardService.withSeams`.
- Produces: executable expectations for `GameSessionFactory.create` before the
  production type exists.

- [ ] Add a test that creates a session, awaits the first non-`GameInitial`
  state, calls its completion hook, and proves engagement receives the supplied
  date/score/highest tier before `afterCompleted` runs.
- [ ] Add coin tests proving zero calls neither dependency and a nonzero signed
  delta awaits `storage.addCoins` before `loot.load`.
- [ ] Add submission tests proving online forwarding of date/difficulty/move
  log and a null `onSubmitRun` when the leaderboard is absent.
- [ ] Add an observability test proving analytics identity and that a swallowed
  submission error reaches the supplied `onError` callback.
- [ ] Run the new test file and verify it fails because
  `application/game_session_factory.dart` does not exist:

```powershell
flutter test test/application/game_session_factory_test.dart
```

### Task 3: Implement the minimum factory

**Files:**

- Create: `lib/application/game_session_factory.dart`
- Test: `test/application/game_session_factory_test.dart`

**Interfaces:**

- Produces:

```dart
GameSessionFactory({
  required StorageService storage,
  required EngagementCubit engagement,
  required LootCubit loot,
  LeaderboardService? leaderboard,
  void Function(Object, StackTrace?, {bool fatal})? onError,
  void Function(String, [Map<String, Object?>?])? onAnalyticsEvent,
  String Function()? todayProvider,
});

GameCubit create({
  required Difficulty difficulty,
  Future<void> Function()? afterCompleted,
});
```

- [ ] Store only the constructor dependencies needed to build callbacks.
- [ ] Create `GameCubit` with completion, nonzero coin, conditional submit,
  observability, storage, and date wiring matching the former screen methods.
- [ ] Return it through `GameCubit(...)..init(difficulty: difficulty)` so
  initialization remains started and unawaited.
- [ ] Run the focused test file and verify all factory tests pass:

```powershell
flutter test test/application/game_session_factory_test.dart
```

### Task 4: Specify the real root-to-route path first

**Files:**

- Create: `test/presentation/game_session_route_test.dart`

**Interfaces:**

- Consumes: `TierSelectScreen.sessions` and a real `GameSessionFactory`.
- Produces: one integration-level widget assertion that the factory-created
  cubit initializes and renders `GameScreen` after a tier tap.

- [ ] Pump `TierSelectScreen` with an injected factory and no
  `onTierSelected`, tap a tier, settle initialization, and assert the pushed
  route contains `GameScreen` and a playing-board control.
- [ ] Pop the game route and settle before closing the injected root cubits or
  tearing down the widget tree.
- [ ] Run the new test and verify it fails because `TierSelectScreen` does not
  yet accept `sessions`:

```powershell
flutter test test/presentation/game_session_route_test.dart
```

### Task 5: Move production composition to the root and slim the screen

**Files:**

- Modify: `lib/main.dart`
- Modify: `lib/presentation/screens/tier_select_screen.dart`
- Test: `test/presentation/game_session_route_test.dart`

**Interfaces:**

- Consumes: `GameSessionFactory.create` from Task 3.
- Preserves: test-first `onTierSelected`, the `_engagement`/`_loot`/`_rivalry`
  state fallbacks, screen notification flow, duel settlement, and navigation.

- [ ] Add nullable `sessions` to `TierSelectScreen`; after the override return,
  use `widget.sessions!.create(difficulty: difficulty,
  afterCompleted: _maybeRequestPermissionThenReschedule)` inside the existing
  `BlocProvider` route.
- [ ] Delete `_onTierCompleted`, `_creditCoins`, and `_submitRun` plus imports
  made unused by their removal. Do not add a factory fallback.
- [ ] In `main`, create and load one `LootCubit`, create one
  `GameSessionFactory` after leaderboard resolution, require both on
  `ConnectMergeApp`, and pass both into `TierSelectScreen`.
- [ ] Add `_ConnectMergeAppState.dispose()` that calls only
  `widget.loot.close()` before `super.dispose()`.
- [ ] After account deletion's wipe, synchronously call
  `widget.engagement.load()`, `widget.rivalry?.load()`, and
  `widget.loot.load()` before the existing best-effort re-authentication.
- [ ] Run the factory test, route test, and existing untouched tier-select
  tests:

```powershell
flutter test test/application/game_session_factory_test.dart test/presentation/game_session_route_test.dart test/presentation/tier_select_screen_test.dart test/presentation/tier_select_overflow_probe_test.dart
```

### Task 6: Format, verify, and audit the frozen plan

**Files:**

- Verify only the scoped changed files; make no unrelated edits.

- [ ] Format only the new and modified Dart files:

```powershell
dart format lib/application/game_session_factory.dart lib/main.dart lib/presentation/screens/tier_select_screen.dart test/application/game_session_factory_test.dart test/presentation/game_session_route_test.dart
```

- [ ] Run fresh static analysis and capture its full tail:

```powershell
flutter analyze
```

- [ ] Run the fresh full test suite and capture its full tail:

```powershell
flutter test
```

- [ ] Re-read root `PLAN.md` line by line and verify every callback, ownership,
  account-deletion reload, screen boundary, test requirement, forbidden path,
  and out-of-scope decision against the read-only diff.
- [ ] Run `git diff --check` and inspect `git status --short`; do not stage,
  commit, branch, checkout, or stash.

