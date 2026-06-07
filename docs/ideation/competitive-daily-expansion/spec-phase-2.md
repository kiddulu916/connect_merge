# Implementation Spec: Competitive Daily Expansion - Phase 2

**Contract**: ./contract.md
**Estimated Effort**: XL
**Prerequisites**: Phase 1 (tiers, UTC seeding, move-log recording) merged.

## Technical Approach

Phase 2 brings the game online: a Supabase backend ($0 free tier), zero-friction identity (anonymous auth + display name), and a **global per-tier daily leaderboard whose scores are server-verified by replay**. The defining constraint is trust — a public leaderboard tied to ad revenue will be attacked, so the client never submits a number it computed; it submits the **move log** from Phase 1, and a Supabase **Edge Function** replays that log against the regenerated `(utcDate, difficulty)` board to compute the authoritative score.

This makes the single highest-risk task a **cross-language determinism port**: `prng.dart` (Mulberry32) and the relevant seeding/merge logic must be reimplemented in TypeScript (Deno, for Edge Functions) and produce **byte-identical** output to Dart. JavaScript numbers are 64-bit floats, so every 32-bit operation must use `Math.imul(...)` and `>>> 0` to emulate Dart's int truncation. The existing `Prng` is already written with this portability in mind (it documents that Dart's `Random` was rejected precisely to keep the sequence stable), which de-risks the port — but it must be pinned with a **cross-language equivalence test**: a fixed set of seeds whose first N outputs are captured from Dart and asserted in the TS test, and vice-versa.

Architecture on the client stays clean: a new `LeaderboardService` (and `AuthService`) sit in `infrastructure/`, mirroring how `AdService`/`StorageService` isolate plugins so the rest of the app never imports `supabase_flutter` directly. On the server, two pieces: SQL migrations (tables + RLS) and one Edge Function (`submit-score`). Writes to the `scores` table are **only** allowed from the Edge Function (service role); clients have read-only RLS on leaderboard views.

## Feedback Strategy

**Inner-loop command**: `deno test supabase/functions/_shared/engine.test.ts` (server verifier) and `flutter test test/infrastructure/leaderboard_service_test.dart` (client).

**Playground**: Two playgrounds — (1) `deno test` for the ported engine/PRNG and the replay verifier (pure, runs in ms); (2) Supabase local dev (`supabase start`) for the Edge Function + DB, hit via `curl`/`deno test` against the local endpoint.

**Why this approach**: The risky core (cross-language determinism + replay) is pure logic best pinned by fast Deno tests; the integration surface (auth, RLS, function deploy) is verified against a local Supabase stack before touching the cloud.

> **Environment note**: Requires the Supabase CLI and Deno locally. No mobile device toolchain on this machine — client integration against the live project is verified by the user on a real build; everything testable headlessly (verifier, service unit tests with a mocked client) is covered here.

## File Changes

### New Files

| File Path | Purpose |
| --------- | ------- |
| `supabase/migrations/0001_players_scores.sql` | `players`, `scores` tables, indexes, RLS, and the leaderboard read view/RPC. |
| `supabase/functions/submit-score/index.ts` | Edge Function: authenticates, replays the move log, writes the authoritative score. |
| `supabase/functions/_shared/prng.ts` | TS port of `prng.dart` (Mulberry32) using `Math.imul`/`>>>0`. |
| `supabase/functions/_shared/seeder.ts` | TS port of seed-key + board generation for `(date,difficulty)`. |
| `supabase/functions/_shared/engine.ts` | TS port of the merge rules + replay (`verifyRun(date,difficulty,moveLog) -> {score, highestTier, valid}`). |
| `supabase/functions/_shared/engine.test.ts` | Deno tests: replay correctness + cross-language equivalence vectors. |
| `lib/infrastructure/auth_service.dart` | Anonymous sign-in + display-name management via `supabase_flutter`. |
| `lib/infrastructure/leaderboard_service.dart` | Submit a run (calls `submit-score`) + fetch a tier's daily leaderboard. |
| `lib/infrastructure/supabase_client.dart` | Single initialized Supabase client (URL/anon key from `--dart-define`). |
| `lib/domain/models/leaderboard_entry.dart` | `{rank, displayName, score, isMe}`. |
| `lib/presentation/screens/leaderboard_screen.dart` | Per-tier daily leaderboard UI with tier tabs. |
| `lib/presentation/screens/display_name_screen.dart` | First-run display-name (+ emoji/avatar) capture. |
| `test/infrastructure/leaderboard_service_test.dart` | Submit/fetch against a mocked Supabase client. |
| `test/domain/models/leaderboard_entry_test.dart` | JSON mapping. |

### Modified Files

| File Path | Changes |
| --------- | ------- |
| `pubspec.yaml` | Add `supabase_flutter`. |
| `lib/main.dart` | Initialize Supabase + ensure anonymous session before runApp; route to display-name capture if unset. |
| `lib/application/game_cubit.dart` | On completion, hand the `(date, difficulty, moveLog, adContinues)` to a submit flow (via a callback/service) and expose submit status. |
| `lib/presentation/screens/score_share_screen.dart` | Add "View leaderboard" + show the player's rank after submission. |
| `lib/presentation/screens/tier_select_screen.dart` | Add a leaderboard entry point per tier. |

## Implementation Details

### Cross-language PRNG + seeder port (highest risk)

**Pattern to follow**: `lib/domain/engine/prng.dart` and `lib/domain/engine/daily_seeder.dart` — port line-for-line.

**Overview**: Reproduce the deterministic board + drop schedule on the server, bit-identically.

```typescript
// prng.ts — Mulberry32, 32-bit-faithful
export class Prng {
  private state: number;
  constructor(seed: number) { this.state = seed >>> 0; }
  nextU32(): number {
    this.state = (this.state + 0x6D2B79F5) >>> 0;
    let t = this.state;
    t = Math.imul(t ^ (t >>> 15), t | 1) >>> 0;
    t = ((t + Math.imul(t ^ (t >>> 7), 61 | t)) >>> 0) ^ t;
    t = t >>> 0;
    return (t ^ (t >>> 14)) >>> 0;
  }
  nextInt(max: number): number { return this.nextU32() % max; }
}
```

**Key decisions**:
- Use `>>> 0` after every arithmetic step and `Math.imul` for all multiplies — this is the make-or-break detail.
- Seed key string `"$date:$difficulty"` and the SHA256→u32 reduction must match Dart's byte order exactly (`bytes[0] | bytes[1]<<8 | bytes[2]<<16 | bytes[3]<<24`).

**Implementation steps**:
1. Port `Prng`, then `seedForKey` (SHA256 via Deno `crypto.subtle` or std), then board generation (rejection-sampling placement + drop tiers via `dropCap`).
2. Capture equivalence vectors from Dart: write a throwaway Dart test that prints the first 20 `nextU32()` for seeds `[1, 42, 0x9E3779B9, seedForKey("2026-06-07:legendary")]`; paste them as expected values into `engine.test.ts`.
3. Assert the TS board for a known `(date,tier)` matches the Dart board (cell tiers + drop schedule) — capture the Dart board the same way.

**Feedback loop**:
- **Playground**: `supabase/functions/_shared/engine.test.ts`.
- **Experiment**: for seeds `[1,42,0x9E3779B9, key-hash]`, assert TS `nextU32()[0..19]` equals the Dart-captured vectors; assert a full `(2026-06-07, legendary)` board+drops matches.
- **Check command**: `deno test supabase/functions/_shared/engine.test.ts`

### Replay verifier

**Overview**: Given `(date, difficulty, moveLog)`, regenerate the board, apply each `MergeEvent` (validating legality) and `ContinueEvent` (grant moves up to `kMaxAdContinuesPerDay`), apply the deterministic drop after each merge, and return the authoritative score + highest tier, or reject.

```typescript
export function verifyRun(date: string, difficulty: Difficulty, log: MoveEvent[]): VerifyResult {
  // 1. regenerate board + dropTiers + landing PRNG (stream B) from (date,difficulty)
  // 2. for each event in order:
  //    - MergeEvent: reject if !canMerge(board,from,to); else merge + applyDrop(next tier)
  //    - ContinueEvent: reject if continues exceeded or status != outOfMoves; else +reward moves
  //    - reject if movesRemaining < 0 at any point
  // 3. reject if final score/highestTier inconsistent; return { valid, score, highestTier }
}
```

**Key decisions**:
- The server is the **only** authority for score; the client-sent score (if any) is ignored except as a sanity log.
- Illegal move, out-of-budget continue, or wrong tier seed → `valid:false`, HTTP 422, nothing written.
- Drops are regenerated server-side (never trusted from the client) — the client only sends merges/continues.

**Implementation steps**:
1. Port `canMerge`/`merge`/`applyDrop`/`hasMergeAvailable`/`evaluateStatus`.
2. Implement `verifyRun` mirroring `GameCubit.merge`/`grantAdReward` ordering exactly.
3. Unit-test against a Dart-captured legitimate run (must match) and against tampered logs (must reject).

**Feedback loop**:
- **Playground**: `engine.test.ts`.
- **Experiment**: feed (a) a captured legit run → score matches Dart; (b) a log with an illegal merge → rejected; (c) a log with 4 continues when cap is 3 → rejected; (d) a swapped-tier log → score differs / rejected.
- **Check command**: `deno test supabase/functions/_shared/engine.test.ts`

### submit-score Edge Function

**Overview**: Auth + verify + upsert best score for `(player, date, difficulty)`.

**Implementation steps**:
1. Read the caller's JWT (anonymous user id) from the `Authorization` header via the Supabase client.
2. Parse `{date, difficulty, moveLog}`; reject if `date != server UTC today` (no backfilling other days) or `difficulty` invalid.
3. `verifyRun(...)`; on `valid`, upsert into `scores` keeping the max score for that `(player,date,difficulty)`; return `{rank, score}`.
4. On invalid, return 422 with a generic reason (don't leak verifier internals).

**Feedback loop**:
- **Playground**: `supabase start` (local stack) + a `deno test`/`curl` script hitting `http://localhost:54321/functions/v1/submit-score`.
- **Experiment**: POST a legit log with a valid anon JWT → 200 + rank; POST without auth → 401; POST a tampered log → 422; POST twice with a lower then higher score → leaderboard keeps the higher.
- **Check command**: `curl -s -H "Authorization: Bearer $ANON_JWT" -d @run.json localhost:54321/functions/v1/submit-score | jq .`

### Auth + display name (client)

**Pattern to follow**: `lib/infrastructure/ad_service.dart` (plugin isolation).

**Overview**: Ensure an anonymous session at startup; capture a display name on first run; expose `currentPlayer`.

**Implementation steps**:
1. `Supabase.initialize(url, anonKey)` in `main.dart` (values via `--dart-define`).
2. `AuthService.ensureSignedIn()` → `signInAnonymously()` if no session.
3. If `players.display_name` is null, route to `DisplayNameScreen`; on submit, upsert the player's row.

**Feedback loop**:
- **Playground**: `test/infrastructure/leaderboard_service_test.dart` with a mocked client.
- **Experiment**: no session → `ensureSignedIn` creates one; display name set → persists and is read back.
- **Check command**: `flutter test test/infrastructure/leaderboard_service_test.dart`

### Leaderboard UI

**Pattern to follow**: existing screens + `flutter_bloc`.

**Overview**: Tier-tabbed daily leaderboard; highlights the player's row; shows local reset countdown.

**Implementation steps**:
1. `LeaderboardService.fetch(difficulty, date)` calls the read view/RPC (top N + the player's own rank).
2. Render ranked list with `isMe` highlight; tabs switch tier.
3. Entry points from tier-select and the post-game result screen.

**Feedback loop**:
- **Playground**: `flutter run` (manual) + widget test with a stubbed service.
- **Experiment**: render with 0 entries (empty state), 1 entry (you), and 50 entries (your row highlighted mid-list).
- **Check command**: `flutter test test/presentation` (leaderboard widget test)

## Data Model

### Schema Changes

```sql
create table players (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 20),
  avatar text,
  created_at timestamptz default now()
);

create table scores (
  id bigint generated always as identity primary key,
  player_id uuid not null references players(id) on delete cascade,
  utc_date date not null,
  difficulty text not null check (difficulty in ('easy','medium','hard','legendary')),
  score int not null check (score >= 0),
  highest_tier int not null,
  created_at timestamptz default now(),
  unique (player_id, utc_date, difficulty)   -- one best score per tier per day
);
create index idx_scores_board on scores (utc_date, difficulty, score desc);

alter table players enable row level security;
alter table scores  enable row level security;

-- players: a user reads/writes only their own row
create policy player_self on players for all using (auth.uid() = id) with check (auth.uid() = id);
-- scores: world-readable (leaderboards), but NO client insert/update — only the
-- service role (Edge Function) writes. No insert/update policy = clients cannot write.
create policy scores_read on scores for select using (true);
```

### Leaderboard read RPC

```sql
-- returns top N for a (date,difficulty) plus the caller's own rank
create function leaderboard(p_date date, p_diff text, p_limit int default 100)
returns table(rank bigint, display_name text, score int, is_me boolean)
language sql stable as $$
  select rank() over (order by s.score desc) as rank,
         p.display_name, s.score, (s.player_id = auth.uid()) as is_me
  from scores s join players p on p.id = s.player_id
  where s.utc_date = p_date and s.difficulty = p_diff
  order by s.score desc limit p_limit;
$$;
```

## API Design

### Edge Function

| Method | Path | Description |
| ------ | ---- | ----------- |
| `POST` | `/functions/v1/submit-score` | Verify a run via replay; upsert best score; return rank. |

```jsonc
// Request (Authorization: Bearer <anon JWT>)
{ "date": "2026-06-07", "difficulty": "hard",
  "moveLog": [ {"t":"merge","from":3,"to":8}, {"t":"merge","from":1,"to":2}, {"t":"continue"} ] }
// Response 200
{ "valid": true, "score": 1240, "highestTier": 7, "rank": 42 }
// Response 422 { "valid": false, "reason": "invalid_run" }
```

## Testing Requirements

### Unit Tests

| Test File | Coverage |
| --------- | -------- |
| `supabase/functions/_shared/engine.test.ts` | Cross-language vectors; replay score matches Dart; tamper rejection. |
| `test/infrastructure/leaderboard_service_test.dart` | Submit/fetch payload shaping against a mock client. |
| `test/domain/models/leaderboard_entry_test.dart` | JSON mapping incl. `is_me`. |

### Integration Tests (local Supabase stack)

| Scenario | Expectation |
| -------- | ----------- |
| Legit run, valid JWT | 200, score == Dart score, row upserted |
| No/invalid JWT | 401 |
| Tampered log | 422, no row |
| Resubmit higher then lower | leaderboard keeps the higher |
| Wrong `date` (not UTC today) | 422 |

### Manual Testing
- [ ] Real build: fresh install → anonymous session → set display name → complete a tier → appear on that tier's board.
- [ ] Second device: different name, both visible and correctly ranked.

## Error Handling

| Error Scenario | Handling Strategy |
| -------------- | ----------------- |
| Offline at submit time | Queue the move log locally (Hive); retry on next launch; UI shows "score pending". |
| Edge Function 5xx / timeout | Client retries with backoff; never block the result screen. |
| Verifier rejects a legit run (parity bug) | Hard-fail loudly in tests via equivalence vectors; in prod, log the rejected payload server-side for diagnosis (no PII). |
| Display name taken/empty/offensive | Names are non-unique (rank by score); enforce length; optional client-side profanity filter (future). |
| Duplicate submit (same run twice) | Unique `(player,date,difficulty)` + max-keep upsert makes it idempotent. |

## Failure Modes

| Component | Failure Mode | Trigger | Impact | Mitigation |
| --------- | ------------ | ------- | ------ | ---------- |
| PRNG port | Float drift | Missing `>>>0`/`Math.imul` | Server board ≠ client board → all legit runs rejected | Equivalence vectors gate CI; port reviewed op-by-op. |
| Replay verifier | Event-order mismatch | TS applies drop/continue in different order than `GameCubit` | Score mismatch | `verifyRun` mirrors cubit ordering; tested against captured legit run. |
| RLS | Client write to `scores` | Missing/loose policy | Cheaters bypass the verifier entirely | No insert/update policy on `scores`; only service role writes; test an anon insert is denied. |
| Anonymous auth | Identity loss on reinstall | App data cleared | Player loses rank history | Accepted for v1 (account linking is Future); note in UX. |
| Edge Function | Cold start latency | First call after idle | Slow submit | Submit off the critical path; optimistic "pending" UI. |
| Free tier limits | Quota exhaustion | Sudden growth | Writes fail | Monitor usage; upsert-only keeps row count bounded (1/player/day/tier); upgrade path documented. |

## Validation Commands

```bash
# Server (Deno / Supabase)
deno test supabase/functions/_shared/engine.test.ts
supabase start
supabase functions serve submit-score      # local function
# Client
flutter analyze
flutter test test/infrastructure/leaderboard_service_test.dart
flutter test
```

## Rollout Considerations

- **Secrets**: Supabase URL + anon key via `--dart-define` (not committed); service role key only in the Edge Function env.
- **Monitoring**: watch Edge Function error rate (esp. 422s — a spike means a parity regression), DB row count vs free-tier limits.
- **Rollback**: leaderboard UI behind a simple flag; if the verifier misbehaves, hide the board and keep the game playable (Phase 1 stands alone).

## Open Items

- [ ] Decide leaderboard page size / pagination (spec assumes top 100 + own rank).
- [ ] Choose SHA256 impl in Deno (std `crypto` vs `crypto.subtle`) and confirm byte order matches Dart.
- [ ] Capture the Dart equivalence vectors (one throwaway Dart test) before porting.

---

_This spec is ready for implementation. Follow the patterns and validate at each step._
