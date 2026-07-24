# Plan Review Log: App Sharing → Referral Auto-Link Feature
Act 1 (grill) complete — plan locked with the user. MAX_ROUNDS=5.

## Grill decisions captured
- Platform scope: Android auto-link (Play Install Referrer); iOS graceful fallback (auto-link only if installed, else manual code).
- Recipient selection: OS share sheet with pre-filled message; no custom picker.
- Facebook: reuse PNG score-card share, bake link/code onto the card; text channels get the generated message.
- Link hosting: connectmerge.app on Vercel (assetlinks.json already hosted); Vercel redirects not-installed browsers to Play Store with `&referrer=code%3D<code>`.
- Message copy: name + reworded hook ("Everyone plays the same puzzle, one attempt every day — can you get the highest score?"), no score.

## Round 1 — Codex
Material flaws found; no files modified.

1. Host likely cannot verify: apex `connectmerge.app` 308-redirects to `www`; assetlinks.json must be served from the exact host without redirects. Fix: serve both well-known files from one canonical non-redirecting host; use that exact host in links/manifest/entitlements.
2. iOS installed-app behavior not implemented: no Associated Domains entitlement / AASA. Fix: add `applinks:<host>`, wire `CODE_SIGN_ENTITLEMENTS`, serve AASA (TeamID, bundle id, `/invite/*`).
3. app_links incompletely configured: Flutter 3.24+ needs the default deep-link handler disabled. Fix: `flutter_deeplinking_enabled=false` (Android) + `FlutterDeepLinkingEnabled=false` (iOS), test cold+warm.
4. Referrals can attach to disposable anonymous account: anon startup satisfies auth.uid(); guest mode replays before Google identity. Fix: gate redemption on Google identity, retain through guest/adoption.
5. Consumed-boolean loses referrals on transient auth/Play/network failure (Play retains referrer 90 days). Fix: persist pending code; mark consumed only on terminal ok/self/invalid_code.
6. Hive one-shot state deleted during account adoption/wipe (only `_installKeys` survive). Fix: add referral keys to `_installKeys`; test survival across restore/adoption/wipe.
7. "Live link wins" has no implementable race policy: single overwritable pending slot + async referrer. Fix: serialize both sources through one coordinator with explicit live-link priority + order tests.
8. Friend codes not safe URL segments: `friend_code` unconstrained text; parser accepts any host/segment. Fix: `^[A-Z2-7]{8}$` DB constraint (preflight), build with `Uri`, validate host/code at web+client+RPC.
9. Concurrent friend-code allocation can return a stale code. Fix: `UPDATE ... WHERE friend_code IS NULL RETURNING`, re-select winner.
10. Web routing requirements contradict: unconditional Play 302 can't also give iOS/desktop fallback, and installed users still hit the site via in-app browsers/unverified links. Fix: serve a platform-neutral landing page (Play, App Store, open-app, manual-code).
11. Facebook referral content best-effort: friend-code loads null silently; render-failure text fallback has neither code nor link. Fix: ensure/retry code at share time, include invite in text fallback, test overflow.
12. Test/observability plan misses failure seams: pure parser tests can't prove attribution/verification/auth-gating/retries/routing; no analytics. Fix: coordinator/auth/restart tests, web route tests, Play internal-track + TestFlight verification, code-free referral analytics.

VERDICT: REVISE

### Claude's response
Accepted 1–8 and 10–12 as material and repo-grounded. Revised PLAN.md:
- **Host (1):** added a canonical non-redirecting host as a hard prerequisite; assetlinks + links + manifest must all use the exact same host.
- **iOS (2):** made the iOS claim honest — installed-iOS deep-link requires Associated Domains + AASA; listed as an explicit step, and if not shipped, iOS is manual-code-only (matches the Q1 "graceful fallback" scope).
- **app_links (3):** added the `flutter_deeplinking_enabled=false` / `FlutterDeepLinkingEnabled=false` config + cold/warm tests.
- **Auth identity (4):** gate redemption on a real Google identity, not bare `auth.uid()`; retain the pending code through guest→adoption.
- **Retryable (5):** persist pending code, mark consumed only on terminal redeem result; rely on Play's 90-day retention for retries.
- **Hive survival (6):** referral keys join `_installKeys`; survival tested across restore/adoption/wipe.
- **Race coordinator (7):** one coordinator serializes deep-link + referrer with explicit live-link priority + both-order tests.
- **URL safety (8):** validate `^[A-Z2-7]{8}$` and exact host at parse + build with `Uri`; DB CHECK after preflight.
- **Web landing (10):** replaced the unconditional 302 with a platform-aware landing page (Play/App Store/open-app/manual-code) — also fixes the in-app-browser case.
- **FB content (11):** ensure/retry code at share time, invite included in the text fallback, overflow tested.
- **Observability (12):** added coordinator/auth/restart/web-route tests, real-device Play-internal-track + TestFlight verification, and code-free analytics (fetch/defer/redeem-result/failure-reason).
- **Allocation race (9):** accepted as a small pre-existing hardening (this feature makes codes load-bearing), folded into the code-safety step rather than treated as new scope.

## Round 2 — Codex
Most prior findings addressed; remaining gaps:
1. Wrong iOS bundle id: plan used `com.kidd.connect_merge`; actual is `com.kiddulu.connectMerge` (project.pbxproj:385).
2. Host + iOS scope still placeholders/conditional — commit to exact host, fingerprints, iOS scope now.
3. Web work has no implementation location — name the owner-side repo/path + acceptance command.
4. Coordinator semantics still ambiguous — persist BOTH inputs, define pending→inFlight→terminal window; a live link can still vanish during guest onboarding.
5. DB preflight assumed, not planned — dirty `friend_code` row aborts migration; fixtures use invalid `MYCODE12`. Add repair-or-abort + fix fixtures.
6. Share copy factually wrong — gameplay is one run PER DIFFICULTY each day; "we're friends automatically" false for iOS deferred + permanent guests.
7. Landing "Open app" via https just reloads the page — use `connectmerge://invite/<code>`.

VERDICT: REVISE

### Claude's response
Verified 1/5/6 against the code and accepted all seven:
- **iOS id (1):** corrected to `com.kiddulu.connectMerge`.
- **Placeholders (2):** resolved host = `www.connectmerge.app` (repo confirms apex 308→www, delete-account/index.ts:34); iOS scope committed to manual-code-only for v1 (AASA deferred to Out of scope). No conditionals left.
- **Web location (3):** named the owner-side `www.connectmerge.app` Vercel project (separate repo) as P2, with curl acceptance checks and the full route spec.
- **Coordinator (4):** rewrote step 8 — both inputs persisted as `{code,source}`, explicit `pending→inFlight→terminal` state machine, live-link-wins only before inFlight, mid-flight queueing; tests for both orders + mid-flight.
- **DB preflight (5):** added an explicit pre-migration `!~` count with repair-or-abort, and the `MYCODE12` fixture fix.
- **Copy (6):** redrafted to "one run per difficulty a day" and platform-neutral "add me"; flagged final wording as the user's sign-off call.
- **Open app (7):** landing button now targets `connectmerge://invite/<code>`.

## Round 3 — Codex
Round-2 fixes accepted; new coordinator/gating edges:
1. Google gating is incorrectly global — regresses live links for installed guests; only install-referrer needs durable Google identity.
2. A successful referrer can discard a queued live-link tap — always process a queued live link; suppress only lower-priority queued referrers after live-link success.
3. Superseded referrers return next launch — replacing a pending referrer with a live link never reaches terminal, so Play's retained referrer re-fires. Add a `superseded` terminal transition.
4. Crash recovery from `inFlight` undefined — keep the durable record until terminal; restore interrupted `inFlight` as `pending` (RPC idempotent).
5. "iOS manual-only" contradicts the all-platform Open-app button — iOS already registers `connectmerge://`; installed iOS redeems via that tap. Reword: only deferred install is manual on iOS.
6. URL contract too broad — parser accepts http/extra segments/arbitrary hosts; `pathPrefix="/invite"` catches `/inviteevil`. Accept only exact forms; use `pathPrefix="/invite/"`.
7. Web prerequisite still not actionable — name the Vercel repo/owner/test command/fingerprints or split into a separately owned blocking deliverable with content acceptance.

VERDICT: REVISE

### Claude's response
Verified 5/6 against the code (iOS CFBundleURLTypes registers the scheme; pathPrefix breadth). Accepted all seven:
- **Scoped gating (1):** Google identity now required only for `source == installReferrer`; live links keep existing guest-inclusive post-onboarding flow.
- **Suppression direction (2):** coordinator always runs a queued live link; suppresses a queued referrer only after a live-link success.
- **Superseded (3):** added a `superseded` terminal transition that consumes/clears the deferred referrer so Play's retained data can't resurrect it.
- **Crash recovery (4):** durable record persists to terminal; startup restores `inFlight → pending` and retries (idempotent).
- **iOS wording (5):** reframed — installed iOS redeems via the explicit Open-app/custom-scheme tap; only deferred (post-install) linking is manual on iOS. Fixed goal + out-of-scope.
- **URL contract (6):** parser accepts only exact `connectmerge://invite/<code>` and `https://www.connectmerge.app/invite/<code>`; manifest `pathPrefix="/invite/"`.
- **Web deliverable (7):** restructured as a separately owned blocking deliverable with named owner-supplied inputs (W1 repo/owner, W2 fingerprints, W3 iOS-listing) and content-level curl/adb acceptance tests. The specific values are legitimately owner-supplied — named, not hand-waved.

## Round 4 — Codex
Round-3 findings addressed; persistence/verification precision:
1. Durable schema can't represent the queue — one `{code,source,state}` record can't hold in-flight + queued. Persist an atomic `{active, queued?}` envelope before any RPC.
2. Terminal install referrers resurrect — clearing the queue doesn't stop Play returning the referrer for ~90 days. Add install-scoped `install_referrer_handled`, checked before read/enqueue, set on every terminal referrer outcome.
3. Transient failure violates live-link priority — a failed in-flight referrer becomes pending again while a higher-priority live link waits. Discard/handle the referrer and promote the live link.
4. Equal-priority arrivals undefined — dedup identical codes; newest distinct queued live link replaces the older.
5. `curl -s` no-redirect acceptance doesn't inspect status. Assert 200, empty redirect_url, content type, body.
6. Web tests assigned to the Flutter suite despite living in another repo. Move to the web deliverable's CI.

VERDICT: REVISE

### Claude's response
Accepted all six (pure persistence/test-ownership precision, no new architecture):
- **Envelope (1):** durable record is now `{active:{code,source}, queued?:{code,source}}`, persisted before any RPC.
- **Handled flag (2):** added install-scoped `install_referrer_handled` — checked before read/enqueue (step 7), set on every terminal referrer outcome, never on transient. Reconciles r1#5 retryability with no-resurrection.
- **Priority on transient (3):** transient referrer failure with a queued live link now discards/handles the referrer and atomically promotes the live link.
- **Dedup (4):** identical code = no-op; newest distinct queued live link replaces the older.
- **Acceptance (5):** curl commands now assert `%{http_code}` + empty `%{redirect_url}` + content type + body.
- **Test ownership (6):** web route/validation/encoding/well-known tests moved to the web deliverable's CI; Flutter suite keeps client tests. `install_referrer_handled` also added to `_installKeys` (step 10) so it survives wipe.

## Round 5 — Codex (MAX_ROUNDS)
Round-4 #1/#4/#6 fully addressed; remaining precision:
1. Handled-state not crash-atomic — envelope + `install_referrer_handled` are separate keys; a crash between clearing/promotion and flagging can resurrect/discard. Persist `{handled, active?, queued?}` as one snapshot per transition.
2. assetlinks acceptance discards evidence (`-o /dev/null`) — pipe through `jq -e`, assert package, relation, every fingerprint.
3. Transient retry scheduling undefined — no trigger/backoff. Retry serially on identity readiness/foreground/connectivity with bounded exponential backoff.
4. Share-time code retrieval not implementable — ScoreShareScreen gets a nullable code and rasterizes immediately. Inject an async loader, await on share, rebuild + await frame before capture, reuse in fallback.
5. Empty/malformed referrers never terminal — refetched/logged every launch. Mark successful-but-codeless fetches handled; retry only fetch/service failures.

VERDICT: REVISE

### Claude's response
Accepted all five (verified #4 against score_share_screen.dart:38 + tier_select_screen.dart:222):
- **Atomic snapshot (1):** merged into a single serialized `{handled, active?, queued?}` value rewritten whole on every transition; crash-boundary tests added.
- **Acceptance (2):** replaced with `jq -e` assertions on package `com.kidd.connect_merge`, relation `delegate_permission/common.handle_all_urls`, every W2 fingerprint, and a header check for `200` / no `Location`.
- **Retry schedule (3):** serial retries on identity-ready/foreground/connectivity with bounded exponential backoff.
- **Share loader (4):** inject `ensureFriendCode`, await on share, rebuild + await rendered frame before capture, reuse in card + text fallback.
- **Codeless-fetch terminal (5):** a successful fetch is terminal regardless of payload (sets `handled`); only fetch/service failure retries.

## Resolution — MAX_ROUNDS (5) reached
Not a deadlock: **every** Codex finding across all five rounds was accepted (a few reframed), and **zero open disagreements** remain. The loop hit the cap because the plan is exhaustively detailed — each round Codex found a finer edge (architecture → coordinator logic → persistence atomicity → verification-command rigor), not a flaw in direction. The round-5 fixes are folded into PLAN.md. Substantively converged; handed to the user for final sign-off.
