# Nomva 1.7 (47): internal TestFlight delivery

Delivered September 23, 2026. Source commit `d22859d3eed5bac57ec431cc2c327d02eda50f18` is on GitHub `main` and `codex/nomva-health-sync-testflight`.

## Public site and database notice

- The existing `food-db-9debd65e` GitHub release now states the Open Food Facts attribution and ODbL/DbCL database license. Its downloadable `foods.sqlite.gz` expands to the app's exact database SHA-256, `9debd65ed41eadf15f9d1d01346e5b5115d3d8525f5d08cbdf6a6f38696be9df`.
- The live `index.html`, `privacy.html`, `support.html`, and `data-sources.html` were deployed to `https://nomva.nerdquad.com` and matched the edited source hashes. The revised data-sources page also identifies the 1.7 (47) TestFlight candidate. `/health` reported 804,289 available catalog rows.
- This repository has no GitHub Pages site configured. The public pages are served by the Nomva production server; GitHub hosts the repository and database-release download.

## Build and Apple gates

| Gate | Verified result |
| --- | --- |
| Source | Committed source copied to a local build mirror; app, project, tests, and CI scripts compared byte for byte. |
| Automated checks | 192 server tests, 63 iOS core tests, and the targeted weight-screen UI test passed before archive. The app also passed a simulator build. |
| Archive | `Nomva 1.7-47-legal.xcarchive` succeeded. App `com.nomva.app` and widget `com.nomva.app.widgets` both report 1.7 (47), have valid signatures, and bundle the pinned database hash. |
| Upload | Xcode reported `Uploaded package is processing.`, `Upload succeeded.`, and `EXPORT SUCCEEDED` at 18:26 PDT. Export specified `testFlightInternalTestingOnly=true`. |
| Apple processing | App Store Connect build upload `081231b6-bf3b-4da6-8911-fd0106a54128` is `COMPLETE` with no errors or warnings; the build resource is `VALID` and `INTERNAL_ONLY`. |
| Tester availability | Build beta detail reports `IN_BETA_TESTING`; the internal `Testers` group includes build 47 and has one tester. |

The first upload attempts are preserved in the local evidence. A 1.6 (47) upload was rejected because the approved 1.6 prerelease train was closed. A later 1.7 (47) export reached the signing step and waited on the dedicated distribution keychain; refreshing its existing signing-tool access allowed the same 1.7 archive to upload successfully. No app code was rebuilt for that retry.

## Remaining decisions and checks

- The public App Store app is still 1.6 (46), with its older weight screenshot. No 1.7 App Store submission or public release was requested or made. A new version's approved screenshot must be replaced before public submission.
- The Nomva mark needs full trademark clearance or a rebrand decision. The icon's original source or generation record remains unconfirmed. The internal-only TestFlight build uses the existing branding.
- TestFlight availability does not establish installation or physical HealthKit, Garmin, camera, purchase, or restore acceptance.

Local evidence: `reports/release-47/archive-1.7.log`, `upload-1.7.log`, `asc-status-final.txt`, and the preserved archive at `/Users/jerrycrews/Library/Developer/Xcode/Archives/2026-09-23/Nomva 1.7-47-legal.xcarchive`.
