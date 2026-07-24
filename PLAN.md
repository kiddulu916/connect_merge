# Plan: App Sharing → Referral Auto-Link Feature
_Locked via grill — by Claude + kiddulu916. Revised after Codex review rounds 1–3._

## Goal
Turn the existing invite flow into a referral loop that survives a fresh install. A player shares a generated message (text channels) or their score card (Facebook) carrying one universal link on the canonical host, `https://www.connectmerge.app/invite/<code>`. A recipient who **already has the app** (Android verified App Links, or iOS/Android via the custom-scheme "Open app" button) deep-links in and is added as a friend. A recipient who **does not** lands on a small platform-aware page; **Android** users go to the Play Store with the friend code embedded as an install referrer, and on first launch after a durable Google sign-in the app reads it and creates the mutual edge automatically. **Deferred (post-install) auto-linking is Android-only in v1**; iOS installs add the friend via manual code entry (the code is shown on the landing page).

## Resolved facts
- **Canonical host = `www.connectmerge.app`** — apex 308-redirects to `www` (`delete-account/index.ts:34`), so `www` is the non-redirecting origin used in every link, the App-Links intent-filter, and `assetlinks.json`.
- **Android applicationId = `com.kidd.connect_merge`; iOS bundle id = `com.kiddulu.connectMerge`** (`project.pbxproj:385`).
- **iOS custom scheme `connectmerge://` is already registered** (`Info.plist` CFBundleURLTypes), so installed iOS handles the "Open app" button and custom-scheme links; only *deferred install* linking is manual on iOS.

## Prerequisites — owner-side web deliverable (separately owned, blocking)
Tracked as its own deliverable because it lives outside this Flutter repo. Required inputs the **owner must supply** before this can be verified (Codex r3#7):
- **W1** — the `www.connectmerge.app` Vercel **project/repo name + responsible owner**.
- **W2** — the **release + Play App Signing SHA-256 fingerprints** for `assetlinks.json`.
- **W3** — whether an **iOS App Store listing** exists (determines the iOS landing button target).
Acceptance — assert status, not just body (Codex r4#5):
- `curl -sS -D headers.txt https://www.connectmerge.app/.well-known/assetlinks.json | jq -e '.[] | select(.target.package_name=="com.kidd.connect_merge" and (.relation[]=="delegate_permission/common.handle_all_urls"))'` succeeds, the saved JSON contains **every** W2 fingerprint under `target.sha256_cert_fingerprints`, and `headers.txt` shows `200` with no `Location:` (Codex r5#2).
- `curl -sS -o body.html -w '%{http_code} redirect=[%{redirect_url}]\n' https://www.connectmerge.app/invite/ABCD2345` → `200 redirect=[]`, and `body.html` contains the Play URL with `referrer=code%3DABCD2345`, the `connectmerge://invite/ABCD2345` Open-app link, and the literal code.
- `adb shell pm verify-app-links --re-verify com.kidd.connect_merge` reports `verified` for `www.connectmerge.app`.
- Route/validation/encoding/well-known tests live in **this web deliverable's own CI** (not the Flutter suite — Codex r4#6).

## Approach

### Web (`www.connectmerge.app`, Vercel — owner-side)
1. Serve `GET /invite/:code` as a **platform-aware landing page** (not a blind 302 — Codex r1#10):
   - Validate `:code` against `^[A-Z2-7]{8}$`; neutralize anything else.
   - **Android** (not installed / in-app browser that bypassed App Links): "Get it on Google Play" → `https://play.google.com/store/apps/details?id=com.kidd.connect_merge&referrer=code%3D<code>` (URL-encoded via a serverless/edge function).
   - **iOS/desktop:** App Store button iff W3 says a listing exists, else a "search Connect Merge, then enter code <code>" panel.
   - **All platforms:** an **"Open app"** button targeting `connectmerge://invite/<code>` (custom scheme actually re-opens the app — Codex r2#7), plus the manual **friend code** as selectable text. Covers FB/Instagram in-app browsers where App Links never fire, and lets installed iOS redeem via one tap.
2. Serve `/.well-known/assetlinks.json` from `www` with no redirect (W2).

### Native config
3. **Android App Links:** repoint the `/invite` intent-filter host from apex to `www.connectmerge.app`, tighten `pathPrefix` to **`/invite/`** so `/inviteevil` no longer matches (Codex r3#6), keep `autoVerify="true"`.
4. **app_links plugin (Codex r1#3):** `flutter_deeplinking_enabled=false` (Android) + `FlutterDeepLinkingEnabled=false` (Info.plist). Cold-start + warm-resume tests.

### Flutter client
5. **Single message builder** in `FriendsService`: `inviteMessage(code, {name})` → copy + `inviteHttpsLink(code)` built with `Uri` on `www.connectmerge.app`. Draft copy (**final wording is the user's sign-off**, Codex r2#6 — gameplay is one run *per difficulty* per day, auto-add not guaranteed on iOS/guest):
   `"<Name> challenged you on Connect Merge — everyone plays the same daily puzzle, one run per difficulty a day. Think you can top my score? Install and add me: <link>"`
   No-name fallback when the display name is unknown.
6. Repoint both share sites — `score_share_screen.dart:316`, `friends_screen.dart:114` — from `inviteLink` to `inviteMessage` (https). Custom scheme stays parsed inbound (and powers the landing "Open app" button).
7. **Install-referrer read (Android only), one-shot-on-fetch (Codex r1#5, r4#2, r5#5):** add `android_play_install_referrer`. On startup, **first check the `handled` bit in the persisted snapshot (step 8)** — if set, skip entirely (Play returns the same referrer for ~90 days). Otherwise read the referrer. **A successful fetch is terminal regardless of payload**: if it yields no valid `^[A-Z2-7]{8}$` `code=<code>` (organic install, malformed referrer), set `handled` and stop — do not re-fetch/re-log it every launch. Only an actual fetch/service failure stays un-`handled` for retry. A valid code is enqueued into the coordinator. Never block launch on the async connect.

8. **Redeem coordinator — explicit persisted state machine** (Codex r1#7, r2#4, r3#1-4, r4#1-4, r5#1). Persist **one atomic snapshot `{handled, active?:{code,source}, queued?:{code,source}}`** (source ∈ {liveLink, installReferrer}) as a single serialized value written **before** any RPC and rewritten whole on **every** transition, so the `handled` bit and the active/queued inputs can never diverge across a crash (Codex r5#1 — no separate keys). Priority `liveLink > installReferrer`.
   - **Enqueue (dedup first, Codex r4#4):** a code identical to `active` or `queued` is a no-op. No `active` → set it. `active` present → fill `queued` by priority; a newer **distinct** live link replaces an older queued live link; a `liveLink` that supersedes a not-yet-in-flight `installReferrer` marks the referrer handled (below) and takes `active`.
   - **Run:** promote `active` to in-flight, call `redeemCode`.
     - `ok`: clear `active`; run a queued **liveLink** always, but **drop a queued installReferrer** after a live-link success (Codex r3#2).
     - `self` / `invalidCode`: consume `active`; run `queued` if any.
     - transient (auth/Play/network): keep `active` pending for retry — **except** if `active` is an `installReferrer` and a `liveLink` is queued, discard/mark-handled the referrer and **atomically promote the live link** (preserve priority, Codex r4#3).
   - **`handled` bit (Codex r4#2):** set on **every terminal referrer outcome** (`ok`/`self`/`invalidCode`/`superseded`/priority-discard, plus the successful-but-empty fetch of step 7) — **never** on transient failure.
   - **Transient retry schedule (Codex r5#3):** retries are **serial** (one in-flight at a time), triggered on identity-readiness, app foreground, and connectivity recovery, with **bounded exponential backoff** (cap the attempts/interval) so there's neither a permanent stall nor a tight loop.
   - **Crash recovery (Codex r3#4):** the snapshot persists until terminal; on startup an interrupted in-flight `active` is restored to pending and retried — `redeem_code` is idempotent. Test each crash boundary (before/after RPC send, before/after `handled` write — now the same atomic write, Codex r5#1).
   - Replaces `DeepLinkService`'s single overwritable slot; both inputs are durable, so a live link arriving mid guest-onboarding is not lost. Tests: both arrival orders, mid-flight arrival, supersede, dedup, newest-live-link-replaces, transient-with-queued-live-link promotion, crash-restore, and referrer-handled-suppresses-resurrection.
9. **Identity gating, scoped (Codex r1#4, r3#1):** require a durable **Google identity only for `source == installReferrer`**. Live-link redemption keeps today's behavior — deferred via `_pendingAfterOnboarding` (`main.dart:399-409`) until onboarding completes, guests included. Carry a pending referrer through guest→Google account adoption.
10. **Hive survival (Codex r1#6):** add the single coordinator snapshot key (`{handled, active?, queued?}`) to `HiveStorageService._installKeys` (currently owner/deviceId/localRevision/syncedRevision) so it survives restore, adoption, and `wipeAccountData()` — otherwise `handled` is wiped and Play resurrects the referrer. Test all three paths.
11. **Facebook card (Codex r1#11, r5#4):** `ScoreShareScreen` currently receives only the nullable code captured at game start (`tier_select_screen.dart:222`) and rasterizes a stateless card immediately (`score_share_screen.dart:38`), so "ensure at share time" is not implementable as-is. **Inject an async code loader** (`ensureFriendCode`), await it on the share action, **rebuild the card and await the rendered frame** before capture, then reuse that resolved code in both the baked-on card (`share_card.dart` / `share_card_renderer.dart`) and the plain-text render-failure fallback (`score_share_screen.dart:304`). Test: loader awaited before capture, code present on card + fallback, null/large-text overflow.

### Data hardening (Codex r1#8/#9, r2#5, r3#6)
12. **Friend-code constraint with explicit preflight.** `friend_code` is unconstrained text and self-updatable, so migration must repair-or-abort, not assume clean data:
    - `select count(*) from players where friend_code is not null and friend_code !~ '^[A-Z2-7]{8}$'`; if >0, null those rows (forces re-allocation) then add `CHECK (friend_code ~ '^[A-Z2-7]{8}$')`.
    - Fix the invalid fixture `MYCODE12` (`test/presentation/friends_screen_test.dart`) to a valid `[A-Z2-7]{8}` code.
    - `ensure_friend_code` allocation hardening: `UPDATE ... WHERE friend_code IS NULL RETURNING`, re-select the winner.
13. **Tighten the URL contract (Codex r3#6):** the parser accepts ONLY exact `connectmerge://invite/<code>` and `https://www.connectmerge.app/invite/<code>` (reject http, extra segments, other hosts, and validate `^[A-Z2-7]{8}$`), matching the tightened `pathPrefix="/invite/"`.

### Tests & observability (Codex r1#12)
14. **Flutter unit/widget:** referrer + invite-URL parsers (exact-form + rejection); `inviteMessage`; coordinator (both orders, mid-flight, supersede, dedup, newest-live-link-replaces, transient-promotion, crash-restore, referrer-handled-suppression); scoped identity gating (guest live-link OK; guest referrer deferred; adoption); Hive survival; FB card presence/null/overflow; cold/warm app_links. **Web route/validation/encoding/well-known tests live in the owner-side web deliverable's CI, not here** (Codex r4#6).
15. **Real-device gates:** Play internal-track install proving referrer attribution end-to-end; `pm verify-app-links` for `www`.
16. **Analytics (code-free):** `firebase_analytics` events for referrer fetch, deferred-redeem attempt, redeem result (ok/self/invalid), failure reason — never logging the code.

## Key decisions & tradeoffs
- **Play Install Referrer, not Firebase Dynamic Links (dead Aug 2025) or Branch (paid).** Android-only deferred linking; iOS deferred is manual in v1.
- **One coordinator, both inputs durable, fully specified state machine** — priority, supersede, suppression, and crash recovery are explicit, not emergent.
- **Google identity required only for install-referrer redemption** — deferred referrals must not attach to a throwaway guest, but live-link taps keep working for guests.
- **Platform-aware landing page + custom-scheme Open-app** — survives in-app browsers, iOS/desktop, and unverified-link states.
- **OS share sheet, no custom recipient picker.**

## Risks / open questions
- **Web deliverable (W1–W3) is the top external dependency** — wrong host/fingerprint = App Links silently don't verify and installed Android recipients fall through to the web page. Owner must supply the inputs and pass the acceptance tests.
- **Guest/anonymous auth semantics** — confirm what "Play as guest" sets before wiring scoped identity gating (step 9).
- **Final share copy is the user's call** (factual per-difficulty wording vs the punchier draft).
- **Referrer is attacker-settable**, but `redeem_code` rejects self-add and is idempotent → blast radius is "adds one arbitrary existing code once."

## Out of scope
- **iOS deferred (post-install) auto-linking** (Associated Domains/AASA, or Branch/AppsFlyer/fingerprinting) — iOS install → manual code in v1. (Installed-iOS explicit Open-app IS supported.)
- In-app contact/SMS picker or programmatic multi-recipient send.
- Referral attribution dashboards beyond the code-free analytics events above.
- Play Store listing copy / ASO / screenshots (separate prior plan).
