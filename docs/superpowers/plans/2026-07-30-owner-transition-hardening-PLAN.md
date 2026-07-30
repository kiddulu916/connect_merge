# Plan: Hold `_pausing` through the claim owner-mutation + serialize transitions
_Locked via grill — by Claude + kiddulu916_

## Goal
Defense-in-depth hardening deferred from PR #10 (Codex #1-v2). `_quiesceForOwnerTransition()` releases `_pausing` BEFORE `claimAndRestore`/`claimAndPushLocal` finish mutating the owner, so a concurrent `arm()` (or an overlapping `pauseAndDrain`) during the claim could re-arm/unpause and start a push that races the unfinished mutation. Unreachable in today's call graph, but harden it: hold `_pausing` through the owner mutation, make `arm()` a no-op while `_pausing`, arm only AFTER the mutation, and serialize ALL owner transitions (both claim methods AND `pauseAndDrain`) on one lock so `_pausing` has a single owner at a time. Client-only. Behavior-preserving for every existing outcome; adds robustness only.

## Approach
1. **`arm()` (`profile_sync_service.dart:~315`): add `_pausing` to the early-return guard**, so ANY `arm()` is a no-op while a transition holds `_pausing`:
   ```dart
   if (_armed || _superseded || uid == null || localOwner == null ||
       !localOwner.canPush(uid) || _pausing) {
     return;
   }
   ```
   Safe for existing callers: `bootstrap`'s `arm()` runs with `_pausing == false`; the claim methods now `arm()` only after releasing `_pausing`.
2. **`_quiesceForOwnerTransition` (`:430`): stop releasing `_pausing`** — remove the trailing `_pausing = false;` (the caller's `finally` releases it). Update the doc: it now LEAVES `_pausing` held; the caller MUST release it in a `finally`, AND must call quiesce INSIDE that `try` (Codex R1 #1 — `_pausing` is set true synchronously before the `_inFlight` drain await, which can throw).
3. **Add the serialization lock:**
   ```dart
   Future<void> _transitionLock = Future<void>.value();

   /// Serializes owner transitions (claim/restore AND pauseAndDrain) so two
   /// cannot interleave their quiesce/mutate/arm sequences or contend on
   /// `_pausing`. Errors do not break the chain.
   Future<T> _serializeTransition<T>(Future<T> Function() body) {
     final run = _transitionLock.then((_) => body());
     _transitionLock = run.then((_) {}, onError: (_) {});
     return run;
   }
   ```
4. **`claimAndRestore` — quiesce inside the `try`; `arm()` after release; preserve empty-cloud arm→log order (Codex R1 #1, #4):**
   ```dart
   Future<SnapshotOutcome> claimAndRestore() =>
       _serializeTransition(_claimAndRestore);

   Future<SnapshotOutcome> _claimAndRestore() async {
     late final SnapshotOutcome outcome;
     var armAfter = false;
     try {
       await _quiesceForOwnerTransition(); // leaves _pausing == true
       _forcePushPending = false;
       final claim = await _claim();
       if (claim == null) {
         outcome = SnapshotOutcome.missingPlayerRow;
       } else {
         final uid = currentUid()!;
         if (claim.snapshot == null) {
           await storage.wipeAccountData();
           await storage.rebindOwner(uid,
               snapshotRevision: claim.revision, claimed: true);
           outcome = SnapshotOutcome.emptySnapshot;
           armAfter = true; // log emitted AFTER arm(), below
         } else if (claim.snapshot is! Map) {
           await storage.markRecoveryRequired(uid,
               snapshotRevision: claim.revision);
           _onLog?.call('profile restore outcome: corrupt');
           outcome = SnapshotOutcome.corrupt;
         } else {
           outcome = await restore(
             Map<String, dynamic>.from(claim.snapshot! as Map),
             serverRevision: claim.revision,
           );
           armAfter = outcome == SnapshotOutcome.restored;
         }
       }
     } finally {
       _pausing = false;
     }
     if (armAfter) arm();
     if (outcome == SnapshotOutcome.emptySnapshot) {
       _onLog?.call('profile restore outcome: empty cloud'); // arm→log, as today
     }
     return outcome;
   }
   ```
   The `corrupt` log stays in the `try` (matches today: no arm on that path). The `restored` log lives inside `restore()` (unchanged; it fires before the post-`finally` `arm()`, same order as today).
5. **`claimAndPushLocal` — START the forced push inside the lock, AWAIT it outside (Codex R2 #1).** Awaiting the push outside a lock that was released at closure-return would let a queued transition interleave between the release and `pushNow`. Instead, inside the serialized closure (after releasing `_pausing` + `arm()`), SYNCHRONOUSLY start `pushNow(force:true)` (which sets `_inFlight` synchronously) and return it in a record; await that future OUTSIDE the lock. The next transition's quiesce then drains this `_inFlight`, so ordering holds and the lock is not held across the network wait:
   ```dart
   Future<SnapshotOutcome> claimAndPushLocal() async {
     final (claim, pushFuture) = await _serializeTransition(() async {
       late final _ClaimedProfile? c;
       try {
         await _quiesceForOwnerTransition();
         c = await _claim();
         if (c != null) {
           await storage.recordClaim(currentUid()!,
               snapshotRevision: c.revision);
         }
       } finally {
         _pausing = false;
       }
       if (c == null) {
         return (null, null) as (_ClaimedProfile?, Future<ProfilePushOutcome>?);
       }
       arm();
       _forcePushPending = true;
       // Start (do NOT await) synchronously: pushNow sets _inFlight before the
       // closure returns, so the lock releases with the push already on the
       // wire and the next transition's quiesce drains it. No interleave gap.
       final pf = pushNow(force: true);
       return (c, pf);
     });
     if (claim == null) return SnapshotOutcome.missingPlayerRow;
     final pushed = await pushFuture!; // awaited OUTSIDE the transition lock
     return switch (pushed) {
       ProfilePushOutcome.pushed ||
       ProfilePushOutcome.clean =>
         SnapshotOutcome.restored,
       ProfilePushOutcome.superseded => SnapshotOutcome.superseded,
       ProfilePushOutcome.failed => SnapshotOutcome.pushFailed,
     };
   }
   ```
6. **`pauseAndDrain` — serialize on the same lock + own `try/finally` (Codex R1 #2/#3):**
   ```dart
   Future<void> pauseAndDrain({bool discardQueuedWork = true}) =>
       _serializeTransition(() async {
         try {
           _pausing = true;
           _debounceTimer?.cancel();
           _debounceTimer = null;
           _queued = false;
           _forceQueued = false;
           _disarm();
           final running = _inFlight;
           if (running != null) await running;
           if (discardQueuedWork) {
             await storage.discardStaleDirty();
             _forcePushPending = false;
           }
           _superseded = false;
         } finally {
           _pausing = false;
         }
       });
   ```
   Same operations as today, now (a) serialized against claims so it can't release a claim's `_pausing`, and (b) leak-safe via `try/finally`.

## Approach — tests
7. Add to `test/infrastructure/profile_sync_service_test.dart`:
   - **`arm()`/`pushNow` are inert while a claim is mutating — the #1-v2 regression (Codex R1 #5):** owner is `claimed: true` matching `currentUid` (so pre-hardening `arm()` would PASS its own owner check — otherwise the test is vacuous). The `claim_profile` rpc completes a `claimEntered` completer, then awaits a `gate` completer. `await claimEntered`; while suspended, call `sync.arm()` AND `unawaited(sync.pushNow(force: true))`; assert `sync.isArmed == false` and NO `push_profile` rpc recorded. Complete `gate`; assert the claim finishes with its normal outcome and (for a restored/empty path) arms. This FAILS on the pre-hardening code (external `arm()` succeeds and pushes during the window).
   - **Overlapping transitions serialize:** start two claims (or a claim + a `pauseAndDrain`) without awaiting; assert the second's `claim_profile` (or drain effect) does not begin until the first completes.
   - **Forced-push handoff boundary (Codex R2/R3 — must distinguish "push started inside the lock"):** starting claim #2 AFTER `push_profile` has begun is vacuous (`_inFlight` exists either way). Instead use TWO gates and queue claim #2 while claim #1 still holds the lock: (a) `claim1Gate` blocks claim #1's `claim_profile` (claim #1 suspended INSIDE its serialized body, lock held); start `claimAndPushLocal` (claim #1); start `claimAndRestore` (claim #2) — it queues on `_transitionLock`. (b) Complete `claim1Gate`; claim #1 finishes the closure (recordClaim → arm → START `push_profile`, which blocks on `push1Gate` and sets `_inFlight`) and releases the lock. Pump; assert `push_profile`(claim1) is recorded and `claim_profile`(claim2) is NOT yet (claim #2's quiesce is draining the in-flight push). (c) Complete `push1Gate`; assert the final rpc order is claim1 `claim_profile` → claim1 `push_profile` → claim2 `claim_profile`. This FAILS on the prior outside-lock version (claim #2's quiesce sees `_inFlight == null` and its `claim_profile` runs before claim #1's `push_profile`); include it in the step 8 fail-without-fix proof.
8. **Prove the #1-v2 test catches the bug:** temporarily revert steps 1–2 (release `_pausing` in quiesce; drop the `arm()` `_pausing` guard) and confirm the "inert while mutating" test FAILS; restore and confirm PASS. Record both runs.
9. Existing `profile_sync_service_test` (incl. `pauseAndDrain waits for an in-flight old-account push`) / `account_flow_controller_test` / bootstrap tests are the behavior-preserving guard.
10. Proof: `flutter test test/infrastructure/profile_sync_service_test.dart test/application/account_flow_controller_test.dart test/main_test.dart`, then `flutter test test/application/ test/infrastructure/`. All green.
11. Commit.

## Key decisions & tradeoffs
- **Serialize ALL owner transitions (both claims AND `pauseAndDrain`) on one chained lock.** Because `_pausing` is a single shared boolean, every operation that sets it must be mutually exclusive, or one can clear another's pause (Codex R1 #2). Serializing is simpler than re-architecting `_pausing` into a ref-count and reuses `serializedPrizeCommit`'s proven pattern; a rare overlap completes in order.
- **`arm()` gains `_pausing`; the claim's `arm()` moves after the release.** While `_pausing` holds (through the mutation) NO push can start (`pushNow`, `_schedulePush`, and now `arm()` all honor it); after release the claim arms normally. The `finally`→`arm()` gap is synchronous (no `await`), so nothing interleaves.
- **The forced push in `claimAndPushLocal` is STARTED inside the lock, AWAITED outside it (Codex R1 #6/#7 + R2 #1).** Holding the lock across the network wait would wedge later transitions on a hung push; awaiting it after a plain lock-release would open an interleave gap before `pushNow`. Starting it synchronously inside the closure (so `_inFlight` is set before release) and awaiting outside gets both: the lock frees promptly, and the next quiesce's `_inFlight` drain still orders any queued transition behind the push.
- **Quiesce runs inside each caller's `try/finally`, and `pauseAndDrain` gets its own.** Guarantees `_pausing` is released even if the drain / storage ops throw (Codex R1 #1/#3).
- **Empty-cloud keeps `arm()`→log order** (Codex R1 #4) so a throwing logger cannot leave the service disarmed and the callback observes the same state.
- **Scope: the two claim methods, `arm()`, quiesce, and `pauseAndDrain`.** `restore()` (only reached via the now-serialized `claimAndRestore`) and bootstrap (single-use pre-arm) stay as-is.

## Risks / open questions
- **Deadlock:** transition bodies never await another transition (claims/pauseAndDrain don't call each other; bootstrap awaits them sequentially and is not itself serialized), so the chain can't self-wait; `onError` heals the lock on a failing body.
- **Hung-push wedge (Codex R2 #2 — documented assumption, not eliminated):** the forced push is awaited outside the lock, but a `push_profile` RPC that NEVER completes still wedges every LATER transition — the next transition's `_quiesceForOwnerTransition` awaits that same hung `_inFlight` during its drain. This is exactly today's behavior (`pauseAndDrain` already awaits `_inFlight`); this change does NOT worsen it. It relies on the Supabase transport eventually completing or erroring. A bare `Future.timeout` is NOT a safe fix (the underlying write can still land after the timeout), so a genuine cancellable/deadlined RPC would be a separate, larger change — out of scope here.
- **`_pausing` leak:** every path that sets `_pausing=true` is inside a `try/finally` that releases it (claims, pauseAndDrain).
- **Behavior preservation:** outcomes, `_onLog` strings + order, and arm-or-not decisions are identical per branch; existing claim/bootstrap/pauseAndDrain tests pin them; the new tests pin only the added robustness.

## Out of scope
- Draining `restore()`/bootstrap independently (still not reachable).
- Re-architecting `_pausing` into ref-count/ownership semantics (serialization suffices).
- `_pushOnce`/`markPushed`/RPC-contract changes; the observability log wording.
- Server/edge; no TS mirror.
