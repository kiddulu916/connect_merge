# Plan: Google sign-in, guest identity, and cross-device profile restore
_Locked via grill — by Claude + kiddulu916_
_Revised after Codex review rounds 1–2._

(The prior task's plan — rewarded-ad reward-routing race — lives in git history at `636026b`.)

## Goal

Let a player carry their whole game to a new device. Today identity is
anonymous-only (`AuthService.ensureSignedIn`, `main.dart:113`) and the server
holds almost nothing a player would call "progress": `players` is
display_name + avatar, `scores` is verified runs, and everything else — XP,
level, coins, cosmetics, streak, almanac, prize ledger, tutorial flag, lifetime
stats, the stats-calendar history — lives only in Hive. This plan adds a Google
identity that can be linked to the existing anonymous user (preserving uid,
name, scores and friendships), a first-run gate offering Google-or-guest, a
`jsonb` snapshot of all durable Hive state synced to the player's own `players`
row, and a single-active-device claim so two phones can never clobber each
other. A guest gets a generated name and skips name creation entirely.

Nothing here touches `lib/domain/engine` or its TypeScript mirror, so the
dual-engine invariant and `kLeaderboardSeason` are untouched.

## The local-ownership record (read this first — three review findings collapse into it)

One Hive record, `owner`, guards the crash and account-swap boundaries:

```
owner = { uid, snapshot_revision, restore_complete: bool, recovery_required: bool }
```

`recovery_required` is set when a restore fails validation and is cleared
**only** when a restore or rebind commits successfully — never as a side effect
of launching, retrying, or signing in again.

- **It gates writes at the storage layer.** `HiveStorageService` rejects any
  durable write when `owner.uid` != the currently authenticated uid. This
  covers every write that crosses a boundary *after* the rebind — a queued
  push, a half-swapped session, a backup-restored session with no box.
- **It does NOT cover stale-work provenance, and cannot.** A prize job started
  under uid A that completes after `owner` has been rebound to B sees
  `owner.uid == currentUid == B` and passes. The guard is a boundary check, not
  an identity check on in-flight work. That case is handled separately in
  step 11 by draining the futures, which are enumerated in exactly one place.
- **It makes restore crash-safe — by being written twice.**
  `restore_complete: false` is persisted **before any live key is touched**,
  and `true` only after promotion finishes. Committing `true` last is *not*
  sufficient on its own: during a same-uid "Reload profile" the existing record
  already says `true`, so a crash mid-promotion would leave partial state
  looking complete.
- **It is authoritative at bootstrap**, with explicitly defined states (below)
  rather than a blanket mismatch rejection.

**Bootstrap states** (undefined states here would disable durable writes for
every existing install):

| `owner` | session | behavior |
|---|---|---|
| absent | present | bind `owner.uid` to the session uid; writes allowed. Covers existing installs and fresh guests. |
| absent | none (offline / unconfigured) | locally unbound; writes allowed, sync inert. Preserves today's offline-first behavior. |
| present, uid matches | present | normal. |
| present, uid differs | present | blocked → recovery, branched (below). |
| present | none (offline / expired session) | writes allowed against the last owner, sync disabled; reconcile or block once authentication returns. An existing player launching offline after session expiry must still be able to play. |
| `restore_complete == false` | any | interrupted restore → re-run restore before anything else. |
| `recovery_required == true` | any | blocked (see step 7): a prior restore failed validation. |

**Recovery is branched on the current identity, never generic** — the two ways
to reach a mismatch need opposite actions, and guessing wrong is destructive:

- **Google session** (crash between adopt and restore) → `claim_profile` +
  validated restore. The cloud row is the truth.
- **Anonymous session** (crash between sign-out/delete and wipe) →
  `wipeAccountData()`, rebind `owner`, show the gate. The local data belongs to
  a user who is already gone.

`owner`, `device_id` and the local revision are **install-scoped**, not
account-scoped: `wipeAccountData()` clears `profile` / `stats:*` / `history` and
preserves them. A blanket `wipeAll()` would delete `device_id` and regenerate
it, instantly invalidating the claim the same flow just made. Every path that
ends a session (sign-out, account deletion) **rebinds `owner` to the new
anonymous uid before exposing the gate** — otherwise the retained owner A
blocks all writes for the new user B.

## Approach

1. **Migration `0011_profile_snapshot.sql`.** Add to `players`:
   `profile_snapshot jsonb`, `snapshot_revision int not null default 0`,
   `snapshot_updated_at timestamptz`, `active_device_id uuid`. Add
   `check (profile_snapshot is null or octet_length(profile_snapshot::text) <= 262144)`.
   (`snapshot_revision` is the DB row counter; the JSON payload carries its own
   `schema_version` — deliberately different names so they can't be confused.)
   Also `grant select, insert, update on table public.players to authenticated`:
   `0010` had to do exactly this for `scores` because stacks provisioned without
   DML default privileges leave `authenticated` with no table-level grant, and
   `security invoker` functions then fail with "permission denied".

2. **Two RPCs in the same migration, mirroring `0010`'s conventions**
   (`drop function if exists` first, schema-qualified `public.players`,
   `set search_path = public`, null-argument rejection,
   `revoke execute … from public, anon` then `grant execute … to authenticated`).
   Each must be a single atomic statement or the guard is decorative.
   - `claim_profile(p_device uuid)` →
     `update public.players set active_device_id = p_device where id = auth.uid()
      returning profile_snapshot, snapshot_revision`.
     Claim and fetch in **one** `UPDATE … RETURNING`, closing the window where
     an old device pushes between a new device's pull and its claim.
   - `push_profile(p_device uuid, p_snapshot jsonb)` →
     `update public.players set profile_snapshot = p_snapshot,
      snapshot_revision = snapshot_revision + 1, snapshot_updated_at = now()
      where id = auth.uid() and active_device_id = p_device`,
     returning `true` if a row was updated, `false` ⇒ **superseded**.
     `snapshot_updated_at` is server-side; the client never supplies it.

3. **Google/Supabase configuration, settled now rather than at implementation.**
   - Supabase Google provider: **Web** OAuth client ID **and client secret**.
   - Android OAuth clients registered for **three** certificates: debug, the
     upload key (`connect_merge-upload.jks`), **and the Play App Signing
     certificate** — Play re-signs the AAB, so registering only the upload-key
     SHA-1 still produces "invalid ID token" in production.
   - `serverClientId` = the **Web** client ID, not the Android one.
   - Manual account linking enabled (required for `linkIdentityWithIdToken`).
   - **Nonce — decided: one nonce per process, checking stays ENABLED.**
     `google_sign_in` v7 requires `initialize()` exactly once per process, so a
     fresh nonce per *attempt* is impossible; the earlier wording was
     self-contradictory. Actual design: generate one random nonce `N` at
     startup, `initialize(serverClientId: <web>, nonce: sha256(N))`, hold `N` in
     memory, and pass raw `N` to Supabase on every sign-in attempt in that
     process. Supabase compares the token's nonce claim to the supplied value
     and does not track consumed nonces, so retries within a process are fine.
     Supabase's nonce check is **not** disabled.
   - **Credential shape — always obtain and pass both tokens.** `idToken` comes
     from `GoogleSignInAccount.authentication.idToken`; the access token is
     **not** on that object in v7 — it is obtained from the
     `authorizationClient` (`authorizeScopes(['email','profile'])`). Both are
     acquired unconditionally on every attempt; there is no id-token-only
     first try.

4. **`pubspec.yaml`:** add `google_sign_in: ^7.2.0` (a concrete constraint —
   the v6→v7 API change is exactly what a loose one would break; verify the
   exact current 7.x patch at `pub add` time).
   `gotrue 2.26.0` is already locked (`pubspec.lock:418`) and ships
   `linkIdentityWithIdToken` — no Supabase bump needed. Both `idToken` **and**
   `accessToken` from the native credential are passed to Supabase.

5. **Android Auto Backup exclusion.** `AndroidManifest.xml` sets no backup
   attributes, so `allowBackup` defaults to **true**. Add
   `android:dataExtractionRules` + `android:fullBackupContent` XML excluding
   **both** the `connect_merge` Hive box **and** Supabase's session persistence
   (SharedPreferences) — excluding only Hive would let a restored phone come up
   holding a valid session with no local data, which is precisely the
   owner-mismatch state. Backup restore therefore lands the player at the gate,
   where signing in pulls the cloud snapshot. The `owner` record is the
   authoritative backstop if any of this is ever misconfigured.

6. **`AuthService` additions** (keeps the rule that nothing else imports the
   plugin):
   - `Future<GoogleAuthResult> signInWithGoogle()` — obtains one native
     credential and calls `linkIdentityWithIdToken(OAuthProvider.google, …)`.
     On `identity_already_exists` (422) it **caches that exact credential**
     internally and returns `collision` **without touching the session**.
   - `Future<GoogleAuthResult> confirmAdopt()` — consumes the cached credential
     **once** and calls `signInWithIdToken(...)`. The confirmation is therefore
     bound to the identity the player was actually warned about; re-prompting
     for a credential after confirmation would let a *different* Google account
     be selected post-consent. The cache is cleared on **cancel, failure, any
     new sign-in attempt, and sign-out** — a lingering credential is a consent
     bound to a stale decision.
   - `bool get hasGoogleIdentity` — from `currentUser.identities`.
   - `Future<void> signOut()` — signs out of **both** Supabase and the Google
     plugin (leaving the plugin signed in silently re-attaches the same account
     on the next attempt).
   - `setDisplayName` unchanged. No session stashing and no `setSession`
     rollback: the session is never swapped speculatively.

7. **`ProfileSyncService`** (new, `lib/infrastructure/profile_sync_service.dart`):
   - `collect(StorageService)` → `{schema_version, profile, stats, history}`
     where `stats` covers **every `Difficulty.values` key including
     `challenge`** — a real tier whose `LifetimeStats` is written through
     `saveStats` (`game_cubit.dart:655`).
   - `restore(json)` — validate fully in memory, persist
     `owner{restore_complete: false}` **before touching any live key**, stage
     and promote, then commit `restore_complete: true`. Outcomes are four
     distinct states, not one "abort" bucket:
     - **`missingPlayerRow`** (`claim_profile` matched no row) ⇒ the claim did
       **not** happen. Sync stays disarmed; the player must create a display
       name, which creates the row, and only then is `claim_profile` retried.
     - **`emptySnapshot`** (row exists, `profile_snapshot` is null) ⇒ a
       legitimate existing profile that has never synced ⇒ `wipeAccountData()`,
       bind `owner.uid`, proceed to normal onboarding. Not an error.
     - **corrupt / oversized / newer `schema_version`** ⇒ blocked state: no
       gameplay, no sync, retry-or-support message. Local data is never shown
       or pushed under the adopted uid. **`recovery_required: true` is
       persisted at the moment validation fails** — even though live account
       data is untouched — because validation runs *before*
       `restore_complete: false` is written, so on a same-uid reload a restart
       would otherwise find the old `owner` still complete and resume gameplay
       against exactly the state that was supposed to be blocked.
   - Restore runs with the `onChanged` hook **suppressed**, and sync is armed
     only after `claim_profile` succeeds.
   - `push()` calls `push_profile`; `false` ⇒ stop pushing for the rest of the
     session and surface the superseded modal.
   - Debounced (~5s), coalescing, flushed on app pause/detach.
   - **Dirty tracking is a local revision counter written in the same Hive
     `putAll` as the value it describes** — incrementing it in a separate write
     after the payload leaves a process-death window that silently drops
     progress. A push captures the revision it uploads and clears dirty only if
     `local_revision` is still that value on success.
   - `device_id` is a v4 uuid, install-scoped, **preserved by
     `wipeAccountData()`**.

8. **`HiveStorageService` / `StorageService`:** add the `owner`-based write
   guard, a suppressible `onChanged` hook on `saveProfile` / `saveStats` /
   `appendResult` (`addCoins` already routes through `saveProfile`),
   `replaceHistory(...)`, a staged `restoreAll(...)`, and `wipeAccountData()`
   alongside the existing `wipeAll()`.

9. **`AuthGateScreen`** (new): "Continue with Google" / "Play as guest".
   Inserted in `main.dart` ahead of `DisplayNameScreen`, shown only when
   `needsDisplayName && auth != null` — offline/unconfigured first-run keeps
   today's behavior exactly.
   - **Guest** → generate `Player` + 6 random digits, `setDisplayName` with up
     to 3 retries on `DisplayNameTakenException`, `claim_profile`, then
     `_onOnboarded()` — skipping `DisplayNameScreen` and landing in
     `TierSelectScreen`, which runs the tutorial (`tutorialSeen` is false).
   - **Google → `linked`** (anonymous user upgraded in place, same uid) → no
     display name yet → `DisplayNameScreen`, then claim + push.
   - **Google → `collision`** → destructive warning **before any session
     change**, naming what is locally visible and stating the abandonment
     plainly: *"This Google account already has a Connect Merge profile.
     Signing in switches to it and permanently abandons this device's guest
     account — level 14, 2,400 coins, a 19-day streak, and its leaderboard
     scores and friends."* Continue ⇒ `confirmAdopt()` → `claim_profile` →
     validate → `wipeAccountData()` + staged restore → `owner` committed →
     reload cubits → `TierSelectScreen`.
   - **Crash-resume:** if `hasGoogleIdentity && needsDisplayName` at bootstrap,
     the link already succeeded before the process died — skip the gate, resume
     at `DisplayNameScreen`, reconcile any missing claim or initial push.

10. **Restore ordering:** claim + validate + restore + `engagement.load()` /
    `loot.load()` / `rivalry.load()` are all `await`ed **before** the route
    flips to `TierSelectScreen`, because `TierSelectScreen.initState`
    (`tier_select_screen.dart:206`) reads `tutorialSeen` from Hive and would
    otherwise show the tutorial to a restored veteran.

11. **Account-scoped work is retained and drained.** The four prize /
    challenge-payout checks fire `unawaited` at bootstrap
    (`main.dart:132-139`), before onboarding has resolved. Move them to fire
    only after onboarding/restore completes, **retain their futures in a list,
    and `await` them before any session swap** (adopt, sign-out, delete).
    `ProfileSyncService` is drained too, and it needs more than an await:
    `pauseAndDrain()` before any swap — cancel the debounce timer, await any
    in-flight push, and **discard queued work belonging to the old account** so
    a guest's pending push cannot land under the adopted session or leave stale
    dirty/superseded state behind. Sync state is reset and re-armed only after
    `owner` reconciliation completes.
    The `owner` guard alone is insufficient here: a job started under uid A
    that lands after `owner` is rebound to B sees `owner.uid == currentUid == B`
    and passes. Draining is chosen over threading an account epoch through
    `EngagementCubit` because all four call sites are already enumerated in one
    place — it's the smaller change, and it does not alter any cubit API.

12. **Account switching clears account data only after a validated pull**, via
    `wipeAccountData()`. Hive keys carry no uid, so the next account would
    otherwise inherit the previous player's coins and push them into its own
    cloud row.

13. **Profile screen:**
    - Google-linked → **Sign out**: `await` a final guarded push (on failure,
      the player is told explicitly that unsynced progress will be lost and
      must confirm) → drain retained account-scoped futures → sign out of
      Supabase **and** Google → `wipeAccountData()` → **`await ensureSignedIn()`
      behind a loading state** → **rebind `owner` to the new anonymous uid** →
      then expose the gate. `_onAccountDeleted` (`main.dart:309`) currently
      leaves `ensureSignedIn()` unawaited and shows the route immediately; that
      race must not be inherited, and it gets the same rebind choreography.
    - Guest → **"Save your progress — Sign in with Google"** in the same slot.
      Also the only entry point for players who installed before this ships:
      they already have a `display_name`, so they never see the gate. It
      **reuses the gate's orchestration verbatim** rather than reimplementing
      it, and both outcomes are specified:
      - `linked` ⇒ uid, name, scores and friendships are preserved in place;
        `claim_profile`, then an **initial push** so the cloud row stops being
        empty. No `DisplayNameScreen` (they already have a name).
      - `collision` ⇒ the same destructive warning and `confirmAdopt()` flow as
        the gate — and this is the path where the warning matters most, since
        this player has weeks of real progress rather than a fresh install.
    - **Change name** → pushes the existing `DisplayNameScreen` (currently
      reachable only on first run, which would strand every guest as
      `Player482915` permanently).

14. **Superseded modal:** "Your profile was opened on another device. Progress
    on this device isn't being saved." Single action **Reload profile** →
    `claim_profile` + validated restore. User-initiated, so two open devices
    can't ping-pong claims automatically.

15. **Observability.** Log claim/push/pull failures, superseded events, restore
    outcomes (empty-cloud / corrupt / oversized / newer-version), owner
    mismatches and interrupted restores, guest-name retry exhaustion, and each
    gate outcome through the existing `AnalyticsService` /
    `CrashReportingService` — no tokens or snapshot contents in the payload.

16. **Tests.**
    - `collect` → `restore` round-trip preserves all three key families across
      **every** `Difficulty.values` tier.
    - Each restore outcome is distinct: `missingPlayerRow` ⇒ sync stays
      disarmed until name creation + retried claim; `emptySnapshot` ⇒
      onboarding; corrupt / oversized / newer-version ⇒ blocked, local Hive
      unchanged, nothing pushed.
    - The `owner` guard rejects a write whose uid doesn't match the session,
      and an interrupted restore (`restore_complete == false`) is detected and
      retried at bootstrap.
    - Every bootstrap state in the table above, especially **absent owner**
      (existing installs and offline players must stay writeable).
    - **A job started under uid A that commits after `owner` is rebound to B is
      prevented by draining, not by the guard** — the drain must be proven, since
      the guard demonstrably passes this case.
    - **Process death mid-promotion during a same-uid "Reload profile"** leaves
      `restore_complete == false` and is recovered, not mistaken for complete.
    - Sign-out and account deletion rebind `owner` to the new anonymous uid, so
      the next guest/link flow can write.
    - **A failed-validation restore persists `recovery_required`** and a restart
      stays blocked rather than resuming gameplay on the old complete `owner`.
    - **`owner` present with no session** (offline after session expiry) stays
      playable with sync disabled, and reconciles when auth returns.
    - **Recovery branches correctly on identity**: a Google session claims and
      restores; an anonymous session wipes, rebinds and shows the gate. A test
      per branch, since taking the wrong one is destructive.
    - The cached collision credential is cleared on cancel, failure, new
      attempt and sign-out, and `confirmAdopt()` after a cancel cannot adopt.
    - **A debounced or in-flight push queued under the guest account does not
      land under the adopted session**, and `pauseAndDrain()` leaves no stale
      dirty/superseded state.
    - **Both ProfileScreen Google outcomes**: `linked` claims and performs the
      initial push without routing to `DisplayNameScreen`; `collision` runs the
      same confirm-adopt flow as the gate.
    - **`recovery_required` is cleared only by a successful restore or rebind**
      — never by a bare relaunch or a fresh sign-in.
    - `device_id` survives `wipeAccountData()`, so the post-adopt claim stays
      valid and pushes are accepted.
    - A local write mid-upload is not cleared by the in-flight push's success,
      and the revision persists with its payload across a simulated kill.
    - Restore does not self-trigger a push; `push_profile` returning false marks
      superseded and stops further pushes.
    - `confirmAdopt()` consumes the cached credential and cannot silently adopt
      a different Google account than the one warned about.
    - Guest-name retry on 23505; crash-resume (`hasGoogleIdentity &&
      needsDisplayName`) skips the gate.
    - `supabase/tests/profile_claim_smoke.sql` exercising concurrent
      claim/push at SQL level (precedent: `leaderboard_smoke.sql`).
    - Two-device claim/supersede, Android backup-restore, and Play-signed
      release sign-in are **documented manual verification steps**.
    - Existing engine/golden-vector suites stay untouched and green.

## Key decisions & tradeoffs

- **Snapshot the progression, don't just restore identity.** Identity-only
  recovery would return scores and name but reset streak, coins and cosmetics —
  perceived as data loss. Cost: a sync path and a conflict rule.
- **Single active device (`active_device_id`), not field-wise merge.** Merging
  breaks on coins, which are *not* monotonic: buy on phone A (balance drops,
  item owned), phone B still holds the old balance, max-merge keeps both — a
  free-item dupe. Avoiding it means a wallet event ledger. Since `scores` is
  already `unique (player_id, utc_date, difficulty)`, concurrent same-day play
  on two devices gains nothing legitimate anyway.
- **One ownership record for boundaries, draining for in-flight work.** The
  storage-layer `owner` check covers the crash-boundary and restore-atomicity
  cases in one mechanism every durable write already routes through. It
  explicitly does **not** cover stale in-flight work — a job started under uid A
  passes the guard once `owner` is B — so the four enumerated account-scoped
  futures are retained and drained before any swap. Two mechanisms, each for
  the case it actually covers, rather than one over-claimed guard.
- **Install-scoped state is not account-scoped state.** `device_id`, `owner`
  and the local revision survive `wipeAccountData()`. The distinction is load
  bearing: wiping `device_id` during an adopt would invalidate the very claim
  that adopt just made.
- **The claim guard is only as good as its atomicity.** Both operations are
  single `UPDATE … RETURNING` RPCs, not client-sequenced statements.
- **Never destroy local state before a validated pull**, and never treat "no
  cloud data" as a failure — an empty snapshot is a legitimate new account.
- **On a guest↔cloud collision, cloud wins after an explicit destructive
  warning shown *before* the session changes, bound to the exact credential
  that collided.** Asymmetric on purpose: the cloud side is backed by verified
  `scores` rows only the replay-verifying Edge Function can write.
- **Rejected: server-side merge of the abandoned guest's scores and
  friendships.** A guest reaching this via Profile can own real server rows, but
  merging two uids' `scores` collides with
  `unique (player_id, utc_date, difficulty)` and needs a service-role writer to
  `scores` — the one thing the trust model in `0001` exists to prevent.
  Disclosure, not machinery.
- **Keep the eager anonymous `ensureSignedIn()` at bootstrap.** Required, since
  `linkIdentityWithIdToken` upgrades an existing anonymous user in place.
- **Native ID token, not `signInWithOAuth`.** One credential feeds both the link
  and the sign-in call. The browser flow would add a third link type to
  `DeepLinkService` (already multiplexing invites and duels), where a dropped
  callback means a half-linked account.
- **Gate only when auth is live.** The alternative needs an offline guest name
  written locally and reconciled later — a second identity write path, to fix a
  cosmetic consistency itch.
- **Sign out only where it's reversible.** For a guest the anonymous session is
  the only key to the row, so sign-out is irreversible deletion;
  `deleteAccount()` already serves players who want that.
- **Accepted, not fixed: the snapshot is client-authored.** `player_self` RLS
  lets a modded client write any `profile_snapshot`. Bounded on purpose: it buys
  cosmetics, never rank, because `scores` has no client write policy at all and
  the economy is walled off from `BoardState.score`. No worse than editing Hive
  today. The size check and `uuid` typing bound the *abuse* surface (storage
  exhaustion), not the *cheating* surface.

## Risks / open questions

- **Nonce granularity (decided, not open).** One nonce per process, not per
  attempt — a `google_sign_in` v7 constraint, since `initialize()` runs once.
  Supabase's nonce check stays on. The residual weakness is that repeated
  attempts within one app process share a nonce; acceptable, and far better
  than disabling the check.
- **Play App Signing.** The most likely production-only failure: sign-in works
  in debug and from the upload-key build, then fails for real users because the
  Play re-signing certificate was never registered.
- **Orphaned anonymous users.** Every adopt abandons an anonymous `auth.users`
  row — and, for a guest who reached this from Profile, its `players` row,
  `scores` and friendships too. Harmless but accumulating.
- **Backup exclusion is a behavior change for guests.** A guest restoring a new
  phone from device transfer no longer gets progress automatically — they must
  sign in. That's what makes the claim guard sound, but it removes a recovery
  path guests silently had.
- **Snapshot size drift.** Low tens of KB today; the 256 KB check backstops it.
  An uncapped future list in `PlayerProfile` would start failing pushes — the
  intended loud failure, but only if step 15's telemetry is watched.
- **The revision counter and the `owner` guard are the subtle pieces.** Both
  fail silently (dropped progress, or writes rejected for the wrong reason).
  Their tests are not optional.

## Out of scope

- iOS. There is no `ios/` directory; Android-only build
  (`applicationId com.kidd.connect_merge`).
- Syncing the in-progress per-day `GameSnapshot` (`"$date:<tier>"`). Racing a
  live move log against `submit-score`'s replay verification is not worth
  resume-on-another-device.
- Field-wise merge / multi-device concurrent play, and any wallet event ledger.
- Server-side merge of an abandoned guest's `scores` / friendships.
- Rename rate-limiting or name-change cooldowns.
- Server-side validation or anti-cheat for `profile_snapshot` contents.
- Any change to `lib/domain/engine`, its TS mirror, golden vectors, or
  `kLeaderboardSeason`.
- Other OAuth providers (Apple, Facebook), email/password, email recovery.
