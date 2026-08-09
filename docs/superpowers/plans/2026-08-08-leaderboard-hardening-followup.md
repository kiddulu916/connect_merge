# Leaderboard Submission Hardening Follow-up Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close four real, still-open gaps in the already-shipped, already-live leaderboard score-submission retry feature (`commit 140c975`, merged 2026-08-01, migration deployed 2026-08-03) — found via continued adversarial review of a stale copy of that feature's design doc, then independently re-verified against the actual shipped code.

**Architecture:** No new subsystems. Each task is a small, targeted patch to existing, already-tested files: the production Supabase client's error handling, the Edge Function's rejection-reason classification, `GameCubit`'s account-scoping check, and a `PopScope` on the result screen route.

**Tech Stack:** Flutter/Dart (client), Deno/TypeScript (Supabase Edge Function), Supabase Postgres (unaffected by this plan — no migration needed).

## Global Constraints

- This feature is LIVE IN PRODUCTION. Every change must be backward-compatible with already-persisted `SubmitStatusRecord` data and already-submitted scores — no data migration, no breaking change to `SubmitStatusRecord.toJson`/`fromJson`.
- `flutter analyze` must stay clean (`flutter_lints` + `strict-casts`/`strict-raw-types`, `prefer_const_constructors`, `prefer_final_locals`, `avoid_print` — see `analysis_options.yaml`).
- The full existing suite must keep passing: `flutter test` (743 tests before this plan) and `deno test --frozen supabase/functions/` (58 tests before this plan). Run the specific affected file after each task's own step, and the full suite once at the end.
- Each task ends with its own commit, following this repo's existing convention: failing test → implementation → passing test → commit.
- Do not add a mocking library (e.g. `mocktail`/`mockito`) — not a current dependency. Follow this repo's existing pattern of testing via injectable seams/fakes and small pure functions (see `LeaderboardService.withSeams`, `InMemoryStorageService`, `supabase/functions/submit-score/best_score.ts`'s test).
- `SubmitOutcome`, `SubmitStatus`, `SubmitStatusRecord`, `LocalOwner` already exist — this plan extends their usage, it does not redefine them.

---

### Task 1: Handle `FunctionException` in the production `LeaderboardService` transport

**Why this is first:** `LeaderboardService`'s production `_invoke` closure (`lib/infrastructure/leaderboard_service.dart:51-57`) assumes `client.functions.invoke()` always returns a value — it never catches an exception. The pinned `functions_client` (2.6.4, confirmed via `pubspec.lock:435` and Supabase's own SDK source) throws `FunctionException` on any non-2xx HTTP response, with the decoded response body on `.details`. `submit-score/index.ts` always responds 422 for a rejection (never 200 with `valid:false`). So today, every real rejection from `submit-score` propagates as a thrown exception all the way to `GameCubit._submitOnce`'s generic `catch` (`lib/application/game_cubit.dart:617-622`), which unconditionally maps ANY exception to `SubmitOutcome.retryableFailure` — meaning `SubmitOutcome.terminalRejection` and its loud `_onError` "possible tampering/parity bug" report are dead code in production today. A genuine replay rejection currently retries silently forever instead of settling and raising the alarm this feature exists to raise.

**Files:**
- Modify: `lib/infrastructure/leaderboard_service.dart:51-57`
- Test: `test/infrastructure/leaderboard_service_test.dart`

**Interfaces:**
- Consumes: `FunctionException` — verified directly against the actually-installed `functions_client-2.6.4` package source (`lib/src/types.dart`), reached transitively via `leaderboard_service.dart`'s existing `import 'package:supabase_flutter/supabase_flutter.dart';` (chain: `supabase_flutter.dart` exports `package:supabase/supabase.dart`, which exports `package:functions_client/functions_client.dart`, which exports `src/types.dart` — no new import needed). Real shape: `class FunctionException implements Exception { final int status; final dynamic details; final String? reasonPhrase; const FunctionException({required this.status, this.details, this.reasonPhrase}); }`. There is only this one exception class in 2.6.4 — no `FunctionsHttpException`/`FunctionsRelayException` subtype split (that hierarchy exists only in a newer, unpinned package version; an earlier draft of this plan assumed it incorrectly). `FunctionsClient.invoke()` (`lib/src/functions_client.dart:206-213`) throws this `FunctionException` on any non-2xx status, `return`s a `FunctionResponse` otherwise — confirmed by reading the method directly. `FunctionResponse` — verified shape: `const FunctionResponse({this.data, required this.status})`.
- Produces: `_invokeSubmitScore(Future<FunctionResponse> Function())` and `_asJsonMap(dynamic)` — private top-level functions in `leaderboard_service.dart`, directly unit-testable without a real `SupabaseClient`. No public API changes — `LeaderboardService`'s constructor signature and `submitRun`'s signature are unchanged.

- [ ] **Step 1: Write the failing tests**

Dart private (`_`-prefixed) top-level members are visible only within their own file, so the two new helper functions this task adds must be public to be unit-tested from `test/infrastructure/leaderboard_service_test.dart`. This matches how `LeaderboardService.withSeams` already exposes a public, test-only constructor for the same reason — expose the two helpers as public top-level functions, documented as implementation details:

```dart
/// Maps a raw Functions invocation outcome to the JSON map [SubmitResult.fromJson]
/// expects. A caught 422 [FunctionException] is treated the same as a normal
/// 2xx submit-score response — its decoded body lives on `.details` — since
/// `submit-score` always responds 422 for an application-level rejection, never
/// 200 with `valid:false`. Any other HTTP status (401, 403, 500, etc.) means the
/// exception is a transport/auth/server failure, not a submit-score verdict, and
/// is rethrown so callers can retry instead of misreading it as a rejection.
Future<Map<String, dynamic>> invokeSubmitScore(
  Future<FunctionResponse> Function() invoke,
) async {
  try {
    final res = await invoke();
    return asJsonMap(res.data);
  } on FunctionException catch (e) {
    if (e.status != 422) rethrow;
    return asJsonMap(e.details);
  }
}

/// Coerces a decoded response body to a JSON map, falling back to an explicit
/// `{'valid': false}` when the body isn't a map (matches [SubmitResult.fromJson]'s
/// existing safe-default behavior for a malformed response shape).
Map<String, dynamic> asJsonMap(dynamic data) {
  if (data is Map) return Map<String, dynamic>.from(data);
  return <String, dynamic>{'valid': false};
}
```

Now write the failing tests. Add this new group to `test/infrastructure/leaderboard_service_test.dart` (add `import 'package:supabase_flutter/supabase_flutter.dart';` and `import 'package:connect_merge/infrastructure/leaderboard_service.dart' show LeaderboardService, invokeSubmitScore, asJsonMap;` — note `leaderboard_service.dart` already has `import 'package:supabase_flutter/supabase_flutter.dart';`, so no export ambiguity; the test file needs its own import for the `FunctionException`/`FunctionResponse` types it constructs directly):

```dart
  group('invokeSubmitScore (production transport, Task 1 hardening)', () {
    test('returns the response data unchanged on success', () async {
      final result = await invokeSubmitScore(() async => FunctionResponse(
            data: {'valid': true, 'score': 500, 'highestTier': 5, 'rank': 1},
            status: 200,
          ));
      expect(result, {
        'valid': true,
        'score': 500,
        'highestTier': 5,
        'rank': 1,
      });
    });

    test('a caught 422 FunctionException is parsed as a verdict body',
        () async {
      final result = await invokeSubmitScore(() async => throw
          const FunctionException(
            status: 422,
            details: {'valid': false, 'reason': 'invalid_run'},
          ));
      expect(result, {'valid': false, 'reason': 'invalid_run'});
    });

    test('a non-422 FunctionException rethrows instead of being parsed',
        () async {
      expect(
        () => invokeSubmitScore(() async => throw
            const FunctionException(status: 401, details: null)),
        throwsA(isA<FunctionException>()),
      );
    });

    test('a 500 FunctionException with a JSON-decodable body still rethrows',
        () async {
      // Not every JSON-shaped exception body is a submit-score verdict — a
      // server error can also return a JSON body, and must not be
      // misclassified as an application rejection.
      expect(
        () => invokeSubmitScore(() async => throw
            const FunctionException(
              status: 500,
              details: {'error': 'internal'},
            )),
        throwsA(isA<FunctionException>()),
      );
    });

    test('a non-FunctionException transport error still propagates',
        () async {
      expect(
        () => invokeSubmitScore(() async => throw Exception('network down')),
        throwsException,
      );
    });
  });

  group('asJsonMap', () {
    test('passes a map through', () {
      expect(asJsonMap({'valid': true}), {'valid': true});
    });

    test('falls back to valid:false for a non-map body', () {
      expect(asJsonMap('not a map'), {'valid': false});
      expect(asJsonMap(null), {'valid': false});
    });
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/infrastructure/leaderboard_service_test.dart`
Expected: FAIL — `invokeSubmitScore`/`asJsonMap` are undefined names (not yet added to `leaderboard_service.dart`).

- [ ] **Step 3: Implement**

In `lib/infrastructure/leaderboard_service.dart`, add the two functions above (`invokeSubmitScore`, `asJsonMap`) as top-level functions in the file (placed after the imports, before the `SubmitResult` class). Then replace the production constructor's `_invoke` closure:

Replace:
```dart
  /// Production constructor: wires the seams to [client].
  LeaderboardService(SupabaseClient client)
      : _invoke = ((fn, body) async {
          final res = await client.functions.invoke(fn, body: body);
          final data = res.data;
          if (data is Map) return Map<String, dynamic>.from(data);
          return <String, dynamic>{'valid': false};
        }),
```

With:
```dart
  /// Production constructor: wires the seams to [client].
  LeaderboardService(SupabaseClient client)
      : _invoke = ((fn, body) =>
            invokeSubmitScore(() => client.functions.invoke(fn, body: body))),
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/infrastructure/leaderboard_service_test.dart`
Expected: PASS, all tests including the pre-existing ones in this file (the production constructor's public behavior — `submitRun` sends the right payload, `fetch`/`fetchPeriod`/`myDailyRanks`/`myPeriodRanks` unaffected — is unchanged; only the internal error-handling path changed).

Also run: `flutter analyze` — expected clean.

- [ ] **Step 5: Commit**

```bash
git add lib/infrastructure/leaderboard_service.dart test/infrastructure/leaderboard_service_test.dart
git commit -m "fix(leaderboard): catch 422 FunctionException in production transport

The production _invoke closure never caught the real Supabase client's
FunctionException on a non-2xx response, so every genuine submit-score
rejection propagated as a thrown exception instead of a normal SubmitResult
— making SubmitOutcome.terminalRejection and its tampering/parity-bug alert
dead code in production. Now catches a 422 specifically (submit-score's own
verdict status) and parses its decoded body the same way a 2xx response is
read; any other status still rethrows as a transport/auth/server failure."
```

---

### Task 2: Split `submit-score`'s conflated `invalid_run` reason

**Why this matters now, not before Task 1:** `submit-score/index.ts` returns `reason: "invalid_run"` for five distinct causes — malformed JSON, a missing/mistyped `date`/`difficulty`, an unrecognized difficulty, a stale/non-today date, AND an actual replay-verification failure. Only the last is a genuine "this exact move log can never succeed" case. Before Task 1, this conflation didn't matter in practice (every 422 was misclassified as retryable regardless of its reason string). Now that Task 1 makes the reason string actually reach the client, a malformed-request bug or a clock-skew date would incorrectly settle as permanently terminal alongside real replay rejections.

**Files:**
- Create: `supabase/functions/submit-score/validate_request.ts`
- Create: `supabase/functions/submit-score/validate_request.test.ts`
- Modify: `supabase/functions/submit-score/index.ts:1-73`

**Interfaces:**
- Produces: `validateSubmitRequest(payload: unknown, utcToday: string): ValidatedRequest`, where `ValidatedRequest = { ok: true; date: string; difficulty: Difficulty; moveLog: unknown } | { ok: false; reason: "malformed_request" | "stale_date" }`. `index.ts` consumes this; no other file depends on it.
- **No change needed in `lib/application/game_session_factory.dart`** — `_submitRun`'s existing mapping (`game_session_factory.dart:70-72`, `result.reason == 'invalid_run' ? SubmitOutcome.terminalRejection : SubmitOutcome.retryableFailure`) already treats anything other than the literal string `'invalid_run'` as retryable. It was already written generically; only the server was conflating reasons under one string.

- [ ] **Step 1: Write the failing test**

Create `supabase/functions/submit-score/validate_request.test.ts`:

```typescript
import { validateSubmitRequest } from "./validate_request.ts";

function assertEquals(actual: unknown, expected: unknown): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `Expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    );
  }
}

const TODAY = "2026-08-08";

Deno.test("validateSubmitRequest: accepts a well-formed same-day request", () => {
  const result = validateSubmitRequest(
    { date: TODAY, difficulty: "easy", moveLog: [] },
    TODAY,
  );
  assertEquals(result, { ok: true, date: TODAY, difficulty: "easy", moveLog: [] });
});

Deno.test("validateSubmitRequest: null payload is malformed_request", () => {
  assertEquals(validateSubmitRequest(null, TODAY), {
    ok: false,
    reason: "malformed_request",
  });
});

Deno.test("validateSubmitRequest: non-object payload is malformed_request", () => {
  assertEquals(validateSubmitRequest("not an object", TODAY), {
    ok: false,
    reason: "malformed_request",
  });
});

Deno.test("validateSubmitRequest: missing/mistyped date is malformed_request", () => {
  assertEquals(
    validateSubmitRequest({ date: 123, difficulty: "easy", moveLog: [] }, TODAY),
    { ok: false, reason: "malformed_request" },
  );
});

Deno.test("validateSubmitRequest: missing/mistyped difficulty is malformed_request", () => {
  assertEquals(
    validateSubmitRequest({ date: TODAY, difficulty: 5, moveLog: [] }, TODAY),
    { ok: false, reason: "malformed_request" },
  );
});

Deno.test("validateSubmitRequest: unrecognized difficulty is malformed_request", () => {
  assertEquals(
    validateSubmitRequest(
      { date: TODAY, difficulty: "impossible", moveLog: [] },
      TODAY,
    ),
    { ok: false, reason: "malformed_request" },
  );
});

Deno.test("validateSubmitRequest: a date that isn't the server's today is stale_date, not malformed_request", () => {
  assertEquals(
    validateSubmitRequest(
      { date: "2026-08-01", difficulty: "easy", moveLog: [] },
      TODAY,
    ),
    { ok: false, reason: "stale_date" },
  );
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `deno test supabase/functions/submit-score/validate_request.test.ts`
Expected: FAIL — `./validate_request.ts` does not exist.

- [ ] **Step 3: Implement**

Create `supabase/functions/submit-score/validate_request.ts`:

```typescript
// Pre-replay-verification request validation for submit-score, split into
// its own testable module (mirrors this repo's existing pattern of
// extracting Edge Function logic into small pure files — see best_score.ts,
// match-contacts/sanitize.ts — rather than testing Deno.serve handlers
// directly).
//
// Distinguishes causes that were previously conflated under one
// "invalid_run" reason: a malformed/unrecognized request (client bug, may be
// fixed by a later client update) and a stale date (clock skew or a genuine
// backfill attempt) are both classified separately from "invalid_run",
// which this module never returns — that reason is reserved exclusively for
// an actual replay-verification failure, decided later in index.ts after
// this validation passes.

import { Difficulty, isDifficulty } from "../_shared/constants.ts";

export type ValidatedRequest =
  | { ok: true; date: string; difficulty: Difficulty; moveLog: unknown }
  | { ok: false; reason: "malformed_request" | "stale_date" };

/** Validates and classifies a submit-score request body against the
 * server's own notion of "today" ([utcToday]). Never returns
 * "invalid_run" — that reason belongs solely to replay-verification
 * failure, decided in index.ts after this function returns `ok: true`. */
export function validateSubmitRequest(
  payload: unknown,
  utcToday: string,
): ValidatedRequest {
  if (payload === null || typeof payload !== "object") {
    return { ok: false, reason: "malformed_request" };
  }
  const { date, difficulty, moveLog } = payload as {
    date?: unknown;
    difficulty?: unknown;
    moveLog?: unknown;
  };
  if (typeof date !== "string" || typeof difficulty !== "string") {
    return { ok: false, reason: "malformed_request" };
  }
  if (!isDifficulty(difficulty)) {
    return { ok: false, reason: "malformed_request" };
  }
  // No backfilling other days: the submitted date must be the server's UTC
  // today. This is a stale_date, not a malformed_request — the request
  // shape is fine, only its timing is wrong (clock skew or backfill).
  if (date !== utcToday) {
    return { ok: false, reason: "stale_date" };
  }
  return { ok: true, date, difficulty, moveLog };
}
```

Now modify `supabase/functions/submit-score/index.ts`. Replace the header comment block (lines 9-13):

```typescript
// Responses:
//   200 { valid, score, highestTier, rank }
//   401 no/invalid auth
//   422 { valid:false, reason:"malformed_request" } (unparseable/invalid shape)
//   422 { valid:false, reason:"stale_date" }        (not the server's UTC today)
//   422 { valid:false, reason:"invalid_run" }       (replay verification failed)
//   422 { valid:false, reason:"submit_failed" }     (retryable database failure)
```

Add the import (after the existing imports, line 19):
```typescript
import { validateSubmitRequest } from "./validate_request.ts";
```

Replace the request-parsing block (lines 48-65):

Old:
```typescript
  // 2. Parse + validate the request shape.
  let payload: { date?: unknown; difficulty?: unknown; moveLog?: unknown };
  try {
    payload = await req.json();
  } catch {
    return json({ valid: false, reason: "invalid_run" }, 422);
  }
  const { date, difficulty, moveLog } = payload;
  if (typeof date !== "string" || typeof difficulty !== "string") {
    return json({ valid: false, reason: "invalid_run" }, 422);
  }
  if (!isDifficulty(difficulty)) {
    return json({ valid: false, reason: "invalid_run" }, 422);
  }
  // No backfilling other days: the submitted date must be the server's UTC today.
  if (date !== utcToday()) {
    return json({ valid: false, reason: "invalid_run" }, 422);
  }
```

New:
```typescript
  // 2. Parse + validate the request shape.
  let payload: unknown;
  try {
    payload = await req.json();
  } catch {
    return json({ valid: false, reason: "malformed_request" }, 422);
  }
  const validated = validateSubmitRequest(payload, utcToday());
  if (!validated.ok) {
    return json({ valid: false, reason: validated.reason }, 422);
  }
  const { date, difficulty, moveLog } = validated;
```

`isDifficulty` is now only used inside `validate_request.ts` — remove it from `index.ts`'s import if `index.ts` no longer references it directly elsewhere in the file (check: `isDifficulty` was only used in the block just replaced). Change the import line:

Old: `import { isDifficulty, kLeaderboardSeason } from "../_shared/constants.ts";`
New: `import { kLeaderboardSeason } from "../_shared/constants.ts";`

- [ ] **Step 4: Run tests to verify they pass**

Run: `deno test supabase/functions/submit-score/validate_request.test.ts`
Expected: PASS, all 7 tests.

Also run: `deno test --frozen supabase/functions/` — expected all 58+ pre-existing tests still pass (this changes `index.ts`'s control flow but not `verifyRun`/`verifyRunChallenge`/`upsertBestScore`, which are untouched).

- [ ] **Step 5: Commit**

```bash
git add supabase/functions/submit-score/validate_request.ts supabase/functions/submit-score/validate_request.test.ts supabase/functions/submit-score/index.ts
git commit -m "fix(submit-score): split invalid_run into malformed_request/stale_date/invalid_run

invalid_run was returned for five distinct causes — malformed JSON, a bad
date/difficulty shape, an unrecognized difficulty, a stale date, AND actual
replay rejection. Now that the client (Task 1) actually sees the reason
string, treating all five as permanently terminal would block recovery from
a transient/fixable client-side issue. invalid_run is now reserved
exclusively for genuine replay-verification failure; the other four causes
get their own reason strings, already correctly retryable per
GameSessionFactory._submitRun's existing (unchanged) mapping."
```

**Deploy note (not part of this task's commit, tracked separately per this repo's own established practice):** this Edge Function change does not reach production until `submit-score` is redeployed — `_shared`/function commits don't auto-deploy. Redeploy and verify live before considering this fix actually effective in production, matching how the original feature's Phase 2/3 rollout was verified.

**Deploy ORDERING requirement (hard constraint, not just "redeploy at some point"):** this server-side reason-split (Task 2) MUST be deployed *before* the client build carrying Task 1's exception-handling fix reaches users — not merely "before considering the fix effective." The two changes ship on independent channels: the Edge Function via `supabase functions deploy` (instant), the client via an app-store release (slow rollout). If the order is reversed, a **new-client + old-server** window opens: the old server still returns the conflated `reason: "invalid_run"` for what are actually transient/legitimate causes — a clock-skewed `stale_date` (a device clock straddling the UTC-midnight boundary is a real, legitimate player), or a `malformed_request`. Task 1's now-working handler parses that `invalid_run` as a genuine replay rejection → `SubmitOutcome.terminalRejection` → fires the tampering/parity-bug `_onError` alert AND permanently settles a run that should have stayed retryable. Before Task 1 this was harmless (any 422 threw uncaught → generic `catch` → always `retryableFailure`); Task 1 is exactly what makes the reason string load-bearing for the first time, which is why this ordering constraint did not exist before this branch. Safe order: deploy `submit-score` first, then release the Task 1 client.

---

### Task 3: Fix the cross-account stale-write race on `submitStatus`

**The gap:** `HiveStorageService._guardWrite()` (`lib/infrastructure/hive_storage_service.dart:119-133`) blocks a write only when the **current** `LocalOwner.uid` mismatches the **current** session's uid (`_currentUserId()`, resolved fresh at write-time). It has no notion of "this write's *origin* is a superseded session." Sequence: account A has a submission in flight (already past its network call) → the app switches accounts (`wipeAccountData()` + `rebindOwner(B)`) → A's in-flight `_settleSubmission` finally resolves and calls `saveSubmitStatus` → at that moment, `owner.uid` is now B (just rebound) and `_currentUserId()` also resolves to B (the live session) → they match → `_guardWrite()` sees no mismatch and lets the write through → **A's stale result silently overwrites B's submit-status record for that date/difficulty.**

**Fix:** mirror the exact pattern `GameCubit` already uses for generation-staleness (`if (generation != _submitGeneration) return;`, four call sites in `_submitOnce`/`_settleSubmission`) — capture the owner uid at the start of an attempt, and skip the write (not just proceed and let a same-instant guard catch it) if the owner has changed since.

**Files:**
- Modify: `lib/application/game_cubit.dart:563-675` (`_submitted`/`_submitGeneration` field block through `_settleSubmission`)
- Test: `test/application/game_cubit_submission_test.dart`

**Interfaces:**
- Consumes: `StorageService.owner` (`LocalOwner? get owner`, already declared at `storage_service.dart:210`) and `InMemoryStorageService.rebindOwner(String uid, {int snapshotRevision = 0, bool claimed = false})` (test-only, already exists at `storage_service.dart:364`).
- Produces: no new public API on `GameCubit` — this is an internal correctness fix, no signature changes.

- [ ] **Step 1: Write the failing test**

Add to `test/application/game_cubit_submission_test.dart` (place near the existing generation-race test, e.g. after the "continued board invalidates a stale result" test):

```dart
  test('a submission that outlives an account switch does not settle under the new account',
      () async {
    final storage = InMemoryStorageService();
    await storage.rebindOwner('account-a');
    await _saveCompleted(storage, _terminalBoard());
    final called = Completer<void>();
    final release = Completer<void>();
    final cubit = GameCubit(
      storage: storage,
      todayProvider: () => _date,
      onSubmitRun: ({
        required date,
        required difficulty,
        required moveLog,
        required adContinues,
      }) async {
        called.complete();
        await release.future;
        return SubmitOutcome.success;
      },
    );

    final init = cubit.init(difficulty: _difficulty);
    await called.future;
    expect(storage.loadSubmitStatus(_date, _difficulty).status,
        SubmitStatus.pending);

    // Simulate an account switch happening while the submission is in
    // flight, after the "pending" write already landed under account A.
    await storage.rebindOwner('account-b');

    release.complete();
    await init;

    // The stale attempt must NOT have settled under account B's record.
    expect(storage.loadSubmitStatus(_date, _difficulty).status,
        SubmitStatus.pending);
    await cubit.close();
  });

  test('a submission that completes before any account change settles normally',
      () async {
    final storage = InMemoryStorageService();
    await storage.rebindOwner('account-a');
    await _saveCompleted(storage, _terminalBoard());
    final cubit = GameCubit(
      storage: storage,
      todayProvider: () => _date,
      onSubmitRun: ({
        required date,
        required difficulty,
        required moveLog,
        required adContinues,
      }) async =>
          SubmitOutcome.success,
    );

    await cubit.init(difficulty: _difficulty);

    expect(storage.loadSubmitStatus(_date, _difficulty).status,
        SubmitStatus.settled);
    await cubit.close();
  });
```

- [ ] **Step 2: Run tests to verify the first one fails**

Run: `flutter test test/application/game_cubit_submission_test.dart --plain-name "outlives an account switch"`
Expected: FAIL — with today's shipped code, the stale attempt DOES settle (status becomes `SubmitStatus.settled`), since no owner-change check exists yet.

Run: `flutter test test/application/game_cubit_submission_test.dart --plain-name "completes before any account change"`
Expected: PASS already (this test documents existing, correct same-account behavior — included as a regression guard for the fix, not because it currently fails).

- [ ] **Step 3: Implement**

In `lib/application/game_cubit.dart`, modify the field block and the three methods (`_submit` is unchanged; `_submitOnce` and `_settleSubmission` change):

Replace:
```dart
  bool _submitted = false;
  int _submitGeneration = 0;
  Future<void>? _submissionInFlight;
  int? _submissionInFlightGeneration;
```

With (adds one doc-commented helper, no new stored field — the captured uid is a local variable threaded through the call, matching how `generation` is already threaded):
```dart
  bool _submitted = false;
  int _submitGeneration = 0;
  Future<void>? _submissionInFlight;
  int? _submissionInFlightGeneration;

  /// True when the local owner is unchanged since [capturedUid] was read at
  /// an attempt's start — mirrors the existing `generation != _submitGeneration`
  /// staleness check, but for account identity: `HiveStorageService._guardWrite`
  /// only compares the CURRENT owner against the CURRENT session, which can't
  /// detect a write whose origin is a superseded account (by the time a stale
  /// attempt resolves post-switch, both "current" values already agree with
  /// each other, just not with who actually started the attempt).
  bool _ownerUnchangedSince(String? capturedUid) =>
      storage.owner?.uid == capturedUid;
```

Replace `_submitOnce`:
```dart
  Future<void> _submitOnce(BoardState board, int generation) async {
    final capturedUid = storage.owner?.uid;
    if (!_ownerUnchangedSince(capturedUid)) return;
    try {
      await storage.saveSubmitStatus(
        _date,
        _difficulty,
        SubmitStatus.pending,
        generation,
      );
    } catch (e, st) {
      _onError?.call(e, st);
      return;
    }
    if (generation != _submitGeneration) return;
    onAnalyticsEvent?.call('score_submit_attempt', {
      'difficulty': _difficulty.name,
    });

    final hook = onSubmitRun;
    SubmitOutcome outcome;
    if (hook == null) {
      outcome = SubmitOutcome.retryableFailure;
    } else {
      try {
        outcome = await hook(
          date: _date,
          difficulty: _difficulty,
          moveLog: board.moveLog,
          adContinues: board.adContinuesUsed,
        );
      } catch (e, st) {
        if (generation != _submitGeneration) return;
        _onError?.call(e, st);
        _reportSubmitResult(SubmitOutcome.retryableFailure);
        return;
      }
    }
    if (generation != _submitGeneration) return;
    _reportSubmitResult(outcome);

    switch (outcome) {
      case SubmitOutcome.retryableFailure:
        return;
      case SubmitOutcome.success:
        await _settleSubmission(generation, capturedUid);
        return;
      case SubmitOutcome.terminalRejection:
        _onError?.call(
          StateError('score_submit_terminal_rejection: invalid_run'),
          null,
          fatal: false,
        );
        await _settleSubmission(generation, capturedUid);
        return;
    }
  }
```

Replace `_settleSubmission`:
```dart
  Future<void> _settleSubmission(int generation, String? capturedUid) async {
    // Re-checked here, not just by the caller: an ad continue can bump
    // _submitGeneration during the network call this settles, and without
    // this guard a stale write landing after that bump would overwrite the
    // continued run's freshly-reset (none, newGeneration) status with a
    // superseded (settled, oldGeneration) one — silently blocking the
    // improved run's own future submission on the next resume.
    if (generation != _submitGeneration) return;
    // Same idea, for account identity instead of generation: a write whose
    // origin account no longer matches the current owner is discarded, not
    // persisted under the new account's record.
    if (!_ownerUnchangedSince(capturedUid)) return;
    try {
      await storage.saveSubmitStatus(
        _date,
        _difficulty,
        SubmitStatus.settled,
        generation,
      );
      if (generation == _submitGeneration) _submitted = true;
    } catch (e, st) {
      _onError?.call(e, st);
    }
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/application/game_cubit_submission_test.dart`
Expected: PASS, all tests in the file including the two new ones and every pre-existing test (the added checks only skip a write when the owner has genuinely changed — same-account flows, including offline/no-owner play where `storage.owner` stays `null` throughout, are unaffected since `null == null` is `true`).

Also run: `flutter analyze` — expected clean.

- [ ] **Step 5: Commit**

```bash
git add lib/application/game_cubit.dart test/application/game_cubit_submission_test.dart
git commit -m "fix(leaderboard): discard a stale submission that outlives an account switch

HiveStorageService._guardWrite only compares the CURRENT owner against the
CURRENT session — it can't detect a write whose origin is a superseded
account, since by the time a stale in-flight attempt resolves post-switch,
both 'current' values already agree with the NEW account, not the one the
attempt actually started under. Captures the owner uid at attempt-start and
re-checks it before each persist point, mirroring the existing
generation-staleness check already used for the same class of problem."
```

---

### Task 4: Intercept hardware/system Back on the result screen

**The gap:** `submitIfPending()` is only called from the explicit in-app Main Menu button (`lib/presentation/screens/game_screen.dart:174-177`). The route has no `PopScope`, and `GameCubit.close()` (`game_cubit.dart:791-795`) doesn't trigger or await a submission. A player who dismisses the result screen via Android's hardware/gesture Back — never tapping Main Menu — exits with `submitStatus == none` on a continue-eligible completed board, which the resume rule deliberately treats as "genuinely still undecided, do nothing." That run may never submit unless the player happens to return and tap Main Menu explicitly.

**Files:**
- Modify: `lib/presentation/screens/game_screen.dart:88-132` (`build`)
- Test: `test/presentation/game_screen_test.dart` (new file — none exists yet for this screen)

**Interfaces:**
- Consumes: `GameCubit.submitIfPending()` (already exists, `game_cubit.dart:681-684`) — no-ops safely when not in `GameOverShowScore` state, so it's safe to call unconditionally on any pop from this screen.
- Produces: no new public API — this is a widget-tree change only (wraps the existing `Scaffold` in `PopScope`).

- [ ] **Step 1: Write the failing test**

Create `test/presentation/game_screen_test.dart`. Model its `GameCubit` construction and pump setup on the existing pattern in `test/application/game_cubit_submission_test.dart` (fixture helpers `_terminalBoard`, `_saveCompleted`) and on `test/presentation/score_share_screen_test.dart`'s widget-pump style (`MaterialApp` + `BlocProvider.value`):

```dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:connect_merge/application/engagement_cubit.dart';
import 'package:connect_merge/application/game_cubit.dart';
import 'package:connect_merge/domain/constants.dart';
import 'package:connect_merge/domain/engine/daily_seeder.dart';
import 'package:connect_merge/domain/models/board_state.dart';
import 'package:connect_merge/domain/models/difficulty.dart';
import 'package:connect_merge/domain/models/game_status.dart';
import 'package:connect_merge/infrastructure/ad_service.dart';
import 'package:connect_merge/infrastructure/storage_service.dart';
import 'package:connect_merge/presentation/screens/game_screen.dart';

const _date = '2026-07-18';
const _difficulty = Difficulty.easy;

// Copied verbatim from test/application/game_cubit_submission_test.dart's
// existing private helpers (test-file-private in Dart — cannot be imported
// across files, so this is intentional duplication, not drift risk, as long
// as it's kept byte-identical to the source).
BoardState _terminalBoard() => _continueEligibleBoard().copyWith(
      adContinuesUsed: kMaxAdContinuesPerDay,
    );

BoardState _continueEligibleBoard() =>
    const DailySeeder(_date, _difficulty).generate().board.copyWith(
          movesRemaining: 0,
          status: GameStatus.outOfMoves,
        );

Future<void> _saveCompleted(StorageService storage, BoardState board) async {
  await storage.saveSnapshot(GameSnapshot(
    date: _date,
    difficulty: _difficulty,
    board: board,
    completed: true,
  ));
}

void main() {
  testWidgets(
      'hardware/system back on the result screen triggers submitIfPending',
      (tester) async {
    final storage = InMemoryStorageService();
    await _saveCompleted(storage, _terminalBoard());
    final calls = <String>[];
    final cubit = GameCubit(
      storage: storage,
      todayProvider: () => _date,
      onSubmitRun: ({
        required date,
        required difficulty,
        required moveLog,
        required adContinues,
      }) async {
        calls.add('submitted');
        return SubmitOutcome.success;
      },
    );
    await cubit.init(difficulty: _difficulty);

    await tester.pumpWidget(MaterialApp(
      home: BlocProvider<GameCubit>.value(
        value: cubit,
        child: GameScreen(
          adService: AdService.withSeams(),
          storage: storage,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Simulate the system/hardware back gesture (Android back button,
    // iOS edge swipe) rather than tapping the in-app Main Menu button.
    final dynamic widgetsAppState =
        tester.state(find.byType(WidgetsApp));
    await widgetsAppState.didPopRoute();
    await tester.pumpAndSettle();

    expect(calls, ['submitted']);
    expect(storage.loadSubmitStatus(_date, _difficulty).status,
        SubmitStatus.settled);
    await cubit.close();
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/presentation/game_screen_test.dart`
Expected: FAIL — `calls` stays empty and `submitStatus` stays `none`/`pending`, since nothing intercepts the simulated back gesture yet.

- [ ] **Step 3: Implement**

In `lib/presentation/screens/game_screen.dart`, wrap the `Scaffold` returned by `build` in a `PopScope`:

Replace:
```dart
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
```

With:
```dart
  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) return;
        // Fire-and-forget, matching how a resume-triggered retry already
        // runs independent of any screen's lifecycle: submitIfPending()
        // itself no-ops unless the cubit is in GameOverShowScore, and its
        // own first step (persisting `pending`) is fast, local Hive I/O —
        // blocking the pop on it would reintroduce the "never blocks
        // navigation" violation an earlier draft of this fix had.
        context.read<GameCubit>().submitIfPending();
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
```

This requires closing the new `PopScope(...)` wrapper — add one more closing `);` at the very end of the `build` method's return statement, matching the existing `Scaffold`'s closing structure (the existing `Scaffold(...)` call closes with `);` at line 131 — that becomes the `Scaffold`'s own close, followed by a new `);` for `PopScope`). Read the full existing `build` method (`game_screen.dart:88-132`) before editing to match brace structure exactly — do not guess indentation.

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/presentation/game_screen_test.dart`
Expected: PASS.

Also run: `flutter test test/presentation/` (in case any other widget test exercises `GameScreen` and asserts on its exact widget tree depth/type — a `PopScope` wrapper adds one level) and `flutter analyze`.

- [ ] **Step 5: Commit**

```bash
git add lib/presentation/screens/game_screen.dart test/presentation/game_screen_test.dart
git commit -m "fix(leaderboard): intercept hardware/system back to trigger submitIfPending

submitIfPending() was only wired to the explicit in-app Main Menu button;
hardware/gesture back on the result screen popped the route without ever
calling it, leaving a continue-eligible completed run unsubmitted
indefinitely. PopScope now fires the same call on any pop, fire-and-forget
so navigation is never blocked on the network call."
```

---

### Final verification (after all 4 tasks)

- [ ] Run the full suite: `flutter analyze`, `flutter test`, `deno test --frozen supabase/functions/`.
- [ ] Confirm test counts are at least 743 + (new tests added: ~7 in Task 1, ~2 in Task 3, 1 in Task 4) for Flutter, and 58 + 7 (Task 2) for Deno.
- [ ] Redeploy `submit-score` (Task 2's change requires this — Edge Function commits don't auto-deploy) and verify live before considering this plan's server-side fix actually effective in production.
- [ ] **Deploy ORDERING (pre-release checklist item, not optional):** deploy the `submit-score` Edge Function (Task 2) BEFORE the client build carrying Task 1 reaches users. Reversing the order opens a new-client + old-server window where the old server's conflated `invalid_run` (returned for a legitimate clock-skewed `stale_date` or a `malformed_request`) is parsed by Task 1's handler as a genuine replay rejection — firing the tampering/parity-bug alert and permanently settling a run that should have been retryable. See Task 2's "Deploy ORDERING requirement" note for the full failure mode.
