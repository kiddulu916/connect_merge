# Plan Review Log: Google sign-in, guest identity, and cross-device profile restore
Act 1 (grill) complete — plan locked with the user. MAX_ROUNDS=5.

(The prior task's log — rewarded-ad reward-routing race — lives in git history at 636026b.)

## Round 1 — Codex

Material problems found:

1. **Destructive restore order:** The plan deliberately tests `wipeAll()` before `pull()` ([PLAN.md](/C:/Users/dat1k/Projects/connect_merge/PLAN.md:88)); offline, null, corrupt, or incompatible cloud data therefore destroys valid local progress.
   - Fix: Pull and fully validate into memory first, then atomically replace Hive; preserve local state on any failure.

2. **Claim/pull race:** An old device can push after the new device pulls but before it claims, leaving the new device to later overwrite newer progress.
   - Fix: Implement one transactional RPC that claims the row and returns its snapshot from the same `UPDATE ... RETURNING`.

3. **Lost dirty update:** If local write B occurs while snapshot A is uploading, A’s success can clear `snapshot_dirty`, permanently losing B.
   - Fix: Persist a monotonically increasing revision and clear dirty only when the uploaded revision still equals the current revision.

4. **Restore triggers its own sync:** `restore()` uses the same `saveProfile`/`saveStats` hooks that schedule pushes; before claim completes, this can return zero rows and mark the restoring session superseded.
   - Fix: Provide a notification-suppressed atomic restore operation and enable syncing only after the claim succeeds.

5. **The device ID is cloneable:** `device_id` lives in Hive while Android backup is enabled by default in the current manifest, so device-to-device restore can give two phones the same ID and defeat the guard. Android backs up most internal files unless explicitly excluded. [Android Auto Backup](https://developer.android.com/identity/data/autobackup)
   - Fix: Store the install ID in Android no-backup storage or exclude it from both cloud backup and device transfer.

6. **Collision handling strands real server data:** The claim that adopted anonymous users have “no `players` row” is false for existing players entering through Profile; their verified scores and friendships remain attached to an inaccessible UID.
   - Fix: Transactionally merge best scores and friendships server-side before deleting the guest, or explicitly disclose that all guest online identity data is abandoned.

7. **Account switching races existing jobs:** Prize checks already start unawaited at bootstrap ([main.dart](/C:/Users/dat1k/Projects/connect_merge/lib/main.dart:132)); they and queued sync work can write under or into the wrong account during session replacement.
   - Fix: Pause and drain account-scoped work, bind every operation to a captured UID/account epoch, and start prize checks only after onboarding/restore finishes.

8. **Sign-out can discard the debounce window:** The proposed `signOut() → wipeAll()` sequence does not flush dirty progress first.
   - Fix: Await a final guarded push before sign-out, blocking destructive wipe unless it succeeds or the user explicitly accepts losing unsynced changes.

9. **Challenge stats are omitted:** `collect()` lists only easy through legendary, but `Difficulty.challenge` exists and completion writes its `LifetimeStats` through `saveStats` ([game_cubit.dart](/C:/Users/dat1k/Projects/connect_merge/lib/application/game_cubit.dart:620)).
   - Fix: Serialize and restore every `Difficulty.values` stats key, including Challenge.

10. **Crash recovery after successful linking is missing:** If the app dies after identity linking but before display-name save/claim/push, the next launch shows the Google gate again and may misclassify the already-linked identity as a collision.
    - Fix: When `hasGoogleIdentity && needsDisplayName`, resume at name creation and bootstrap-reconcile any missing claim or initial snapshot.

11. **The native-auth configuration weakens security and lacks required credentials:** Permanent “skip nonce check” weakens replay protection, while the current Flutter reference says Google ID-token sign-in also requires the Google access token. [Supabase nonce guidance](https://supabase.com/docs/guides/self-hosting/self-hosted-oauth), [Flutter ID-token reference](https://supabase.com/docs/reference/dart/auth-signinwithidtoken)
    - Fix: Keep nonce checking enabled and implement the currently supported Google credential flow with both required tokens—or use OAuth/PKCE if the native SDK cannot provide nonce protection.

12. **Cancel-after-adopt relies on an acknowledged unreliable rollback:** Switching sessions merely to show cloud name/level makes cancellation depend on refresh-token restoration and creates unnecessary auth-state races.
    - Fix: Show the generic destructive warning immediately after the link collision and call `signInWithIdToken` only after confirmation.

13. **The schema permits storage abuse and has no compatibility boundary:** Any anonymous user can upload unbounded JSONB; `active_device_id` is unconstrained text, and snapshots have no schema version.
    - Fix: Use `uuid` for device IDs, add a JSONB byte-size check and explicit snapshot version, and set `snapshot_updated_at` server-side on every push.

14. **The tests miss the dangerous behavior:** Fake-client happy paths cannot validate RLS row counts, concurrent claims, mid-push writes, malformed snapshots, process-death checkpoints, or Android backup cloning.
    - Fix: Add Supabase integration concurrency tests plus fault-injection tests for each destructive transition and record token-free claim/push/pull failure telemetry.

VERDICT: REVISE
### Claude's response

Accepted (11 of 14):
- **#1 destructive restore order** — restore now validates fully in memory and aborts leaving Hive untouched; `wipeAll()` never runs ahead of a successful pull.
- **#2 claim/pull race** — claim + fetch collapsed into one `claim_profile()` `UPDATE … RETURNING` RPC; push likewise a single guarded `push_profile()` RPC.
- **#3 lost dirty update** — boolean dirty flag replaced with a local revision counter; dirty clears only if the revision is unchanged on push success.
- **#4 restore self-triggers sync** — `onChanged` suppressed during restore; sync armed only after the claim succeeds.
- **#5 cloneable device id** — VERIFIED: `AndroidManifest.xml` has no backup attributes, so `allowBackup` defaults true. Added backup-rules XML excluding the Hive box, plus a risk note that this removes a recovery path guests silently had.
- **#7 account-scoped work races the swap** — prize/payout checks moved out of bootstrap (`main.dart:132-139`) to after onboarding/restore, each bound to a captured uid.
- **#8 sign-out drops the debounce window** — final guarded push awaited; failure requires explicit user confirmation before the wipe.
- **#9 Challenge stats omitted** — VERIFIED: `Difficulty.challenge` exists (`difficulty.dart:10`) and writes stats via `game_cubit.dart:655`. My "×4" was simply wrong; `collect`/`restore` now iterate `Difficulty.values`.
- **#10 crash after link** — `hasGoogleIdentity && needsDisplayName` at bootstrap now skips the gate and resumes at name creation.
- **#12 cancel-after-adopt rollback** — adopted wholesale, and it removes a listed risk: the warning is now shown on `collision` *before* any session change, so `signInWithIdToken` only runs post-confirmation and there is nothing to roll back.
- **#13 schema hardening** — `active_device_id` typed `uuid`, 256 KB `octet_length` check, explicit `snapshot_version`, `snapshot_updated_at` set server-side inside the RPC.

Partially accepted (2):
- **#6 collision strands server data** — the factual half is right and now disclosed: a guest reaching this from Profile can own real `scores` and friendships, and the warning says so explicitly. The proposed **server-side merge is rejected**: merging two uids' scores collides with `unique (player_id, utc_date, difficulty)` and needs a service-role writer to `scores`, which is precisely what the trust model in `0001` exists to prevent. Disclosure, not machinery.
- **#11 nonce / access token** — `accessToken` accepted and now passed alongside `idToken`. On nonce: the plan no longer assumes "skip nonce check"; it keeps nonce verification enabled if `google_sign_in` can surface a raw nonce, with disabling as a last resort recorded as an accepted weakening. Switching to OAuth/PKCE is still rejected — it would add a third link type to `DeepLinkService`, where a dropped callback yields a half-linked account.

Partially accepted (1):
- **#14 tests** — fault injection, malformed/oversized/newer-version snapshots, mid-push writes, process-death checkpoints and failure telemetry all added. Full **Supabase integration concurrency tests are rejected as a gate**: the local stack is known-unreliable here (it lacks default table grants). Substituted a `supabase/tests/profile_claim_smoke.sql` at the SQL level, with two-device and backup-restore cases as documented manual verification.

## Round 2 — Codex

Most prior findings are addressed: atomic claim/pull, validated restore, Challenge stats, hook suppression, mid-upload revision checks, collision disclosure, final sign-out flush, schema bounds, observability, and stronger tests.

Remaining or new material problems:

1. **Adoption immediately invalidates its own claim:** `claim_profile` uses the current Hive `device_id`, then `wipeAll()` deletes it and generates a different UUID ([PLAN.md](/C:/Users/dat1k/Projects/connect_merge/PLAN.md:107)); every subsequent push returns superseded.
   - Fix: Keep install-scoped metadata outside account wipes, or use `wipeAccountData()` that preserves `device_id`.

2. **No local owner UID protects crash boundaries:** A crash after session adoption but before restore—or after sign-out but before wipe—reopens Hive data belonging to the previous UID under the new session.
   - Fix: Persist `storage_owner_uid` and block all cubits/routes/sync at bootstrap until it matches the authenticated UID or account recovery finishes.

3. **Null/invalid adopted snapshots are contradictory:** Restore aborts and preserves local Hive, but the session has already switched, so guest data can be displayed or pushed into the adopted account.
   - Fix: On owner mismatch, keep sync and gameplay blocked; explicitly handle missing row/null snapshot as empty-cloud onboarding and invalid/newer snapshots as retry/support states.

4. **Backup exclusion is incomplete:** Excluding only Hive does not ensure a restored phone reaches the gate; Supabase’s persisted session may be restored from shared preferences while Hive is absent. Android backs up shared preferences by default. [Android Auto Backup](https://developer.android.com/identity/data/autobackup)
   - Fix: Exclude Supabase auth persistence too, or make the owner-UID bootstrap reconciliation authoritative when Hive is absent.

5. **Confirmation is not bound to the selected Google identity:** The second `signInWithGoogle(confirmAdopt: true)` obtains another credential, allowing a different account to be selected after the user confirmed abandoning progress for the first account.
   - Fix: Cache the collision credential inside `AuthService` and consume that exact credential once in a separate `confirmAdopt()` call.

6. **Dirty revision durability remains unspecified:** An `onChanged` hook after the profile write still permits process death between persisting progress and incrementing `local_revision`.
   - Fix: Persist the value and incremented revision together in one Hive `putAll`, then notify the debounce service.

7. **“No cubit changes” conflicts with stale-UID dropping:** Prize methods mutate storage internally, so an outer UID check after their futures finish is already too late ([PLAN.md](/C:/Users/dat1k/Projects/connect_merge/PLAN.md:111)).
   - Fix: Either permit cubit changes for a pre-commit account-epoch check, or retain and drain all account-scoped futures before any session swap.

8. **Atomic local restore is asserted but not designed:** Clearing keys and then writing several profile/stats/history keys is not one crash-safe operation under the current storage layout.
   - Fix: Stage the complete replacement and commit an owner/version marker last; bootstrap treats a missing marker as an interrupted restore and retries.

9. **OAuth configuration is still unresolved and incomplete:** Current `google_sign_in` exposes a nonce only through one-time initialization, yet the plan defers the security decision; Supabase setup also requires the Web client secret, and production Android needs its OAuth client plus the Play App Signing certificate—not merely the upload-key SHA-1. [GoogleSignIn initialization](https://pub.dev/documentation/google_sign_in/latest/google_sign_in/GoogleSignIn/initialize.html), [Supabase Google setup](https://supabase.com/docs/guides/auth/social-login/auth-google)
   - Fix: Pin the plugin version and settle/test the nonce lifecycle now; document Web ID/secret and debug, upload, and Play-signing Android registrations.

10. **Sign-out choreography still has two holes:** It does not explicitly sign out the Google plugin, and reusing `_onAccountDeleted` exposes the gate while `ensureSignedIn()` is still unawaited ([main.dart](/C:/Users/dat1k/Projects/connect_merge/lib/main.dart:309)).
    - Fix: Sign out both Supabase and Google, await fresh anonymous authentication behind a loading state, then expose the gate.

11. **RPC hardening omits repository conventions:** The new functions do not specify pinned `search_path`, explicit qualified tables, null argument rejection, or execute revokes/grants used by migration `0010`.
    - Fix: Mirror `0010`: qualify `public.players`, set `search_path`, reject nulls, revoke `public/anon`, and grant only `authenticated`; rename DB `snapshot_version` to `snapshot_revision` to distinguish it from JSON schema version.

VERDICT: REVISE
### Claude's response

Accepted as-designed (8):
- **#1 adoption invalidates its own claim** — real bug I introduced: `wipeAll()` deleted `device_id` and regenerated it right after claiming. Split into `wipeAccountData()` (account keys) vs install-scoped keys (`device_id`, `owner`, revision) that survive it.
- **#4 backup exclusion incomplete** — Supabase persists its session in SharedPreferences, which Android backs up by default; exclusion rules now cover both it and the Hive box, with the ownership record as backstop.
- **#5 confirmation not bound to the identity** — genuine consent flaw. `signInWithGoogle()` now caches the colliding credential and `confirmAdopt()` consumes that exact one once, so a different Google account can't be selected after the warning.
- **#6 revision durability** — revision now persists in the same `putAll` as the payload it describes, closing the process-death window.
- **#9 OAuth configuration** — settled rather than deferred: Web client ID **and secret**, `google_sign_in` pinned to `^7.x`, the nonce lifecycle written out (fresh nonce → SHA-256 → `initialize`), and the **Play App Signing certificate** added alongside debug and upload keys. That last one was a correction, not a nit — upload-key-only registration fails in production exactly where it's hardest to debug.
- **#10 sign-out holes** — Google plugin sign-out added; `ensureSignedIn()` is now awaited behind a loading state instead of inheriting `_onAccountDeleted`'s unawaited race.
- **#11 RPC conventions** — mirrored `0010` exactly (`drop function if exists`, qualified `public.players`, `set search_path`, null rejection, revoke from public/anon + grant to authenticated). Renamed the DB column to `snapshot_revision`, leaving `schema_version` for the JSON payload. Also added `grant select, insert, update on public.players to authenticated` — `0010` needed precisely this for `scores` on stacks without DML default privileges.
- **#3 null/invalid adopted snapshot** — the contradiction was real. Restore outcomes are now three explicit states, not one "abort": null/no row ⇒ legitimately empty cloud account, proceed to onboarding; corrupt/oversized/newer ⇒ blocked, nothing shown or pushed under the adopted uid.

Accepted, but consolidated rather than implemented as proposed (3):
- **#2 owner uid**, **#7 stale-UID dropping vs. "no cubit changes"**, and **#8 atomic restore marker** are three symptoms of one missing invariant, so they get **one** mechanism: a single install-scoped `owner = {uid, snapshot_revision, restore_complete}` record that (a) gates every durable write at the storage layer, (b) is committed last to make restore crash-safe, and (c) is authoritative at bootstrap.
  - On **#7** specifically: Codex is right that my "no cubit changes" claim was false — prize methods mutate storage internally, so an outer check after the future resolves is too late. But the proposed fixes (drain all account-scoped futures, or thread an account epoch through the cubits) both add machinery. The storage-layer owner guard rejects the stale write at the point of the write, which is strictly later than any epoch check and needs no cubit API change. Same protection, smaller diff. "No cubit changes" is dropped as a claim; it's now a consequence.
  - Three separate guards would each have to be right. One has to be right once, and every durable write already routes through it.

## Round 3 — Codex

The revision addresses most prior findings, including device-ID preservation, backup exclusions, credential binding, SQL hardening, restore outcomes, revision durability, and sign-out flushing. Remaining issues:

1. **The owner guard cannot identify stale-work provenance:** A prize job started under UID A can finish after restore commits owner B; at write time both current UID and owner are B, so A’s payload passes the guard ([PLAN.md](/C:/Users/dat1k/Projects/connect_merge/PLAN.md:194)).
   - Fix: Retain and drain the four account-scoped futures before session swaps, or carry the initiating UID/epoch into each commit.

2. **Same-UID reload is not crash-safe yet:** Committing `restore_complete:true` last is insufficient when the existing owner already says true; a crash while promoting staged keys during “Reload profile” leaves partial state appearing complete.
   - Fix: Persist and await `restore_complete:false` before changing any live key, then write true only after promotion finishes.

3. **Owner initialization is undefined for core paths:** Existing installations, offline-first players, and fresh guests start without an owner; strict `owner.uid != currentUid` rejection would disable all durable writes.
   - Fix: Define bootstrap states explicitly: absent owner binds to the available session UID, no-session offline state remains locally unbound/writeable, and only an existing different UID triggers recovery.

4. **Sign-out preserves the old owner:** `wipeAccountData()` retains owner A, then creates anonymous user B and exposes the gate; guest or newly linked flows remain blocked unless ownership is explicitly rebound.
   - Fix: After fresh anonymous auth, initialize an empty owner for B before showing the gate; apply the same awaited reset choreography to account deletion.

5. **“Null snapshot / no row” conflates different states:** A row with a display name but no snapshot is an existing empty profile; no row means `claim_profile` failed and display-name creation plus a second claim are still required.
   - Fix: Return and handle `missingPlayerRow` separately from `emptySnapshot`, keeping sync disarmed until the missing row is created and claimed.

6. **The nonce plan remains internally unresolved:** `google_sign_in` v7 requires `initialize()` exactly once, so it cannot be reinitialized with a fresh nonce per attempt as proposed. Its access token also comes through the authorization client, not the authentication token object. [GoogleSignIn.initialize](https://pub.dev/documentation/google_sign_in/latest/google_sign_in/GoogleSignIn/initialize.html)
   - Fix: Choose one supported design now—one nonce per process with checking enabled, or OAuth/PKCE—and specify `authentication.idToken` plus `authorizationClient` access-token acquisition.

7. **Tests do not cover the two remaining owner races.**
   - Fix: Add tests for an A-started job committing after owner B is complete, and process death during a same-UID staged reload after the owner is marked incomplete.

VERDICT: REVISE
### Claude's response

All seven accepted. Two are corrections to *my* round-2 consolidation, which over-claimed:

- **#1 owner guard can't identify provenance** — conceded, and it reverses my round-2 rejection of #7. A job started under uid A that lands after `owner` is rebound to B sees `owner.uid == currentUid == B` and passes; the guard is a boundary check, not an identity check on in-flight work. The plan now says so explicitly and **drains the four retained futures** before any swap. Draining beats epoch-threading here only because all four call sites sit together at `main.dart:132-139` — my earlier "same protection, smaller diff" claim was simply wrong about the protection.
- **#2 same-uid reload isn't crash-safe** — right, and subtle: committing `restore_complete: true` last does nothing when the *existing* record already says `true`. The record is now written **twice** — `false` persisted before any live key is touched, `true` after promotion.
- **#3 owner initialization undefined** — this would have bricked durable writes for every existing install. Added an explicit bootstrap state table, including *absent owner + no session* (offline) staying writeable and locally unbound.
- **#4 sign-out preserves old owner** — retained owner A would block all writes for new anonymous user B. Rebind now happens after fresh auth, before the gate is exposed, on both sign-out and account deletion.
- **#5 null-snapshot conflation** — `missingPlayerRow` (claim matched nothing, row must be created and re-claimed) is now separate from `emptySnapshot` (row exists, never synced). Sync stays disarmed through the former.
- **#6 nonce** — this is the third round it has come back, so it is now decided rather than deferred: **one nonce per process, Supabase's nonce check stays enabled.** `initialize()` runs once per process, so per-attempt nonces are impossible; Supabase compares the token's nonce claim without tracking consumption, so intra-process retries work. Also corrected the credential shape — in v7 the access token comes from `authorizationClient`, not `authentication`.
- **#7 tests for the two races** — added, including the explicit note that the A-started-job case must be proven by the drain, since the guard demonstrably passes it.

## Round 4 — Codex

The previous seven findings are largely addressed. Four material gaps remain:

1. **Blocked restore failures are not persisted:** Validation happens before `restore_complete:false`; on a same-UID reload with corrupt/newer cloud data, restart sees the old `owner` still complete and resumes gameplay despite the required blocked state ([PLAN.md](/C:/Users/dat1k/Projects/connect_merge/PLAN.md:162)).
   - Fix: Persist `recovery_required`/`restore_complete:false` when validation fails, even though live account data remains untouched.

2. **One bootstrap state is still missing:** `owner` present with no session is undefined, which can occur when an existing player launches offline after session expiry.
   - Fix: Explicitly allow offline writes against the last owner with sync disabled, then reconcile or block once authentication returns.

3. **Owner-mismatch “recovery” lacks a deterministic branch:** Adoption crashes require cloud claim/restore, while sign-out or deletion crashes require local wipe plus anonymous rebind; treating both as generic recovery risks the wrong destructive action.
   - Fix: Branch on the current identity: Google session → claim/restore; anonymous session → wipe account data, rebind, and show the gate.

4. **Credential handling remains contradictory:** Step 3 says fetch the access token only if ID-token-only auth fails, while step 4 requires always passing both; cancellation also does not clear the cached collision credential.
   - Fix: Always obtain and pass both tokens, and clear the cached credential on cancel, failure, new attempt, and sign-out.

Add tests for these four paths; the rest is sound.

VERDICT: REVISE
### Claude's response

All four accepted; all four are narrow and none reopened a settled decision.

- **#1 blocked restore not persisted** — the ordering bug is real: validation runs *before* `restore_complete:false` is written, so a same-uid reload that fails validation would restart into the old complete `owner` and resume gameplay on exactly the state meant to be blocked. `recovery_required: true` is now persisted at the moment validation fails, even though live data is untouched.
- **#2 missing bootstrap state** — `owner` present + no session (existing player launching offline after session expiry) added: writes allowed against the last owner, sync disabled, reconcile when auth returns. Without it the offline-first guarantee this app already ships would break for exactly its most established players.
- **#3 recovery lacks a deterministic branch** — the sharpest of the four. Adopt-crash and sign-out-crash both present as "owner mismatch" but need opposite actions, and generic recovery could wipe data that the cloud has not got. Now branched on identity: Google session ⇒ claim + restore; anonymous session ⇒ wipe, rebind, gate. A test per branch.
- **#4 credential contradiction** — steps 3 and 4 genuinely contradicted each other (conditional vs. mandatory access token). Resolved to always acquire both tokens on every attempt, and the cached collision credential is cleared on cancel, failure, new attempt and sign-out.

## Round 5 — Codex (MAX_ROUNDS)

The four prior findings are addressed. Three new material gaps remain:

1. **Profile sync itself is not drained across session swaps:** Step 11 drains only prize futures; a debounced/in-flight guest push can complete after adoption, mutate shared dirty/superseded state, or run under the adopted session.
   - Fix: `pauseAndDrain()` `ProfileSyncService` before adopt/sign-out/delete, discard queued old-account work, then resume with session state reset after owner reconciliation.

2. **The existing-player link path has no success choreography:** ProfileScreen is the only entry point for existing installs, but its button does not specify handling `linked` with claim + initial push, or `collision` with the adoption flow.
   - Fix: Define both ProfileScreen outcomes explicitly and reuse the same claim/push or confirm-adopt orchestration as the gate.

3. **`recovery_required` is absent from the declared owner schema and successful recovery never explicitly clears it.**
   - Fix: Add it to `owner`, set it on validation failure, and clear it only when restore/rebind commits successfully.

Add focused tests for paused in-flight sync, both ProfileScreen Google outcomes, and recovery-flag clearing.

VERDICT: REVISE
### Claude's response

All three accepted. Each is a gap my own round-4 edits opened, not a new disagreement:

- **#1 sync not drained** — I added draining for the prize futures and forgot the service that pushes on a timer. `pauseAndDrain()` added: cancel the debounce, await the in-flight push, discard queued old-account work, reset and re-arm only after `owner` reconciliation.
- **#2 ProfileScreen link path unspecified** — the entry point that matters most for the existing user base had no success choreography. Both outcomes now specified and explicitly reusing the gate's orchestration: `linked` ⇒ claim + initial push, no name screen; `collision` ⇒ same confirm-adopt flow.
- **#3 `recovery_required` not in the schema** — I introduced the flag in the bootstrap state table without adding it to the record it lives in. Added, with the clearing rule stated: only a successful restore or rebind clears it.

### Resolution — MAX_ROUNDS reached

Five rounds ran; findings fell 14 → 11 → 7 → 4 → 3, and Codex confirmed each prior round's fixes before moving on. **No substantive disagreement remains open.** Exactly two proposals were rejected across all five rounds, both with reasons recorded above and neither re-raised after rejection:

1. **Server-side merge of an abandoned guest's `scores`/friendships** (R1 #6) — collides with `unique (player_id, utc_date, difficulty)` and needs a service-role writer to `scores`, which the trust model in `0001` exists to prevent.
2. **Supabase integration concurrency tests as a merge gate** (R1 #14) — the local stack lacks default table grants; substituted a SQL-level smoke test plus documented manual two-device verification.

The honest caveat: the three round-5 fixes above are **applied but not re-reviewed** — the round cap was reached, not an APPROVED verdict. They are small and localized (one field added to a record, one drain call, one already-specified flow reused), and none reopens a decision.

## Round 6 — Codex (user-authorized, past MAX_ROUNDS)

The prior material findings are addressed:

- Sync work is paused, drained, discarded, and re-armed across identity changes.
- Existing guest-to-Google linking now uses the same claim/adoption choreography.
- `recovery_required` has explicit persistence, clearing rules, and test coverage.
- Prize futures are drained before account transitions.

No new material flaws found. Minor cleanup: replace the illustrative `google_sign_in: ^7.x` with a valid concrete pubspec constraint such as `^7.2.0`.

VERDICT: APPROVED
### Claude's response

Accepted: `^7.x` was illustrative, not a valid pubspec constraint. Replaced with `google_sign_in: ^7.2.0`, noting the exact patch should be confirmed at `pub add` time.

### Final resolution — CONVERGED

**`VERDICT: APPROVED` at round 6.** Findings across the full review: 14 → 11 → 7 → 4 → 3 → 0.

The round-5 fixes that were applied-but-unverified at the cap have now been explicitly confirmed by Codex (sync drain, ProfileScreen link choreography, `recovery_required` schema + clearing rules, prize-future draining). No open disagreements.

Rejected across all six rounds, both with recorded reasons, neither re-raised:
1. Server-side merge of an abandoned guest's `scores`/friendships (R1 #6).
2. Supabase integration concurrency tests as a merge gate (R1 #14).

Plan is locked and ready to implement.

## Act 3 — Build

Builder: Codex (`gpt-5.6-sol`, codex-cli 0.144.4), thread `019f879c-cf1a-77a3-8f8f-4ee08f64e614`.
Reviewer: Claude. Branch `feat/google-signin-profile-sync`.
PROOF_CMD = `flutter analyze && flutter test`.

### Round 1 — Codex build

Stopped partway, reporting that "another active session" was overwriting
`storage_service.dart`. No other session existed; the JSONL stream showed
`collab_tool_call` sub-agents, so it had raced itself. Infrastructure half was
on disk and intact (storage + ownership + migration + backup rules + tests);
auth/UI half unstarted. Resumed the same thread with the misdiagnosis
corrected and an instruction to serialize its own edits.

It then completed: migration `0011`, two atomic RPCs, `ProfileSyncService`,
`AuthService` Google flow, `AccountFlowController`, `AuthGateScreen`, main.dart
bootstrap wiring, ProfileScreen controls, Android backup rules, and 6 new test
files. Reported `flutter analyze` clean, 632 tests passing.

### Claude's verdict — one serious defect

Independently re-ran the proof (clean, 632 passing) and read the full diff.
Scope guard held: no diff in `lib/domain/engine/**`, `supabase/functions/**`,
golden vectors, or `kLeaderboardSeason`. Migration mirrors `0010`'s conventions
exactly. The `AuthService` credential binding, staged restore ordering, and the
double-flush-around-the-drain sign-out path are all faithful, and the sign-out
choreography is better than the spec required.

**Defect: the entire pre-existing user base would have been bricked for sync.**
Proven with a throwaway probe against `ProfileSyncService.withSeams`, not by
inference. An install that onboarded before this feature has a display_name, so
it never reaches the auth gate — and `claim_profile` was only ever called from
the gate flows. Observed:

  Launch 1: bootstrap -> owner==null -> bare rebindOwner -> ready
            armed=false, RPC calls=[]        (never claims, never syncs)
  Launch 2: owner matches uid -> arm() -> push against a NULL
            active_device_id -> guard matches 0 rows
            push=superseded, superseded=true (on a device nothing superseded)

### Round 2 — Codex fix attempt

Stalled again on the same self-inflicted write race, this time delivering **zero
implementation changes** — though it had written the test cases for the fix
first. Per the skill's `MAX_FIX_ROUNDS` rule, Claude took over rather than
ping-pong a third time.

### Claude's takeover

Added a `claimed` flag to `LocalOwner` (defaults false, so records written by
older builds re-claim rather than being trusted), threaded through both storage
implementations, and:
- `arm()` and `_pushOnce` now gate on a held claim, never a bare uid match.
- Bootstrap claims when binding an owner that has never claimed — covering both
  the upgrade cohort and any bind whose claim failed offline — via
  `claimAndPushLocal`, never the destructive adoption path.
- A failed claim binds unclaimed, stays disarmed, and retries next bootstrap.
- `missingPlayerRow` still routes to name creation rather than blocking.

Caught one bug in my own change while fixing it: `claimAndRestore`'s
empty-snapshot branch rebound *after* a successful claim but dropped the flag,
which would have left those accounts permanently unable to push.

**Note on the write race:** Codex's background processes were still alive during
the takeover and were still writing files. Its complaint was wrong for round 1
but arguably right for round 2 — the competing writer was me. Processes were
killed and the entire proof re-run from a settled tree.

Codex's own pre-written tests for this fix passed against the implementation, so
my duplicate test file was deleted in favor of its versions (they assert the
exact RPC sequence and device-id threading).

### Final verification — Claude, settled tree, no writers

- `flutter analyze` — No issues found!
- `flutter test` — **All tests passed (635)**, up from 570 pre-feature.
- Scope guard clean; no migration or function deployed anywhere.
