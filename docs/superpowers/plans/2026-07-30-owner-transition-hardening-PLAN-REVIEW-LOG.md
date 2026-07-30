# Plan Review Log: Owner-transition hardening (PR #10 #1-v2)
Act 1 (grill) complete — plan locked with the user. MAX_ROUNDS=5.
PLAN_FILE=docs/superpowers/plans/2026-07-30-owner-transition-hardening-PLAN.md
Reviewer model: gpt-5.6-sol (config default now) — codex-cli 0.144.4.

Thread 019fb28f-1925-7830-9220-8c2276ec0de0.

## Round 1 — Codex
1. HIGH — `_pausing` leaks if `_quiesceForOwnerTransition`'s `_inFlight` drain throws (await is outside try/finally). Fix: move quiesce await inside each caller's try/finally.
2. HIGH — `pauseAndDrain()` independently writes `_pausing`; overlapping a claim, whichever finishes first unpauses the other. Fix: serialize pauseAndDrain on the same chain (or ref-count `_pausing`).
3. MEDIUM — `pauseAndDrain()` has its own pause leak (throw in `_inFlight`/discardStaleDirty skips release). Fix: wrap its paused region in try/finally.
4. MEDIUM — empty-cloud order changes (today arm→log; plan logs while paused then arms; a throwing logger leaves it disarmed). Fix: preserve arm→log.
5. MEDIUM — #1-v2 test under-specified: a guest/cloud-uid mismatch makes old arm() fail its owner check (vacuous pass); clean owner makes "no push" vacuous; zero-delay pump weak. Fix: claimed:true owner matching currentUid, claimEntered completer, external arm()+pushNow, assert old pushes / hardened disarmed+no push.
6. MEDIUM — holding `_transitionLock` across `pushNow(force:true)` wedges later transitions on a hung push. Fix: narrow the serialized region so the forced push is awaited outside the lock.
7. MEDIUM — queued transitions can't quiesce timers promptly while the lock is held across the push. (Same fix as #6.)

Confirmed: no self-deadlock (bootstrap not serialized, acquires lock once); both post-finally arm() gaps are synchronously await-free; bootstrap's line-144 arm() runs with _pausing==false and the owner-validity test is unaffected; late-final valid; _claim() errors still reach callers; ordinary in-flight push creates no lock cycle.

VERDICT: REVISE

### Claude's response — all 7 accepted
- #1: quiesce await moved INSIDE each caller's try/finally.
- #2/#3: `pauseAndDrain` now wrapped in `_serializeTransition` + its own try/finally (serialized against claims; leak-safe).
- #4: empty-cloud restructured to arm()→log (log emitted after the finally+arm).
- #5: strengthened the regression test (claimed:true owner matching currentUid, claimEntered completer, external arm()+pushNow, assert old pushes vs hardened disarmed+no-push).
- #6/#7: narrowed `claimAndPushLocal`'s serialized region — quiesce+claim+recordClaim+arm under the lock; `pushNow(force:true)` awaited OUTSIDE it (next quiesce's `_inFlight` drain preserves ordering).
Kept step 8 (prove the regression test fails without the hardening).

## Round 2 — Codex
1. HIGH — forced-push handoff race: lock releases at closure-return, but `_forcePushPending`/`pushNow` run after the outer await resumes, so a queued transition can interleave (set _pausing, disarm, drain null) before the push. Fix: start pushNow synchronously inside the closure, return (claim, pushFuture) record, await the future outside.
2. MEDIUM — "hung push can't wedge the chain" is false: the next transition acquires the lock then awaits the hung _inFlight in quiesce. Fix: document the transport-completion assumption (a bare Future.timeout is unsafe — the write can still land); + add a boundary test.
Confirmed correct: quiesce finally-covered, pauseAndDrain mutually exclusive + leak-safe, no nested lock, empty-cloud arm/log order preserved, #1-v2 setup deterministic.

VERDICT: REVISE

### Claude's response — both accepted
- #1: `claimAndPushLocal` now returns `(claim, pushFuture)` from the serialized closure — pushNow(force:true) is STARTED synchronously inside the lock (sets _inFlight before release), awaited OUTSIDE. No interleave gap.
- #2: corrected the risk wording — a hung push_profile DOES wedge later transitions via the next quiesce's _inFlight drain, same as pauseAndDrain today, not worsened; relies on transport completion/timeout; a real cancellable RPC is a separate larger change (out of scope). Added the forced-push handoff boundary test.

## Round 3 — Codex
Production code confirmed correct (pseudocode, pause ownership, exception paths, ordering, wedge documentation). One test flaw: the handoff test starts claim #2 after push_profile has begun, when _inFlight already exists in both impls — so it cannot prove the push started inside the lock. Fix: gate claim #1 INSIDE its serialized body, queue claim #2, release claim #1, assert claim1→push1 with claim2 absent until gated push1 completes; prove failure against the outside-lock version.

VERDICT: REVISE

### Claude's response — accepted
Rewrote the boundary test with TWO gates: claim1Gate suspends claim #1's claim_profile inside the serialized body (lock held) while claim #2 queues on _transitionLock; releasing claim1Gate lets claim #1 start push_profile (gated, _inFlight set) and release the lock; assert claim2's claim_profile stays absent until push1Gate completes; final order claim1.claim_profile → claim1.push_profile → claim2.claim_profile. Marked it to be proven failing on the outside-lock version in step 8.

## Round 4 — Codex
The two-gate test now deterministically pins the handoff and fails the outside-lock version. No remaining correctness, deadlock, behavior, or coverage issues.

VERDICT: APPROVED

### Resolution
Converged after 4 rounds. Plan locked and approved. No code written during either act.

## Act 3 — Build (Codex builds, Claude verifies)
Builder model: gpt-5.6-sol (config default). Thread 019fb2f9-22a4-7133-bd10-ed4b41d04387. Codex self-committed as 273f456; touched ONLY profile_sync_service.dart + its test.

### Claude's verdict — VERIFIED
- Full production diff (171 lines) matches the 4-round-approved plan verbatim: `_transitionLock` + `_serializeTransition`; `claimAndRestore`->`_serializeTransition(_claimAndRestore)` with quiesce-in-try, `_pausing` released in finally, arm() after finally, empty-cloud arm->log preserved, corrupt log in try; `claimAndPushLocal` returns `(claim, pushFuture)` — pushNow(force:true) started synchronously inside the lock, awaited outside; `arm()` gains `|| _pausing`; `_quiesceForOwnerTransition` holds `_pausing`; `pauseAndDrain` serialized + own try/finally.
- **Regression tests genuinely catch the bug (Codex's mandatory fail-without-fix run):** without the hardening, test 1 fails `Expected: false, Actual: <true>` (isArmed true during the claim) and test 2 fails with order `[claim1.claim_profile, claim2.claim_profile, claim1.push_profile]` (queued claim interleaves before the push). Both PASS with the hardening.
- Ran proof myself: `flutter analyze` (2 files) -> No issues; proof suites (profile_sync + account_flow_controller + main_test) -> 46/46; broad application+infrastructure -> 403/403.
