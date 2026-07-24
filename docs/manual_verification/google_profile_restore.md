# Google profile restore manual verification

These checks require credentials, signing infrastructure, two Android devices,
or Android restore behavior and therefore are intentionally not simulated by
the automated suite.

## Configuration prerequisite

- Enable the Supabase Google provider and manual identity linking. Configure
  the Web OAuth client ID and secret in Supabase.
- Launch Flutter with
  `--dart-define=GOOGLE_WEB_CLIENT_ID=<web OAuth client id>`. This must be the
  Web client ID, not an Android client ID.
- Register Android OAuth clients for the debug certificate, the upload-key
  certificate, and the Play App Signing certificate.

## Play-signed Google link

1. Install a Play-signed build from an internal testing track on a clean device.
2. At the first-run gate, choose **Continue with Google** and select an account
   that has never played Connect Merge.
3. Confirm name creation succeeds, the uid is unchanged from the anonymous uid,
   and a relaunch opens the tier screen without returning to the gate.
4. Repeat with a Google account that already owns a Connect Merge profile.
   Confirm the destructive warning appears before the session changes and the
   restored profile is visible only after accepting it.

## Two-device claim and supersession

1. Sign into the same Google profile on device A, make progress, background the
   app, and confirm the snapshot revision advances.
2. Sign into that profile on device B. Confirm B restores A's latest profile.
3. Resume A and make another durable change. Confirm A shows the superseded
   modal and no longer advances the server revision.
4. Choose **Reload profile** on A. Confirm it restores B's profile and becomes
   active; a later write from B must then show the same superseded modal.

## Android backup and device transfer

1. On a guest install, create local progress and ensure a Supabase session is
   present.
2. Run both cloud-backup restore and cable/device-transfer restore onto a new
   Android device.
3. Confirm neither the `connect_merge` Hive box nor the Supabase session is
   restored. The new install must show the identity gate, and Google sign-in
   must pull the cloud snapshot rather than expose the old guest bytes.

## Crash-boundary probes

1. Force-stop after Google adoption but before restore finishes. Relaunch and
   confirm the Google mismatch branch claims and restores before gameplay.
2. Force-stop during **Reload profile** promotion. Relaunch and confirm the
   incomplete owner record blocks gameplay until the restore is rerun.
3. Force-stop after sign-out/delete but before local cleanup. Relaunch and
   confirm the anonymous mismatch branch wipes account data, rebinds the new
   anonymous uid, and then shows the gate.
