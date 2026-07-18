# Game Session Factory and Root Cubit Refresh — Design

Date: 2026-07-18
Status: Approved (frozen by root `PLAN.md` after four adversarial reviews)

## Summary

Per-tier `GameCubit` composition moves from `TierSelectScreen` into one plain
`GameSessionFactory` in `lib/application/`. The factory owns the existing
completion, coin, submission, and observability bridges and starts each cubit's
asynchronous initialization before returning it. Navigation, duel settlement,
and notification permission policy remain in the screen.

`LootCubit` becomes a root-owned cubit created in `main.dart`, loaded once at
startup, passed through `ConnectMergeApp`, and closed by
`_ConnectMergeAppState.dispose`. Account deletion reloads all profile-backed
root cubits after the local wipe so the new anonymous session cannot render the
deleted profile's streak, rivalry, or wallet state.

## Factory contract

`GameSessionFactory` receives `StorageService`, `EngagementCubit`, `LootCubit`,
an optional `LeaderboardService`, optional function-typed `onError` and
`onAnalyticsEvent` hooks, and an optional UTC `todayProvider`. Its single
method is:

```dart
GameCubit create({
  required Difficulty difficulty,
  Future<void> Function()? afterCompleted,
})
```

The returned cubit is created with the same callbacks previously assembled in
`TierSelectScreen` and starts `init(difficulty: difficulty)` through an
unawaited cascade. `create` remains synchronous; consumers that need initialized
state await the first state that is not `GameInitial`.

The completion callback first awaits
`engagement.onTierCompleted(date: todayProvider(), score: score,
highestTier: highestTier)`, then awaits `afterCompleted` when supplied. The
screen supplies its existing contextual notification-permission and reschedule
flow as that callback.

The coin callback returns immediately for a zero delta. A nonzero delta awaits
the single durable `storage.addCoins(delta)` path and then calls `loot.load()`
so the shared wallet state refreshes. The submission callback is null when the
leaderboard is absent; otherwise it forwards only date, difficulty, and move
log to `LeaderboardService.submitRun`, preserving the server-authoritative
replay path. Both observability hooks are passed directly to `GameCubit`.

## Root ownership and refresh

`main.dart` constructs `LootCubit(storage: storage)..load()` and a single
`GameSessionFactory` after the online services are resolved. `ConnectMergeApp`
requires both and passes them into `TierSelectScreen`.

`_ConnectMergeAppState.dispose()` closes only the hoisted loot cubit. It does
not close engagement, rivalry, or duels: engagement can still have unawaited
startup prize checks, while duels remains reachable by the live deep-link
subscription. Coordinating those lifetimes and disposing `DeepLinkService` is
separate work.

After account deletion, `_onAccountDeleted` sets onboarding state, reloads
engagement, optional rivalry, and loot from wiped storage, and best-effort
starts a new anonymous auth session. These synchronous cubit loads happen
after the Profile screen has completed the wipe and popped its routes.

## Screen boundary

`TierSelectScreen` gains a nullable `sessions` parameter. `_startTier` checks
the existing `onTierSelected` test override first. Without the override it uses
`widget.sessions!`, deliberately failing on a production contract violation
instead of rebuilding a hidden fallback composition root.

The screen deletes `_onTierCompleted`, `_creditCoins`, and `_submitRun`. It
retains `_settleDuelIfMatched`, notification permission and rescheduling,
navigation, and the existing local engagement/loot/rivalry cubit fallbacks.
Those fallbacks continue to bind the state fields `_engagement`, `_loot`, and
`_rivalry`, keeping existing widget tests unchanged.

## Proof

Factory unit tests pin initialization, completion ordering and values, zero and
nonzero coin behavior, online/offline submission behavior, and observability
threading. One new presentation widget test injects a real factory without the
tier-selection override, taps a tier, observes a factory-created `GameCubit`
render `GameScreen`, and pops the route before teardown.

Final proof is a clean `flutter analyze` and a green full `flutter test` run.
No existing widget test is edited.

## Out of scope

- Closing engagement, rivalry, or duels, or disposing `DeepLinkService`.
- AppScope, InheritedWidget, service-locator, or other DI infrastructure.
- Moving duel settlement, notification scheduling, or navigation out of the
  screen.
- Changes to `GameCubit`, `LootCubit`, `EngagementCubit`, `RivalryCubit`, or
  `DuelCubit`.
- Other screens' service threading, including `PracticeScreen`.
- Domain, infrastructure, Supabase, TypeScript mirror, season, dependency, or
  package changes.

