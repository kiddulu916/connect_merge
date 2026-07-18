# Plan Review Log: game-session composition out of tier_select_screen (candidate #4)

Act 1 (grill) complete — plan locked with the user. MAX_ROUNDS=5.

(Candidate #1's log lives in git history at b06017f; #2's at 28a539e; #3's at e70490e; #5's at 63c3682.)

Grill decisions: shape = GameSessionFactory in lib/application/ + hoist LootCubit to main.dart (user picked over full AppScope DI and over minimal-hoist-only); screen fallbacks KEPT as documented test-only scaffolding (production always injects after the hoist; ~10 widget-test sites untouched). Settled from code: tier_select_screen.dart:321 is the only production GameCubit site; widget tests use the onTierSelected override so the factory path needs unit tests, not widget-test churn; notification permission flow stays screen-side via an afterCompleted callback.

## Round 1 — Codex

Material lifecycle and wiring gaps remain:

1. Hoisted `LootCubit` has no owner. Today the screen closes locally created loot at [tier_select_screen.dart:189](/C:/Users/dat1k/Projects/connect_merge/lib/presentation/screens/tier_select_screen.dart:189); the plan makes `_ownsLoot` false while `main.dart` never closes it.  
   Fix: Add an explicit root lifecycle owner that closes the hoisted `LootCubit` on disposal.

2. Account deletion leaves the hoisted loot state stale. `wipeAll()` runs before `_onAccountDeleted`, but unlike today, rebuilding `TierSelectScreen` will reuse the old loaded cubit and its pre-deletion balance/chest state.  
   Fix: Reload all profile-backed root cubits—at least `loot`, plus existing `engagement` and `rivalry`—inside `_onAccountDeleted`.

3. The fallback factory is underspecified and can bind the wrong cubits. Building it from nullable `widget.engagement`/`widget.loot` would either fail or create duplicates instead of using the state-owned fallbacks initialized at [tier_select_screen.dart:151](/C:/Users/dat1k/Projects/connect_merge/lib/presentation/screens/tier_select_screen.dart:151).  
   Fix: If retained, construct the fallback factory with `_engagement` and `_loot`, not the nullable widget parameters.

4. The new factory fallback is unnecessary scaffolding. Every listed widget test supplies `onTierSelected`, and `_startTier` returns before constructing a game; none needs a fallback `GameSessionFactory`. The fallback merely preserves a second production-reachable composition path.  
   Fix: After the `onTierSelected` early return, require `widget.sessions` and fail loudly if production omitted it.

5. `create()` cannot truthfully return an “initialized” cubit. `GameCubit.init` is asynchronous, and the existing cascade starts it without awaiting it, so a fresh cubit may still be `GameInitial` when returned.  
   Fix: Specify that `create()` starts initialization, and have tests await the first non-`GameInitial` state before asserting.

6. The proposed tests never exercise the actual root-to-route wiring. Existing widget tests short-circuit navigation, while factory unit tests cannot detect `ConnectMergeApp` forgetting or misrouting `sessions`/`loot`.  
   Fix: Add one widget test using an injected factory without `onTierSelected`, tap a tier, and verify the factory-created `GameCubit` drives `GameScreen`.

VERDICT: REVISE
### Claude's response

Accepted (6/6): hoisted LootCubit gets a real owner — _ConnectMergeAppState.dispose() closes it plus the already-hoisted engagement/rivalry/duels (pre-existing leak, none is closed today) (1); _onAccountDeleted reloads all profile-backed root cubits post-wipe — fixes the NEW loot staleness and the PRE-EXISTING engagement/rivalry staleness (2); fallback-factory idea DELETED — it would preserve the exact second composition path this candidate removes, and no test needs it since every widget test returns at the onTierSelected override; past the override widget.sessions! fails loudly (3, 4); create() contract reworded to "starts init" (async, never awaited — same cascade as today), tests await the first non-GameInitial state (5); one new widget test exercises the real root-to-route wiring (injected factory, no override, tap tier → factory-created GameCubit drives GameScreen) (6).

## Round 2 — Codex

Most prior findings are addressed: account deletion reloads state, the factory fallback is gone, async initialization is acknowledged, and a real route test is planned.

One new material issue:

- Closing `duels` in `ConnectMergeApp.dispose()` leaves `DeepLinkService.onDuel` pointing at the disposed state while its stream subscription remains active; a later link can call a closed cubit.  
  Fix: Keep this change scoped to closing the newly hoisted `LootCubit`, or clear both callbacks and call `deepLinks.dispose()` before closing `duels`.

Minor contradiction: Step 1 still says `create()` returns an “initialized” cubit, while Step 2 correctly says initialization is merely started.  
Fix: Change Step 1 to “initializing `GameCubit`” so the test contract is unambiguous.

VERDICT: REVISE
### Claude's response

Accepted (2/2): dispose() now detaches both DeepLinkService callbacks (onDuel, onInviteCode) BEFORE closing any cubit, so an in-flight link can never reach a closed DuelCubit; step-1 wording fixed to "initializing GameCubit" matching the async-init contract.

## Round 3 — Codex

Async-init wording is fixed. Teardown is only partially fixed:

- Detaching deep-link callbacks prevents calls into closed cubits, but leaves the existing `DeepLinkService` subscription alive.
- Newly closing `EngagementCubit` can race the four unawaited prize checks in `main.dart`, which may later emit into the closed cubit.

Fix: Keep this plan scoped to closing the newly hoisted `LootCubit`; handle broader root shutdown separately with deep-link disposal and async-task coordination.

VERDICT: REVISE
### Claude's response

Accepted (1/1, fully): dispose() scoped to closing ONLY the newly hoisted LootCubit — my round-1 "fix the pre-existing leak while we're here" was scope creep that traded a benign leak for an emit-after-close race (unawaited prize checks into a closed EngagementCubit; live deep-link subscription into a closed DuelCubit). Broader root shutdown moved to Out of scope as named future work. Account-deletion reloads (load(), not close()) stay — they're safe and fix real staleness.

## Round 4 — Codex

Round-3 finding is addressed: teardown now closes only the newly hoisted `LootCubit`, avoiding deep-link and engagement-task races. Async-init wording, account reset, fallback removal, and route-level coverage remain consistent. No new material issues found.

VERDICT: APPROVED
## Act 3 — Build

### Round 1 — Codex build

Thread 019f74ec-273f-7132-9eb0-f9b07f28dc94 (gpt-5.6-sol). Implemented all of PLAN.md in one pass: docs/superpowers spec + red-green plan, GameSessionFactory (exact _startTier/_onTierCompleted/_creditCoins/_submitRun wiring, unawaited init cascade, engagement-before-afterCompleted ordering, zero-delta coins no-op, offline null submit), LootCubit hoisted to main.dart with dispose() closing ONLY it, _onAccountDeleted reloading engagement/rivalry/loot, screen bridges deleted with sessions! past the onTierSelected override, cubit fallbacks intact, 6 factory unit tests + 1 root-to-route widget test. Deviations: none. No git mutations.

### Claude's verdict

Full diff read: factory wiring is line-for-line faithful to the old screen bridges; main.dart is now the sole production composition root; dispose/reload scoping matches the round-3 review decision exactly; remaining screen changes are dart-format cosmetics. Existing widget tests untouched. Proof re-run by Claude: flutter analyze clean; flutter test 535/535 (was 529; +7 new, one pre-existing count overlap). PASSED review, round 1 of 2 — no fix rounds needed.

Shipped: committed to main and pushed after user sign-off; CI validates.
