# Signing and distribution

CI builds for the simulator with `CODE_SIGNING_ALLOWED=NO`. Nothing in `ci.yml` is signed. TestFlight uploads go through `.github/workflows/testflight.yml`, which skips (green) until the secrets below exist.

## One-time setup (personal developer account is fine for the beta)

1. **Devices** (Certificates, Identifiers and Profiles, Devices): register the iPhone and the Apple Watch you will test on. TestFlight and App Store distribution profiles need no devices. But `xcodebuild archive` with automatic signing first creates an Apple Development profile, and Apple will not make one for a team with no registered device. The same devices are needed for direct installs anyway. (This is the reviewer's reading and has not been run; if the archive says there is no device to generate a profile from, this is why.)
2. **App IDs** (Identifiers). Two ids, the second starting with the first:
   - iPhone: `app.stationcoach.recorder`
   - Watch: `app.stationcoach.recorder.watchkitapp`, with the **HealthKit** capability enabled (the entitlement is already in `Watch/StationCoachWatch.entitlements`). Automatic signing does not reliably add capabilities.
   - If `app.stationcoach` is taken, pick your own prefix and set it as the repo variable `BUNDLE_PREFIX` (step 6). The workflow rewrites the project in the runner; nothing is committed.
3. **App Store Connect**: My Apps, New App, iOS, bundle id = the iPhone id. The watch app needs no record of its own.
4. **API key**: Users and Access, Integrations, App Store Connect API, generate a key with role **Admin**. Cloud-managed distribution certificates need Admin; App Manager is likely not enough. Note the Key ID and the Issuer ID, and download the `.p8` once.
5. **Secrets, in an Environment** named `testflight` (Settings, Environments, New environment). Under "Deployment branches and tags" allow only `main` and the tag pattern `beta-*`, so a branch with an edited workflow cannot read them. Add as environment secrets:
   - `ASC_KEY_ID`: the Key ID
   - `ASC_ISSUER_ID`: the Issuer ID
   - `ASC_KEY_P8`: the key file, base64 on one line (`base64 -i AuthKey_XXXX.p8 | pbcopy`)
   - `APPLE_TEAM_ID`: the 10-character team id (Membership details)

   Because of the branch rule, run the workflow from `main` or push a `beta-*` tag; a run from another branch is refused.
6. Optional repo **variable** `BUNDLE_PREFIX` (not a secret), only if you changed the ids in step 2.
7. **Tester**: App Store Connect, TestFlight, Internal Testing, add a group and add the athletes (they must be users on the account with an Apple ID; external testers need a beta review).

## Shipping a build

Actions, `testflight`, Run workflow (or push a tag such as `beta-3`). The build number is the run number, the marketing version is `MARKETING_VERSION` in `project.yml`. Processing in App Store Connect takes 5 to 30 minutes, then the build appears in the TestFlight app. A missing secret is printed by name and the run ends green without uploading. Runs queue one at a time (`concurrency` on the upload job only).

## Why xcodebuild with destination upload, not fastlane or altool

The lane is `xcodegen`, `xcodebuild archive`, then `xcodebuild -exportArchive` with `destination` `upload` in the export options, which uploads straight to App Store Connect. It uses only what ships with Xcode: no Ruby or Bundler to pin, and no separate `altool` step (Apple is steering away from `altool --upload-app`). The runner selects the newest stable Xcode 26.x first (`tools/ci/select-xcode.sh`, also used by `ci.yml`), because App Store Connect now wants uploads built with the 26 SDKs. Signing is automatic: `-allowProvisioningUpdates` with the API key creates the cloud-managed certificate and profiles, so none are in the repo. Each clean runner may create a new Apple Development certificate; if Apple reports the certificate limit, revoke old ones. The key is written to a temp file with mode 600 and deleted in an `always()` step.

## Background modes and other notes

- `WKBackgroundModes` `workout-processing` and `audio` are set in `project.yml`. Confirm the audio mode is accepted for the profile.
- App Groups are not used (the watch and phone exchange files over WatchConnectivity).
- Export compliance is answered in the plists (`ITSAppUsesNonExemptEncryption` false).
- A free Personal Team (direct install, no TestFlight) signs for 7 days only. The watch needs Developer Mode on (Settings, Privacy and Security).
- Not verified without an account: the archive, export and upload steps have never run against App Store Connect.
