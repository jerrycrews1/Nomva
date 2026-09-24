# Nomva 1.7 (48): Health weight-write recovery

Delivered to the internal TestFlight group on September 23, 2026. The app archive was built from source commit `2f325c100372f48e7906625db56bc6ae23bd732e`, pushed to GitHub `main` and `codex/nomva-health-sync-testflight`.

## Change

- If Health Weight write access has never been decided, saving a Nomva weigh-in requests it directly. The weigh-in is saved locally first.
- If Health explicitly denies the write, the app pauses Health export and explains how to restore Weight write access. Later local weigh-ins no longer produce the same alert on every save. The pending weights can be exported by enabling **Save Nomva Weigh-ins** again in Weight Sync.
- A transient Health write failure offers **Try Apple Health Again**, which now retries exporting the already saved entry. Local save failures and imported-weight editing errors have accurate alert titles.
- Two debug-only UI fixtures exercise denial and transient failure. They are absent from the Release app.

The user reported that turning Weight sync off and on in the installed build caused the Health permission request to appear and that saving then worked. Build 48 improves this recovery flow; that report is not a physical-device test of build 48.

## Evidence

| Gate | Result |
| --- | --- |
| Focused UI tests | 2 passed, 0 failed: denial pauses export and avoids a second alert; retry re-exports the saved entry. `/Users/jerrycrews/Developer/NomvaRelease48Evidence/weight-permission-ui.xcresult` |
| Core tests | 62 passed, 0 failed. `/Users/jerrycrews/Developer/NomvaRelease48Evidence/core-tests.xcresult` |
| Source | The committed app, project, tests, and CI scripts matched the build mirror byte for byte. |
| Archive | `/Users/jerrycrews/Library/Developer/Xcode/Archives/2026-09-23/Nomva 1.7-48-weight-permission.xcarchive` succeeded. App `com.nomva.app` and widget `com.nomva.app.widgets` both report 1.7 (48) with valid signatures. The app retains HealthKit entitlements and the pinned `foods.sqlite` SHA-256 `9debd65ed41eadf15f9d1d01346e5b5115d3d8525f5d08cbdf6a6f38696be9df`. |
| Upload | Xcode reported `Uploaded package is processing.`, `Upload succeeded.`, and `EXPORT SUCCEEDED` at 20:23 PDT. Export was `testFlightInternalTestingOnly=true`. `reports/release-48/upload.log` |
| Apple processing | App Store Connect build `9d4418c3-9080-47c1-9599-eb733f2ac01e` is `VALID`; upload state is `COMPLETE` with no errors or warnings. `reports/release-48/asc-status-final.txt` |
| Internal tester access | `IN_BETA_TESTING`, present in the `Testers` group, with one internal tester. `reports/release-48/asc-status-final.txt` |

Build 48 has not been installed or tested on the physical iPhone. Apple Health permissions remain under the user's control; the app cannot grant itself Weight write access.
