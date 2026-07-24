# Google sign-in setup — the three blockers

Google sign-in cannot be tested until all three are done. They are all outside
the repository (consoles + one migration), which is why the build shipped
without them.

Verified state as of 2026-07-21:

| Thing | Value |
|---|---|
| Android package | `com.kidd.connect_merge` |
| Firebase project | `connect-merge-1` |
| Supabase project | `nnoqqchqprfikhabrrjt` (`https://nnoqqchqprfikhabrrjt.supabase.co`) |
| Debug SHA-1 | `F4:62:CC:AC:7C:C5:FF:B7:DB:99:A9:A9:DC:38:C9:B2:94:11:C5:5E` |
| Upload SHA-1 | `FC:B5:CD:12:EA:BA:90:A6:71:F8:18:46:79:4F:17:B0:D9:E1:E3:0F` |
| Hosted migrations | at `0010` — **`0011` not applied** |
| `oauth_client` entries in `google-services.json` | **none** |

That last row is the headline: Google sign-in has never been enabled for this
Firebase project, so there is no Android OAuth client and no Web client ID yet.

---

## Blocker 1 — Create the OAuth clients (Firebase / Google Cloud)

Without this, `google_sign_in` throws before Supabase is ever contacted.

### 1a. Register the SHA-1 fingerprints

1. Firebase console → project **connect-merge-1** → gear icon → **Project
   settings** → **General**.
2. Scroll to **Your apps** → the Android app `com.kidd.connect_merge`.
3. **Add fingerprint**, and add **both** of these (SHA-1, not SHA-256):

   ```
   F4:62:CC:AC:7C:C5:FF:B7:DB:99:A9:A9:DC:38:C9:B2:94:11:C5:5E   (debug)
   FC:B5:CD:12:EA:BA:90:A6:71:F8:18:46:79:4F:17:B0:D9:E1:E3:0F   (upload key)
   ```

4. **Later, before any Play release**, add a third: Play Console → your app →
   **Test and release** → **Setup** → **App signing** → copy the **SHA-1 of the
   "App signing key certificate"**. Play re-signs your AAB with its own key, so
   a build that signs in perfectly from the upload-key APK will fail in
   production with "invalid ID token" if this one is missing. This is the single
   most common way this feature breaks only for real users.

### 1b. Enable Google as a sign-in provider

Firebase console → **Authentication** → **Sign-in method** → **Google** →
enable → save. This is what actually mints the OAuth clients.

### 1c. Download the regenerated `google-services.json`

1. Project settings → **Your apps** → Android app → **google-services.json**.
2. Replace `android/app/google-services.json` in the repo.
3. Verify it now contains OAuth clients — this must print at least a
   `client_type 3` (Web) and `client_type 1` (Android):

   ```bash
   python -c "
   import json
   d=json.load(open('android/app/google-services.json'))
   for c in d['client']:
       for o in c.get('oauth_client', []):
           print(o.get('client_type'), o.get('client_id'))
   "
   ```

   If nothing prints, 1b did not take effect — do not continue.

### 1d. Grab the Web client ID and secret

Google Cloud console → **APIs & Services** → **Credentials**, same project.
Under **OAuth 2.0 Client IDs** find the one named **"Web client (auto created
by Google Service)"**. You need two values from it:

- **Client ID** — ends in `.apps.googleusercontent.com`. This is
  `GOOGLE_WEB_CLIENT_ID` *and* the ID you paste into Supabase.
- **Client secret** — Supabase needs this too.

> **The #1 mistake here:** using the *Android* client ID as `serverClientId`.
> It must be the **Web** one. The Android client has no secret and will produce
> "invalid ID token" / audience-mismatch errors that look like nonce problems.

---

## Blocker 2 — Configure Supabase auth

Dashboard → project `nnoqqchqprfikhabrrjt` → **Authentication**.

1. **Providers → Google**: enable it, paste the **Web** client ID into
   "Client IDs" and the **Web** client secret into "Client Secret". Save.
2. **Providers → Google → "Skip nonce check"**: leave this **OFF**. The app
   generates one nonce per process, hashes it into
   `GoogleSignIn.initialize(nonce: sha256(N))`, and sends the raw `N` to
   Supabase, so nonce verification works. Only turn it on if you hit a
   persistent nonce mismatch — and if you do, note it in `PLAN.md` as an
   accepted replay-protection weakening.
3. **Sign In / Providers → Anonymous sign-ins**: must stay **enabled** (already
   is — the whole app depends on it).
4. **Manual linking**: enable it. Without this,
   `linkIdentityWithIdToken` fails and *every* Google attempt falls through to
   the adopt path, which is destructive-by-design for guests. In current
   dashboards this lives under **Authentication → Sign In / Providers →
   Advanced / "Allow manual linking"**. If you cannot find the toggle, it can
   also be set in project config as `security_manual_linking_enabled = true`.

---

## Blocker 3 — Apply migration 0011

The hosted project is at `0010`. Until `0011` lands, `claim_profile` and
`push_profile` do not exist and `players` has no snapshot columns, so every
claim fails — the app stays playable (it degrades to `offlineReady`) but
nothing ever syncs.

Use the **CLI, not the MCP tools**, because of the earlier migration-history
repair on this project:

```bash
cd C:/Users/dat1k/Projects/connect_merge
supabase link --project-ref nnoqqchqprfikhabrrjt   # if not already linked
supabase migration list                            # expect local 0011 pending
supabase db push
supabase migration list                            # expect 0011 on both sides
```

Sanity-check the result (read-only):

```sql
select column_name from information_schema.columns
where table_name = 'players'
  and column_name in ('profile_snapshot','snapshot_revision',
                      'snapshot_updated_at','active_device_id');

select proname from pg_proc
where proname in ('claim_profile','push_profile');
```

Expect four columns and two functions. `supabase/tests/profile_claim_smoke.sql`
exercises claim, supersession, revision bumping, the size check, and
privileges if you want the fuller check.

---

## Then: run it on the Pixel

```bash
flutter run -d 57161FDCQ00846 \
  --dart-define=SUPABASE_URL=https://nnoqqchqprfikhabrrjt.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=<your anon key> \
  --dart-define=GOOGLE_WEB_CLIENT_ID=<web client id from 1d>
```

All three defines are required. Miss `SUPABASE_URL`/`SUPABASE_ANON_KEY` and the
app degrades to offline and never shows the gate; miss `GOOGLE_WEB_CLIENT_ID`
and the Google button throws with
`GOOGLE_WEB_CLIENT_ID must be supplied as a dart-define`.

**Note:** your existing install already has a `display_name`, so it will **not**
show the first-run gate. Reach Google sign-in via **Profile → "Save your
progress — Sign in with Google"**, or uninstall first to see the gate.

### What to check, in order

1. **Guest path** — fresh install → gate → "Play as guest" → you get a
   `Player######` name, skip name creation, land in the tutorial.
2. **Link path** — Profile → "Save your progress" → pick a Google account with
   no existing profile → same uid, name and scores retained, and a snapshot row
   appears (`select id, snapshot_revision, active_device_id from players`).
3. **Collision path** — sign in with a Google account that already owns a
   profile → the destructive warning must appear **before** anything changes,
   and Cancel must leave you exactly where you were.
4. **Restore path** — second device, same Google account → coins, XP, streak,
   cosmetics, stats calendar all return, and the tutorial does **not** replay.
5. **Supersede path** — with device B active, make a change on device A → A
   shows "opened on another device" and stops syncing.

`google_profile_restore.md` in this folder has the fuller manual matrix
including Play-signed and Android-backup cases.

---

## Troubleshooting map

| Symptom | Almost always |
|---|---|
| `ApiException: 10` (DEVELOPER_ERROR) | SHA-1 not registered for the certificate you built with, or `google-services.json` not refreshed after 1b |
| "invalid ID token" / audience mismatch | Android client ID used as `serverClientId` instead of the Web one |
| Works in debug, fails from Play | Play App Signing SHA-1 never registered (step 1a.4) |
| Every Google attempt hits the destructive adopt warning | Manual linking not enabled (Blocker 2.4) |
| Signs in fine but nothing ever syncs; `active_device_id` stays null | Migration `0011` not applied |
| Nonce mismatch errors | Nonce is per-process; fully restart the app rather than hot-reloading between attempts |
