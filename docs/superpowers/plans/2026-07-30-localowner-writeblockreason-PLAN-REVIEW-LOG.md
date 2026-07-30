# Plan Review Log: `LocalOwner.writeBlockReason`
Act 1 (grill) complete — plan locked with the user. MAX_ROUNDS=5.
PLAN_FILE=docs/superpowers/plans/2026-07-30-localowner-writeblockreason-PLAN.md
Reviewer model: gpt-5.6-sol (`-m`/`-c` override; config's gpt-5.3-codex 400s on ChatGPT-account auth) — codex-cli 0.144.4.

Thread 019fb208-85ee-7d33-80e2-63317396b564.

## Round 1 — Codex
1. **Material:** both proposed `_guardWrite`s call `_currentUserId()` eagerly before `writeBlockReason` runs, whereas current guards never call it when restore/recovery already blocks; a throwing/stateful callback changes exception + side effects. Fix: `writeBlockReason(null) ?? writeBlockReason(_currentUserId())` (lazy session).
2. **Test gap:** planned precedence cases cover restore-vs-mismatch and recovery-vs-mismatch, but never `!restoreComplete && recoveryRequired`; the first precedence edge is unpinned. Fix: add an all-three-blockers case asserting restoreIncomplete.
3. **Technically observable:** const→runtime exception instances change object identity, though no caller relies on identity. Fix (optional): exhaustive switch throwing the existing const exception per reason.
4. **Coupling hazard:** `!= null` auto-classifies every future write-block reason as a recovery/reconcile condition; docs don't enforce the invariant. Fix (optional): exhaustive switches in the UI callers.

Confirmed exact: reason ladder matches both guards; null-session behavior; both main.dart boolean equivalences incl owner==null and use of auth.currentUserId; Hive-keeps / InMemory-omits corruption check is behavior-preserving.

VERDICT: REVISE

### Claude's response
- **#1 (Material) ACCEPTED** — both `_guardWrite`s now use `writeBlockReason(null) ?? writeBlockReason(_currentUserId())`, keeping `_currentUserId()` lazy exactly as today.
- **#2 ACCEPTED** — added the all-three-blockers precedence test (`!restoreComplete && recoveryRequired && mismatch` → restoreIncomplete).
- **#3 REJECTED (noted)** — const→non-const is behaviorally irrelevant (no identity reliance, no `==` override; callers catch by type + read `.reason`). Not worth an exhaustive switch.
- **#4 REJECTED switch / STRENGTHENED doc** — reuse+coupling was the user's locked grill decision; all 3 current reasons ARE recovery/reconcile conditions and the recovery gate's `writeBlockReason(null)` can only return restore/recovery reasons (safe-by-construction). Added a doc-comment INVARIANT instead of two main.dart switches over a 3-value enum.

## Round 2 — Codex
Both material issues addressed: lazy `??` preserves `_currentUserId()` timing and precedence; the all-three-blockers test pins the full ladder. Accepts #3 (exception identity technically observable but unused/non-contractual) and #4 (equivalence exact, choice locked, invariant documents the future obligation) — neither a blocker.

VERDICT: APPROVED

### Resolution
Converged after 2 rounds. Plan locked and approved. No code written during either act.
