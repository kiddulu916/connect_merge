# Plan: Fix rewarded-ad reward-routing race and non-idempotent grants
_Locked via grill — by Claude + kiddulu916_

## Goal

An audit of all 7 rewarded-ad placements found the ad unit ID setup itself is
correct (one shared `AdConfig.rewardedUnitId`, as AdMob intends — ad unit IDs
identify a slot/format, not a reward type), and every placement's `onReward`
closure calls the right Cubit method for that placement. But `AdService.showRewarded`
has no guard against being called again while an ad is already mid-show or
while a just-earned reward is still being persisted, several screens render
multiple "watch ad" buttons/dialogs with no loading/disabled state, and three
of the seven reward methods have an internal `await` gap that a same-tick
reentrant call can slip through. Fix all four: make `AdService` guarantee at
most one `showRewarded()` call in flight **from tap through reward
persistence** (not just through ad dismissal) — which structurally rules out
two different `onReward` closures ever being attached to the same ad and rules
out a second legitimate watch starting while the first's reward is still being
written — disable every "watch ad" control while one is in flight, and add a
same-tick reentrancy guard to the three `await`-crossing reward methods as
defense-in-depth.

## Approach

1. **`AdService` hardening** (`lib/infrastructure/ad_service.dart`) — this is
   where the fix for the cross-placement race and the drop-a-paid-for-reward
   bug both live; step 3 below is defense-in-depth, not a substitute for this.

   - Add a **private** `final ValueNotifier<bool> _showing = ValueNotifier(false);`
     with a public `ValueListenable<bool> get showing => _showing;` (exposing the
     mutable `ValueNotifier` itself would let any caller flip service state).
   - In `showRewarded`, check `_showing.value` **immediately after the
     `_initialized` check and before touching `_rewarded`** — if already `true`,
     log `ad_busy` and call `onUnavailable()`, with no redundant
     `_preloadRewarded()` call.
   - **`onReward` becomes `Future<void> Function()` (was `void Function()`) —
     this is the actual fix for Codex Round 4's critical finding, not a
     wording change.** Round 3 correctly identified that `_showing` clearing
     on ad *dismissal* (not on reward *persistence* completing) leaves a gap
     where a second legitimate watch can start while the first watch's reward
     write is still in flight. Round 4 then correctly rejected this plan's
     first fix for that gap — a Cubit-side guard that silently drops the
     second call — because the second call is a **paid-for, legitimate**
     reward, and discarding it is a worse bug than the race it was meant to
     prevent. The right fix is to close the gap at its source instead of
     compensating for it downstream: make `AdService` track the `onReward`
     call's own Future and hold `_showing` busy until *both* the ad has been
     dismissed/failed *and* that Future completes.
     ```dart
     Future<void>? _pendingReward;
     ...
     ad.show(onUserEarnedReward: (_, __) {
       if (!rewarded) {
         rewarded = true;
         _pendingReward = onReward();
       }
     });
     ```
     In `onAdDismissedFullScreenContent`, after the existing `ad.dispose()`/
     `_rewarded = null` cleanup: `try { await _pendingReward; } finally {
     _pendingReward = null; _showing.value = false; _preloadRewarded(); }`.
     **The `finally` is load-bearing, not defensive boilerplate** (Codex
     Round 5, critical): without it, an exception thrown by the reward
     method's own persistence (e.g. a Hive write failure) would propagate out
     of the `await` and skip clearing `_showing`/preloading entirely —
     permanently bricking every rewarded placement on the very first storage
     error anyone hits, which is a far worse outcome than the race this whole
     step exists to fix. The callback's declared type (`void
     Function(RewardedAd)`) doesn't require awaiting — making the callback
     body `async` and letting its returned Future run fire-and-forget from
     the SDK's perspective is fine, since our own `_showing` state (not the
     SDK) is what callers actually depend on. Since `Future<void>? await`s a
     no-op instantly when null, this is a no-op on the failed-to-show path
     where no reward fired.
     Every existing call site already returns a `Future<void>` from its
     `onReward` closure for free — `undoAfterReward()`, `grantFreezeToken()`,
     `doubleReward()`, `grantAdReward()`, `grantAdCosmetic()`, `doubleRunCoins()`
     already return `Future<...>`, so `() => cubit.undoAfterReward()` already
     type-checks as `Future<void> Function()`. Only the hint callback
     (`game_screen.dart:330-333`, wraps a synchronous
     `revealNextDropAfterReward()` call) needs a one-line change to `() async
     { ... }` so it satisfies the new signature — harmless since it has no
     real async work.
   - **Telemetry: four distinct events instead of one overloaded
     `ad_load_failed`**: `!_initialized` → `ad_not_initialized`; `ad == null`
     (not yet loaded/still loading) → `ad_not_ready`; `_showing.value` already
     `true` → `ad_busy`; `onAdFailedToShowFullScreenContent` → `ad_show_failed`.
     `ad_load_failed` is reserved strictly for `onAdFailedToLoad` — the only
     branch that's an actual SDK load failure.
   - Add a `_loadingRewarded` bool guard around `_preloadRewarded()` so
     overlapping calls (e.g. `init()` racing a failed-show's retry) can't
     issue two concurrent `RewardedAd.load` calls that complete out of order
     and leak or clobber a loaded ad. **Ordering matters** (Codex Round 4):
     check `!_initialized` → placeholder ID (`AdConfig.isPlaceholder(...)`) →
     `_loadingRewarded` already true, in that order, and only set
     `_loadingRewarded = true` *after* all three checks pass, immediately
     before calling the loader. Setting it `true` before the placeholder
     check would permanently stick it `true` on iOS (the early-return for a
     placeholder ID never reaches a callback that would clear it). Clear
     `_loadingRewarded` in both `onAdLoaded` and `onAdFailedToLoad`; if
     `onAdLoaded` ever fires while `_rewarded` is already non-null
     (defensive), dispose the redundant instance instead of overwriting.
   - **Idempotent cleanup via one shared helper per failure class, not
     duplicated inline logic** (Codex Round 4: "a boolean flag flipping twice
     is harmless, but duplicate analytics events, `onUnavailable` calls,
     disposal, and preload retries are not"): define `_handleLoadFailure()`
     and `_handleShowFailure()` as the *only* place their respective side
     effects happen. `_handleLoadFailure()` guards on `if (!_loadingRewarded)
     return;` as before. `_handleShowFailure()` **cannot** guard on
     `_showing.value` (Codex Round 5, critical): `_showing` is intentionally
     still `true` after a normal dismissal while `_pendingReward` is being
     awaited (see above), so a *stale* future-error from `ad.show(...)`'s
     ignored return value — arriving after the ad already dismissed normally
     and reward persistence is legitimately still in flight — would read
     `_showing.value == true`, wrongly conclude it's the live failure path,
     and clear busy early while `_pendingReward` is still running underneath
     it. Add a separate **per-show** `bool _showTerminalHandled` (reset to
     `false` at the top of `showRewarded` when a show actually starts,
     alongside `rewarded`/`_pendingReward`), and guard both
     `onAdFailedToShowFullScreenContent` and the future-error path on `if
     (_showTerminalHandled) return; _showTerminalHandled = true;` instead —
     this tracks "has *this* show's terminal SDK event already been handled,"
     which is a different question from "is a reward still being persisted."
     Call each helper from both its normal SDK callback (`onAdFailedToLoad` /
     `onAdFailedToShowFullScreenContent`) and from the future-error handling
     below.
   - **Unhandled `Future<void>` from `RewardedAd.load`/`ad.show`**: both calls'
     return values are currently discarded. An error completing outside the
     registered callbacks (e.g. a platform-channel-level failure) would
     otherwise leave `_loadingRewarded`/`_showing` stuck `true` forever,
     silently killing every rewarded placement until app restart. Two
     distinct failure shapes need covering, per Codex Round 4 (a synchronous
     `throw` vs. a returned `Future<void>` that later completes with an
     error — different Dart catch mechanics): wrap the call itself in a
     synchronous `try`/`catch` calling the relevant `_handle*Failure()`, *and*
     chain `.catchError((_) => _handle*Failure())` onto the returned Future.
   - **Why this closes both the cross-placement race and the dropped-reward
     bug:** the existing per-show local `rewarded` latch (already in the
     code) guarantees a single `showRewarded()` call's `onReward` fires at
     most once. `_showing` now stays `true` from tap through reward
     persistence, so no second `showRewarded()` call — and therefore no
     second `onReward` — can start until the first watch's reward has
     actually been written, for any placement. No reward is ever silently
     dropped, and no two `onReward` closures can ever be attached to
     overlapping ad state.
   - Testing seams, mirroring the `AnalyticsService.withSeams` pattern already
     used in this codebase's test suite — **one named constructor, no public
     mutator** (Codex Round 4: a separate `debugSetShowing` method is only
     `@visibleForTesting` by convention/lint, not by the language, so it would
     reopen the exact "any caller can flip service state" hole Round 1 closed
     by making `_showing` private):
     ```dart
     @visibleForTesting
     AdService.withSeams({
       this.analytics,
       bool initialized = true,
       bool showing = false,
       Future<void> Function({required String adUnitId, required AdRequest request,
           required RewardedAdLoadCallback rewardedAdLoadCallback})? loadRewarded,
       String Function()? rewardedUnitIdOverride,
     })
     ```
     `initialized`/`showing` seed the two gate checks directly at construction
     (no post-construction mutation needed — a test wanting a busy service
     just constructs one with `showing: true`). `loadRewarded` defaults to a
     thin wrapper around the real `RewardedAd.load` and lets a test inject a
     call-counting fake to verify `_loadingRewarded` suppresses a second
     concurrent load, that `onAdFailedToLoad` clears it for a retry, and that
     both a synchronously-throwing fake and a `Future<void>.error(...)`-returning
     fake each still clear it (not just one failure shape) — without needing
     to fabricate a real `RewardedAd` instance (a concrete SDK class with no
     test-constructible instances), which is why the success-path "dispose a
     redundant loaded ad" branch stays honestly untestable here, same
     limitation the existing suite already lives with. `rewardedUnitIdOverride`
     defaults to `() => AdConfig.rewardedUnitId` and lets a test supply the
     literal `'null'` directly, proving `AdService` itself — not just the pure
     predicate — skips the load.

2. **UI-level disable-while-showing** (belt-and-suspenders with #1). Rather
   than repeating a `ValueListenableBuilder<bool>` at all 7 call sites, add
   one small shared widget, `lib/presentation/widgets/ad_busy_gate.dart`:
   ```dart
   class AdBusyGate extends StatelessWidget {
     final ValueListenable<bool> busy;
     final VoidCallback? onPressed; // nullable: preserves the caller's own
                                     // eligibility gating (e.g. canUndo)
     final Widget Function(BuildContext context, VoidCallback? onPressed) builder;
     ...
     Widget build(BuildContext context) => ValueListenableBuilder<bool>(
       valueListenable: busy,
       builder: (context, isBusy, _) => builder(context, isBusy ? null : onPressed),
     );
   }
   ```
   `onPressed` is nullable so the gate only ever narrows toward disabled,
   never widens a legitimately-ineligible action to enabled — a required
   non-null `onPressed` would make Undo tappable with an empty undo stack the
   instant the ad is idle.
   - `lib/presentation/screens/game_screen.dart`: the undo `OutlinedButton.icon`
     (line ~264), wrapped in `AdBusyGate`. `HintButton` (line ~259) already
     takes an `enabled: bool` prop (not `onPressed`), so instead of
     `AdBusyGate` it gets a `ValueListenableBuilder<bool>` inline changing
     `enabled: cubit.canUseHint` to `enabled: cubit.canUseHint && !busy`.
   - `RewardedDialog` (`lib/presentation/widgets/rewarded_dialog.dart`) and
     `_CosmeticTile` (`lib/presentation/screens/cosmetics_screen.dart:106-123`)
     **own their buttons internally and currently receive neither `AdService`
     nor a busy listenable** (Codex Round 4 — this plan previously said
     "wrapped in `AdBusyGate`" without specifying how the listenable reaches
     them, which it can't as currently written). Both need an explicit `bool
     busy` constructor param (mirroring the `StreakBanner` fix below, not
     `AdBusyGate`, since both already take a plain `VoidCallback?` prop from
     their parent rather than owning a builder):
     - `RewardedDialog`: add `bool busy = false`; change
       `onPressed: onWatch` to `onPressed: busy ? null : onWatch`. Thread from
       `game_screen.dart`'s `_promptRewarded`, via a `ValueListenableBuilder<bool>`
       on `adService.showing` wrapping the `showDialog` builder.
     - `_CosmeticTile`: add `required bool busy`; change
       `onPressed: onUnlockViaAd` to `onPressed: busy ? null : onUnlockViaAd`.
       Thread from `CosmeticsScreen.build` via a `ValueListenableBuilder<bool>`
       on `widget.adService.showing` wrapping the `ListView`/tile-building code
       (line ~56-75), passing the resolved `busy` value into each tile.
   - `lib/presentation/screens/score_share_screen.dart`: the `double-coins-button`
     (line ~195) and "Watch ad for more moves" button (line ~200), both
     wrapped in `AdBusyGate`. `ScoreShareScreen` is `StatelessWidget` and
     doesn't currently receive `AdService` — add a required
     `ValueListenable<bool> adBusy` constructor param, passed from
     `game_screen.dart` as `adService.showing` at the existing call site
     (line ~163).
   - `lib/presentation/screens/loot_chest_screen.dart`: `double-loot-button`
     (line ~109), wrapped in `AdBusyGate` — already has `adService`.
   - `lib/presentation/screens/tier_select_screen.dart` /
     `lib/presentation/widgets/streak_banner.dart`: `StreakBanner` owns its
     freeze button internally and hides it entirely when `onFreeze` is null
     (`if (onFreeze != null) TextButton.icon(onPressed: onFreeze, ...)`,
     `streak_banner.dart:62-68`) — passing `null` to disable-while-busy would
     make the whole control vanish instead of showing disabled. Add an
     explicit `bool busy` constructor param (default `false`); change
     `onPressed: onFreeze` to `onPressed: busy ? null : onFreeze`, and thread
     `busy` through `tier_select_screen.dart:856` via a
     `ValueListenableBuilder<bool>` on `widget.adService.showing` wrapping the
     `StreakBanner` construction.

3. **Same-tick reentrancy guard, defense-in-depth on the 3 methods with a
   genuine `await` gap**, mirroring the existing `_grantingAd` pattern in
   `GameCubit.grantAdReward()` (`lib/application/game_cubit.dart:576-600`:
   bool set `true` at the top, checked before proceeding, cleared in a
   `finally`). With step 1's fix, `AdService` now guarantees a second
   `showRewarded()` (and therefore a second `onReward`) can't start until the
   first watch's reward is fully persisted — so these three guards are no
   longer covering "a legitimate next watch arrives too early" (step 1 rules
   that out structurally); they cover the narrower case of some other code
   path invoking the same method twice in the same tick (defensive, cheap,
   consistent with the pattern `grantAdReward` already established).
   - **Dropped:** `GameCubit.revealNextDropAfterReward()` — fully synchronous
     (no `await`), so a flag set and cleared within one call can never block a
     second call; the guard would be dead code (Codex Round 1).
   - `GameCubit.undoAfterReward()` (`lib/application/game_cubit.dart:459-462`):
     add `bool _grantingUndo`, same shape as `_grantingAd`.
   - `EngagementCubit.grantFreezeToken()` (`lib/application/engagement_cubit.dart:738-...`):
     add `bool _grantingFreeze`, same shape.
   - `LootCubit.doubleReward()` (`lib/application/loot_cubit.dart:65-75`):
     its existing `base.doubled` check is read before `await
     storage.saveProfile(...)` and only written after (`_claimed = doubled`),
     so two same-tick calls could both pass the guard and both credit coins
     — the same TOCTOU shape `_grantingAd` was built to prevent, missed in
     the original audit because the field write comes after an `await`
     rather than in an obviously-mutating line (Codex Round 1). Add `bool
     _grantingLootDouble`, same shape.

4. **iOS placeholder ad unit IDs**: `AdConfig` currently resolves both real
   and test iOS rewarded/banner unit IDs to the literal string `'null'`
   (`lib/infrastructure/ad_config.dart:13,15,19,21`), pending real iOS unit
   setup. Add a pure, directly-testable static helper to `AdConfig`:
   `static bool isPlaceholder(String unitId) => unitId == 'null';` — a plain
   string comparison with no `Platform.isIOS` dependency, so it's testable
   with literal strings without any platform mocking, which Flutter host
   tests can't do anyway (same constraint `ad_config_test.dart` already lives
   with by not exercising the iOS branch). In `AdService._preloadRewarded()`
   (and `createBanner()` for the banner case), short-circuit before calling
   `RewardedAd.load`/constructing `BannerAd` when
   `AdConfig.isPlaceholder(AdConfig.rewardedUnitId)` /
   `AdConfig.isPlaceholder(AdConfig.bannerUnitId)` is `true` — see step 1 for
   the required ordering relative to `_loadingRewarded`. Skip the network
   round-trip entirely and leave `_rewarded` unset so `showRewarded` falls
   through to its existing `onUnavailable` path. No change to the existing
   `AdConfig` ID fields; only the new helper method is added.

5. **Tests** (existing suite conventions in `test/infrastructure/ad_service_test.dart`
   and `ad_config_test.dart`):
   - `AdConfig`: `isPlaceholder('null')` is `true`; `isPlaceholder(AdConfig.rewardedUnitId)`
     is `false` on the host test platform (resolves to the real Android ID) —
     a pure unit test, no platform mocking.
   - `AdService`, via `AdService.withSeams(...)` — **scoped to what the
     `loadRewarded`-only seam can actually reach** (Codex Round 5 correctly
     caught that earlier drafts of this Tests section implied coverage the
     seam doesn't provide — see the note below):
     - `showing: true` at construction → `showRewarded` hits `onUnavailable`,
       logs `ad_busy`, never touches the in-flight call's callbacks.
     - `initialized: false` (default-constructed) → logs `ad_not_initialized`.
     - `ad == null` (nothing loaded yet) → logs `ad_not_ready`, distinct from
       `ad_load_failed`.
     - Via the injected `loadRewarded` fake, which the seam *can* drive
       directly (it receives the real `rewardedAdLoadCallback` and can invoke
       `onAdFailedToLoad` itself without needing a real `RewardedAd`): two
       overlapping preload triggers invoke the loader once while
       `_loadingRewarded` is true; `onAdFailedToLoad` clears the guard so a
       subsequent preload invokes the loader again; a fake that `throw`s
       synchronously *and* (separate test case) a fake returning
       `Future<void>.error(Exception(...))` each still leave
       `_loadingRewarded` clear afterward rather than stuck — both failure
       shapes, not just one (Codex Round 4). Calling `_handleLoadFailure()`'s
       effects twice (simulate both the callback and the future-error path
       firing) logs `ad_load_failed` exactly once.
     - Via the injected `rewardedUnitIdOverride: () => 'null'`: confirm
       `_preloadRewarded()` never invokes `loadRewarded` at all — the actual
       service-level skip behavior, not just the pure predicate in isolation.
     - **Not achievable with this seam, and no longer claimed as a planned
       test** (Codex Round 5): `onAdFailedToShowFullScreenContent` →
       `ad_show_failed`, the `onReward`-completion-gates-`_showing` behavior,
       and the `_showTerminalHandled` guard against a stale show-future
       error. All three live on the *show* side (`ad.show(...)`,
       `ad.fullScreenContentCallback`, `onUserEarnedReward`), which requires
       a real `RewardedAd` instance to reach at all — the `loadRewarded` seam
       only fakes the *load* call, not the ad object it would hand back on
       success. Building a second seam for the show lifecycle (Codex's
       suggestion: extract a testable coordinator, or inject a show-side
       fake analogous to `loadRewarded`) is real, valuable follow-up work,
       but is a further architecture change beyond this plan's bounded scope
       — noted in Risks; these three behaviors are covered by code review and
       manual on-device QA instead, same honest limitation already
       acknowledged for `onAdLoaded`'s success path.
   - `GameCubit`/`EngagementCubit`/`LootCubit`: a test per new guard
     (`_grantingUndo`, `_grantingFreeze`, `_grantingLootDouble`) that invokes
     the method twice back-to-back without awaiting the first, asserting only
     one grant lands — using each method's existing fake/in-memory storage
     seam.
   - Dropped: no test for double-invoking `revealNextDropAfterReward`, since
     no guard is added there.
   - **UI wiring**: one widget test per affected screen driving the relevant
     busy listenable to `true` and asserting that screen's specific "watch ad"
     control(s) render disabled — `game_screen.dart` (hint, undo,
     `RewardedDialog`'s "Watch" button), `score_share_screen.dart`
     (double-coins + more-moves), `cosmetics_screen.dart` (`_CosmeticTile`'s
     unlock button), `loot_chest_screen.dart` (double-loot),
     `tier_select_screen.dart` (`StreakBanner`'s freeze CTA).

## Key decisions & tradeoffs

- **No per-placement ad unit IDs.** Confirmed this is correct AdMob usage, not
  a gap — unit IDs identify slots/format to the ad network, not reward types.
  Splitting into 7 IDs would only fragment AdMob's fill/eCPM reporting per unit
  with no functional benefit. `adType` string tagging + per-call-site closures
  already correctly distinguish rewards; that closure wiring was independently
  confirmed correct in the audit (no placement grants another's reward).
- **Fix both the service-layer race AND the UI gap**, not just one. The service
  guard alone leaves the pre-show tap window unprotected from a UX standpoint
  (button still looks tappable); the UI guard alone doesn't protect against any
  non-UI caller or a future regression that removes a button's disabled state.
  One shared `ValueNotifier<bool>` in `AdService` drives both, so there's no
  duplicated state to keep in sync.
- **`onReward` became awaitable so `AdService` can close the gap at its
  source, instead of a Cubit-side guard compensating for it (Codex Round 4,
  the most significant revision this plan went through).** The original
  design let `_showing` clear on ad dismissal while a reward method's own
  `await` was potentially still running, then relied on a Cubit-side "am I
  already granting" flag to block a second, legitimate watch's `onReward`
  from firing during that window. Codex correctly called this out as strictly
  worse than the bug it prevented: it would silently discard a reward the
  player just watched a full video ad for. Making `_showing` track the
  reward's own completion (not just the ad's dismissal) closes the gap
  without ever having to choose between "double-grant" and "silently drop a
  paid-for reward" — neither can happen, because a second watch simply can't
  start until the first is fully done, full stop.
- **The 3 Cubit-side guards are now true defense-in-depth, not load-bearing
  for the ad race.** Earlier revisions (Rounds 1 and 3) went back and forth on
  what these guards were actually protecting against — first framed as
  closing the ad race directly, then reframed as covering the "second
  legitimate watch during persistence" gap once Round 3 found `_showing`
  didn't cover it. With that gap now closed at the `AdService` level (see
  above), the guards are back to protecting only same-tick reentrancy from
  some other call path — cheap, consistent with `_grantingAd`'s existing
  precedent, and no longer required to reason about ad timing at all, which
  is a simpler invariant to hold in your head than either prior framing.
- **`LootCubit.doubleReward()` was re-classified from safe to needs-a-guard.**
  The original audit called its `base.doubled` check idempotent, but that
  check is read before `await storage.saveProfile(...)` and only written after
  — the same TOCTOU shape as `_grantingAd` was built to prevent, just missed
  in the first pass because the field write comes after an await rather than
  in an obviously-mutating line. Caught by Codex Round 1; added to step 3.
- **iOS `'null'` handled as a load-skip via string comparison, not a
  platform check.** `AdConfig` keeps the placeholder as-is (it's a known,
  documented "pending real IDs" marker); the fix is purely "don't waste a
  network call on a value we know is a placeholder." Checking the literal
  string rather than `Platform.isIOS` also means it's testable without
  mocking the platform, and once real iOS IDs land, no code path needs to
  change back — the string stops matching and loads proceed normally.
  **Ordering matters** (Codex Round 4): the placeholder check must run before
  `_loadingRewarded` is set `true`, or iOS permanently sticks the load guard
  on after the very first preload attempt.
- **`AdBusyGate.onPressed` is nullable, not required.** A required non-null
  `onPressed` would make `AdBusyGate` its own source of a new bug —
  re-enabling an action whenever the ad is idle regardless of the action's
  own eligibility (e.g. Undo becoming tappable with an empty undo stack).
  Nullable `onPressed` means the gate only ever narrows toward disabled, never
  widens toward enabled (Codex Round 3).
- **`RewardedDialog` and `_CosmeticTile` get an explicit `busy` param, not
  `AdBusyGate`.** Both already take a plain `VoidCallback?` from their parent
  rather than owning a builder-based construction, so a direct `bool busy`
  prop (same treatment as `StreakBanner`) is the smaller diff than retrofitting
  them onto `AdBusyGate`'s API shape (Codex Round 4 — this plan previously
  claimed both were "wrapped in `AdBusyGate`" without this prop existing).
- **Idempotent cleanup lives in one helper per failure class
  (`_handleLoadFailure`/`_handleShowFailure`), not duplicated inline at each
  call site.** A boolean flag being set twice is harmless on its own, but the
  analytics event, `onUnavailable()` call, disposal, and preload retry that
  go with it are not — calling them twice from two different code paths
  reacting to the same underlying failure would double-fire all of them.
  Each helper's own guard clause makes a second call from either path (SDK
  callback vs. `.catchError` on the ignored `Future`) a true no-op (Codex
  Round 4).
- **`AdService.withSeams` takes `initialized`/`showing` as constructor
  params; no separate public mutator method exists.** A `debugSetShowing`
  method marked only `@visibleForTesting` is advisory, not enforced by the
  language — production code could still call it, reopening the "any caller
  can flip service state" hole that making `_showing` private was meant to
  close. Seeding state at construction avoids the method entirely (Codex
  Round 4).
- **`await _pendingReward` in the dismissal handler is wrapped in
  `try`/`finally`, not a bare `await`.** Without it, an exception from the
  reward method's own persistence work would propagate out of the dismissal
  callback and skip clearing `_showing`/`_pendingReward`/preloading —
  permanently bricking every rewarded placement the first time any storage
  write throws, which is strictly worse than the race this step exists to
  fix (Codex Round 5, critical).
- **`_handleShowFailure()`'s idempotency guard is a new per-show
  `_showTerminalHandled` flag, not `_showing.value`.** `_showing` is
  deliberately still `true` after a normal dismissal while reward persistence
  runs (that's the whole point of the awaitable-`onReward` fix above) — so
  guarding show-failure handling on `_showing.value == true` would let a
  *stale* error from `ad.show(...)`'s ignored return Future, arriving after
  a normal dismissal, misread "reward still persisting" as "still the live
  failure path" and clear busy early mid-persistence. A separate flag scoped
  to "has this particular show's terminal event already been handled"
  answers a different question than `_showing` and doesn't have this
  collision (Codex Round 5, critical).
- **Rejected: AdMob server-side reward verification (Codex Round 1, point 10).**
  Codex correctly notes the server never confirms an ad was actually watched
  before honoring a `ContinueEvent` in the replay — a modified client could
  claim ad-gated continues without watching anything. This is real, but it's
  a distinct, larger initiative (AdMob SSV + a server-issued nonce threaded
  through the move log, touching the dual-engine `engine.ts`/`engine.dart`
  surface per `CLAUDE.md`) — not a bug in the reward-routing/idempotency
  wiring this plan is scoped to fix. Flagging as a follow-up, not folding it
  into this plan.
- **Rejected across all five rounds, confirmed by user at Resolution: keep
  the plan at root `PLAN.md`, not also under `docs/superpowers/plans/`.**
  This session runs under the `/grill-me-codex` skill, whose protocol writes
  to root `PLAN.md`/`PLAN-REVIEW-LOG.md`. `docs/superpowers/plans/` is for
  the heavier spec-driven feature workflow; this bug-fix plan doesn't need a
  duplicate copy there. The task-by-task, test-first discipline the point
  was really after still applies during implementation regardless of which
  directory the doc lives in.

## Risks / open questions

- `AdService` is never explicitly disposed today (`main.dart` constructs it at
  line 62 but no call site calls `.dispose()`) — pre-existing, not introduced
  by this plan. The new `_showing` notifier follows the same app-lifetime
  singleton pattern as `_rewarded`; no new call-after-dispose risk is
  introduced beyond what already exists for the banner/rewarded callbacks.
- The `onAdLoaded` success path of the new `_loadingRewarded` guard (disposing
  a redundant ad if one is somehow already cached) can't be independently unit
  tested — `RewardedAd` is a concrete SDK class with no test-constructible
  instances, so no fake `onAdLoaded` callback can supply a real instance. Only
  the suppression-count and failure-path-clears-the-guard behavior are
  covered; the success/dispose branch is exercised by code review and manual
  QA on-device, same limitation the existing test suite already lives with
  for anything downstream of a real ad load.
- `onAdDismissedFullScreenContent`'s body becoming `async` (to `await
  _pendingReward` before clearing `_showing`) means its side effects
  (`_preloadRewarded()`, clearing `_showing`) now happen on a later microtask
  than dismissal itself, rather than synchronously within the callback. Not
  expected to be observable to callers (nothing currently assumes synchronous
  clearing), but worth a note during implementation review in case some other
  code path implicitly relied on it.
- **Show-lifecycle behavior (`ad_show_failed` telemetry, the awaitable-`onReward`
  gating, `_showTerminalHandled`) isn't independently unit-testable with the
  current seams** (Codex Round 5) — same root cause as the `onAdLoaded`
  success-path gap above: `RewardedAd` has no test-constructible instances, so
  nothing can drive `ad.fullScreenContentCallback`/`onUserEarnedReward` in a
  test without a real ad object. Codex's suggested fix — extract the show
  lifecycle into a small coordinator class that doesn't need to hold a real
  `RewardedAd`, or add a second injectable seam mirroring `loadRewarded` for
  the show side — is legitimate and would close this gap, but is an
  additional architecture change beyond this bug-fix plan's scope. Logged as
  follow-up work; these paths are covered by code review and manual on-device
  QA for now.
- **Reward-before-dismissal callback ordering assumption — confirmed by user.**
  Codex Round 5 flagged that the design assumes `onUserEarnedReward` always
  fires before `onAdDismissedFullScreenContent`, which Google's own AdMob
  guarantees but mediated third-party networks aren't contractually bound to
  preserve. Confirmed with the project owner: this ad unit runs Google-only
  demand, no mediation configured — consistent with `pubspec.yaml` listing
  only `google_mobile_ads` with no mediation-adapter package. The plan ships
  as designed; revisit the coordinator design if mediation is ever added
  later.

## Out of scope

- Setting up real iOS AdMob unit IDs (business/account-side task, not code).
- Any change to the shared-unit-ID architecture itself.
- Banner/interstitial ad review (this audit and fix are scoped to rewarded ads only).
- AdMob server-side reward verification / anti-fraud (see rejected point above)
  — real gap, separate initiative.
