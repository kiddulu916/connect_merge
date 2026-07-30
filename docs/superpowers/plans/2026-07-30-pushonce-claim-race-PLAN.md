# Plan: Drain the in-flight push before a claim rebinds the owner
_Locked via grill — by Claude + kiddulu916_

## Goal
Fix a pre-existing concurrency bug (found by Codex during PR #7's review): `ProfileSyncService.claimAndRestore()` and `claimAndPushLocal()` call bare `_disarm()` — which stops NEW pushes but does NOT wait for an in-flight one — before mutating the owner. So a `_pushOnce()` already awaiting its `push_profile` RPC can resume AFTER the owner has been rebound/restored and land its `markPushed(oldRevision)` on the new owner, corrupting the freshly-restored sync state. `pauseAndDrain()` already quiesces correctly; the claim paths must do the same. Client-only.

## Approach
1. Add a private quiesce helper to `ProfileSyncService`. It mirrors the front half of `pauseAndDrain` (`profile_sync_service.dart:431-442`) — critically, it holds `_pausing = true` ACROSS the `await`, so no replacement push can start while we drain (Codex R1 #1: `pushNow` returns clean and `_schedulePush` no-ops when `_pausing`, verified at `:347`/`:340`), and it clears the queue flags (Codex R1 #4):
   ```dart
   /// Quiesce the pusher for an owner transition (claim/restore): block new
   /// pushes, cancel queued/debounced work, disarm, and WAIT for any push
   /// already on the wire so it cannot land its markPushed on an owner about
   /// to be replaced. `_pausing` is held across the await so a concurrent
   /// arm()/write cannot start a replacement push that escapes the drain.
   Future<void> _quiesceForOwnerTransition() async {
     _pausing = true;
     _debounceTimer?.cancel();
     _debounceTimer = null;
     _queued = false;
     _forceQueued = false;
     _disarm();
     final running = _inFlight;
     if (running != null) await running;
     _superseded = false;
     _pausing = false;
   }
   ```
2. In `claimAndRestore()` (`:195-198`) replace `_disarm(); _superseded = false; _forcePushPending = false;` with:
   ```dart
   await _quiesceForOwnerTransition();
   _forcePushPending = false;
   ```
   (The helper already resets `_superseded`; `_forcePushPending = false` stays explicit — a restore clears any pending force-push obligation.)
3. In `claimAndPushLocal()` (`:234-236`) replace `_disarm(); _superseded = false;` with:
   ```dart
   await _quiesceForOwnerTransition();
   ```
   (It sets `_forcePushPending = true` later, at `:247`, intentionally — do NOT clear it here.)
4. **Do NOT refactor `pauseAndDrain`.** Leave that proven method exactly as-is (its `_pausing` window spans the optional `discardStaleDirty`, a sequencing the helper deliberately does not replicate). The ~7-line overlap between the helper and `pauseAndDrain`'s front half is an intentional, documented duplication chosen over perturbing a proven concurrency method.
5. Add a race-regression test to `test/infrastructure/profile_sync_service_test.dart`, mirroring the Completer pattern of `pauseAndDrain waits for an in-flight old-account push` (`:258`). Corrected per Codex R1 #5 (`syncedRevision` is a LOCAL revision — with a single save the captured and current local revisions are equal, so a stale `markPushed` leaves `isDirty == false` and the assertion is vacuous; a SECOND gated save makes it bite):
   - `storage = InMemoryStorageService(currentUserId: () => 'player-1')`; `rebindOwner('player-1', snapshotRevision: 1, claimed: true)`.
   - `pushGate = Completer<dynamic>()`; `rpc`: `push_profile` → `await pushGate.future` then `true`; `claim_profile` → `[{'profile_snapshot': <valid snapshot>, 'snapshot_revision': 5}]`. Record call methods+order.
   - `sync = withSeams(...)..arm()`; `saveProfile(...)` (save #1) then `final push = sync.pushNow();` → `_pushOnce` in-flight, gated on `pushGate` (its captured revision = local rev after save #1).
   - `saveProfile(...)` (save #2, WHILE the push is gated) → advances local revision past the captured one.
   - `final claim = sync.claimAndRestore();` (do NOT await); `await Future<void>.delayed(Duration.zero)`.
   - **Assert drain ordering:** `claim_profile` NOT yet called (claim is blocked in the drain).
   - `pushGate.complete(true); await push; await claim;`.
   - **Assert integrity:** `claim == SnapshotOutcome.restored`; `storage.owner!.snapshotRevision == 5` (restored, not corrupted); `storage.syncedRevision == storage.localRevision` and `storage.isDirty == false` (the restore reset sync state cleanly; the stale push's `markPushed(capturedRev)` did NOT survive to leave a mismatched syncedRevision).
6. Add a SECOND test (Codex R1 #6) for `claimAndPushLocal`'s drain: gate an in-flight push, start `claimAndPushLocal()`, assert it waits (no `claim_profile` until the push drains), then after completion assert the ordering `push → claim_profile → forced new push_profile` and final owner/dirty-state integrity.
7. **Prove both tests catch the bug (Codex confirmed the ordering is deterministic and the `snapshotRevision` assertion alone distinguishes):** run them against the code with the drain REMOVED (revert steps 2-3 to bare `_disarm(); _superseded=false; …`) and confirm they FAIL; restore the drain and confirm they PASS. Record both in the report.
8. Proof: `flutter test test/infrastructure/profile_sync_service_test.dart test/application/account_flow_controller_test.dart test/main_test.dart`, then `flutter test test/application/ test/infrastructure/`. All green.
9. Commit.

## Key decisions & tradeoffs
- **Drain in BOTH `claimAndRestore` and `claimAndPushLocal`.** `claimAndRestore` is the confirmed bug (rebinds a different owner). `claimAndPushLocal` shares the gap; the drain is a safe no-op when nothing is in flight (bootstrap's early call) and correct otherwise.
- **`_quiesceForOwnerTransition` holds `_pausing` across the drain (Codex R1 #1).** This is the robustness fix: snapshotting `_inFlight` once is only safe because `_pausing` blocks any replacement push from starting (`pushNow`/`_schedulePush` both honor it). It also clears `_queued`/`_forceQueued` (Codex R1 #4) so old-session queued work cannot survive the claim.
- **`pauseAndDrain` left untouched (small deliberate duplication).** Safer than refactoring a proven concurrency method whose `_pausing` window intentionally spans `discardStaleDirty`.
- **This is a behavior CHANGE (bug fix), not behavior-preserving.** The regression tests are written to FAIL on the old (un-drained) code and PASS on the new — step 7 proves it.

## Risks / open questions
- **Deadlock:** `_pushOnce` does not transitively await the claim (it awaits only its own `push_profile` RPC + `markPushed`), so `_quiesceForOwnerTransition` cannot self-deadlock. The wait is NOT code-bounded, though — a `push_profile` RPC that never returns stalls the claim indefinitely; this matches `pauseAndDrain`'s existing behavior and the underlying Supabase client's timeout, so it is not made worse here.
- **`restore()` is not independently drained (Codex R1 #2, deferred).** Verified it has NO direct production caller — its only production path is `claimAndRestore` (now drained); the four direct callers are controlled tests. Documented precondition: `restore()` must be invoked with the pusher already quiesced (as `claimAndRestore` does). Independently draining it would add redundant hot-path work; privatizing it would break the tests. Left as a guarded invariant, not a production race.
- **Bootstrap's anonymous-mismatch wipe/rebind (`:155`) is not drained (Codex R1 #3, deferred).** `bootstrap` runs once at startup on a fresh, unarmed service (`_inFlight == null`), so there is nothing to drain; documented as a single-use-pre-arm precondition.
- **`_pausing` is released before the claim RPC + owner mutation (Codex R2 #1-v2, deferred by user decision).** Codex asked to hold `_pausing` through the ENTIRE mutation (try/finally) and serialize overlapping transitions, so a concurrent `arm()` mid-claim could not start a racing push. INVARIANT that makes this unreachable today: nothing re-`arm()`s the sync during an in-flight claim — `arm()`'s only callers are `bootstrap` and the two claim methods, all sequentially awaited by `account_flow_controller`; the sole lifecycle→sync call, `flush()` on paused/detached (`main.dart:391`), early-returns while `!_armed` (i.e. is inert while a claim holds the service disarmed); `resumed` calls `redeemCoordinator.retry()`, not the sync. If a future change makes claims overlap OR calls `arm()`/`pushNow()` concurrently with a claim, revisit this: hold `_pausing` through the owner mutation via try/finally and `arm()` only after. Tracked as a follow-up.

## Out of scope
- Hardening `restore()` and bootstrap against a hypothetical second/concurrent invocation (the two deferred items above — not reachable as races in the current call graph).
- PR A (`writeBlockReason`, shipped) and `canPush`.
- Any change to `_pushOnce`'s own logic, `markPushed`, or the RPC contract.
- The observability/log-message imprecision from PR #7's review (still deferred).
- Server/edge; no TS mirror.
