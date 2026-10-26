# Signing and distribution (not set up yet)

CI builds for the simulator with `CODE_SIGNING_ALLOWED=NO`. Nothing here is signed. A device install (Ray's phone and watch) needs the Apple developer account, which is still being set up (personal account for the beta, transfer to a company later).

When it exists, provide:

- **Team ID** (10 characters): add `DEVELOPMENT_TEAM` to `settings.base` in `project.yml`, and set `CODE_SIGN_STYLE: Automatic` for a first device build.
- **Bundle ids** (change `bundleIdPrefix` and both `PRODUCT_BUNDLE_IDENTIFIER`s together if the placeholders are taken):
  - iPhone app: `app.stationcoach.recorder`
  - Watch app: `app.stationcoach.recorder.watchkitapp` (must start with the iPhone id)
  - `WKCompanionAppBundleIdentifier` in the watch Info.plist must equal the iPhone id.
- **HealthKit capability** on the watch app id (entitlement `com.apple.developer.healthkit` is already in `Watch/StationCoachWatch.entitlements`). Enable HealthKit for that App ID in the developer portal.
- **Background modes** on the watch app (set in `project.yml` as `WKBackgroundModes`): `workout-processing` and `audio`. Confirm the audio mode is accepted for the profile.
- **App Groups**: not used in M1 (the watch and phone exchange files over WatchConnectivity only).
- **TestFlight**: an App Store Connect app record for the iPhone id, then archive the `StationCoach` scheme; the watch app is embedded. Add Ray and the two other athletes as internal or external testers.
- A **device with Developer Mode** enabled on the watch (Settings, Privacy and Security) for direct installs.
