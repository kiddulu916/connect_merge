# Plan Review Log: Extract `LocalOwner.canPush`
Act 1 (grill) complete — plan locked with the user. MAX_ROUNDS=5.
PLAN_FILE=docs/superpowers/plans/2026-07-28-storage-sync-canpush-PLAN.md
Reviewer model: gpt-5.6-sol (`-m` override this run; config's gpt-5.3-codex 400s on ChatGPT-account auth) — codex-cli 0.144.4. Thread 019faa3a-5cd3-7983-a1e9-6f9b84185356.

## Round 1 — Codex
Material findings:

1. **The plan falsely claims `_pushOnce()` is regression-pinned.** Existing tests cover rejection before `arm()`, but none makes an already-armed service ineligible before `_pushOnce()`; the new truth-table test only tests `LocalOwner`.
Fix: Add one integration test that arms, creates dirty state, changes the UID/owner, then asserts `flush()` makes no RPC, returns `failed`, logs, and disarms.

2. **`LocalOwner.canPush` overstates what the object knows.** It ignores `_armed`, `_superseded`, `_pausing`, dirty/force state, null ownership, and in-flight mutations; it is only an owner-eligibility predicate, and its public placement invites incorrect reuse by the materially different write guards.
Fix: Prefer a private `_ownerCanPush(LocalOwner owner, String uid)` in `profile_sync_service.dart`, or at minimum rename it `isPushEligibleFor` and document that it is only a preflight subpredicate.

3. **There is an unacknowledged in-flight race.** `_pushOnce()` checks eligibility, awaits the RPC, then `markPushed()` updates whichever owner exists afterward; `reloadProfile()` can call `claimAndRestore()`, which merely disarms without draining the old request. An accepted old push can therefore advance a newly restored owner's revision.
Fix: Drain in-flight pushes before claim/restore owner mutation and add a completer-based race regression test; track this separately if the refactor must remain behavior-only.

4. **The "byte-identical boolean" wording is wrong.** Only the four-field owner rejection subexpression is identical; `arm()` additionally checks `_armed` and `_superseded`, while null UID in `_pushOnce()` returns `failed` without logging or disarming.
Fix: Rewrite the claim as "the four-field owner-eligibility subpredicate is identical" and explicitly preserve each branch's distinct effects.

5. **Observability remains misleading.** Every `_pushOnce()` rejection—including incomplete restore, recovery-required, and unclaimed—is logged as "local owner mismatch"; hiding the fields behind a boolean makes diagnosis harder.
Fix: Log a non-sensitive reason or at least rename the message to "local owner ineligible."

Verification: the four-field predicates are logically identical—`uid != owner.uid || !restoreComplete || recoveryRequired || !claimed` equals `!canPush(uid)` by De Morgan's law. Keeping each caller's current null and sync-state guards does preserve its existing behavior. The write guards are correctly excluded (they allow offline/unclaimed writes, omit `claimed`). Bootstrap's same-UID/unclaimed branch is correctly left alone (routes to claiming, not pushing).

Simpler plan: keep the helper private to `ProfileSyncService`, add the missing `_pushOnce()` integration test, avoid a new public model API and standalone trivial test file.

VERDICT: REVISE

### Claude's response
Codex verified the core is sound (De Morgan equivalence; guards preserve behavior; write-guards/bootstrap correctly excluded). Dispositions:
- **#1 ACCEPTED** — added Approach step 3: a `_pushOnce()` ineligible-branch integration test (arm eligible+claimed → dirty → rebind ineligible uid → push → assert no RPC, `failed`, disarm, log), run pre-refactor so it pins current behavior.
- **#4 ACCEPTED** — corrected the "byte-identical boolean" wording to "four-field owner-eligibility subpredicate is identical," and spelled out each site's preserved guards/branch bodies.
- **#2 PARTIAL** — kept `canPush` public on `LocalOwner` (user locked this home in the grill; a private `_ownerCanPush` in sync reverses it and loses locality). Mitigated the "misuse by write-guard" risk with a MANDATORY doc comment (Approach step 1) stating it is push-eligibility only (requires `claimed`) and must not be reused for the write-guard/UI gate. Rejected the rename as cosmetic; kept the user-approved `canPush` signature.
- **#3 REJECTED for this change / NOTED** — the in-flight push vs claim/restore race is pre-existing; a behavior-preserving refactor must not alter drain semantics. Added to Risks as a tracked separate follow-up (Codex itself said "track separately if behavior-only").
- **#5 REJECTED for this change / NOTED** — the vague log string is pre-existing; changing it is an observable behavior change. Added to Risks as a follow-up tied to the deferred write-guard reason-enum.


## Round 2 — Codex
1. **Not addressed:** the new `_pushOnce()` test is invalid. `rebindOwner()` sets `_syncedRevision = _localRevision`, clearing dirty state; unforced `pushNow()` therefore returns `clean` before `_pushOnce()`. Fix: Call `pushNow(force: true)`, or change `currentUid` after dirtying storage without rebinding.
2. **Acceptably addressed:** the mandatory documentation distinguishes sync-owner eligibility from write guards/UI gates. The private-helper rejection rationale is inaccurate—a private helper would still single-source the fields—but the locked `LocalOwner` placement is implementable. Fix: Remove that inaccurate sentence and describe locality as the chosen tradeoff.
3. **Acceptably deferred:** the in-flight race predates this refactor, is precisely documented, and has a concrete follow-up.
4. **Partially addressed:** subpredicate line is correct, but another line still claims both sites produce a "byte-identical boolean." Fix: change it to "the four-field owner-eligibility subpredicate is identical."
5. **Acceptably deferred:** the misleading log is recorded without altering observable behavior in this refactor.

No other new implementation risks found; the broken integration-test recipe is the material blocker.

VERDICT: REVISE

### Claude's response
Codex confirmed #2/#3/#5 acceptably handled; two real items fixed:
- **#1 ACCEPTED (was a real bug in the test recipe)** — verified against source: `rebindOwner` (`storage_service.dart:300`) clears dirty, and the storage write-guard keys off the STORAGE's `currentUserId` (`:283`), separate from the sync `currentUid` seam. Rewrote Approach step 3 with the valid recipe: dirty via a real write (write-guard still sees matching uid), then flip the MUTABLE sync `currentUid` closure to a different uid (owner untouched, storage stays dirty) → `_pushOnce` hits the ineligible branch; assert no RPC (recording rpc), `failed`, disarm, log.
- **#4 ACCEPTED** — fixed the leftover "byte-identical boolean" in the Risks/ordering bullet.
- **#2 ACCEPTED (wording)** — reframed the private-helper rejection on locality + the locked decision, not on single-sourcing (a private helper would still single-source; Codex was right).

## Round 3 — Codex
All prior findings addressed: (1) revised test preserves dirty state and reaches `_pushOnce()` correctly; (2) `LocalOwner` placement justified and misuse boundaries documented; (3) in-flight race acceptably deferred/tracked; (4) byte-identical wording corrected everywhere; (5) log imprecision acceptably deferred/tracked. No new material problem found. The test recipe is coherent with both the write guard and push queue.

VERDICT: APPROVED

### Resolution
Converged after 3 rounds (Act 1 grill + Act 2 cross-model review). Plan locked and approved. No code written during either act.

## Act 3 — Build (Codex builds, Claude verifies)
Builder model: gpt-5.6-sol (`-c model` override; config's gpt-5.3-codex 400s). Thread 019faa4d-e2d8-7903-8cde-13100cb37b3b.

### Round 1 — Codex build
Codex report: added documented `LocalOwner.canPush`; routed `arm()` and `_pushOnce()` through it; added the `canPush` truth-table unit test and the `_pushOnce` ineligible-owner integration test. `flutter analyze` clean; full `flutter test` 722 passed. Deviations: none. (Process deviation: Codex self-committed as `f62919f` despite the "Codex never commits" contract — Claude will finalize the commit/attribution at the human gate.)

### Claude's verdict — VERIFIED
- Read the full diff (4 files, +73/-11). `lib/` changes are exactly to spec: `canPush = this.uid == uid && restoreComplete && !recoveryRequired && claimed` with the mandatory doc comment distinguishing it from the write-guard/UI gate; both call sites reduced to `!localOwner.canPush(uid)` with every other guard and branch body preserved verbatim. `!canPush(uid)` equals the removed inline predicate by De Morgan.
- Tests faithful to Approach step 3 (mutable sync `currentUid`, real dirtying write, recording rpc, `onLog` capture, `debounce: 1 day` so the timer can't auto-fire, plus a second-write assertion confirming the disarm persisted).
- Ran proof myself: `flutter analyze` on the 4 touched files → No issues; the 3 proof suites → 31/31 pass.
- **Behavior-preservation empirically proven:** reverted the two `lib/` files to pre-refactor (inline predicate, no `canPush`) and re-ran `profile_sync_service_test.dart` → 24/24 pass, including the new `_pushOnce` test. The test pins existing behavior on BOTH old and new code; the refactor changes no behavior. Tree restored clean.
