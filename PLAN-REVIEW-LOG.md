# Plan Review Log: Fix rewarded-ad reward-routing race and non-idempotent grants
Act 1 (grill) complete — plan locked with the user. MAX_ROUNDS=5.

(The prior task's log — first-launch onboarding tour — lives in git history at 278396e.)

## Round 1 — Codex

The plan is not safe to implement yet.

1. **Critical — `_grantingHint` cannot work.** `revealNextDropAfterReward()` is synchronous, so `finally` clears the flag before any second invocation; the proposed "double-invoking synchronously grants once" test is impossible to pass.
   Fix: Enforce exactly-once delivery in `AdService` by atomically consuming the loaded ad and retaining its existing per-show `rewarded` latch; omit `_grantingHint`.

2. **Critical — `LootCubit.doubleReward()` was incorrectly classified as idempotent.** Its doubled state is committed only after `await storage.saveProfile`, so overlapping calls can both pass the guard and credit twice.
   Fix: Add an in-flight guard around `doubleReward()` and an overlapping-call test using blocking storage.

3. **High — transient guards do not identify one ad watch.** A delayed duplicate callback arriving after `undoAfterReward()` or `grantFreezeToken()` completes sees the flag cleared and grants again; those methods cannot distinguish a duplicate from a legitimate later watch.
   Fix: Either guarantee exactly-once entirely in `AdService`, or pass and consume a stable ad-instance reward token.

4. **High — concurrent rewarded loads remain racy.** Every tap while `_rewarded == null` starts another `_preloadRewarded()`; competing completions can overwrite `_rewarded`, leak an ad, or have dismissal of one ad erase another ready ad.
   Fix: Add a `_loadingRewarded` guard, clear it on both load callbacks, dispose stale results, and set `_rewarded = null` when an ad is acquired for showing.

5. **High — the busy check is ordered incorrectly and corrupts telemetry.** Checking it after `ad == null` can initiate another preload, while logging contention as `ad_load_failed` makes load-failure metrics false.
   Fix: Check busy immediately after initialization, before inspecting the cached ad, and report a distinct `ad_busy` event or no event.

6. **High — the iOS test is not implementable as written.** `AdConfig` uses `dart:io Platform.isIOS`, which host Flutter tests cannot override, while preserving the string `'null'` also contradicts the existing `ca-app-pub-` assertions.
   Fix: Represent missing IDs as nullable values and make platform selection injectable or based on an overridable target-platform seam.

7. **Medium — `showing` exposes mutable service state.** Any caller can set the public `ValueNotifier.value`, breaking the lifecycle invariant.
   Fix: Keep a private `_showing` notifier and expose only `ValueListenable<bool>`.

8. **Medium — disposal is incomplete and potentially unsafe.** The app never calls `AdService.dispose()`, and a late SDK callback after notifier disposal would attempt to mutate a disposed notifier.
   Fix: Define explicit ownership, call `adService.dispose()` from that owner, and ignore/dispose late load or fullscreen callbacks after `_disposed`.

9. **Testing gap — the service race cannot be meaningfully exercised with current seams.** Manually setting the public notifier only tests a branch, not callback preservation, dismissal reset, failed-show reset, or competing loads.
   Fix: Add injectable rewarded load/show seams and widget tests proving every affected CTA disables and re-enables on both terminal callbacks.

10. **Security boundary remains client-only.** Server replay validates the legality and cap of `ContinueEvent`, but not that AdMob issued the reward, so a modified client can still claim ad continues without watching ads.
   Fix: Document honest-client-only enforcement, or use AdMob server-side verification with a server-issued nonce if monetization integrity is required.

11. **Repository workflow conflict.** The plan is not under `docs/superpowers/plans/` and does not break work into the required failing-test → implementation → passing-test → commit tasks.
   Fix: Rewrite it into the repository's mandated task-by-task plan format before implementation.

VERDICT: REVISE

### Claude's response

Accepted and revised:
- Point 1: dropped the `_grantingHint` guard entirely (dead code on a sync method); reframed step 1 (AdService `_showing` guard) as the actual fix for the cross-placement race, with the Cubit guards demoted to a narrower, separate "await-gap reentrancy" concern.
- Point 2: added `LootCubit.doubleReward()` to the guarded-methods list (was misclassified safe in the original audit) — real TOCTOU across its `await storage.saveProfile`.
- Point 3: addressed by point 1's reframe — once AdService guarantees exactly-once `showRewarded`, cross-watch races are structurally closed; remaining guards are for same-tick reentrancy only, which they do handle correctly.
- Point 4: added a `_loadingRewarded` guard around `_preloadRewarded()`, cleared on both load callbacks, dispose-on-redundant-load.
- Point 5: reordered the busy check to run immediately after the `_initialized` check (before touching `_rewarded`), and split telemetry into a distinct `ad_busy` event instead of reusing `ad_load_failed`.
- Point 6: changed the iOS check from a `Platform.isIOS` test to a plain string-equality check against the literal `'null'` placeholder — testable without platform mocking, consistent with how `ad_config_test.dart` already avoids the iOS branch.
- Point 7: `_showing` is now private with a `ValueListenable<bool> get showing` accessor.
- Point 9: added a `@visibleForTesting debugSetShowing` seam mirroring the existing `AnalyticsService.withSeams` pattern, so the busy branch is testable without a real AdMob load.

Rejected (logged reason):
- Point 8 (dispose ownership): confirmed via `main.dart` that `AdService.dispose()` is never called today — pre-existing gap, not introduced by this plan. The new `_showing` notifier follows the same app-lifetime-singleton lifecycle as the existing `_rewarded` field; no incremental risk. Noted in Risks section rather than adding new disposal wiring out of scope for this fix.
- Point 10 (AdMob server-side verification): real gap, but a distinct, larger initiative touching the dual-engine replay-verification surface — out of scope for this reward-routing/idempotency bug-fix plan. Logged as a follow-up in "Out of scope."
- Point 11 (plan location): this session was explicitly invoked via `/grill-me-codex`, whose protocol writes to root `PLAN.md`/`PLAN-REVIEW-LOG.md` — kept that location. Accepted the spirit of the point (test-first, task-by-task discipline) for the implementation phase regardless of doc location.

## Round 2 — Codex

Most prior findings are addressed: notifier encapsulation, busy ordering, preload serialization, hint guard removal, loot concurrency, and anti-fraud scoping.

Remaining material issues:

1. **Busy test cannot reach the busy branch.** `showRewarded()` checks `_initialized` before `_showing`, but `debugSetShowing(true)` does not initialize the service.
   Fix: Replace the setter with an `AdService.withSeams` constructor that supplies initialized/busy state.

2. **The placeholder-ID test remains impossible.** Host tests resolve Android IDs, so the inline `'null'` branch cannot be exercised without an ID/platform seam.
   Fix: Inject unit IDs in the test constructor or make platform selection overridable.

3. **The central preload fix is untested.** Tests cover only a manually forced busy branch, not concurrent-load suppression, callback cleanup, or redundant-ad disposal.
   Fix: Inject the rewarded loader and test that two preload requests issue one load and both completion paths clear `_loadingRewarded`.

4. **The goal still overclaims exact idempotency.** Transient Cubit guards block overlapping calls only; delayed sequential duplicates still grant another undo/freeze, and hints remain repeatable.
   Fix: Narrow the goal to overlapping-show/overlapping-write protection, or add persistent reward tokens if delayed duplicates are genuinely in scope.

5. **`StreakBanner` is no longer an open question.** It owns the button and hides it when `onFreeze` is null, so the current API cannot render it disabled.
   Fix: Explicitly add an enabled/busy property and set `onPressed` to null while busy.

6. **No UI-disable tests are planned.** Seven placement changes could compile while one or more buttons remain enabled.
   Fix: Add a busy-state widget test for each affected screen or centralize the binding and test it once.

7. **Telemetry remains mislabeled.** `_rewarded == null` while a preload is still running continues to log `ad_load_failed`, despite the plan reserving that event for genuine failures.
   Fix: Log `ad_not_ready` for missing/loading ads and log `ad_load_failed` from `onAdFailedToLoad` with the SDK error.

8. **Repository planning requirements remain unmet.** The plan is still outside `docs/superpowers/plans/` and is not organized as red → green → commit tasks.
   Fix: Convert it to the mandated task-by-task plan before implementation.

VERDICT: REVISE

### Claude's response

Accepted and revised:
- Point 1: added `AdService.withSeams({analytics, initialized = true, loadRewarded})` named constructor; `debugSetShowing` now reachable in tests because `initialized` can be set directly.
- Point 2: added `AdConfig.isPlaceholder(String)` as a pure static helper, tested with plain string literals (`'null'` vs a real ID) — no platform mocking needed. `AdService` now calls `AdConfig.isPlaceholder(...)` instead of an inline `== 'null'` check.
- Point 3: `AdService.withSeams`' `loadRewarded` param lets tests inject a call-counting fake loader to verify `_loadingRewarded` suppresses concurrent load calls and that `onAdFailedToLoad` clears it for a retry. Noted honestly in Risks that the `onAdLoaded`/redundant-dispose success path stays untestable (RewardedAd has no test-constructible instances) — same limitation the existing suite already has.
- Point 4: reworded Goal to state the actual mechanism ("AdService guarantees at most one showRewarded() in flight, which rules out cross-placement and delayed-duplicate races structurally") instead of implying the 3 Cubit guards deliver general idempotency; added a decision-log entry explaining why the narrower wording is correct (the Cubit guards only need to catch same-tick overlap, because step 1 already rules out delayed duplicates).
- Point 5: added `bool busy` to `StreakBanner`, `onPressed: busy ? null : onFreeze` (keeps the button visible-but-disabled instead of vanishing), threaded from `tier_select_screen.dart` via a `ValueListenableBuilder` on `adService.showing`.
- Point 6: introduced one shared `AdBusyGate` widget wrapping `ValueListenableBuilder<bool>` instead of duplicating the pattern at all 7 call sites; one widget test covers the gating mechanism itself, each call site just wires it in (HintButton is the one exception — its `enabled: bool` API doesn't fit `AdBusyGate`'s `onPressed`-based builder, handled inline instead).
- Point 7: `ad == null` (not-yet-loaded) branch renamed to log `ad_not_ready`; `ad_load_failed` now reserved strictly for `onAdFailedToLoad`.

Rejected (logged reason, unchanged from Round 1):
- Point 8 (plan location): already addressed in Round 1's response — this session runs under `/grill-me-codex`, whose protocol writes to root `PLAN.md`/`PLAN-REVIEW-LOG.md`. Not re-litigating; the task-by-task test-first discipline the point is really after will still apply during implementation regardless of which directory the doc lives in.

## Round 3 — Codex

Most prior findings are now addressed: reachable service seams, preload suppression testing, narrowed idempotency scope, `StreakBanner` behavior, telemetry naming, and UI gating strategy.

Remaining issues:

1. **The core "one `onReward` in flight" claim is false.** `onReward` is `void Function()`, but several callers pass `async` callbacks; dismissal can clear `_showing` while reward persistence is still running.
   Fix: Say "one reward callback dispatch per show," or change the callback to `Future<void>` and keep busy until both dismissal and reward completion.

2. **`AdBusyGate` loses existing eligibility state.** Its required non-null `onPressed` would re-enable Undo whenever the ad is idle, even when `cubit.canUndo` is false.
   Fix: Accept `VoidCallback?` and pass null through whenever either the base callback is null or the ad is busy.

3. **Telemetry cleanup is incomplete.** The uninitialized and failed-to-show branches still log `ad_load_failed`, contradicting "reserved for `onAdFailedToLoad` only."
   Fix: Rename those events to `ad_not_initialized` and `ad_show_failed`.

4. **Ignored SDK futures can strand the new flags.** `RewardedAd.load()` and `show()` return `Future<void>`; an exceptional completion outside the callbacks can leave `_loadingRewarded` or `_showing` permanently true.
   Fix: Attach error cleanup to both returned futures while keeping callback cleanup idempotent.

5. **UI wiring tests are still missing from Step 5.** Testing `AdBusyGate` proves the helper, not that all seven placements use it correctly.
   Fix: Explicitly add one busy-state wiring assertion per affected screen.

6. **`AdConfig.isPlaceholder()` is test-only indirection.** Testing that `unitId == 'null'` recognizes `'null'` does not verify the service short-circuit.
   Fix: Use the direct comparison without a helper, or inject unit IDs into the existing service seam and test the actual skip behavior.

7. **Repository workflow remains unmet.** The plan is still not a dated red → green → commit plan under `docs/superpowers/plans/`.
   Fix: Convert it to the required implementation-plan format before building.

VERDICT: REVISE

### Claude's response

Accepted and revised:
- Point 1: this was a real overclaim, not just wording — corrected the Goal and the step-1 explanatory bullet to state precisely what `_showing` guarantees ("one ad show in flight," not "one reward persisted") and why the 3 Cubit guards are load-bearing for the specific gap this leaves (a second legitimate watch's `onReward` firing while the first watch's `await`-based reward persistence is still running after dismissal cleared `_showing`). Updated the "Key decisions" entry to match — no longer claims the Cubit guards are pure defense-in-depth.
- Point 2: `AdBusyGate.onPressed` changed from required `VoidCallback` to nullable `VoidCallback?`; gate only narrows toward disabled, never widens toward enabled. Added a decision-log entry.
- Point 3: added `ad_not_initialized` (was `ad_load_failed`) for the `!_initialized` branch and `ad_show_failed` (was `ad_load_failed`) for `onAdFailedToShowFullScreenContent` — four distinct events total now (`ad_not_initialized`, `ad_not_ready`, `ad_busy`, `ad_show_failed`), `ad_load_failed` reserved strictly for `onAdFailedToLoad`.
- Point 4: added `try`/`catch`/`.catchError` around the `RewardedAd.load(...)` and `ad.show(...)` calls to clear `_loadingRewarded`/`_showing` on an unhandled future error, as a fallback to the normal callback-based cleanup (idempotent either way). Added a decision-log entry and a test for it.
- Point 5: added an explicit "UI wiring" test bullet — one widget test per affected screen (5 screens) asserting that screen's specific control(s) render disabled when the relevant busy listenable is true.
- Point 6: extended `AdService.withSeams` with `rewardedUnitIdOverride`, letting a test inject `() => 'null'` and assert `_preloadRewarded()` never calls the injected `loadRewarded` fake — genuine service-level coverage of the skip behavior, not just the pure predicate. Kept `AdConfig.isPlaceholder` (still used by real `AdService` code, not test-only indirection once the service itself is testable through it).

Rejected (logged reason, unchanged from Rounds 1-2):
- Point 7 (plan location): third time this point has come up; reaffirming the same rejection — this session runs under `/grill-me-codex`, whose protocol writes to root `PLAN.md`/`PLAN-REVIEW-LOG.md`. Not re-litigating further in the log; the point is noted, not adopted.

## Round 4 — Codex

Most prior findings are addressed, but the revision introduces one critical correctness problem.

1. **Critical — legitimate rewarded ads can now grant nothing.** The plan explicitly allows a second legitimate ad to complete while the first reward persists, then uses a transient guard that silently drops that second reward.
   Fix: Make `onReward` awaitable and keep the global busy state until both dismissal and reward persistence finish; do not use "return if granting" to discard paid-for rewards.

2. **`RewardedDialog` and `_CosmeticTile` cannot be gated as described.** Both own their buttons internally and currently receive neither `AdService` nor a busy listenable.
   Fix: Explicitly thread `ValueListenable<bool>` into both widgets or move their button construction to the owning screens.

3. **SDK-error cleanup is not automatically idempotent.** Setting a boolean twice is harmless, but duplicate analytics, `onUnavailable`, disposal, and preload calls are not.
   Fix: Route callback and Future-error paths through one exact-once guarded cleanup function.

4. **The proposed error test covers the wrong failure mode.** A synchronous throw does not test a returned `Future<void>` completing with an error.
   Fix: Test both `throw` and `Future<void>.error(...)`; the SDK methods return `Future<void>`.

5. **Placeholder ordering remains unspecified.** Setting `_loadingRewarded = true` before returning for `'null'` permanently blocks future loads.
   Fix: Check initialized → placeholder → already-loading, then set `_loadingRewarded = true`.

6. **The public debug setter reopens the state-mutation hole.** `@visibleForTesting` is advisory; production code can still call it.
   Fix: Add initial busy state to `withSeams` and delete `debugSetShowing`.

7. **Repository planning requirements remain unmet.** This still is not a dated red → green → commit plan under `docs/superpowers/plans/`.
   Fix: Convert it before implementation.

VERDICT: REVISE

### Claude's response

Accepted and revised (point 1 was the most substantial change of any round):
- Point 1: this was the correct call — changed `AdService.showRewarded`'s `onReward` parameter from `void Function()` to `Future<void> Function()`, tracked its returned Future as `_pendingReward`, and made `_showing` clear only after both dismissal/failure AND that Future resolving. This closes the gap at its source instead of compensating for it with a guard that discards a legitimate reward. Every existing call site already returns a `Future` from its `onReward` closure except the hint one, which needs a one-line `async` wrapper. Reframed step 3's guards, the Goal, and multiple decision-log entries to match — they're now true defense-in-depth (same-tick reentrancy only), not covering "second legitimate watch during persistence" since that gap no longer exists.
- Point 2: added explicit `bool busy` constructor params to `RewardedDialog` and `_CosmeticTile` (same treatment as `StreakBanner`, not `AdBusyGate`, since both take a plain `VoidCallback?` already rather than a builder), threaded from their parent screens via `ValueListenableBuilder` on the existing `adService`/`widget.adService`.
- Point 3: introduced `_handleLoadFailure()`/`_handleShowFailure()` as the single place each failure's side effects (analytics, `onUnavailable`, disposal, retry) happen, each starting with a guard-clause check so a second call from either the SDK callback or the future-error path is a true no-op.
- Point 4: split the error test into two cases — a synchronously-throwing fake and a separate `Future<void>.error(...)`-returning fake — plus a test that calling the failure helper twice only logs once.
- Point 5: specified the exact check order (`!_initialized` → placeholder → `_loadingRewarded`) and only setting `_loadingRewarded = true` after all three pass, with an explicit decision-log entry explaining why the wrong order permanently breaks iOS.
- Point 6: removed `debugSetShowing` entirely; `AdService.withSeams` now takes `initialized`/`showing` as constructor params, seeding state at construction with no post-construction public mutator.

Rejected (logged reason, unchanged from Rounds 1-3):
- Point 7 (plan location): fourth occurrence of this point across all four rounds; reaffirming the same rejection once more and consolidating it into a single "rejected across all four rounds" entry in the decision log rather than repeating the full reasoning each time.

## Round 5 — Codex (final round, MAX_ROUNDS=5)

Most prior findings are addressed, including legitimate reward completion, internal widget wiring, placeholder ordering, nullable eligibility, and asynchronous SDK errors.

Remaining material issues:

1. **Critical — reward persistence failure permanently bricks rewarded ads.** `await _pendingReward` has no `try/finally`; any storage exception prevents clearing `_pendingReward`/`_showing` and preloading the next ad.
   Fix: Await reward work inside `try/catch/finally`, report the error, and always clear/preload in `finally`.

2. **The planned show/reward tests are impossible with the proposed seams.** Injecting `loadRewarded` cannot produce a `RewardedAd`, so tests cannot simulate dismissal, failed-to-show, or `onUserEarnedReward`.
   Fix: Add a show-lifecycle seam that exposes reward/dismiss/failure callbacks, or extract the lifecycle coordinator into a directly testable class.

3. **`_showing` is not a valid exact-once failure sentinel.** It intentionally remains true after dismissal while reward persistence runs, so a late `show()` Future error can enter `_handleShowFailure`, clear busy early, and duplicate cleanup.
   Fix: Use a separate per-show terminal/failure-handled flag rather than overloading `_showing`.

4. **The design assumes reward always precedes dismissal.** Google ads guarantee that ordering, but mediated networks may choose another order; dismissal could see `_pendingReward == null`, clear busy, then receive a late reward.
   Fix: Explicitly scope this to non-mediated Google ads or design the per-show coordinator to tolerate reward-after-dismissal.

5. **Repository instructions still outrank the grill skill.** Keeping root `PLAN.md` is fine for the review protocol, but implementation still requires the dated red → green → commit plan mandated by `AGENTS.md`.
   Fix: Preserve `PLAN.md` and additionally publish the final implementation plan under `docs/superpowers/plans/`.

VERDICT: REVISE

### Claude's response — MAX_ROUNDS reached, moving to Resolution

Accepted and revised (points 1-3, all correct and cheap):
- Point 1: wrapped `await _pendingReward` in `try`/`finally` in the dismissal handler — `finally` always clears `_pendingReward`/`_showing` and calls `_preloadRewarded()` regardless of whether the reward's own persistence throws. Added a decision-log entry marking this load-bearing, not defensive boilerplate.
- Point 2: this was a real overclaim in Step 5's Tests — the `loadRewarded` seam only fakes the *load* path, not the *show* path, so `ad_show_failed` telemetry, the awaitable-`onReward` gating behavior, and `_showTerminalHandled` genuinely can't be unit-tested with the seams this plan designs. Removed those three test bullets from Step 5 and moved them to Risks as an honest, acknowledged gap (same shape as the pre-existing `onAdLoaded` success-path gap), noting Codex's suggested fix (extract a testable show-lifecycle coordinator) as legitimate future work beyond this plan's scope rather than doing that larger refactor now.
- Point 3: replaced `_handleShowFailure()`'s guard from `_showing.value` (which is deliberately still `true` during in-flight reward persistence after dismissal, per point 1's own fix) to a new dedicated per-show `_showTerminalHandled` flag — closes the specific scenario Codex traced (a stale `ad.show()` future-error arriving after normal dismissal misreading "reward still persisting" as "still the live failure path" and clearing busy early).

Flagged to the user rather than decided unilaterally (both genuinely depend on information/tradeoffs outside what the code can settle):
- Point 4 (mediation ordering): `pubspec.yaml` shows only `google_mobile_ads`, no separate mediation-adapter package — evidence, not proof, that this integration runs Google-only demand (mediation can be configured server-side in the AdMob console with no additional Flutter dependency). Whether that's actually the case is something only the user/project owner knows from their AdMob console config.
- Point 5 (plan location): Codex's ask softened this round from "move it" to "also publish under docs/superpowers/plans/" — a smaller, more reasonable ask than rounds 1-4's version. Bringing to the user rather than rejecting a 5th time outright.

MAX_ROUNDS (5) reached without full APPROVED. Moving to Resolution — presenting the final plan with these two flagged points for the user to decide, not faking convergence.

## Resolution

MAX_ROUNDS (5) reached. Rounds 1-4 fully converged (each REVISE was resolved by either a plan fix or a logged rejection); Round 5 left 2 points that genuinely depended on information outside the code, brought to the user directly rather than decided unilaterally:

1. **AdMob mediation** — user confirmed this ad unit runs Google-only demand, no mediation configured. The reward-before-dismissal ordering assumption holds; plan ships as designed. Revisit the more defensive coordinator design if mediation is added later.
2. **Plan doc location** — user confirmed root `PLAN.md` only, no duplicate under `docs/superpowers/plans/`.

Both points resolved. Plan is locked for implementation.
