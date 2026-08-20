# iOS setup, build, and App Store submission — fresh macOS clone

Everything needed to take a fresh `git clone` of this repo on a clean macOS
machine to a TestFlight/App Store build. Written against the state of the repo
as of this doc's commit — re-check the "Known gaps" section against current
`main` before you rely on it, since several of these are open items.

Reference facts pulled from the repo (don't re-derive, just use these):

| Thing | Value |
|---|---|
| iOS bundle ID | `com.kiddulu.connectMerge` (Xcode target `Runner`) |
| Android bundle ID (for contrast — different on purpose) | `com.kidd.connect_merge` |
| Firebase project | `connect-merge-1` |
| Firebase iOS app ID | `1:306868850236:ios:cc3f01eeb536f880d2fd39` |
| Supabase project | `nnoqqchqprfikhabrrjt` (`https://nnoqqchqprfikhabrrjt.supabase.co`) |
| iOS deployment target | 13.0 |
| Flutter version pinned in CI | 3.44.2 (`.github/workflows/test.yml`) |
| Dart SDK constraint | `>=3.4.0 <4.0.0` |
| App version (pubspec) | `1.2.1+8` → `CFBundleShortVersionString`/`CFBundleVersion` come from this |

---

## 1. Install prerequisites (macOS)

1. **Xcode** — install the latest stable release from the Mac App Store, then
   accept the license and install additional components:
   ```bash
   sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
   sudo xcodebuild -runFirstLaunch
   xcodebuild -version
   ```
   Apple periodically raises the minimum SDK a new/updated App Store
   submission must be built with (check
   [developer.apple.com/news](https://developer.apple.com/news/) if a
   `flutter build ipa` or archive upload gets rejected for "SDK too old") —
   always use the newest Xcode you can before archiving for release.
2. **CocoaPods**:
   ```bash
   sudo gem install cocoapods
   pod --version
   ```
3. **Flutter SDK** — install via FVM, `flutter version`, or a manual clone;
   pin to the version CI uses so `flutter test`/golden vectors behave
   identically:
   ```bash
   flutter --version   # confirm 3.44.2 (or update .github/workflows/test.yml if intentionally bumping)
   flutter doctor -v   # resolve every ✗, especially the Xcode/CocoaPods rows
   ```
4. **Deno** (only needed to run the Edge Function test suite, not for the iOS
   build itself):
   ```bash
   curl -fsSL https://deno.land/install.sh | sh
   ```
5. **Apple Developer Program membership** ($99/yr) on the account that will
   own the `com.kiddulu.connectMerge` bundle ID / App Store Connect record.
6. **Access you'll need before you can build a real (non-offline) app**:
   - Firebase console access to project `connect-merge-1` (to pull
     `GoogleService-Info.plist` — see §3).
   - Supabase dashboard access to project `nnoqqchqprfikhabrrjt` (to pull the
     anon key).
   - AdMob console access to app `ca-app-pub-4807961095325796` (to pull real
     iOS ad unit IDs — see §5, this is currently an open gap).

## 2. Clone and install Dart/Flutter dependencies

```bash
git clone <repo-url> connect_merge
cd connect_merge
flutter pub get
```

CocoaPods integration is driven by Flutter's own tooling, not a committed
`Podfile` (there isn't one checked in yet — it's generated on first iOS
build/pod install). The first of these will create `ios/Podfile` and run
`pod install` for you:

```bash
open ios/Runner.xcworkspace   # generates Podfile + Pods/ via Xcode's build, or
flutter build ios --no-codesign --debug   # generates it headlessly
```

If `pod install` ever needs to be re-run by hand later:

```bash
cd ios && pod install --repo-update && cd ..
```

## 3. Firebase config file (missing from the repo — you must add it)

`lib/firebase_options.dart` already hardcodes the iOS `FirebaseOptions`
(FlutterFire-CLI-generated, keyed to `iosBundleId: com.kiddulu.connectMerge`),
which is enough for `Firebase.initializeApp()` to succeed. But no
`GoogleService-Info.plist` is committed under `ios/Runner/` (only
`android/app/google-services.json` exists for Android), and some native
Firebase behavior (Crashlytics dSYM processing, some Analytics defaults)
expects the plist to be physically present in the app bundle. Add it:

1. Firebase console → project **connect-merge-1** → gear icon → **Project
   settings** → **Your apps** → the iOS app (`com.kiddulu.connectMerge`) →
   download `GoogleService-Info.plist`.
2. Drag it into `ios/Runner/` in Xcode (target membership: **Runner**), or
   just place the file at `ios/Runner/GoogleService-Info.plist` — it's
   already covered by `flutter_launcher_icons`/normal resource bundling once
   it's a member of the Runner target.
3. `flutter clean && flutter pub get` and rebuild.

## 4. Environment variables (`--dart-define`)

The app reads Supabase/Google config via `String.fromEnvironment`, not `.env`
files bundled at runtime — everything is baked in at **build time** via
`--dart-define`. Copy the template and fill it in:

```bash
cp .env.example .env      # already gitignored, safe to edit
```

`.env` fields:

| Key | Required for | Where to find it |
|---|---|---|
| `SUPABASE_URL` | leaderboards, friends, auth, duels | Supabase dashboard → project `nnoqqchqprfikhabrrjt` → Settings → API → Project URL |
| `SUPABASE_ANON_KEY` | same as above | same page → "anon" / "publishable" key |
| `GOOGLE_WEB_CLIENT_ID` | Google Sign-In | Google Cloud console → APIs & Services → Credentials → the **Web** OAuth client (not the iOS/Android one) — see `docs/manual_verification/google_signin_setup.md` for the full provisioning walkthrough. A working default is baked into `auth_service.dart`, but override it explicitly for any build you intend to actually ship. |

Every `flutter run`/`flutter build` command below should append:

```bash
--dart-define-from-file=.env
```

Omitting all three defines is fine for local iteration — the app degrades to
fully offline play (no leaderboards/auth) rather than crashing — but you want
the real values for anything you intend to submit.

## 5. Known gaps to close before a *real* release build

These are things the repo currently ships as placeholders/incomplete. None
block `flutter run` in debug, but each will bite you before App Store
submission:

- **iOS AdMob unit IDs are unset.** `lib/infrastructure/ad_config.dart`
  hardcodes `_testBannerIos`, `_testRewardedIos`, `_realBannerIos`, and
  `_realRewardedIos` all to the literal string `'null'` — ads will not load
  on iOS in either test or release mode until you fill these in with real
  unit IDs from the AdMob console (app `ca-app-pub-4807961095325796`, same
  project as Android — you just need iOS-specific ad units created for it).
  The `GADApplicationIdentifier` in `ios/Runner/Info.plist`
  (`ca-app-pub-4807961095325796~2255720130`) should also be double-checked
  against the AdMob console's iOS app entry — verify it isn't accidentally
  the Android app ID.
- **No App Tracking Transparency (ATT) prompt configured.** `Info.plist` has
  no `NSUserTrackingUsageDescription` key. `google_mobile_ads` will still
  serve non-personalized ads without it, but Apple requires the key (and the
  ATT system prompt) if you want personalized/attributed ads, and its absence
  is a common App Store rejection trigger once ads are live. Add:
  ```xml
  <key>NSUserTrackingUsageDescription</key>
  <string>This identifier is used to deliver more relevant ads.</string>
  ```
  and call the `app_tracking_transparency` plugin's request-permission API
  before first ad load if you want personalized ads (not currently a
  dependency in `pubspec.yaml` — add it if you go this route).
- **No `PrivacyInfo.xcprivacy` manifest checked in for the Runner target.**
  Apple requires privacy manifests for apps bundling SDKs on its "commonly
  used" list (Firebase, Google Mobile Ads are on it). Most of those pods now
  ship their own manifest, but Xcode will flag any gap at archive time —
  build an archive early (§7) and read Xcode's Privacy Report /
  App Store Connect's upload warnings rather than guessing.
- **`assets/images/` is referenced by `pubspec.yaml`
  (`flutter_launcher_icons`'s `image_path`, and the `flutter: assets:` list)
  but does not appear to be tracked in git in this snapshot.** Run
  `git status` / check GitHub for the actual current state before building —
  if it's genuinely missing, `flutter build` will fail with a missing-asset
  error and you'll need to source `assets/images/icon.png` (and whatever else
  belongs there) before proceeding.
- **No Associated Domains / universal links entitlement.** The
  `connectmerge://` custom-scheme deep link (invites, duels) works today; the
  `https://www.connectmerge.app/...` universal-link variant needs an
  Associated Domains entitlement + a hosted `apple-app-site-association` file
  (noted as an open item directly in `Info.plist`'s comments) — not required
  to ship, but worth flagging if invite links matter for launch.
- **Sign in with Apple** is not implemented — only Google Sign-In (optional,
  guest play is the default path). Apple's Guideline 4.8 requires an
  equivalent privacy-preserving sign-in option when you offer third-party
  social login *and* an account is otherwise required to use the app. Since
  the app is fully playable as a guest, this likely doesn't apply — but
  confirm this reasoning still holds before submitting, since reviewers do
  check it.

## 6. Build & test commands

Run these from the repo root.

**Dart/Flutter test suite** (platform-independent, run before any build):
```bash
flutter test
flutter test test/domain/engine/golden_vectors_test.dart   # asserts client/server engine parity
flutter analyze
```

**Edge Function tests** (only relevant if you're also touching
`supabase/functions/`, not required for an iOS-only build):
```bash
deno test supabase/functions/_shared/engine.test.ts
deno test --frozen supabase/functions/
```

**Run on a simulator or connected device** (debug, hot-reload capable):
```bash
open -a Simulator                     # or: xcrun simctl boot "iPhone 16"
flutter devices                       # confirm the simulator/device is listed
flutter run -d <device-id> --dart-define-from-file=.env
```

**Debug build without launching** (useful to sanity-check pod integration
after adding `GoogleService-Info.plist` or bumping a dependency):
```bash
flutter build ios --debug --no-codesign --dart-define-from-file=.env
```

**Release build for App Store distribution** — produces a signed `.ipa`
ready for upload:
```bash
flutter build ipa --release --dart-define-from-file=.env
```
This requires:
- A valid signing identity/provisioning profile. With
  `CODE_SIGN_STYLE = Automatic` (already set in the Xcode project), the
  simplest path is opening `ios/Runner.xcworkspace` in Xcode once, selecting
  the **Runner** target → **Signing & Capabilities**, and picking your Team —
  Xcode will provision automatically from there, and subsequent
  `flutter build ipa` runs pick up the same team.
- Bump `version:` in `pubspec.yaml` (`1.2.1+8` → e.g. `1.2.2+9`) before any
  build you intend to actually upload — App Store Connect rejects a build
  number it's already seen for this bundle ID.

The resulting archive is written to `build/ios/archive/Runner.xcarchive` and
the exported `.ipa` to `build/ios/ipa/`.

## 7. Uploading to App Store Connect / TestFlight

Two equivalent paths — pick whichever you're more comfortable with:

**Path A — Xcode Organizer (recommended for a first submission, gives you
inline validation errors):**
```bash
open ios/Runner.xcworkspace
```
Xcode menu → **Product → Archive** (uses the Release scheme automatically).
When it finishes, the **Organizer** window opens → select the archive →
**Distribute App** → **App Store Connect** → **Upload** → follow the signing
prompts (automatic signing handles this if you picked your Team in §6).

**Path B — CLI, after `flutter build ipa`:**
```bash
xcrun altool --upload-app -f build/ios/ipa/connect_merge.ipa \
  -t ios -u <apple-id-email> -p <app-specific-password>
```
(Generate an app-specific password at appleid.apple.com if you use this
path — do not use your real Apple ID password.) `xcrun altool` is
deprecated in favor of the Transporter app; if `altool` stops working, use
the **Transporter** app from the Mac App Store and drag the `.ipa` in
instead.

**Before you can upload at all**, create the App Store Connect record once:
1. [appstoreconnect.apple.com](https://appstoreconnect.apple.com) → **My
   Apps** → **+** → **New App**.
2. Platform: iOS. Bundle ID: pick `com.kiddulu.connectMerge` (must already
   exist under your account at developer.apple.com/account — Xcode's
   automatic signing usually registers it the first time you build/archive
   with a Team selected).
3. Fill in Name, primary language, SKU (any unique string, e.g.
   `connectmerge-ios`).

Then, per release:
1. Upload the build (Path A or B above). It takes several minutes to finish
   processing in App Store Connect before it's selectable.
2. App Store Connect → your app → **TestFlight** tab → the build appears
   once processed → answer the **Export Compliance** questionnaire (this app
   uses no proprietary encryption beyond standard HTTPS/TLS, so the standard
   "uses only exempt encryption" answer applies — confirm against Apple's
   current wording at submission time) → add internal/external testers.
3. Once you're happy after TestFlight testing: App Store Connect → **App
   Store** tab → **+ Version** → fill in what's new, screenshots (see §8's
   testing checklist for what to capture), description, keywords, support
   URL, privacy policy URL, age rating, App Privacy "nutrition label"
   (declare data collected — this app collects analytics, crash data, and,
   if the player links Google, account identifiers; contacts are hashed
   on-device and never leave the device — see the `NSContactsUsageDescription`
   string in `Info.plist` for the exact framing to reuse) → select your
   uploaded build → **Submit for Review**.

## 8. Manual testing checklist (do this before every submission)

Run through this on a real device where possible (simulator is fine for most
of it, but notifications, ATT, and StoreKit-adjacent ad behavior are more
trustworthy on hardware).

**Core gameplay**
- [ ] Fresh install → daily board loads for today's UTC date, correct grid
      size/starting fill for each difficulty tier (Easy/Medium/Hard/
      Legendary/Challenge).
- [ ] Drag a chain of 2+ tiles (including a diagonal-only chain) → it merges
      per the ascend-or-stay rule; malformed chains (descend, skip a tier)
      are rejected.
- [ ] Move counter decrements; board backfills after every collapse.
- [ ] Run ends correctly on move exhaustion and on deadlock (a wall-forced
      deadlock if you can trigger one on Legendary/Challenge).
- [ ] Score, near-miss message, and the emoji share-grid all render
      correctly at run end; **Share** opens the native iOS share sheet
      (`share_plus`) with the expected text.
- [ ] Undo and hint consume their daily free allotment, then correctly offer
      a rewarded-ad top-up.

**Accounts / sync**
- [ ] Guest path: gate → "Play as guest" → `Player######` name assigned, no
      display-name prompt.
- [ ] Google sign-in: link flow, collision flow (existing profile on that
      Google account), and restore-on-second-device flow all behave per
      `docs/manual_verification/google_signin_setup.md`'s matrix — the iOS
      client needs its own OAuth client registered in the same Firebase
      project/Google Cloud console (a *separate* client ID from Android's,
      referenced automatically via the Google Sign-In iOS SDK using the
      reversed-client-ID URL scheme from `GoogleService-Info.plist` — verify
      `CFBundleURLTypes` picks this up once the plist is added, since it's
      not currently in the committed `Info.plist`).
- [ ] Offline (Airplane Mode): app still launches and plays a full local run;
      Supabase-backed features (leaderboards, friends) degrade gracefully
      without crashing.

**Leaderboards / duels / social**
- [ ] Submitted score appears on the daily/weekly/monthly leaderboard for the
      correct difficulty + season.
- [ ] Duel deep link (`connectmerge://duel/...`) opens the app to the right
      screen from cold start, from background, and from a Safari-tapped link.
- [ ] Invite deep link (`connectmerge://invite/<code>`) same three states.
- [ ] Friend add via code / contacts-hash matching (contacts permission
      prompt shows the exact `NSContactsUsageDescription` copy; denying it
      still allows adding friends by code).

**Notifications**
- [ ] Local daily-reminder notification permission is requested lazily
      (after first run completion), not at cold launch.
- [ ] Denying the permission doesn't break anything else; granting it and
      backgrounding the app around the scheduled time delivers the
      notification, tapping it opens the app.

**Ads**
- [ ] Rewarded video loads and grants the reward (moves/hints/undos/coins) on
      completion, and is a no-op (no crash, no reward) if dismissed early.
- [ ] Banner (if/where shown) renders without layout shift or overlap on both
      a small phone (SE-class) and a large one, portrait and landscape.
- [ ] If ATT is wired up (§5), the permission prompt copy matches
      `NSUserTrackingUsageDescription` and both Allow/Ask-not-to-track paths
      leave ads functional (non-personalized on decline).

**Platform basics**
- [ ] Portrait and both landscape orientations work on iPhone; iPad also
      allows portrait-upside-down (per `UISupportedInterfaceOrientations~ipad`
      in `Info.plist`) — check nothing looks stretched/clipped on iPad sizes.
- [ ] Light/dark system appearance both look correct.
- [ ] Cold launch, background/foreground, and force-quit/relaunch all restore
      state (in-progress run, coins, settings) correctly via Hive.
- [ ] VoiceOver: primary flows (tier select, board interaction, share) are at
      least not broken/unusable — App Review does spot-check accessibility.
- [ ] Crash reporting: force a test exception in a debug build and confirm it
      appears in Firebase Crashlytics for project `connect-merge-1` (symbolicated
      only if you've also configured the Crashlytics dSYM upload build
      phase — not currently present in the Xcode project; optional but
      recommended so crash reports are readable).

## 9. Common first-submission rejection reasons for this app

- **Guideline 5.1.1 (Data collection / privacy)** — make sure the App
  Privacy nutrition label in App Store Connect matches what's actually
  collected (Crashlytics, Analytics, Supabase auth identifiers, hashed
  contacts). Mismatches between the label and actual behavior are a top
  rejection cause.
- **Guideline 2.1 (App Completeness)** — a build shipped with the `'null'`
  iOS ad unit IDs (§5) will show broken/absent ads in review; fix that
  before submitting if ads are meant to be live.
- **Guideline 4.8 (Login Services)** — revisit if guest play ever becomes
  gated behind an account.
- **Missing/incorrect privacy manifest** — App Store Connect will reject the
  binary outright (not just flag it) if a bundled SDK requires a
  `PrivacyInfo.xcprivacy` entry that's missing; this shows up at upload time,
  not in review, so you'll catch it before wasting a review cycle.
