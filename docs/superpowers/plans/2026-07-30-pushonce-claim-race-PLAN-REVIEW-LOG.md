# Plan Review Log: Drain in-flight push before claim
Act 1 (grill) complete — plan locked with the user. MAX_ROUNDS=5.
PLAN_FILE=docs/superpowers/plans/2026-07-30-pushonce-claim-race-PLAN.md
Reviewer model: gpt-5.6-sol (`-m`/`-c` override; config's gpt-5.3-codex 400s on ChatGPT-account auth) — codex-cli 0.144.4.

Thread 019fb21c-47a1-7c71-9ed0-eff47b4bcf01.

## Round 1 — Codex
1. **HIGH** — `_armed==false` not globally guaranteed; a concurrent arm()/claim can re-arm during the drain and the once-snapshotted `_inFlight` lets a replacement future escape. Fix: transition guard honored by arm()/_schedulePush()/pushNow().
2. **HIGH** — direct `restore()` mutates ownership (markRecoveryRequired/startRestore/finishRestore) without draining. Fix: drain at restore() start, or make it private.
3. **MEDIUM** — bootstrap wipe/rebind branches unprotected; safe today (fresh unarmed service) but a repeated call could race. Fix: enforce/document single-use pre-arm, or drain.
4. **MEDIUM** — claim drain doesn't match pauseAndDrain queue semantics; a second pushNow(force:true) can leave `_queued`/`_forceQueued` set. Fix: clear both before draining (as pauseAndDrain does).
5. **MEDIUM** — the `syncedRevision` assertion is ineffective: syncedRevision is a LOCAL revision; with one save captured==current so stale markPushed still leaves isDirty==false. Fix: second gated save, then assert snapshotRevision==5, syncedRevision==localRevision, isDirty==false.
6. **MEDIUM** — claimAndPushLocal's drain untested (bootstrap tests start with _inFlight==null). Fix: add a gated claimAndPushLocal test.

Confirmed: single-op deadlock analysis sound (_pushOnce doesn't await the claim); moving _superseded/_forcePushPending resets after the drain is correct for all branches; bootstrap's early claimAndPushLocal drain is a genuine no-op; the Completer ordering is deterministic and the owner-revision assertion alone would fail old code (5→6) and pass drained.

VERDICT: REVISE

### Claude's response
- **#1 (HIGH) ACCEPTED** — introduced `_quiesceForOwnerTransition()` that holds `_pausing=true` ACROSS the drain-await. Verified `pushNow` (`:347`) and `_schedulePush` (`:340`) both early-return under `_pausing`, so no replacement push can start while draining — the once-snapshot is now safe. Also disarms + clears queue.
- **#4 (MEDIUM) ACCEPTED** — the helper clears `_queued`/`_forceQueued` before draining, matching pauseAndDrain.
- **#5 (MEDIUM) ACCEPTED** — test now does a SECOND gated save and asserts snapshotRevision==5 + syncedRevision==localRevision + isDirty==false.
- **#6 (MEDIUM) ACCEPTED** — added a gated claimAndPushLocal drain test.
- **#2 (HIGH) DEFERRED w/ reason** — verified `restore()` has NO direct production caller (only claimAndRestore, now drained; the 4 direct callers are controlled tests). Not a production race. Privatizing breaks the tests; an independent drain adds redundant hot-path work. Documented restore()'s quiescence precondition as a guarded invariant.
- **#3 (MEDIUM) DEFERRED w/ reason** — bootstrap runs once pre-arm on a fresh unarmed service (_inFlight==null); documented as a single-use-pre-arm precondition.
Kept step 7 (prove the tests FAIL without the drain) as the correctness gate.

## Round 2 — Codex
Accepts #2 (restore) and #3 (bootstrap) deferrals; confirms #4 queue-clear and #5/#6 tests are now specific and deterministic. Holds #1: `_quiesceForOwnerTransition()` releases `_pausing` BEFORE the claim RPC + owner mutation, so a concurrent arm() (or a claim finishing while another is pending) can leave `_armed==true`; after unpausing, a replacement push can start and race the unfinished claim. Fix: reject/serialize overlapping owner transitions and hold `_pausing` through the final owner mutation, releasing it in `finally`, then arm().

VERDICT: REVISE

### Claude's response — #1-v2 judged NOT reachable; surfaced to user
Verified the concurrency call graph:
- `arm()`'s only callers are `bootstrap` and the two claim methods — all sequentially awaited by a single controller (`account_flow_controller`). Nothing calls `arm()` concurrently with an in-flight claim.
- The only lifecycle→sync call is `flush()` on paused/detached (`main.dart:391`); `flush()` early-returns when `!_armed` (`:413`), so it is INERT while a claim holds the service disarmed. `resumed` calls `redeemCoordinator.retry()`, not the sync.
So for a replacement push to race the claim's mutation, some caller must re-`arm()` mid-claim — which no code does. Codex's #1-v2 is sound defense-in-depth for a general primitive but is not reachable here. The full fix (holding `_pausing` through the branchy owner mutation + serializing transitions via try/finally, arming only after) restructures a proven account-recovery flow — real risk for an unreachable scenario. Surfaced the tradeoff to the user for a decision rather than caving or faking convergence.

### Resolution — user-decided tie-break
Codex agreed on all points except #1-v2 (hold `_pausing` through the whole mutation / serialize overlapping transitions). Verified NOT reachable in the current call graph (nothing re-arms mid-claim; flush() inert while disarmed). User chose: ship the targeted fix + document the invariant (same disposition as the accepted restore()/bootstrap deferrals); the deeper primitive hardening is a tracked follow-up. Proceeding to build with the targeted fix. This is a user tie-break, not a Codex APPROVED verdict — logged as such.
