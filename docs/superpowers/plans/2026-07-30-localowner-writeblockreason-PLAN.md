# Plan: `LocalOwner.writeBlockReason` — single-source the write-guard + main.dart recovery reads
_Locked via grill — by Claude + kiddulu916_

## Goal
Finish the `LocalOwner`-predicate extraction started by `canPush` (PR #7). The write-guard reason ladder (`!restoreComplete → restoreIncomplete`, `recoveryRequired → recoveryRequired`, `session uid != owner.uid → ownerMismatch`) is duplicated in `hive_storage_service.dart` and `InMemoryStorageService`, and `main.dart` re-derives two subsets of the same owner-state check inline. Extract ONE `LocalOwner.writeBlockReason(String? currentUserId) → StorageWriteBlockReason?` that serves all three sites. Behavior-preserving; client-only.

## Approach
1. Add to `LocalOwner` (`lib/infrastructure/storage_service.dart:34`):
   ```dart
   /// The write-guard reason that blocks this owner from writing for
   /// [currentUserId] (null when a write is allowed). Checked in precedence
   /// order restoreIncomplete → recoveryRequired → ownerMismatch, matching the
   /// storage guards. [currentUserId] null means "no session" — offline play
   /// against the last owner stays writable, so ownerMismatch never fires.
   /// This is the write-guard predicate: unlike [canPush] it does NOT require
   /// `claimed` (offline/unclaimed owners may write). `main.dart`'s recovery
   /// reads reuse it (writeBlockReason(null) for the recovery gate,
   /// writeBlockReason(uid) for reconcile) because the booleans coincide.
   /// INVARIANT for that reuse: every [StorageWriteBlockReason] is a
   /// recovery/reconcile condition, so `writeBlockReason(...) != null` is a
   /// sound recovery signal. If a future reason is added that is NOT a
   /// recovery condition, revisit the two `main.dart` call sites.
   StorageWriteBlockReason? writeBlockReason(String? currentUserId) {
     if (!restoreComplete) return StorageWriteBlockReason.restoreIncomplete;
     if (recoveryRequired) return StorageWriteBlockReason.recoveryRequired;
     if (currentUserId != null && currentUserId != uid) {
       return StorageWriteBlockReason.ownerMismatch;
     }
     return null;
   }
   ```
2. Rewrite Hive `_guardWrite` (`hive_storage_service.dart:117-141`) to keep its `ownerRecordCorrupt` top-check and delegate the ladder:
   ```dart
   void _guardWrite() {
     if (ownerRecordCorrupt) {
       throw const StorageWriteBlockedException(
         StorageWriteBlockReason.recoveryRequired,
       );
     }
     final localOwner = owner;
     if (localOwner == null) return;
     // Lazy session lookup (Codex R1 #1): restore/recovery block WITHOUT
     // calling _currentUserId(), exactly as today. Only if those pass do we
     // resolve the session for the ownerMismatch check.
     final reason = localOwner.writeBlockReason(null) ??
         localOwner.writeBlockReason(_currentUserId());
     if (reason != null) throw StorageWriteBlockedException(reason);
   }
   ```
3. Rewrite `InMemoryStorageService._guardWrite` (`storage_service.dart:285-301`) the same way (it has no `ownerRecordCorrupt` check today — `ownerRecordCorrupt` is always false there — so leave that out, keeping the change minimal):
   ```dart
   void _guardWrite() {
     final owner = _owner;
     if (owner == null) return;
     final reason = owner.writeBlockReason(null) ??
         owner.writeBlockReason(_currentUserId()); // lazy session (Codex R1 #1)
     if (reason != null) throw StorageWriteBlockedException(reason);
   }
   ```
4. Rewrite the `main.dart` recovery gate (`:105-108`) — currently `ownerRecordCorrupt || recoveryRequired || !restoreComplete`:
   ```dart
   final bool recoveryRequired = storage.ownerRecordCorrupt ||
       (storage.owner?.writeBlockReason(null) != null);
   ```
   (`writeBlockReason(null) != null` ≡ `!restoreComplete || recoveryRequired`; the null session means ownerMismatch cannot fire.)
5. Rewrite the `main.dart` `mustReconcile` check (`:119-123`) — currently `uid != null && (owner?.recoveryRequired == true || owner?.restoreComplete == false || (owner != null && owner.uid != uid))`:
   ```dart
   final mustReconcile =
       uid != null && (owner?.writeBlockReason(uid) != null);
   ```
   (`writeBlockReason(uid) != null` with `uid` non-null ≡ `!restoreComplete || recoveryRequired || uid != owner.uid`; `owner` null → `owner?.` short-circuits to `null` → `!= null` is false, matching the original.)
6. Add `test/infrastructure/local_owner_test.dart` cases (the file exists from PR #7): `writeBlockReason` truth table — all-clear (claimed or not) → null; `!restoreComplete` → restoreIncomplete (even when also uid-mismatched, proving precedence over ownerMismatch); `recoveryRequired` → recoveryRequired (even when also uid-mismatched, proving precedence over ownerMismatch); **all three blockers active (`!restoreComplete && recoveryRequired && uid mismatch`) → restoreIncomplete (Codex R1 #2 — pins restoreIncomplete over recoveryRequired, the first precedence edge)**; uid mismatch with a session → ownerMismatch; uid mismatch with `null` session → null (offline stays writable).
7. Proof: `flutter test test/infrastructure/local_owner_test.dart test/infrastructure/storage_ownership_test.dart test/infrastructure/hive_ownership_test.dart test/infrastructure/hive_storage_test.dart test/infrastructure/in_memory_storage_test.dart test/main_test.dart`, then `flutter test test/application/ test/infrastructure/ test/presentation/`. All green; behavior unchanged.
8. Commit.

## Key decisions & tradeoffs
- **One `writeBlockReason` predicate, three call sites (write-guard + both `main.dart` reads).** Deepest option: zero duplicated field-reads. The booleans coincide today — `writeBlockReason(null)!=null` is exactly the recovery gate, `writeBlockReason(uid)!=null` is exactly `mustReconcile`'s owner-part (both De-Morgan-verified). Tradeoff: couples the recovery-UI reads to the write-guard's reason semantics; if a future block reason were NOT a recovery condition the reuse would need revisiting. Accepted — flagged in the doc comment.
- **Predicate on `LocalOwner`, wrappers stay in callers (mirror of `canPush`, PR #7).** The reason LADDER moves to `LocalOwner`; each `_guardWrite` keeps its thin wrapper (Hive its `ownerRecordCorrupt` top-check + null-owner return + throw; InMemory the null-owner return + throw). `main.dart` keeps `ownerRecordCorrupt || …` and the `uid != null &&` guard at the call site.
- **Precedence order preserved: restoreIncomplete → recoveryRequired → ownerMismatch.** Both current guards check in that order; a board that is both `!restoreComplete` and uid-mismatched throws `restoreIncomplete` today and must keep doing so. The unit test pins this with combined-condition cases.
- **Lazy session lookup (Codex R1 #1).** Both `_guardWrite`s use `writeBlockReason(null) ?? writeBlockReason(_currentUserId())` so `_currentUserId()` is called only when restore+recovery pass — matching the current guards, which never resolve the session if restore/recovery already blocks. Guards against a stateful/throwing session closure.
- **`throw StorageWriteBlockedException(reason)` is non-const now (Codex R1 #3).** `reason` is a runtime value, so the throw can't be `const`. Behaviorally irrelevant: no caller compares exception identity and the type has no `==` override — callers catch by type and read `.reason`. An exhaustive switch to preserve `const` identity was considered and REJECTED as ceremony for zero benefit.
- **Coupling accepted, not switched (Codex R1 #4).** Reusing `writeBlockReason(...) != null` for the two `main.dart` recovery reads was the locked grill decision. All three current reasons ARE recovery/reconcile conditions, and the recovery gate's `writeBlockReason(null)` can only return restore/recovery reasons (never ownerMismatch), so its `!= null` is safe-by-construction. Codex suggested exhaustive switches in `main.dart` to force deliberate classification of any future reason; REJECTED in favor of the doc-comment invariant (step 1) — a new reason is a deliberate, reviewed act, and two switches over a 3-value enum in `main.dart` cost more than the invariant is worth.

## Risks / open questions
- The reason PRECEDENCE is the only subtle behavior surface; pinned by combined-condition unit tests (step 6) plus the existing `storage_ownership_test` / `hive_ownership_test`.
- `main.dart` reads `storage.owner` twice (recovery gate, then `owner` local in the catch block). Preserve the existing read points; do not hoist in a way that changes when `owner` is sampled.
- No `StorageService` interface change; no new abstract method. Client-only (no TS mirror).

## Out of scope
- The `_pushOnce`/claim-restore race (separate PR B).
- `canPush` (already shipped, PR #7) and the `PrizeLedger`/award methods.
- Any change to `StorageWriteBlockReason` the enum or the exception type.
