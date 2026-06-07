# Implementation Spec: Competitive Daily Expansion - Phase 3

**Contract**: ./contract.md
**Estimated Effort**: L
**Prerequisites**: Phase 2 (identity + backend + `scores` table) merged.
**Parallelizable with**: Phase 4 (both depend only on Phase 2). Coordinate on shared files (`lib/main.dart`, `pubspec.yaml`, Supabase migrations, shared leaderboard widgets).

## Technical Approach

Phase 3 adds the **friends / local leaderboard**: rank the people you know by today's score, per tier. Per the contract, friend discovery uses **friend codes + invite (deep) links** (primary, permission-free) and **contacts matching** (bonus, behind the OS contacts permission). Outbound **share cards** to IG/X/anywhere are included because friend-import is impossible on those platforms — sharing is the realistic growth lever and reuses the existing `score_share_screen.dart`.

The friend graph is a symmetric edge list in Supabase. A friend code is a short, unique token on the player's row; redeeming a code (typed or via deep link) creates a mutual `friendships` edge. Contacts matching hashes each contact's normalized phone/email **on device** (SHA256) and sends only hashes to an Edge Function that matches them against opted-in players' stored contact hashes — raw contacts never leave the device. The friends leaderboard is the Phase 2 `leaderboard` query intersected with the caller's friend set.

Client code follows the Phase 2 isolation pattern: extend `LeaderboardService` (or add `FriendsService`) in `infrastructure/`; no screen imports Supabase directly. Deep links use `app_links` (or `uni_links`); contacts use `flutter_contacts`; sharing uses `share_plus` (or the existing share path).

## Feedback Strategy

**Inner-loop command**: `flutter test test/infrastructure/friends_service_test.dart`

**Playground**: `flutter test` for service/logic (hash normalization, edge creation, friends-leaderboard filtering) against a mocked client; local Supabase stack for the contacts-match Edge Function; `flutter run` for deep-link and contacts-permission flows.

**Why this approach**: The privacy-sensitive logic (phone/email normalization + hashing) and the friends-filter query are pure and must be exact, so tests are the tightest loop; permission and deep-link flows need a manual device pass.

> **Environment note**: Contacts permission, deep-link cold-start, and native share sheets require a real device (user-verified). Normalization/hashing, edge logic, and the match function are tested headlessly here.

## File Changes

### New Files

| File Path | Purpose |
| --------- | ------- |
| `supabase/migrations/0002_friends.sql` | `friendships` edges, `friend_code` column, contact-hash table, RLS, friends-leaderboard RPC. |
| `supabase/functions/match-contacts/index.ts` | Accepts hashed contacts, returns matching opted-in players. |
| `lib/infrastructure/friends_service.dart` | Generate/redeem friend codes, list friends, opt-in + match contacts. |
| `lib/infrastructure/contacts_hasher.dart` | Normalize + SHA256 phone/email (pure, fully testable). |
| `lib/infrastructure/deep_link_service.dart` | Parse `mergeloop://invite/<code>` (and https fallback). |
| `lib/domain/models/friend.dart` | `{playerId, displayName, friendCode}`. |
| `lib/presentation/screens/friends_screen.dart` | Friends list + add-by-code + invite + contacts opt-in. |
| `lib/presentation/widgets/friends_leaderboard.dart` | Per-tier friends ranking (reuses Phase 2 leaderboard row widget). |
| `test/infrastructure/contacts_hasher_test.dart` | Normalization + hashing vectors. |
| `test/infrastructure/friends_service_test.dart` | Code redeem, edge creation, friends-filter query shaping. |
| `test/presentation/friends_screen_test.dart` | Renders friends + empty state. |

### Modified Files

| File Path | Changes |
| --------- | ------- |
| `pubspec.yaml` | Add `flutter_contacts`, `app_links`, `share_plus` (+ `crypto` already present). |
| `lib/main.dart` | Register deep-link handler; route `invite/<code>` to redeem. |
| `lib/presentation/screens/leaderboard_screen.dart` | Add a Global / Friends toggle per tier. |
| `lib/presentation/screens/score_share_screen.dart` | Add share-card export + "invite a friend" CTA. |
| `android/app/src/main/AndroidManifest.xml` | Add `READ_CONTACTS` (justified) + deep-link `intent-filter`. |
| `ios/Runner/Info.plist` | `NSContactsUsageDescription` + URL scheme / associated domains. |

## Implementation Details

### Friend codes + redeem

**Overview**: Each player has a unique short code; redeeming creates a mutual edge.

```sql
alter table players add column friend_code text unique;  -- e.g. 8-char base32
create table friendships (
  a uuid references players(id) on delete cascade,
  b uuid references players(id) on delete cascade,
  created_at timestamptz default now(),
  primary key (a, b),
  check (a < b)               -- store one canonical row per pair
);
alter table friendships enable row level security;
create policy friendship_self on friendships for select using (auth.uid() in (a,b));
```

**Key decisions**:
- Store one canonical edge per pair (`a < b`) to avoid duplicates; query both directions.
- Redeem via an RPC/Edge Function (validates the code, prevents self-add, inserts the canonical edge) so RLS stays strict.

**Implementation steps**:
1. Generate `friend_code` on player creation (collision-retry).
2. `redeemCode(code)` RPC: look up target, reject self, insert `friendships`.
3. Build deep link `mergeloop://invite/<code>` + https fallback.

**Feedback loop**:
- **Playground**: `friends_service_test.dart` (mock client) + local stack for the RPC.
- **Experiment**: redeem a valid code (edge appears, both directions list each other); redeem own code (rejected); redeem twice (idempotent).
- **Check command**: `flutter test test/infrastructure/friends_service_test.dart`

### Contacts matching (privacy-first)

**Pattern to follow**: keep raw contacts on-device; only hashes leave.

**Overview**: Normalize phone (E.164) / email (lowercase trim), SHA256, send hashes; server matches against opted-in players' hashes.

```dart
String hashContact(String raw) =>
    sha256.convert(utf8.encode(normalize(raw))).toString();
// normalize: phones -> E.164 digits; emails -> trim + lowercase
```

**Key decisions**:
- **Raw phone/email never sent** — only salted-by-scheme SHA256 hashes; document this in the permission rationale.
- Matching requires the *other* player to have opted in and stored their own contact hash — so friend codes remain the primary path; contacts are a bonus.
- Opt-in is explicit and revocable; revoking deletes stored hashes.

**Implementation steps**:
1. `contacts_hasher.dart` (pure) with normalization rules + tests.
2. Opt-in flow: store the player's own phone/email hash (with consent).
3. `match-contacts` Edge Function: input hash list → output matching player ids (capped); client creates friend edges for chosen matches.

**Feedback loop**:
- **Playground**: `contacts_hasher_test.dart` + local stack for `match-contacts`.
- **Experiment**: `+1 (415) 555-0100`, `4155550100`, `+14155550100` all normalize+hash identically; an unmatched hash returns nothing; a matched opted-in hash returns the player.
- **Check command**: `flutter test test/infrastructure/contacts_hasher_test.dart`

### Friends leaderboard

**Overview**: Phase 2's daily board filtered to the caller's friend set (+ self), per tier.

```sql
create function friends_leaderboard(p_date date, p_diff text)
returns table(rank bigint, display_name text, score int, is_me boolean)
language sql stable as $$
  with friends as (
    select case when a = auth.uid() then b else a end as fid
    from friendships where auth.uid() in (a,b)
    union select auth.uid()
  )
  select rank() over (order by s.score desc), p.display_name, s.score,
         (s.player_id = auth.uid())
  from scores s join players p on p.id = s.player_id
  where s.utc_date = p_date and s.difficulty = p_diff
    and s.player_id in (select fid from friends)
  order by s.score desc;
$$;
```

**Feedback loop**:
- **Playground**: `friends_service_test.dart` + local stack.
- **Experiment**: with 0 friends → just you; with 3 friends, only those + you ranked; a friend who didn't play today is absent.
- **Check command**: `flutter test test/infrastructure/friends_service_test.dart`

### Share cards + invite

**Pattern to follow**: existing `score_share_screen.dart` / `share_grid_builder.dart`.

**Overview**: Render a score/streak card and share via the OS sheet; include the invite link.

**Implementation steps**:
1. Compose a share card (score, tier, rank, mini-grid) reusing `share_grid_builder`.
2. `Share.shareXFiles([...])` with caption + `mergeloop://invite/<code>`.

**Feedback loop**:
- **Playground**: widget test renders the card; manual share on device.
- **Experiment**: card renders for a high score and a deadlock (low score) without overflow.
- **Check command**: `flutter test test/presentation/score_share_screen_test.dart`

## Data Model

See SQL blocks above: `players.friend_code`, `friendships(a,b)`, contact-hash storage (opted-in players only), and two RPCs (`redeemCode`, `friends_leaderboard`).

## API Design

| Method | Path | Description |
| ------ | ---- | ----------- |
| `POST` | `/functions/v1/match-contacts` | Hashed contacts → matching opted-in player ids. |
| `RPC` | `redeem_code` | Validate code, create mutual edge. |
| `RPC` | `friends_leaderboard` | Friends-filtered daily board per tier. |

## Testing Requirements

### Unit Tests

| Test File | Coverage |
| --------- | -------- |
| `test/infrastructure/contacts_hasher_test.dart` | Phone/email normalization equivalence + hash stability. |
| `test/infrastructure/friends_service_test.dart` | Code redeem (valid/self/dupe), friends-filter shaping. |
| `test/presentation/friends_screen_test.dart` | Friends list + empty state. |

### Integration Tests (local stack)
- Redeem creates exactly one canonical edge; both users see each other.
- `match-contacts` returns only opted-in matches; non-opted-in are invisible.
- `friends_leaderboard` excludes non-friends and friends who didn't play.

### Manual Testing
- [ ] Tap an invite link from a cold start → redeem prompt → friend added.
- [ ] Grant contacts permission → see matched friends; deny → graceful fallback to codes only.
- [ ] Share a score card to a real app (IG/X/messages).

## Error Handling

| Error Scenario | Handling Strategy |
| -------------- | ----------------- |
| Contacts permission denied | Hide contacts UI; keep friend codes; never re-nag aggressively. |
| Invalid/expired friend code | Inline error, no crash. |
| Deep link while signed out | Defer redeem until anonymous session + display name exist, then complete. |
| Duplicate friendship | Canonical `(a<b)` PK + upsert → idempotent. |
| Self-add via own link | RPC rejects `a == b`. |

## Failure Modes

| Component | Failure Mode | Trigger | Impact | Mitigation |
| --------- | ------------ | ------- | ------ | ---------- |
| Contacts hashing | Normalization mismatch | Differing phone formats across devices | Real friends don't match | Strict E.164/email normalization + equivalence tests. |
| Privacy | Raw contact leak | Sending unhashed data | Trust/store-policy violation | Only hashes sent; reviewed in code + documented in rationale string. |
| Deep link | Lost on cold start | Link handled before auth ready | Redeem silently dropped | Queue the pending code; complete after init. |
| Friendships RLS | Edge visible to non-members | Loose policy | Privacy leak | `select using (auth.uid() in (a,b))`; test a third party can't read. |
| match-contacts | Enumeration abuse | Attacker submits many hashes to probe membership | Privacy leak | Rate-limit + cap list size; only return opted-in matches. |

## Validation Commands

```bash
deno test supabase/functions/match-contacts        # if test file added
supabase start && supabase functions serve match-contacts
flutter analyze
flutter test test/infrastructure/contacts_hasher_test.dart
flutter test test/infrastructure/friends_service_test.dart
flutter test
```

## Rollout Considerations

- **Permissions**: ship the contacts rationale strings; contacts is opt-in and clearly explained (raw data never leaves device).
- **Monitoring**: watch `match-contacts` call volume (enumeration abuse signal).
- **Rollback**: Friends tab behind a flag; global leaderboard (Phase 2) is unaffected if disabled.

## Open Items

- [ ] Friend-code format/length (spec assumes 8-char base32).
- [ ] Associated-domains / App Links setup for https deep links (vs custom scheme only).
- [ ] Whether to support removing a friend in v1 (recommended: yes, simple delete).

---

_This spec is ready for implementation. Follow the patterns and validate at each step._
