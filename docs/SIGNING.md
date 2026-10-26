# Signing and distribution

CI builds for the simulator with `CODE_SIGNING_ALLOWED=NO`. Nothing in `ci.yml` is signed. TestFlight uploads go through `.github/workflows/testflight.yml`, which skips (green) until the secrets below exist.

## One-time setup (personal developer account is fine for the beta)

1. **App IDs** (developer portal, Identifiers). Two ids, the second starting with the first:
   - iPhone: `app.stationcoach.recorder`
   - Watch: `app.stationcoach.recorder.watchkitapp`, with the **HealthKit** capability enabled (the entitlement is already in `Watch/StationCoachWatch.entitlements`).
   - If `app.stationcoach` is taken, pick your own prefix and set it as the repo variable `BUNDLE_PREFIX` (step 5). The workflow rewrites the project in the runner; nothing is committed.
2. **App Store Connect**: My Apps, New App, iOS, bundle id = the iPhone id. The watch app needs no record of its own.
3. **API key**: Users and Access, Integrations, App Store Connect API, generate a key with role **App Manager**. Note the Key ID and the Issuer ID, and download the `.p8` once.
4. **Repo secrets** (Settings, Secrets and variables, Actions):
   - `ASC_KEY_ID`: the Key ID
   - `ASC_ISSUER_ID`: the Issuer ID
   - `ASC_KEY_P8`: the key file, base64 on one line (`base64 -i AuthKey_XXXX.p8 | pbcopy`)
   - `APPLE_TEAM_ID`: the 10-character team id (Membership details)
5. Optional repo **variable** `BUNDLE_PREFIX` (not a secret), only if you changed the ids in step 1.
6. **Tester**: App Store Connect, TestFlight, Internal Testing, add a group and add the athletes (they must be users on the account with an Apple ID; external testers need a beta review).

## Shipping a build

Actions, `testflight`, Run workflow (or push a tag such as `beta-3`). The build number is the run number, the marketing version is `MARKETING_VERSION` in `project.yml`. Processing in App Store Connect takes 5 to 30 minutes, then the build appears in the TestFlight app. A missing secret is printed by name and the run ends green without uploading.

## Why xcodebuild and altool, not fastlane

The lane is `xcodegen`, `xcodebuild archive`, `xcodebuild -exportArchive`, `xcrun altool --upload-app`. All ship with Xcode on the runner, so there is no Ruby or Bundler to pin. Signing is automatic: `-allowProvisioningUpdates` with the API key lets Xcode create the cloud-managed distribution certificate and profiles, so there are no certificates or profiles in the repo. If the archive fails with a permissions error on certificates, give the key the Admin role. The key is written to a temp file with mode 600 and deleted in an `always()` step.

## Background modes and other notes

- `WKBackgroundModes` `workout-processing` and `audio` are set in `project.yml`. Confirm the audio mode is accepted for the profile.
- App Groups are not used (the watch and phone exchange files over WatchConnectivity).
- Export compliance is answered in the plists (`ITSAppUsesNonExemptEncryption` false).
- A free Personal Team (direct install, no TestFlight) signs for 7 days only. The watch needs Developer Mode on (Settings, Privacy and Security).
- Not verified without an account: the archive, export and altool steps have never run against App Store Connect.
