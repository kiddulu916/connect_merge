# Plan: Move game-session composition out of tier_select_screen

_Locked via grill — by Claude + kiddulu916._

## Goal

`_TierSelectScreenState` is a composition root wearing a screen costume: it constructs the production `LootCubit` (main.dart never passes one), builds and wires `GameCubit` per tier (`tier_select_screen.dart:321` — the app's only production `GameCubit` site), and owns three application bridges (completion→engagement, coins→wallet+loot-refresh, submit→leaderboard). Extract a small `GameSessionFactory` in `lib/application/` that owns `GameCubit` creation and the bridges, construct it once in `main.dart`, and hoist `LootCubit` creation to `main.dart` — so ALL production composition lives in the root and the screen keeps navigation and rendering only. The screen's local-cubit fallbacks stay as explicitly test-only scaffolding (grill decision), so the ~10 widget-test construction sites are untouched.

## Approach

0. **Repo planning workflow first**: dated design doc under `docs/superpowers/specs/` and task-by-task red-green plan under `docs/superpowers/plans/` (dated 2026-07-18, same format as prior candidates).
1. **Failing tests first** (`test/application/game_session_factory_test.dart`, NEW — the factory is a plain class, unit-testable without widgets):
   - `create(difficulty)` returns an initializing `GameCubit` (tests await the first non-`GameInitial` state) whose completion hook calls `engagement.onTierCompleted` with today's date + the run's score/highestTier, THEN awaits the screen-supplied `afterCompleted` callback (ordering pinned).
   - Coins hook: a nonzero delta goes through `storage.addCoins` (single awaited path) and then `loot.load()` refreshes the balance; a zero delta does neither.
   - Submit hook: with a leaderboard present, `submitRun` forwards date/difficulty/moveLog; with `leaderboard: null` the cubit's `onSubmitRun` is null (offline no-op preserved).
   - Observability: `onError`/`onAnalyticsEvent` are threaded into the created cubit.
2. **`GameSessionFactory`** (`lib/application/game_session_factory.dart`): constructor takes `storage`, `engagement`, `loot`, `leaderboard` (nullable), `crashReporting`/`analytics` hooks (nullable, same function-typed style as the cubits), `todayProvider`. One method:
   `GameCubit create({required Difficulty difficulty, Future<void> Function()? afterCompleted})` — builds the `GameCubit` with exactly today's wiring from `_startTier`/`_onTierCompleted`/`_creditCoins`/`_submitRun` and STARTS `init(difficulty:)` via the same unawaited cascade as today (init is async — `create` does not and cannot return an already-initialized cubit; tests await the first non-`GameInitial` state). The notification-permission flow stays screen-side via `afterCompleted` (a UI concern: contextual permission prompt + reschedule).
3. **Hoist `LootCubit` with a real lifecycle**: `main.dart` creates `LootCubit(storage: storage)..load()` and passes it through `ConnectMergeApp` → `TierSelectScreen`. `_ConnectMergeAppState.dispose()` closes the hoisted `loot` — and ONLY `loot` (Codex round 3): closing the other root cubits there would race the unawaited startup prize checks (`engagement`) and the live deep-link subscription (`duels`), turning a pre-existing benign leak into an emit-after-close crash. Broader root shutdown (deep-link stream disposal + async-task coordination) is explicitly future work.
4. **Account-deletion staleness fix** (pre-existing for engagement/rivalry, would newly hit loot): `_onAccountDeleted` in `ConnectMergeApp` reloads every profile-backed root cubit (`engagement.load()`, `rivalry.load()`, `loot.load()`) after the wipe, so the re-onboarded session can't show the deleted account's coins/streak/chest state.
5. **Slim the screen — no fallback factory**: `TierSelectScreen` gains a nullable `sessions`; `_startTier` checks the `onTierSelected` override FIRST (every widget test returns there), then uses `widget.sessions!` — a missing factory past the override is a contract violation that fails loudly, not a silently-composed duplicate path. `_onTierCompleted`, `_creditCoins`, and `_submitRun` are DELETED from the screen. `_settleDuelIfMatched` and all notification logic stay (they need the messenger/UI context). The existing cubit fallbacks (engagement/loot/rivalry) stay for widget-test ergonomics, binding the STATE fields (`_engagement`, `_loot`) — never the nullable widget params.
6. **Wire `main.dart`**: construct the factory after the services exist, pass `sessions` + `loot` down.
7. **Prove**: new factory unit tests green; ONE new widget test exercises the real root-to-route wiring (inject a factory, no `onTierSelected`, tap a tier → the factory-created `GameCubit` drives `GameScreen`); `flutter analyze` clean; full `flutter test` green — existing widget tests untouched.

## Key decisions & tradeoffs

- **Factory over full AppScope DI** (grill decision): one plain class with one method captures everything that was actually wrong (application wiring in presentation) at ~1/10th the churn of threading an app-scope container through every screen. Rejected: minimal LootCubit-only hoist (leaves the GameCubit wiring — most of the candidate).
- **Cubit fallbacks stay; factory fallback REJECTED** (grill decision, narrowed by Codex round 1): the cubit fallbacks are inert 3-line conveniences sparing ~10 widget-test sites, but a fallback *factory* would textually preserve the exact second composition path this candidate deletes — and no test needs it (every widget test returns at the `onTierSelected` override before the factory is touched). Past the override, `widget.sessions!` fails loudly.
- **`afterCompleted` callback keeps notifications in the screen**: the contextual permission prompt is UX policy tied to screen lifecycle; pushing it into the factory would drag `NotificationService` + profile writes into application wiring for no gain. The factory calls engagement first, then `afterCompleted` — same order as today.
- **Loot refresh moves into the factory's coins hook** (it holds the hoisted `LootCubit`), keeping the "credit then refresh the pill" behavior identical.
- **Factory lives in `lib/application/`** — it wires cubits to services, which is exactly what that layer does; no new abstractions, no interfaces, one implementation.

## Risks / open questions

- `create` starts (never awaits) `init` — callers see the same eventually-initialized cubit `_startTier` produces today; the new widget test and factory unit tests await the first non-`GameInitial` state before asserting.
- Closing `loot` in `_ConnectMergeAppState.dispose()` is new behavior on app teardown only (hot-restart / test harness); production teardown is process death. The new root-wiring widget test must pop the game route before shell teardown so a mid-credit `loot.load()` can't hit a closed cubit.
- The screen keeps reading `widget.leaderboard` for UI decisions (leaderboard buttons/routes); only the submit bridge moves. Offline behavior (buttons hidden, submit no-op) is pinned by existing widget tests.
- `ConnectMergeApp` param growth is mechanical; `main.dart` is already the composition root for everything else, so no test churn there (it has no tests).

## Out of scope

- Closing the pre-existing root cubits (`engagement`/`rivalry`/`duels`) and disposing `DeepLinkService` — a proper root-shutdown needs async-task coordination (the unawaited prize checks) and stream teardown; separate work.
- No AppScope/InheritedWidget DI container; no changes to other screens' service threading.
- No changes to `GameCubit`, `LootCubit`, `EngagementCubit` themselves — only who constructs/wires them.
- Duel settlement, notification scheduling, and navigation stay in the screen (UI concerns).
- `PracticeScreen` (doesn't construct `GameCubit`) untouched.
- No TS mirror, no season bump (client-only; replay logic untouched).
